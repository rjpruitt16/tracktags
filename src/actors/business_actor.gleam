// src/actor/business_actors_actor.gleam 
import actors/customer_actor
import actors/metric_actor
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import glixir/supervisor
import logging
import storage/metric_store
import types/business_types
import types/customer_types
import types/metric_types
import utils/utils

pub type State {
  State(
    account_id: String,
    metrics_supervisor: glixir.DynamicSupervisor(
      #(
        String,
        String,
        String,
        Float,
        String,
        String,
        Int,
        String,
        String,
        Float,
        String,
        String,
      ),
      process.Subject(metric_types.Message),
    ),
    customers_supervisor: glixir.DynamicSupervisor(
      #(String, String),
      process.Subject(customer_types.Message),
    ),
    last_accessed: Int,
    user_cleanup_threshold: Int,
  )
}

// Helper functions for consistent naming
pub fn business_subject_name(account_id: String) -> String {
  "tracktags_business_" <> account_id
}

pub fn lookup_business_subject(
  account_id: String,
) -> Result(process.Subject(business_types.Message), String) {
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
    Float,
    String,
    String,
    Int,
    String,
    String,
    Float,
    String,
    String,
  ),
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
    metadata,
    plan_limit_value,
    plan_limit_operator,
    plan_breach_action,
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
    dynamic.string(metadata),
    dynamic.float(plan_limit_value),
    dynamic.string(plan_limit_operator),
    dynamic.string(plan_breach_action),
  ]
}

