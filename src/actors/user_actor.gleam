import actors/metric_actor
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string
import glixir
import glixir/supervisor
import logging
import storage/metric_store

pub type Message {
  RecordMetric(
    metric_id: String,
    metric: metric_actor.Metric,
    initial_value: Float,
    tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: metric_actor.MetricType,
  )
  CleanupTick(timestamp: String, tick_type: String)
  // NEW: For user cleanup
  GetMetricActor(
    metric_name: String,
    reply_with: process.Subject(Option(process.Subject(metric_actor.Message))),
  )
  Shutdown
}

pub type State {
  State(
    account_id: String,
    metrics_supervisor: glixir.DynamicSupervisor(
      #(String, String, String, Float, String, String, Int, String),
      process.Subject(metric_actor.Message),
    ),
    last_accessed: Int,
    // NEW: Track user activity
    user_cleanup_threshold: Int,
    // NEW: Cleanup after 1 hour of inactivity
  )
}

// Helper functions for consistent naming
pub fn user_subject_name(account_id: String) -> String {
  "tracktags_user_" <> account_id
}

pub fn lookup_user_subject(
  account_id: String,
) -> Result(process.Subject(Message), String) {
  case
    glixir.lookup_subject(
      atom.create("tracktags_actors"),
      atom.create(account_id),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("User actor not found: " <> account_id)
  }
}

// Encoder function for metric actor arguments - NOW WITH CLEANUP
fn encode_metric_args(
  args: #(String, String, String, Float, String, String, Int, String),
) -> List(dynamic.Dynamic) {
  let #(
    account_id,
    metric_name,
    tick_type,
    initial_value,
    tags_json,
    operation,
    cleanup_after_seconds,
    metric_type,
  ) = args
  [
    dynamic.string(account_id),
    dynamic.string(metric_name),
    dynamic.string(tick_type),
    dynamic.float(initial_value),
    dynamic.string(tags_json),
    dynamic.string(operation),
    dynamic.int(cleanup_after_seconds),
    dynamic.string(metric_type),
  ]
}

fn decode_metric_reply(
  _reply: dynamic.Dynamic,
) -> Result(process.Subject(metric_actor.Message), String) {
  Ok(process.new_subject())
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  let current_time = current_timestamp()

  // Update last_accessed for user activity
  let updated_state = case message {
    RecordMetric(_, _, _, _, _, _, _) ->
      State(..state, last_accessed: current_time)
    _ -> state
  }

  logging.log(
    logging.Debug,
    "[UserActor] Received message: " <> string.inspect(message),
  )

  case message {
    CleanupTick(timestamp, tick_type) -> {
      // Check if user should be cleaned up due to inactivity
      let inactive_duration = current_time - updated_state.last_accessed

      case inactive_duration > updated_state.user_cleanup_threshold {
        True -> {
          logging.log(
            logging.Info,
            "[UserActor] 🧹 User cleanup triggered: "
              <> updated_state.account_id
              <> " (inactive for "
              <> int.to_string(inactive_duration)
              <> "s, threshold: "
              <> int.to_string(updated_state.user_cleanup_threshold)
              <> "s)",
          )

          // Clean up the store before self-destructing
          case metric_store.cleanup_store(updated_state.account_id) {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[UserActor] ✅ Store cleanup successful: "
                  <> updated_state.account_id,
              )
            Error(error) ->
              logging.log(
                logging.Error,
                "[UserActor] ❌ Store cleanup failed: " <> string.inspect(error),
              )
          }

          // Unregister and self-destruct
          case
            glixir.unregister_subject(
              atom.create("tracktags_actors"),
              atom.create(updated_state.account_id),
              glixir.atom_key_encoder,
            )
          {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[UserActor] ✅ Unregistered user: " <> updated_state.account_id,
              )
            Error(_) ->
              logging.log(
                logging.Warning,
                "[UserActor] ⚠️ Failed to unregister user: "
                  <> updated_state.account_id,
              )
          }

          actor.stop()
        }
        False -> {
          logging.log(
            logging.Debug,
            "[UserActor] User still active: "
              <> updated_state.account_id
              <> " (inactive for "
              <> int.to_string(inactive_duration)
              <> "s)",
          )
          actor.continue(updated_state)
        }
      }
    }

    RecordMetric(
      metric_id,
      metric,
      initial_value,
      tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
    ) -> {
      // ... existing RecordMetric logic stays the same ...
      actor.continue(updated_state)
      // Use updated_state with new last_accessed
    }

    GetMetricActor(metric_name, reply_with) -> {
      // ... existing GetMetricActor logic stays the same ...
      actor.continue(updated_state)
    }

    Shutdown -> {
      logging.log(
        logging.Info,
        "[UserActor] Shutting down: " <> updated_state.account_id,
      )

      // Clean up store on explicit shutdown
      case metric_store.cleanup_store(updated_state.account_id) {
        Ok(_) ->
          logging.log(
            logging.Info,
            "[UserActor] ✅ Store cleanup on shutdown: "
              <> updated_state.account_id,
          )
        Error(error) ->
          logging.log(
            logging.Error,
            "[UserActor] ❌ Store cleanup failed on shutdown: "
              <> string.inspect(error),
          )
      }

      actor.stop()
    }
  }
}

