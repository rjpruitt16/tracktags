import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/otp/actor
import gleam/string
import glixir
import glixir/supervisor
import logging
import storage/metric_store

pub type Message {
  RecordMetric(metric: Metric)
  FlushTick(timestamp: String, tick_type: String)
  CleanupTick(timestamp: String, tick_type: String)
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
    // NEW: Unix timestamp of last activity
    cleanup_after_seconds: Int,
    // NEW: Auto-cleanup threshold
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
  case
    glixir.lookup_subject(
      atom.create("tracktags_actors"),
      atom.create(key),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) ->
      Error("Metric actor not found: " <> account_id <> "/" <> metric_name)
  }
}

// Direct tick handler for PubSub
pub fn handle_tick_direct(registry_key: String, json_message: String) -> Nil {
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
              case tick_data.tick_name {
                "tick_5s" -> {
                  // Always send cleanup ticks for 5-second intervals
                  process.send(
                    subject,
                    CleanupTick(tick_data.timestamp, tick_data.tick_name),
                  )
                  logging.log(
                    logging.Debug,
                    "[MetricActor] ✅ Cleanup tick sent to: "
                      <> account_id
                      <> "/"
                      <> metric_name,
                  )
                }
                _ -> {
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
              }
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
        Error(decode_error) -> {
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
  tags_json: String,
  operation: String,
  cleanup_after_seconds: Int,
) -> Result(process.Subject(Message), actor.StartError) {
  logging.log(
    logging.Info,
    "[MetricActor] Starting: "
      <> account_id
      <> "/"
      <> metric_name
      <> " (flush: "
      <> tick_type
      <> ", cleanup_after: "
      <> int.to_string(cleanup_after_seconds)
      <> "s)",
  )

  let tags = parse_tags_json(tags_json)
  let timestamp = current_timestamp()

  let default_metric =
    Metric(
      account_id: account_id,
      metric_name: metric_name,
      value: initial_value,
      tags: tags,
      timestamp: timestamp,
    )

  let temp_state =
    State(
      default_metric: default_metric,
      current_metric: default_metric,
      tick_type: tick_type,
      last_accessed: timestamp,
      cleanup_after_seconds: cleanup_after_seconds,
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
  case
    metric_store.create_metric(account_id, metric_name, metric_operation, 0.0)
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Metric created in store: " <> metric_name,
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

  case
    actor.new(temp_state) |> actor.on_message(handle_message) |> actor.start
  {
    Ok(started) -> {
      let subject = started.data

      // Register in registry for lookup
      let key = account_id <> "_" <> metric_name
      case
        glixir.register_subject(
          atom.create("tracktags_actors"),
          atom.create(key),
          started.data,
          glixir.atom_key_encoder,
        )
      {
        Ok(_) ->
          logging.log(logging.Info, "[MetricActor] ✅ Registered: " <> key)
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
  let current_time = current_timestamp()

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
      flush_metrics(updated_state)
    }

    CleanupTick(timestamp, tick_type) -> {
      // Dedicated cleanup logic - check if we should self-destruct
      case updated_state.cleanup_after_seconds {
        -1 -> {
          // Should not happen since we don't subscribe to cleanup ticks when disabled
          logging.log(
            logging.Debug,
            "[MetricActor] Ignoring cleanup tick (cleanup disabled): "
              <> updated_state.default_metric.metric_name,
          )
          actor.continue(updated_state)
        }
        cleanup_threshold -> {
          let inactive_duration = current_time - updated_state.last_accessed
          case inactive_duration > cleanup_threshold {
            True -> {
              logging.log(
                logging.Info,
                "[MetricActor] 🧹 Auto-cleanup triggered for: "
                  <> updated_state.default_metric.metric_name
                  <> " (inactive for "
                  <> int.to_string(inactive_duration)
                  <> "s, threshold: "
                  <> int.to_string(cleanup_threshold)
                  <> "s)",
              )

              // Unregister from registry before self-destructing
              let key =
                updated_state.default_metric.account_id
                <> "_"
                <> updated_state.default_metric.metric_name
              case
                glixir.unregister_subject(
                  atom.create("tracktags_actors"),
                  atom.create(key),
                  glixir.atom_key_encoder,
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

              // Self-destruct
              actor.stop()
            }
            False -> {
              logging.log(
                logging.Debug,
                "[MetricActor] Still active: "
                  <> updated_state.default_metric.metric_name
                  <> " (inactive for "
                  <> int.to_string(inactive_duration)
                  <> "s)",
              )
              actor.continue(updated_state)
            }
          }
        }
      }
    }

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
      case
        glixir.unregister_subject(
          atom.create("tracktags_actors"),
          atom.create(key),
          glixir.atom_key_encoder,
        )
      {
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
  account_id: String,
  metric_name: String,
  tick_type: String,
  initial_value: Float,
  tags_json: String,
  operation: String,
  cleanup_after_seconds: Int,
  // NEW: Add cleanup parameter
) -> supervisor.ChildSpec(
  #(String, String, String, Float, String, String, Int),
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
      tags_json,
      operation,
      cleanup_after_seconds,
      // NEW: Pass cleanup parameter
    ),
    restart: supervisor.Permanent,
    shutdown_timeout: 5000,
    child_type: supervisor.Worker,
  )
}

fn flush_metrics(state: State) -> actor.Next(State, Message) {
  logging.log(
    logging.Info,
    "[MetricActor] 📊 Flushing metrics: " <> state.default_metric.metric_name,
  )
  metric_store.reset_metric(
    state.default_metric.account_id,
    state.default_metric.metric_name,
    state.default_metric.value,
  )
  actor.continue(State(..state, current_metric: state.default_metric))
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