fn handle_message(
  state: State,
  message: business_types.Message,
) -> actor.Next(State, business_types.Message) {
  let current_time = utils.current_timestamp()

  // Update last_accessed for user activity
  let updated_state = case message {
    business_types.RecordMetric(_, _, _, _, _, _, _, _, _, _, _) ->
      State(..state, last_accessed: current_time)
    _ -> state
  }

  logging.log(
    logging.Debug,
    "[BusinessActor] Processing message for: " <> updated_state.account_id,
  )

  case message {
    business_types.RecordClientMetric(
      customer_id,
      metric_name,
      initial_value,
      tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
      tags,
      metadata,
      plan_limit_value,
      plan_limit_operator,
      plan_breach_action,
    ) -> {
      logging.log(
        logging.Info,
        "[BusinessActor] Processing client metric: "
          <> updated_state.account_id
          <> "/client:"
          <> customer_id
          <> "/"
          <> metric_name,
      )

      case
        customer_types.lookup_client_subject(updated_state.account_id, customer_id)
      {
        Ok(client_subject) -> {
          logging.log(
            logging.Info,
            "[BusinessActor] ✅ Found existing client, sending metric: "
              <> customer_id,
          )

          process.send(
            client_subject,
            customer_types.RecordMetric(
              metric_name: metric_name,
              initial_value: initial_value,
              tick_type: tick_type,
              operation: operation,
              cleanup_after_seconds: cleanup_after_seconds,
              metric_type: metric_type,
              tags: tags,
              metadata: metadata,
              plan_limit_value: plan_limit_value,
              plan_limit_operator: plan_limit_operator,
              plan_breach_action: plan_breach_action,
            ),
          )
          actor.continue(updated_state)
        }
        Error(_) -> {
          logging.log(
            logging.Info,
            "[BusinessActor] Client not found, spawning: " <> customer_id,
          )

          case
            get_or_spawn_client_simple(
              supervisor: updated_state.customers_supervisor,
              business_id: updated_state.account_id,
              customer_id: customer_id,
            )
          {
            Ok(client_subject) -> {
              logging.log(
                logging.Info,
                "[BusinessActor] ✅ Client spawned, sending metric to mailbox: "
                  <> customer_id,
              )

              process.send(
                client_subject,
                customer_types.RecordMetric(
                  metric_name: metric_name,
                  initial_value: initial_value,
                  tick_type: tick_type,
                  operation: operation,
                  cleanup_after_seconds: cleanup_after_seconds,
                  metric_type: metric_type,
                  tags: tags,
                  metadata: metadata,
                  plan_limit_value: plan_limit_value,
                  plan_limit_operator: plan_limit_operator,
                  plan_breach_action: plan_breach_action,
                ),
              )
              actor.continue(updated_state)
            }
            Error(error) -> {
              logging.log(
                logging.Error,
                "[BusinessActor] ❌ Failed to spawn client: " <> error,
              )
              actor.continue(updated_state)
            }
          }
        }
      }
    }
    business_types.CleanupTick(_timestamp, _tick_type) -> {
      // Check if user should be cleaned up due to inactivity
      let inactive_duration = current_time - updated_state.last_accessed

      case inactive_duration > updated_state.user_cleanup_threshold {
        True -> {
          logging.log(
            logging.Info,
            "[BusinessActor] 🧹 User cleanup triggered: "
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
                "[BusinessActor] ✅ Store cleanup successful: "
                  <> updated_state.account_id,
              )
            Error(error) ->
              logging.log(
                logging.Error,
                "[BusinessActor] ❌ Store cleanup failed: "
                  <> string.inspect(error),
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
                "[BusinessActor] ✅ Unregistered user: "
                  <> updated_state.account_id,
              )
            Error(_) ->
              logging.log(
                logging.Warning,
                "[BusinessActor] ⚠️ Failed to unregister user: "
                  <> updated_state.account_id,
              )
          }

          actor.stop()
        }
        False -> {
          logging.log(
            logging.Debug,
            "[BusinessActor] User still active: "
              <> updated_state.account_id
              <> " (inactive for "
              <> int.to_string(inactive_duration)
              <> "s)",
          )
          actor.continue(updated_state)
        }
      }
    }

    business_types.RecordMetric(
      metric_name,
      initial_value,
      tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
      tags,
      metadata,
      plan_limit_value,
      plan_limit_operator,
      plan_breach_action,
    ) -> {
      logging.log(
        logging.Info,
        "[BusinessActor] Processing metric: "
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
            metric_types.Metric(
              account_id: updated_state.account_id,
              metric_name: metric_name,
              value: initial_value,
              tags: tags,
              timestamp: utils.current_timestamp(),
            )

          logging.log(
            logging.Info,
            "[BusinessActor] ✅ Found existing MetricActor, sending metric",
          )
          process.send(metric_subject, metric_types.RecordMetric(metric))
          actor.continue(updated_state)
        }
        Error(_) -> {
          // Spawn new actor
          logging.log(
            logging.Info,
            "[BusinessActor] MetricActor not found, spawning new one",
          )

          let metric_type_string =
            metric_types.metric_type_to_string(metric_type)

          // Use the actual parameters, not hardcoded values
          let metric_spec =
            metric_actor.start(
              updated_state.account_id,
              metric_name,
              tick_type,
              initial_value,
              dict_to_string(tags),
              operation,
              cleanup_after_seconds,
              metric_type_string,
              metric_types.encode_metadata_to_string(metadata),
              plan_limit_value,
              plan_limit_operator,
              plan_breach_action,
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
                "[BusinessActor] ✅ Spawned metric actor: "
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
                    metric_types.Metric(
                      account_id: updated_state.account_id,
                      metric_name: metric_name,
                      value: initial_value,
                      tags: tags,
                      timestamp: utils.current_timestamp(),
                    )

                  process.send(
                    metric_subject,
                    metric_types.RecordMetric(metric),
                  )
                  logging.log(
                    logging.Info,
                    "[BusinessActor] ✅ Sent metric to newly spawned actor: "
                      <> metric_name,
                  )
                }
                Error(_) -> {
                  logging.log(
                    logging.Info,
                    "[BusinessActor] MetricActor still initializing, will use initial_value",
                  )
                }
              }
              actor.continue(updated_state)
            }
            supervisor.StartChildError(error) -> {
              logging.log(
                logging.Error,
                "[BusinessActor] ❌ Failed to spawn metric: " <> error,
              )
              actor.continue(updated_state)
            }
          }
        }
      }
    }

    business_types.GetMetricActor(metric_name, reply_with) -> {
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
    business_types.RefreshPlanLimit(
      metric_name,
      limit_value,
      _operator,
      _action,
    ) -> {
      logging.log(
        logging.Info,
        "[BusinessActor] Plan limit refresh: "
          <> metric_name
          <> " = "
          <> float.to_string(limit_value),
      )
      // TODO: update business metrics plans
      actor.continue(updated_state)
    }
    business_types.Shutdown -> {
      logging.log(
        logging.Info,
        "[BusinessActor] Shutting down: " <> updated_state.account_id,
      )

      // Clean up store on explicit shutdown
      case metric_store.cleanup_store(updated_state.account_id) {
        Ok(_) ->
          logging.log(
            logging.Info,
            "[BusinessActor] ✅ Store cleanup on shutdown: "
              <> updated_state.account_id,
          )
        Error(error) ->
          logging.log(
            logging.Error,
            "[BusinessActor] ❌ Store cleanup failed on shutdown: "
              <> string.inspect(error),
          )
      }

      actor.stop()
    }
  }
}

// Encoder function for user actor arguments
pub fn encode_business_args(account_id: String) -> List(dynamic.Dynamic) {
  [dynamic.string(account_id)]
}

