import actors/supabase_actor
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import glixir
import glixir/supervisor
import logging
import storage/metric_store
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

pub type Message {
  RecordMetric(metric: Metric)
  FlushTick(timestamp: String, tick_type: String)
  ForceFlush
  GetStatus(reply_with: process.Subject(Metric))
  Shutdown
}

pub type Metric {
  Metric(
    account_id: String,
    metric_name: String,
    value: Float,
    tags: Dict(String, String),
    timestamp: Int,
  )
}

// Updated state with cleanup tracking
pub type State {
  State(
    default_metric: Metric,
    current_metric: Metric,
    tick_type: String,
    last_accessed: Int,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    initial_value: Float,
    metadata: Option(MetricMetadata),
    metric_operation: metric_store.Operation,
    last_flushed_value: Float,
  )
}

// Tick data type for JSON decoding
pub type TickData {
  TickData(tick_name: String, timestamp: String)
}

// Helper functions for consistent naming
pub fn metric_subject_name(account_id: String, metric_name: String) -> String {
  "tracktags_metric_" <> account_id <> "_" <> metric_name
}

pub fn lookup_metric_subject(
  account_id: String,
  metric_name: String,
) -> Result(process.Subject(Message), String) {
  let key = account_id <> "_" <> metric_name
  case glixir.lookup_subject_string(utils.tracktags_registry(), key) {
    Ok(subject) -> Ok(subject)
    Error(_) ->
      Error("Metric actor not found: " <> account_id <> "/" <> metric_name)
  }
}

