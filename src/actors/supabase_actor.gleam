// src/actors/supabase_actor.gleam - FIXED VERSION
import birl
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import glixir
import logging
import storage/metric_batch_store
import types/metric_types.{type MetricBatch}
import utils/utils

// ============================================================================
// TYPES
// ============================================================================

pub type Message {
  BatchMetric(metric: MetricBatch)
  FlushInterval(tick_type: String)
  ForceFlush
  Shutdown
}

pub type BatchingState {
  BatchingState(
    active_tick_types: Dict(String, Bool),
    // Track which tick types are active
    last_flush_time: Int,
    flush_counter: Int,
  )
}

// ============================================================================
// PUBLIC API
// ============================================================================

/// Start the SupabaseActor for batching metrics
pub fn start() -> Result(process.Subject(Message), actor.StartError) {
  logging.log(logging.Info, "[SupabaseActor] 🚀 Starting SupabaseActor")

  // Initialize ETS table for batching
  case metric_batch_store.init_batch_store() {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[SupabaseActor] ✅ Metric batch store initialized",
      )
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[SupabaseActor] Metric batch store already exists",
      )
    }
  }
  let initial_state =
    BatchingState(
      active_tick_types: dict.new(),
      last_flush_time: utils.current_timestamp(),
      flush_counter: 0,
    )
  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start()
  {
    Ok(started) -> {
      let subject = started.data

      // Register in registry for lookup
      case
        glixir.register_subject(
          utils.tracktags_registry(),
          utils.supabase_actor_key(),
          subject,
          glixir.atom_key_encoder,
        )
      {
        Ok(_) -> {
          logging.log(logging.Info, "[SupabaseActor] ✅ Registered in registry")
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[SupabaseActor] ❌ Failed to register: " <> string.inspect(e),
          )
        }
      }

      // Subscribe to "tick:all" to catch all tick intervals
      case
        glixir.pubsub_subscribe_with_registry_key(
          utils.clock_events_bus(),
          "tick:all",
          "actors@supabase_actor",
          "handle_supabase_tick",
          "supabase_flush_key",
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[SupabaseActor] ✅ Subscribed to tick:all for dynamic flushing",
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[SupabaseActor] ❌ Failed to subscribe: " <> string.inspect(e),
          )
        }
      }

      logging.log(logging.Info, "[SupabaseActor] ✅ SupabaseActor started")
      Ok(subject)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[SupabaseActor] ❌ Failed to start: " <> string.inspect(error),
      )
      Error(error)
    }
  }
}

/// Lookup SupabaseActor subject from registry
pub fn lookup_supabase_actor() -> Result(process.Subject(Message), String) {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.supabase_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("SupabaseActor not found in registry")
  }
}

/// Send a metric to SupabaseActor for batching
pub fn send_metric_batch(metric: MetricBatch) -> Result(Nil, String) {
  logging.log(
    logging.Info,
    "[SupabaseActor] 🔍 DEBUG: send_metric_batch called for: "
      <> metric.metric_name,
  )

  case lookup_supabase_actor() {
    Ok(subject) -> {
      logging.log(
        logging.Info,
        "[SupabaseActor] 🔍 DEBUG: Found SupabaseActor, sending batch",
      )
      process.send(subject, BatchMetric(metric))
      Ok(Nil)
    }
    Error(error) -> {
      logging.log(logging.Error, "[SupabaseActor] ❌ DEBUG: " <> error)
      Error(error)
    }
  }
}