// Encoder function for user actor arguments
fn encode_user_args(account_id: String) -> List(dynamic.Dynamic) {
  [dynamic.string(account_id)]
}

// start_link function for bridge to call
pub fn start_link(
  account_id: String,
) -> Result(process.Subject(Message), actor.StartError) {
  logging.log(logging.Info, "[UserActor] Starting for account: " <> account_id)

  case
    glixir.start_dynamic_supervisor_named(atom.create("metrics_" <> account_id))
  {
    Ok(metrics_supervisor) -> {
      logging.log(
        logging.Debug,
        "[UserActor] ✅ Metrics supervisor started for " <> account_id,
      )

      let current_time = current_timestamp()
      let state =
        State(
          account_id: account_id,
          metrics_supervisor: metrics_supervisor,
          last_accessed: current_time,
          user_cleanup_threshold: 3600,
          // 1 hour = 3600 seconds
        )

      case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
        Ok(started) -> {
          // Register in registry for lookup
          case
            glixir.register_subject(
              atom.create("tracktags_actors"),
              atom.create(account_id),
              started.data,
              glixir.atom_key_encoder,
            )
          {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[UserActor] ✅ Registered: " <> account_id,
              )
            Error(_) ->
              logging.log(
                logging.Error,
                "[UserActor] ❌ Failed to register: " <> account_id,
              )
          }

          // Subscribe to cleanup ticks (5-second intervals for checking)
          case
            glixir.pubsub_subscribe_with_registry_key(
              atom.create("clock_events"),
              "tick:tick_5s",
              "actors@user_actor",
              // NEW: Need user_actor handler
              "handle_user_cleanup_tick",
              // NEW: Handler function
              account_id,
              // Registry key = account_id
            )
          {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[UserActor] ✅ User cleanup subscription for: " <> account_id,
              )
            }
            Error(e) -> {
              logging.log(
                logging.Error,
                "[UserActor] ❌ Failed user cleanup subscription: "
                  <> string.inspect(e),
              )
            }
          }

          Ok(started.data)
        }
        Error(error) -> Error(error)
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[UserActor] ❌ Failed to start metrics supervisor: "
          <> string.inspect(error),
      )
      Error(actor.InitFailed("Failed to start metrics supervisor"))
    }
  }
}

pub fn handle_user_cleanup_tick(
  registry_key: String,
  json_message: String,
) -> Nil {
  let account_id = registry_key

  logging.log(
    logging.Debug,
    "[UserActor] 🎯 Cleanup tick for user: " <> account_id,
  )

  case lookup_user_subject(account_id) {
    Ok(user_subject) -> {
      // Parse the tick data (reuse same JSON structure)
      let tick_decoder = {
        use tick_name <- decode.field("tick_name", decode.string)
        use timestamp <- decode.field("timestamp", decode.string)
        decode.success(#(tick_name, timestamp))
      }

      case json.parse(json_message, tick_decoder) {
        Ok(#(tick_name, timestamp)) -> {
          process.send(user_subject, CleanupTick(timestamp, tick_name))
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[UserActor] ❌ Invalid cleanup tick JSON for: " <> account_id,
          )
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Debug,
        "[UserActor] User not found for cleanup tick: " <> account_id,
      )
    }
  }
}

// Returns glixir.ChildSpec for dynamic spawning
pub fn start(
  account_id: String,
) -> glixir.ChildSpec(String, process.Subject(Message)) {
  glixir.child_spec(
    id: "user_" <> account_id,
    module: "Elixir.UserActorBridge",
    function: "start_link",
    args: account_id,
    restart: glixir.permanent,
    shutdown_timeout: 5000,
    child_type: glixir.worker,
    encode: encode_user_args,
  )
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