// Direct tick handler for PubSub
pub fn handle_tick_direct(registry_key: String, json_message: String) -> Nil {
  logging.log(
    logging.Info,
    "[MetricActor] 🎯 DEBUG: handle_tick_direct called for: " <> registry_key,
  )
  // Parse account_id and metric_name - split only on FIRST underscore
  case string.split_once(registry_key, "_") {
    Ok(#(account_id, metric_name)) -> {
      logging.log(
        logging.Debug,
        "[MetricActor] 🎯 Direct tick for: " <> account_id <> "/" <> metric_name,
      )

      // JSON decoder for tick data
      let tick_decoder = {
        use tick_name <- decode.field("tick_name", decode.string)
        use timestamp <- decode.field("timestamp", decode.string)
        decode.success(TickData(tick_name: tick_name, timestamp: timestamp))
      }

      case json.parse(json_message, tick_decoder) {
        Ok(tick_data) -> {
          // Direct lookup and send - route to appropriate message type
          case lookup_metric_subject(account_id, metric_name) {
            Ok(subject) -> {
              // Route based on tick type
              // All other ticks are flush ticks (if they match the metric's flush interval)
              process.send(
                subject,
                FlushTick(tick_data.timestamp, tick_data.tick_name),
              )
              logging.log(
                logging.Debug,
                "[MetricActor] ✅ Flush tick sent to: "
                  <> account_id
                  <> "/"
                  <> metric_name,
              )
            }
            Error(_) -> {
              logging.log(
                logging.Error,
                "[MetricActor] ❌ Actor not found: "
                  <> account_id
                  <> "/"
                  <> metric_name,
              )
            }
          }
        }
        Error(_decode_error) -> {
          logging.log(
            logging.Warning,
            "[MetricActor] ❌ Invalid tick JSON: " <> json_message,
          )
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Error,
        "[MetricActor] ❌ Invalid registry key format: " <> registry_key,
      )
    }
  }
}

// Helper to parse JSON tags (simple version for now)
fn parse_tags_json(tags_json: String) -> Dict(String, String) {
  case tags_json {
    "{}" -> dict.new()
    "" -> dict.new()
    _ -> dict.new()
  }
}

// start_link function with cleanup support
pub fn start_link(
  account_id: String,
  metric_name: String,
  tick_type: String,
  initial_value: Float,
  tags_string: String,
  operation: String,
  cleanup_after_seconds: Int,
  metric_type: String,
  metadata_json: String,
) -> Result(process.Subject(Message), actor.StartError) {
  logging.log(
    logging.Info,
    "[MetricActor] Starting: "
      <> account_id
      <> "/"
      <> metric_name
      <> " (flush: "
      <> tick_type
      <> ", initial value: "
      <> float.to_string(initial_value)
      <> ", tags value: "
      <> tags_string
      <> ", cleanup_after_seconds: "
      <> int.to_string(cleanup_after_seconds)
      <> ", metric_type: "
      <> metric_type
      <> ", cleanup_after: "
      <> int.to_string(cleanup_after_seconds)
      <> ")"
      <> ", metric_json: "
      <> metadata_json,
  )

  let tags = parse_tags_json(tags_string)
  let timestamp = utils.current_timestamp()

  let default_metric =
    Metric(
      account_id: account_id,
      metric_name: metric_name,
      value: initial_value,
      tags: tags,
      timestamp: timestamp,
    )

  let metric_operation = case string.uppercase(operation) {
    "SUM" -> metric_store.Sum
    "AVG" -> metric_store.Average
    "MIN" -> metric_store.Min
    "MAX" -> metric_store.Max
    "COUNT" -> metric_store.Count
    "LAST" -> metric_store.Last
    _ -> metric_store.Sum
  }
  let state =
    State(
      default_metric: default_metric,
      current_metric: default_metric,
      tick_type: tick_type,
      last_accessed: timestamp,
      cleanup_after_seconds: cleanup_after_seconds,
      metric_type: metric_types.string_to_metric_type(metric_type),
      initial_value: initial_value,
      metadata: metric_types.decode_metadata_from_string(metadata_json),
      metric_operation: metric_operation,
      last_flushed_value: initial_value,
    )

  case metric_store.init_store(account_id) {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Store initialized for: " <> account_id,
      )
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[MetricActor] Store already exists for: " <> account_id,
      )
    }
  }

  // Create the metric in ETS
  let restored_value = case state.metric_type {
    metric_types.Checkpoint -> {
      case
        metric_types.should_send_to_supabase(state.metric_type, state.metadata)
      {
        True -> {
          logging.log(
            logging.Info,
            "[MetricActor] 🔍 Attempting to restore checkpoint from Supabase: "
              <> metric_name,
          )
          case
            supabase_client.get_latest_metric_value(account_id, metric_name)
          {
            Ok(restored_value) -> {
              logging.log(
                logging.Info,
                "[MetricActor] ✅ Restored from Supabase: "
                  <> float.to_string(restored_value),
              )
              restored_value
            }
            Error(supabase_client.NotFound(_)) -> {
              logging.log(
                logging.Info,
                "[MetricActor] 📋 No previous value in Supabase, using initial: "
                  <> float.to_string(initial_value),
              )
              initial_value
            }
            Error(error) -> {
              logging.log(
                logging.Warning,
                "[MetricActor] ⚠️ Supabase restore failed: "
                  <> string.inspect(error)
                  <> ", using initial value",
              )
              initial_value
            }
          }
        }
        False -> {
          logging.log(
            logging.Info,
            "[MetricActor] 💰 Supabase disabled for this checkpoint (saving money!), using initial: "
              <> float.to_string(initial_value),
          )
          initial_value
        }
      }
    }
    metric_types.Reset -> {
      logging.log(
        logging.Info,
        "[MetricActor] 🔄 Reset metric, using initial value: "
          <> float.to_string(initial_value),
      )
      initial_value
    }
  }

  // Create the metric in ETS with the restored/initial value
  case
    metric_store.create_metric(
      account_id,
      metric_name,
      metric_operation,
      restored_value,
    )
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Metric created in store: "
          <> metric_name
          <> " = "
          <> float.to_string(restored_value),
      )
    }
    Error(e) -> {
      logging.log(
        logging.Warning,
        "[MetricActor] ⚠️ Metric creation error (might already exist): "
          <> string.inspect(e),
      )
    }
  }

  case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
    Ok(started) -> {
      let subject = started.data

      // Register in registry for lookup
      let key = account_id <> "_" <> metric_name
      case
        glixir.register_subject_string(
          utils.tracktags_registry(),
          key,
          started.data,
        )
      {
        Ok(_) ->
          logging.log(logging.Info, "[MetricActor] ✅ eegistered: " <> key)
        Error(_) ->
          logging.log(
            logging.Error,
            "[MetricActor] ❌ Failed to register: " <> key,
          )
      }

      // SUBSCRIPTION 1: Flush ticks (original behavior)
      case
        glixir.pubsub_subscribe_with_registry_key(
          atom.create("clock_events"),
          "tick:" <> tick_type,
          "actors@metric_actor",
          "handle_tick_direct",
          account_id <> "_" <> metric_name,
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[MetricActor] ✅ Flush subscription: "
              <> tick_type
              <> " for "
              <> key,
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[MetricActor] ❌ Failed flush subscription: " <> string.inspect(e),
          )
        }
      }

      // SUBSCRIPTION 2: Cleanup ticks (NEW - always subscribe to 5s for cleanup)
      case cleanup_after_seconds {
        -1 -> {
          // No cleanup needed
          logging.log(
            logging.Info,
            "[MetricActor] ⏳ No cleanup subscription (cleanup disabled) for: "
              <> key,
          )
        }
        _ -> {
          // Subscribe to 5-second ticks for cleanup checks
          case
            glixir.pubsub_subscribe_with_registry_key(
              atom.create("clock_events"),
              "tick:tick_5s",
              "actors@metric_actor",
              "handle_tick_direct",
              account_id <> "_" <> metric_name,
            )
          {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[MetricActor] ✅ Cleanup subscription: tick_5s for " <> key,
              )
            }
            Error(e) -> {
              logging.log(
                logging.Error,
                "[MetricActor] ❌ Failed cleanup subscription: "
                  <> string.inspect(e),
              )
            }
          }
        }
      }

      logging.log(
        logging.Info,
        "[MetricActor] ✅ MetricActor started with dual subscriptions: "
          <> metric_name,
      )
      Ok(subject)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[MetricActor] ❌ Failed to start "
          <> metric_name
          <> ": "
          <> string.inspect(error),
      )
      Error(error)
    }
  }
}