// Handle ticks from ClockActor
pub fn handle_supabase_tick(_registry_key: String, json_message: String) -> Nil {
  // Parse the tick JSON to know which interval fired
  let tick_decoder = {
    use tick_name <- decode.field("tick_name", decode.string)
    use timestamp <- decode.field("timestamp", decode.string)
    decode.success(#(tick_name, timestamp))
  }

  case json.parse(json_message, tick_decoder) {
    Ok(#(tick_name, _timestamp)) -> {
      case tick_name {
        "tick_1s" -> Nil
        // Silent
        _ ->
          logging.log(
            logging.Info,
            "[SupabaseActor] 🔔 Received " <> tick_name <> " - flushing batches",
          )
      }
      case lookup_supabase_actor() {
        Ok(subject) -> {
          process.send(subject, FlushInterval(tick_name))
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "[SupabaseActor] ❌ Cannot find self for tick",
          )
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Warning,
        "[SupabaseActor] ❌ Invalid tick JSON: " <> json_message,
      )
    }
  }

  Nil
}

// ============================================================================
// MESSAGE HANDLING
// ============================================================================

fn handle_message(
  state: BatchingState,
  message: Message,
) -> actor.Next(BatchingState, Message) {
  case message {
    BatchMetric(metric) -> {
      logging.log(
        logging.Info,
        "[SupabaseActor] 📊 Received metric batch: "
          <> metric.business_id
          <> "/"
          <> metric.metric_name,
      )

      case metric_batch_store.add_batch(metric.flush_interval, metric) {
        Ok(_) -> logging.log(logging.Info, "[SupabaseActor] ✅ Stored batch")
        Error(e) ->
          logging.log(
            logging.Error,
            "[SupabaseActor] ❌ Store failed: " <> string.inspect(e),
          )
      }
      actor.continue(state)
    }
    FlushInterval(tick_type) -> {
      logging.log(
        logging.Info,
        "[SupabaseActor] 🚀 Flushing interval: " <> tick_type,
      )

      process.sleep(300)
      // 100ms delay
      flush_interval_to_supabase(tick_type, state)
    }

    ForceFlush -> {
      logging.log(logging.Info, "[SupabaseActor] 🔄 Force flush all intervals")
      // TODO: Flush all active intervals or implement differently
      actor.continue(state)
    }
    Shutdown -> {
      logging.log(logging.Info, "[SupabaseActor] 🛑 Shutdown requested")
      // Flush any pending metrics before shutdown
      actor.stop()
    }
  }
}

/// Convert MetricBatch to MetricRecord for Supabase (FIXED FIELD MAPPING)
fn batch_to_metric_record(batch: MetricBatch) -> supabase_client.MetricRecord {
  logging.log(
    logging.Info,
    "[SupabaseActor] 🔍 INCOMING BATCH: business_id='"
      <> batch.business_id
      <> "', client_id='"
      <> string.inspect(batch.client_id)
      <> "', scope='"
      <> batch.scope
      <> "'",
  )

  // Extract business_id and client_id from the account_id
  let #(actual_business_id, actual_client_id, actual_scope) = case
    string.contains(batch.business_id, ":")
  {
    True -> {
      // Client metric: "mobile_app:biz_001" -> business="biz_001", client="mobile_app"
      case string.split_once(batch.business_id, ":") {
        Ok(#(client_part, business_part)) -> {
          logging.log(
            logging.Info,
            "[SupabaseActor] 🔍 PARSED CLIENT METRIC: client='"
              <> client_part
              <> "', business='"
              <> business_part
              <> "'",
          )
          #(business_part, Some(client_part), "client")
        }
        Error(_) -> #(batch.business_id, None, "business")
      }
    }
    False -> {
      // Business metric: just business_id
      logging.log(
        logging.Info,
        "[SupabaseActor] 🔍 BUSINESS METRIC: business='"
          <> batch.business_id
          <> "'",
      )
      #(batch.business_id, None, "business")
    }
  }

  logging.log(
    logging.Info,
    "[SupabaseActor] 🔍 FINAL VALUES: business_id='"
      <> actual_business_id
      <> "', client_id='"
      <> string.inspect(actual_client_id)
      <> "', scope='"
      <> actual_scope
      <> "'",
  )

  supabase_client.MetricRecord(
    id: "will_be_generated",
    business_id: actual_business_id,
    client_id: actual_client_id,
    metric_name: batch.metric_name,
    value: float.to_string(batch.aggregated_value),
    metric_type: batch.metric_type,
    scope: actual_scope,
    adapters: batch.adapters,
    flushed_at: timestamp_to_iso(batch.window_end),
  )
}

// ============================================================================
// HELPERS
// ============================================================================

/// Convert Unix timestamp to ISO string using Birl
fn timestamp_to_iso(timestamp: Int) -> String {
  birl.from_unix(timestamp)
  |> birl.to_iso8601()
}

/// Flush a specific tick interval to Supabase
fn flush_interval_to_supabase(
  tick_type: String,
  state: BatchingState,
) -> actor.Next(BatchingState, Message) {
  // Get all batches for this tick interval
  let metric_batches = metric_batch_store.flush_interval(tick_type)
  let batch_count = list.length(metric_batches)

  logging.log(
    logging.Info,
    "[SupabaseActor] 🔍 DEBUG: flush_interval_to_supabase called for: "
      <> tick_type
      <> " found: "
      <> int.to_string(batch_count)
      <> " batches",
  )

  case batch_count {
    0 -> {
      logging.log(
        logging.Debug,
        "[SupabaseActor] No batches to flush for: " <> tick_type,
      )
      actor.continue(state)
    }
    _ -> {
      logging.log(
        logging.Info,
        "[SupabaseActor] 📤 Flushing "
          <> int.to_string(batch_count)
          <> " batches for: "
          <> tick_type,
      )

      // Convert MetricBatch list to MetricRecord list
      let metric_records = list.map(metric_batches, batch_to_metric_record)

      // Send to Supabase in single batch
      case supabase_client.store_metrics_batch(metric_records) {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[SupabaseActor] ✅ Batch insert successful for " <> tick_type,
          )

          // Clear the batches after successful flush
          case metric_batch_store.clear_interval(tick_type) {
            Ok(_) ->
              logging.log(
                logging.Debug,
                "[SupabaseActor] ✅ Cleared " <> tick_type <> " batches",
              )
            Error(e) ->
              logging.log(
                logging.Warning,
                "[SupabaseActor] ⚠️ Failed to clear: " <> string.inspect(e),
              )
          }
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[SupabaseActor] ❌ Batch insert failed for "
              <> tick_type
              <> ": "
              <> string.inspect(error),
          )
          // Keep batches for retry (don't clear on failure)
        }
      }

      actor.continue(state)
    }
  }
}
