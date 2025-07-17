// src/actors/user_actor.gleam 
import actors/metric_actor
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string
import glixir
import glixir/supervisor
import logging
import storage/metric_store
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

pub type Message {
  RecordMetric(
    metric_name: String,
    initial_value: Float,
    tick_type: String,
    supabase_tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
  )
  CleanupTick(timestamp: String, tick_type: String)
  GetMetricActor(
    metric_name: String,
    reply_with: process.Subject(Option(process.Subject(metric_actor.Message))),
  )
  Shutdown
}

pub type State {
  State(
    account_id: String,
    // FIXED: Updated tuple type to match bridge (10 args)
    metrics_supervisor: glixir.DynamicSupervisor(
      #(
        String,
        String,
        String,
        String,
        Float,
        String,
        String,
        Int,
        String,
        String,
      ),
      process.Subject(metric_actor.Message),
    ),
    last_accessed: Int,
    user_cleanup_threshold: Int,
  )
}

// Helper functions for consistent naming
pub fn user_subject_name(account_id: String) -> String {
  "tracktags_user_" <> account_id
}

pub fn lookup_user_subject(
  account_id: String,
) -> Result(process.Subject(Message), String) {
  case glixir.lookup_subject_string(utils.tracktags_registry(), account_id) {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("User actor not found: " <> account_id)
  }
}

pub fn dict_to_string(tags: Dict(String, String)) -> String {
  dict.fold(tags, "", fn(accumulator, key, value) {
    string.append(accumulator, "key: " <> key <> " value: " <> value)
  })
}

// FIXED: Updated encoder function to match bridge signature (10 args)
fn encode_metric_args(
  args: #(
    String,
    String,
    String,
    String,
    Float,
    String,
    String,
    Int,
    String,
    String,
  ),
) -> List(dynamic.Dynamic) {
  let #(
    account_id,
    metric_name,
    tick_type,
    supabase_tick_type,
    initial_value,
    tags_json,
    operation,
    cleanup_after_seconds,
    metric_type,
    metadata,
  ) = args
  [
    dynamic.string(account_id),
    dynamic.string(metric_name),
    dynamic.string(tick_type),
    dynamic.string(supabase_tick_type),
    dynamic.float(initial_value),
    dynamic.string(tags_json),
    dynamic.string(operation),
    dynamic.int(cleanup_after_seconds),
    dynamic.string(metric_type),
    dynamic.string(metadata),
  ]
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  let current_time = utils.current_timestamp()

  // Update last_accessed for user activity
  let updated_state = case message {
    RecordMetric(_, _, _, _, _, _, _, _, _) ->
      State(..state, last_accessed: current_time)
    _ -> state
  }

  logging.log(
    logging.Debug,
    "[UserActor] Processing message for: " <> updated_state.account_id,
  )

  case message {
    CleanupTick(_timestamp, _tick_type) -> {
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
            glixir.unregister_subject_string(
              utils.tracktags_registry(),
              updated_state.account_id,
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
      metric_name,
      initial_value,
      tick_type,
      supabase_tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
      tags,
      metadata,
    ) -> {
      logging.log(
        logging.Info,
        "[UserActor] Processing metric: "
          <> updated_state.account_id
          <> "/"
          <> metric_name
          <> " (operation: "
          <> operation
          <> ")",
      )

      // SIMPLIFIED: Use the standalone lookup function
      case
        metric_actor.lookup_metric_subject(
          updated_state.account_id,
          metric_name,
        )
      {
        Ok(metric_subject) -> {
          // Found existing actor - create a simple Metric and send it
          let metric =
            metric_actor.Metric(
              account_id: updated_state.account_id,
              metric_name: metric_name,
              value: initial_value,
              tags: tags,
              timestamp: utils.current_timestamp(),
            )

          logging.log(
            logging.Info,
            "[UserActor] ✅ Found existing MetricActor, sending metric",
          )
          process.send(metric_subject, metric_actor.RecordMetric(metric))
          actor.continue(updated_state)
        }
        Error(_) -> {
          // Spawn new actor
          logging.log(
            logging.Info,
            "[UserActor] MetricActor not found, spawning new one",
          )

          let metric_type_string =
            metric_types.metric_type_to_string(metric_type)

          // Use the actual parameters, not hardcoded values
          let metric_spec =
            metric_actor.start(
              updated_state.account_id,
              metric_name,
              tick_type,
              supabase_tick_type,
              initial_value,
              dict_to_string(tags),
              operation,
              cleanup_after_seconds,
              metric_type_string,
              metric_types.encode_metadata_to_string(metadata),
            )

          case
            glixir.start_dynamic_child(
              updated_state.metrics_supervisor,
              metric_spec,
              encode_metric_args,
              fn(_) { Ok(process.new_subject()) },
            )
          {
            supervisor.ChildStarted(child_pid, _reply) -> {
              logging.log(
                logging.Info,
                "[UserActor] ✅ Spawned metric actor: "
                  <> metric_name
                  <> " PID: "
                  <> string.inspect(child_pid),
              )

              // Try immediate lookup and send the metric
              case
                metric_actor.lookup_metric_subject(
                  updated_state.account_id,
                  metric_name,
                )
              {
                Ok(metric_subject) -> {
                  let metric =
                    metric_actor.Metric(
                      account_id: updated_state.account_id,
                      metric_name: metric_name,
                      value: initial_value,
                      tags: tags,
                      timestamp: utils.current_timestamp(),
                    )

                  process.send(
                    metric_subject,
                    metric_actor.RecordMetric(metric),
                  )
                  logging.log(
                    logging.Info,
                    "[UserActor] ✅ Sent metric to newly spawned actor: "
                      <> metric_name,
                  )
                }
                Error(_) -> {
                  logging.log(
                    logging.Info,
                    "[UserActor] MetricActor still initializing, will use initial_value",
                  )
                }
              }
              actor.continue(updated_state)
            }
            supervisor.StartChildError(error) -> {
              logging.log(
                logging.Error,
                "[UserActor] ❌ Failed to spawn metric: " <> error,
              )
              actor.continue(updated_state)
            }
          }
        }
      }
    }

    GetMetricActor(metric_name, reply_with) -> {
      let result = case
        metric_actor.lookup_metric_subject(
          updated_state.account_id,
          metric_name,
        )
      {
        Ok(subject) -> option.Some(subject)
        Error(_) -> option.None
      }
      process.send(reply_with, result)
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

      let current_time = utils.current_timestamp()
      let state =
        State(
          account_id: account_id,
          metrics_supervisor: metrics_supervisor,
          last_accessed: current_time,
          user_cleanup_threshold: 3600,
        )

      case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
        Ok(started) -> {
          // Register in registry for lookup
          case
            glixir.register_subject_string(
              utils.tracktags_registry(),
              account_id,
              started.data,
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
              utils.clock_events_bus(),
              "tick:tick_5s",
              "actors@user_actor",
              "handle_user_cleanup_tick",
              account_id,
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