// Clean message handler with lazy cleanup support
fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  let current_time = utils.current_timestamp()

  // Update last_accessed timestamp for relevant operations
  let updated_state = case message {
    RecordMetric(_) | GetStatus(_) ->
      State(..state, last_accessed: current_time)
    _ -> state
  }

  logging.log(
    logging.Debug,
    "[MetricActor] Processing message: "
      <> updated_state.default_metric.account_id
      <> "/"
      <> updated_state.default_metric.metric_name,
  )

  case message {
    RecordMetric(metric) -> {
      // Store in ETS instead of just state
      case
        metric_store.add_value(
          updated_state.default_metric.account_id,
          updated_state.default_metric.metric_name,
          metric.value,
        )
      {
        Ok(new_value) -> {
          logging.log(
            logging.Info,
            "[MetricActor] Value updated: " <> float.to_string(new_value),
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[MetricActor] Store error: " <> string.inspect(e),
          )
        }
      }
      actor.continue(updated_state)
    }

    FlushTick(timestamp, tick_type) -> {
      logging.log(
        logging.Info,
        "[MetricActor] 📊 Flushing "
          <> updated_state.default_metric.metric_name
          <> " on "
          <> tick_type
          <> " at "
          <> timestamp,
      )

      // ✅ Call flush_metrics_and_get_state to get the updated state
      let flushed_state = flush_metrics_and_get_state(updated_state)

      case flushed_state.cleanup_after_seconds {
        -1 -> {
          logging.log(
            logging.Debug,
            "[MetricActor] Ignoring cleanup tick (cleanup disabled): "
              <> flushed_state.default_metric.metric_name,
          )
          actor.continue(flushed_state)
          // ✅ Use flushed_state
        }
        cleanup_threshold -> {
          let inactive_duration = current_time - flushed_state.last_accessed
          case inactive_duration > cleanup_threshold {
            True -> {
              logging.log(
                logging.Info,
                "[MetricActor] 🧹 Auto-cleanup triggered for: "
                  <> flushed_state.default_metric.metric_name
                  <> " (inactive for "
                  <> int.to_string(inactive_duration)
                  <> "s, threshold: "
                  <> int.to_string(cleanup_threshold)
                  <> "s)",
              )

              let key =
                flushed_state.default_metric.account_id
                <> "_"
                <> flushed_state.default_metric.metric_name
              case
                glixir.unregister_subject_string(
                  utils.tracktags_registry(),
                  key,
                )
              {
                Ok(_) ->
                  logging.log(
                    logging.Info,
                    "[MetricActor] ✅ Unregistered during cleanup: " <> key,
                  )
                Error(_) ->
                  logging.log(
                    logging.Warning,
                    "[MetricActor] ⚠️ Failed to unregister during cleanup: "
                      <> key,
                  )
              }
              actor.stop()
            }
            False -> {
              logging.log(
                logging.Debug,
                "[MetricActor] Still active: "
                  <> flushed_state.default_metric.metric_name
                  <> " (inactive for "
                  <> int.to_string(inactive_duration)
                  <> "s)",
              )
              actor.continue(flushed_state)
              // ✅ Use flushed_state
            }
          }
        }
      }
    }
    // Dedicated cleanup logic - check if we should self-destruct
    ForceFlush -> flush_metrics(updated_state)

    GetStatus(reply_with) -> {
      process.send(reply_with, updated_state.current_metric)
      actor.continue(updated_state)
    }

    Shutdown -> {
      logging.log(
        logging.Info,
        "[MetricActor] Shutting down: "
          <> updated_state.default_metric.metric_name,
      )

      // Unregister from registry before stopping
      let key =
        updated_state.default_metric.account_id
        <> "_"
        <> updated_state.default_metric.metric_name
      case glixir.unregister_subject_string(utils.tracktags_registry(), key) {
        Ok(_) ->
          logging.log(logging.Info, "[MetricActor] ✅ Unregistered: " <> key)
        Error(_) ->
          logging.log(
            logging.Warning,
            "[MetricActor] ⚠️ Failed to unregister: " <> key,
          )
      }

      actor.stop()
    }
  }
}