// start_link function for bridge to call
pub fn start_link(
  account_id: String,
) -> Result(process.Subject(business_types.Message), actor.StartError) {
  logging.log(
    logging.Info,
    "[BusinessActor] Starting for account: " <> account_id,
  )

  use metrics_supervisor <- result.try(
    glixir.start_dynamic_supervisor_named_safe("metrics_" <> account_id)
    |> result.map_error(fn(e) {
      actor.InitFailed(
        "Failed to start metrics supervisor: " <> string.inspect(e),
      )
    }),
  )

  use customers_supervisor <- result.try(
    glixir.start_dynamic_supervisor_named_safe("customers_" <> account_id)
    |> result.map_error(fn(e) {
      actor.InitFailed(
        "Failed to start customers supervisor: " <> string.inspect(e),
      )
    }),
  )

  logging.log(
    logging.Debug,
    "[BusinessActor] ✅ Supervisors started for " <> account_id,
  )

  let current_time = utils.current_timestamp()
  let state =
    State(
      account_id: account_id,
      metrics_supervisor: metrics_supervisor,
      customers_supervisor: customers_supervisor,
      last_accessed: current_time,
      user_cleanup_threshold: 3600,
    )

  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle_message)
    |> actor.start,
  )

  // Register in registry for lookup
  case
    glixir.register_subject_string(
      utils.tracktags_registry(),
      account_id,
      started.data,
    )
  {
    Ok(_) ->
      logging.log(logging.Info, "[BusinessActor] ✅ Registered: " <> account_id)
    Error(_) ->
      logging.log(
        logging.Error,
        "[BusinessActor] ❌ Failed to register: " <> account_id,
      )
  }

  // Subscribe to cleanup ticks
  case
    glixir.pubsub_subscribe_with_registry_key(
      utils.clock_events_bus(),
      "tick:tick_5s",
      "actors@business_actor",
      "handle_business_cleanup_tick",
      account_id,
    )
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[BusinessActor] ✅ User cleanup subscription for: " <> account_id,
      )
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[BusinessActor] ❌ Failed user cleanup subscription: "
          <> string.inspect(e),
      )
    }
  }

  Ok(started.data)
}

pub fn handle_business_cleanup_tick(
  registry_key: String,
  json_message: String,
) -> Nil {
  let account_id = registry_key

  logging.log(
    logging.Debug,
    "[BusinessActor] 🎯 Cleanup tick for user: " <> account_id,
  )

  case lookup_business_subject(account_id) {
    Ok(user_subject) -> {
      // Parse the tick data (reuse same JSON structure)
      let tick_decoder = {
        use tick_name <- decode.field("tick_name", decode.string)
        use timestamp <- decode.field("timestamp", decode.string)
        decode.success(#(tick_name, timestamp))
      }

      case json.parse(json_message, tick_decoder) {
        Ok(#(tick_name, timestamp)) -> {
          process.send(
            user_subject,
            business_types.CleanupTick(timestamp, tick_name),
          )
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[BusinessActor] ❌ Invalid cleanup tick JSON for: " <> account_id,
          )
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Debug,
        "[BusinessActor] User not found for cleanup tick: " <> account_id,
      )
    }
  }
}

fn get_or_spawn_client_simple(
  supervisor supervisor: glixir.DynamicSupervisor(
    #(String, String),
    process.Subject(customer_types.Message),
  ),
  business_id business_id: String,
  customer_id customer_id: String,
) -> Result(process.Subject(customer_types.Message), String) {
  case customer_types.lookup_client_subject(business_id, customer_id) {
    Ok(client_subject) -> {
      logging.log(
        logging.Debug,
        "[BusinessActor] ✅ Found existing client: "
          <> business_id
          <> "/"
          <> customer_id,
      )
      Ok(client_subject)
    }
    Error(_) -> {
      logging.log(
        logging.Debug,
        "[BusinessActor] Spawning new client: "
          <> business_id
          <> "/"
          <> customer_id,
      )

      let client_spec = customer_actor.start(business_id, customer_id)
      case
        glixir.start_dynamic_child(
          supervisor,
          client_spec,
          customer_actor.encode_client_args,
          fn(_) { Ok(process.new_subject()) },
        )
      {
        supervisor.ChildStarted(child_pid, _reply) -> {
          logging.log(
            logging.Info,
            "[BusinessActor] ✅ Client spawned: "
              <> business_id
              <> "/"
              <> customer_id
              <> " PID: "
              <> string.inspect(child_pid),
          )

          case customer_types.lookup_client_subject(business_id, customer_id) {
            Ok(client_subject) -> {
              logging.log(
                logging.Info,
                "[BusinessActor] ✅ Found newly spawned client: "
                  <> business_id
                  <> "/"
                  <> customer_id,
              )
              Ok(client_subject)
            }
            Error(_) -> {
              logging.log(
                logging.Info,
                "[BusinessActor] Client spawning, will receive metric via ClientActor",
              )
              Error("Client still registering")
            }
          }
        }
        supervisor.StartChildError(error) -> {
          logging.log(
            logging.Error,
            "[BusinessActor] ❌ Failed to spawn client: " <> error,
          )
          Error(
            "Failed to spawn client "
            <> business_id
            <> "/"
            <> customer_id
            <> ": "
            <> error,
          )
        }
      }
    }
  }
}

// Returns glixir.ChildSpec for dynamic spawning
pub fn start(
  account_id: String,
) -> glixir.ChildSpec(String, process.Subject(business_types.Message)) {
  glixir.child_spec(
    id: "business_" <> account_id,
    module: "Elixir.BusinessActorBridge",
    function: "start_link",
    args: account_id,
    restart: glixir.permanent,
    shutdown_timeout: 5000,
    child_type: glixir.worker,
  )
}