pub fn start(
  account_id account_id: String,
  metric_name metric_name: String,
  tick_type tick_type: String,
  initial_value initial_value: Float,
  tags tags: String,
  operation operation: String,
  cleanup_after_seconds cleanup_after_seconds: Int,
  metric_type metric_type: String,
  metadata metadata: String,
) -> supervisor.ChildSpec(
  #(String, String, String, Float, String, String, Int, String, String),
  process.Subject(Message),
) {
  supervisor.ChildSpec(
    id: "metric_" <> account_id <> "_" <> metric_name,
    start_module: atom.create("Elixir.MetricActorBridge"),
    start_function: atom.create("start_link"),
    start_args: #(
      account_id,
      metric_name,
      tick_type,
      initial_value,
      tags,
      operation,
      cleanup_after_seconds,
      metric_type,
      metadata,
    ),
    restart: supervisor.Permanent,
    shutdown_timeout: 5000,
    child_type: supervisor.Worker,
  )
}

// FIXED: Updated flush_metrics function for MetricActor
fn flush_metrics(state: State) -> actor.Next(State, Message) {
  logging.log(
    logging.Info,
    "[MetricActor] 📊 Flushing metrics: " <> state.default_metric.metric_name,
  )

  // Get current value from metric store
  let current_value = case
    metric_store.get_value(
      state.default_metric.account_id,
      state.default_metric.metric_name,
    )
  {
    Ok(value) -> value
    Error(_) -> state.initial_value
  }

  // Calculate diff since last flush
  let diff = current_value -. state.last_flushed_value

  logging.log(
    logging.Info,
    "[MetricActor] 🔍 Flush diff: current="
      <> float.to_string(current_value)
      <> ", last_flushed="
      <> float.to_string(state.last_flushed_value)
      <> ", diff="
      <> float.to_string(diff),
  )

  // Determine new last_flushed_value based on whether we send to Supabase
  let new_last_flushed_value = case
    metric_types.should_send_to_supabase(state.metric_type, state.metadata)
  {
    True -> {
      case diff {
        0.0 -> {
          logging.log(
            logging.Info,
            "[MetricActor] 📊 No change since last flush, skipping Supabase",
          )
          state.last_flushed_value
          // No change
        }
        _ -> {
          let #(business_id, client_id, scope) =
            metric_types.parse_account_id(state.default_metric.account_id)
          let batch =
            metric_types.MetricBatch(
              business_id: business_id,
              client_id: client_id,
              metric_name: state.default_metric.metric_name,
              aggregated_value: diff,
              operation_count: 1,
              metric_type: metric_types.metric_type_to_string(state.metric_type),
              window_start: utils.current_timestamp(),
              window_end: utils.current_timestamp(),
              flush_interval: metric_types.get_supabase_batch_interval(
                state.metadata,
              ),
              scope: scope,
              adapters: metric_types.metadata_to_adapters(state.metadata),
              metric_mode: metric_types.Simple(
                convert_metric_store_operation_to_simple(state.metric_operation),
              ),
            )

          case supabase_actor.send_metric_batch(batch) {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[MetricActor] ✅ Sent diff to SupabaseActor: "
                  <> float.to_string(diff),
              )
              current_value
              // ✅ Update to current value on success
            }
            Error(e) -> {
              logging.log(logging.Warning, "[MetricActor] ⚠️ Failed: " <> e)
              state.last_flushed_value
              // Keep old value on failure
            }
          }
        }
      }
    }
    False -> {
      logging.log(
        logging.Debug,
        "[MetricActor] Skipping Supabase for this metric type",
      )
      state.last_flushed_value
      // No change when not sending to Supabase
    }
  }

  // Handle metric type specific behavior (reset vs checkpoint)
  case state.metric_type {
    metric_types.Checkpoint -> {
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Checkpoint metric (keeping current value)",
      )
    }
    metric_types.Reset -> {
      logging.log(logging.Info, "[MetricActor] 🔄 Reset metric to initial value")
      case
        metric_store.reset_metric(
          state.default_metric.account_id,
          state.default_metric.metric_name,
          state.initial_value,
        )
      {
        Ok(_) -> logging.log(logging.Info, "[MetricActor] ✅ Reset successful")
        Error(e) ->
          logging.log(
            logging.Warning,
            "[MetricActor] ⚠️ Reset failed: " <> string.inspect(e),
          )
      }
    }
  }

  // ✅ Update state with new last_flushed_value
  actor.continue(
    State(
      ..state,
      current_metric: state.default_metric,
      last_flushed_value: new_last_flushed_value,
    ),
  )
}

/// Convert metric_store.Operation to metric_types.SimpleOperation
fn convert_metric_store_operation_to_simple(
  operation: metric_store.Operation,
) -> metric_types.SimpleOperation {
  case operation {
    metric_store.Sum -> metric_types.Sum
    metric_store.Min -> metric_types.Min
    metric_store.Max -> metric_types.Max
    metric_store.Average -> metric_types.Average
    metric_store.Count -> metric_types.Count
    metric_store.Last -> metric_types.Sum
    // Fallback
  }
}

// Helper function to flush metrics and return just the state
fn flush_metrics_and_get_state(state: State) -> State {
  logging.log(
    logging.Info,
    "[MetricActor] 📊 Flushing metrics: " <> state.default_metric.metric_name,
  )

  // Get current value from metric store
  let current_value = case
    metric_store.get_value(
      state.default_metric.account_id,
      state.default_metric.metric_name,
    )
  {
    Ok(value) -> value
    Error(_) -> state.initial_value
  }

  // Calculate diff since last flush
  let diff = current_value -. state.last_flushed_value

  logging.log(
    logging.Info,
    "[MetricActor] 🔍 Flush diff: current="
      <> float.to_string(current_value)
      <> ", last_flushed="
      <> float.to_string(state.last_flushed_value)
      <> ", diff="
      <> float.to_string(diff),
  )

  // Determine new last_flushed_value based on whether we send to Supabase
  let new_last_flushed_value = case
    metric_types.should_send_to_supabase(state.metric_type, state.metadata)
  {
    True -> {
      case diff {
        0.0 -> {
          logging.log(
            logging.Info,
            "[MetricActor] 📊 No change since last flush, skipping Supabase",
          )
          state.last_flushed_value
        }
        _ -> {
          // Parse the account_id to determine business_id, client_id, and scope
          let #(business_id, client_id, scope) =
            metric_types.parse_account_id(state.default_metric.account_id)

          // Check if we should flush immediately (same interval) or batch for later
          let supabase_batch_interval =
            metric_types.get_supabase_batch_interval(state.metadata)
          let current_tick_interval = "tick_" <> state.tick_type

          logging.log(
            logging.Info,
            "[MetricActor] 🔍 Comparing intervals: supabase="
              <> supabase_batch_interval
              <> ", current="
              <> current_tick_interval,
          )

          case supabase_batch_interval == current_tick_interval {
            True -> {
              // Same interval - flush immediately to avoid race condition
              logging.log(
                logging.Info,
                "[MetricActor] 🚀 Same interval flush (immediate): "
                  <> supabase_batch_interval,
              )
              case
                supabase_client.store_metric(
                  business_id,
                  client_id,
                  state.default_metric.metric_name,
                  float.to_string(diff),
                  metric_types.metric_type_to_string(state.metric_type),
                  scope,
                  None,
                  None,
                  None,
                  None,
                  None,
                )
              {
                Ok(_) -> {
                  logging.log(
                    logging.Info,
                    "[MetricActor] ✅ Direct flush to Supabase: "
                      <> float.to_string(diff),
                  )
                  current_value
                }
                Error(e) -> {
                  logging.log(
                    logging.Warning,
                    "[MetricActor] ⚠️ Direct flush failed: " <> string.inspect(e),
                  )
                  state.last_flushed_value
                }
              }
            }
            False -> {
              // Different interval - use batch system
              logging.log(
                logging.Info,
                "[MetricActor] 📦 Batching for later flush: "
                  <> supabase_batch_interval,
              )
              let batch =
                metric_types.MetricBatch(
                  business_id: business_id,
                  client_id: client_id,
                  metric_name: state.default_metric.metric_name,
                  aggregated_value: diff,
                  operation_count: 1,
                  metric_type: metric_types.metric_type_to_string(
                    state.metric_type,
                  ),
                  window_start: utils.current_timestamp(),
                  window_end: utils.current_timestamp(),
                  flush_interval: supabase_batch_interval,
                  scope: scope,
                  adapters: None,
                  metric_mode: metric_types.Simple(
                    convert_metric_store_operation_to_simple(
                      state.metric_operation,
                    ),
                  ),
                )
              case supabase_actor.send_metric_batch(batch) {
                Ok(_) -> {
                  logging.log(
                    logging.Info,
                    "[MetricActor] ✅ Sent diff to SupabaseActor: "
                      <> float.to_string(diff),
                  )
                  current_value
                }
                Error(e) -> {
                  logging.log(logging.Warning, "[MetricActor] ⚠️ Failed: " <> e)
                  state.last_flushed_value
                }
              }
            }
          }
        }
      }
    }
    False -> {
      logging.log(
        logging.Debug,
        "[MetricActor] Skipping Supabase for this metric type",
      )
      state.last_flushed_value
    }
  }

  // Handle metric type specific behavior (reset vs checkpoint)
  case state.metric_type {
    metric_types.Checkpoint -> {
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Checkpoint metric (keeping current value)",
      )
    }
    metric_types.Reset -> {
      logging.log(logging.Info, "[MetricActor] 🔄 Reset metric to initial value")
      case
        metric_store.reset_metric(
          state.default_metric.account_id,
          state.default_metric.metric_name,
          state.initial_value,
        )
      {
        Ok(_) -> logging.log(logging.Info, "[MetricActor] ✅ Reset successful")
        Error(e) ->
          logging.log(
            logging.Warning,
            "[MetricActor] ⚠️ Reset failed: " <> string.inspect(e),
          )
      }
    }
  }

  // ✅ Return the updated state
  State(
    ..state,
    current_metric: state.default_metric,
    last_flushed_value: new_last_flushed_value,
  )
}
