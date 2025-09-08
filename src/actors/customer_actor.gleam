// src/actors/customer_actor.gleam
import actors/metric_actor
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import glixir/supervisor
import logging
import storage/metric_store
import types/customer_types
import types/metric_types
import utils/auth
import utils/crypto
import utils/utils

pub type State {
  State(
    business_id: String,
    customer_id: String,
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
    last_accessed: Int,
    cleanup_threshold: Int,
    stripe_billing_metrics: List(String),
    machine_ids: List(String),
    machines_expire_at: Int,
    plan_id: Option(String),
    stripe_price_id: Option(String),
  )
}

pub fn dict_to_string(tags: Dict(String, String)) -> String {
  dict.fold(tags, "", fn(accumulator, key, value) {
    string.append(accumulator, "key: " <> key <> " value: " <> value)
  })
}

// ============================================================================
// CLIENT ACTOR PLAN INHERITANCE (Add to customer_actor.gleam)
// ============================================================================

/// Load plan limits for a client and create limit-checking metrics
fn load_client_plan_limits(
  business_id: String,
  customer_id: String,
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
) -> Result(Nil, String) {
  logging.log(
    logging.Info,
    "[ClientActor] Loading plan limits for: "
      <> business_id
      <> "/"
      <> customer_id,
  )

  // Get the client record to find its plan_id
  case supabase_client.get_customer_by_id(business_id, customer_id) {
    Ok(customer) -> {
      case customer.plan_id {
        Some(plan_id) -> {
          logging.log(
            logging.Info,
            "[ClientActor] Client has plan: " <> plan_id,
          )

          // Get plan limits for this plan
          case supabase_client.get_plan_limits_by_plan_id(plan_id) {
            Ok(plan_limits) -> {
              logging.log(
                logging.Info,
                "[ClientActor] Found "
                  <> string.inspect(list.length(plan_limits))
                  <> " plan limits",
              )

              // Create limit-checking metrics for each plan limit
              list.try_each(plan_limits, fn(limit) {
                create_limit_checking_metric(
                  business_id,
                  customer_id,
                  limit,
                  metrics_supervisor,
                )
              })
              |> result.map_error(fn(_) { "Failed to create limit metrics" })
              |> result.map(fn(_) { Nil })
            }
            Error(e) -> {
              logging.log(
                logging.Warning,
                "[ClientActor] Failed to get plan limits: " <> string.inspect(e),
              )
              Error("Failed to get plan limits")
            }
          }
        }
        None -> {
          logging.log(
            logging.Info,
            "[ClientActor] Client has no plan assigned - skipping limit creation",
          )
          Ok(Nil)
        }
      }
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[ClientActor] Failed to get client record: " <> string.inspect(e),
      )
      Error("Failed to get client record")
    }
  }
}

/// Create a limit-checking metric for a plan limit
fn create_limit_checking_metric(
  business_id: String,
  customer_id: String,
  limit: customer_types.PlanLimit,
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
    // ← Missing second type parameter
  ),
) -> Result(Nil, String) {
  let client_key = business_id <> ":" <> customer_id

  logging.log(
    logging.Info,
    "[ClientActor] Creating plan-aware MetricActor for: " <> limit.metric_name,
  )

  // Create MetricActor with plan limits built-in
  let metric_spec =
    metric_actor.start(
      client_key,
      limit.metric_name,
      "tick_1h",
      // Default flush
      0.0,
      // Start at zero usage
      "",
      // No tags
      "SUM",
      // Accumulate usage
      -1,
      // No cleanup
      limit.metric_type,
      // Persistent
      "",
      // No metadata
      limit.limit_value,
      // Plan limit
      limit.breach_operator,
      // Plan operator
      limit.breach_action,
      // Plan action
    )

  case
    glixir.start_dynamic_child(
      metrics_supervisor,
      metric_spec,
      metric_types.encode_metric_args,
      fn(_) { Ok(process.new_subject()) },
    )
  {
    supervisor.ChildStarted(_child_pid, _reply) -> {
      logging.log(
        logging.Info,
        "[ClientActor] ✅ Plan-aware metric spawned: " <> limit.metric_name,
      )
      Ok(Nil)
    }
    supervisor.StartChildError(error) -> {
      Error("Failed to spawn plan-aware metric: " <> error)
    }
  }
}

/// Check if a metric is over its plan limit
pub fn is_metric_over_limit(
  business_id: String,
  customer_id: String,
  metric_name: String,
) -> Result(Bool, String) {
  let client_key = business_id <> ":" <> customer_id
  let limit_metric_name = "_limit_" <> metric_name

  // Get current metric value
  let current_value = case metric_store.get_value(client_key, metric_name) {
    Ok(value) -> value
    Error(_) -> 0.0
    // No metric = no usage
  }

  // Get limit value
  case metric_store.get_value(client_key, limit_metric_name) {
    Ok(limit_value) -> {
      let is_over = current_value >=. limit_value

      logging.log(
        logging.Debug,
        "[ClientActor] Limit check: "
          <> metric_name
          <> " current="
          <> float.to_string(current_value)
          <> " limit="
          <> float.to_string(limit_value)
          <> " over="
          <> string.inspect(is_over),
      )

      Ok(is_over)
    }
    Error(_) -> {
      logging.log(
        logging.Debug,
        "[ClientActor] No limit found for metric: " <> metric_name,
      )
      Ok(False)
      // No limit = no breach
    }
  }
}

fn handle_message(
  state: State,
  message: customer_types.Message,
) -> actor.Next(State, customer_types.Message) {
  let current_time = utils.current_timestamp()

  let updated_state = case message {
    customer_types.RecordMetric(_, _, _, _, _, _, _, _, _, _, _) ->
      State(..state, last_accessed: current_time)
    _ -> state
  }

  logging.log(
    logging.Debug,
    "[ClientActor] Processing message for: "
      <> updated_state.business_id
      <> "/"
      <> updated_state.customer_id,
  )

  case message {
    // When resetting, prune dead metrics lazily
    customer_types.ResetStripeMetrics -> {
      logging.log(
        logging.Info,
        "[CustomerActor] Resetting Stripe billing metrics for: "
          <> state.customer_id,
      )

      let account_id = state.business_id <> ":" <> state.customer_id

      // Try each metric, collect the ones that still exist
      let #(reset_count, alive_metrics) =
        list.fold(state.stripe_billing_metrics, #(0, []), fn(acc, metric_name) {
          let #(count, alive) = acc
          let key = account_id <> "_" <> metric_name

          case glixir.lookup_subject_string(utils.tracktags_registry(), key) {
            Ok(metric_subject) -> {
              // It's alive! Reset it
              process.send(metric_subject, metric_types.ResetToInitialValue)
              logging.log(
                logging.Debug,
                "[CustomerActor] Reset sent to: " <> metric_name,
              )
              #(count + 1, [metric_name, ..alive])
              // Keep in list
            }
            Error(_) -> {
              // Dead metric, prune it
              logging.log(
                logging.Debug,
                "[CustomerActor] Pruning dead metric: " <> metric_name,
              )
              #(count, alive)
              // Don't add to alive list
            }
          }
        })

      logging.log(
        logging.Info,
        "[CustomerActor] Reset "
          <> int.to_string(reset_count)
          <> " StripeBilling metrics, pruned "
          <> int.to_string(
          list.length(state.stripe_billing_metrics) - list.length(alive_metrics),
        )
          <> " dead ones",
      )

      // Update state with pruned list
      let updated_state = State(..state, stripe_billing_metrics: alive_metrics)
      actor.continue(updated_state)
    }

    customer_types.RegisterApiKey(api_key) -> {
      let key_hash = crypto.hash_api_key(api_key)
      let registry_key =
        "client:" <> state.business_id <> ":" <> state.customer_id

      case
        glixir.lookup_subject_string(utils.tracktags_registry(), registry_key)
      {
        Ok(self_subject) -> {
          case auth.register_customer_api_key(key_hash, self_subject) {
            Ok(_) ->
              logging.log(logging.Info, "[CustomerActor] Registered API key")
            Error(e) ->
              logging.log(
                logging.Error,
                "[CustomerActor] Failed to register API key: " <> e,
              )
          }
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "[CustomerActor] Could not find self in registry to register API key",
          )
        }
      }
      actor.continue(state)
    }
    customer_types.CleanupTick(_timestamp, _tick_type) -> {
      let inactive_duration = current_time - updated_state.last_accessed

      case inactive_duration > updated_state.cleanup_threshold {
        True -> {
          logging.log(
            logging.Info,
            "[ClientActor] 🧹 Client cleanup triggered: "
              <> updated_state.business_id
              <> "/"
              <> updated_state.customer_id
              <> " (inactive for "
              <> int.to_string(inactive_duration)
              <> "s)",
          )

          let client_key =
            updated_state.business_id <> ":" <> updated_state.customer_id
          case metric_store.cleanup_store(client_key) {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[ClientActor] ✅ Store cleanup successful: " <> client_key,
              )
            Error(error) ->
              logging.log(
                logging.Error,
                "[ClientActor] ❌ Store cleanup failed: "
                  <> string.inspect(error),
              )
          }

          let registry_key =
            "client:"
            <> updated_state.business_id
            <> ":"
            <> updated_state.customer_id
          case
            glixir.unregister_subject_string(
              utils.tracktags_registry(),
              registry_key,
            )
          {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[ClientActor] ✅ Unregistered client: " <> registry_key,
              )
            Error(_) ->
              logging.log(
                logging.Warning,
                "[ClientActor] ⚠️ Failed to unregister client: " <> registry_key,
              )
          }

          actor.stop()
        }
        False -> {
          logging.log(
            logging.Debug,
            "[ClientActor] Client still active: "
              <> updated_state.business_id
              <> "/"
              <> updated_state.customer_id,
          )
          actor.continue(updated_state)
        }
      }
    }

    customer_types.RecordMetric(
      metric_name,
      initial_value,
      tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
      tags,
      metadata,
      limit_value,
      limit_operator,
      breach_action,
    ) -> {
      logging.log(
        logging.Info,
        "[ClientActor] Processing metric: "
          <> updated_state.business_id
          <> "/"
          <> updated_state.customer_id
          <> "/"
          <> metric_name,
      )

      let client_metric_key =
        updated_state.business_id <> ":" <> updated_state.customer_id

      case metric_actor.lookup_metric_subject(client_metric_key, metric_name) {
        Ok(metric_subject) -> {
          // EXISTING METRIC FOUND
          let metric =
            metric_types.Metric(
              account_id: client_metric_key,
              metric_name: metric_name,
              value: initial_value,
              tags: tags,
              timestamp: utils.current_timestamp(),
            )

          logging.log(
            logging.Info,
            "[ClientActor] ✅ Found existing MetricActor, sending metric",
          )
          process.send(metric_subject, metric_types.RecordMetric(metric))

          // TRACK STRIPE BILLING METRICS HERE TOO!
          let final_state = case metric_type {
            metric_types.StripeBilling -> {
              case
                list.contains(updated_state.stripe_billing_metrics, metric_name)
              {
                True -> updated_state
                // Already tracked
                False ->
                  State(..updated_state, stripe_billing_metrics: [
                    metric_name,
                    ..updated_state.stripe_billing_metrics
                  ])
              }
            }
            _ -> updated_state
          }

          actor.continue(final_state)
        }

        Error(_) -> {
          // METRIC DOESN'T EXIST, SPAWN NEW ONE
          logging.log(
            logging.Info,
            "[ClientActor] MetricActor not found, spawning new one",
          )

          let metric_type_string =
            metric_types.metric_type_to_string(metric_type)

          let metric_spec =
            metric_actor.start(
              client_metric_key,
              metric_name,
              tick_type,
              initial_value,
              dict_to_string(tags),
              operation,
              cleanup_after_seconds,
              metric_type_string,
              metric_types.encode_metadata_to_string(metadata),
              limit_value,
              limit_operator,
              breach_action,
            )

          case
            glixir.start_dynamic_child(
              updated_state.metrics_supervisor,
              metric_spec,
              metric_types.encode_metric_args,
              fn(_) { Ok(process.new_subject()) },
            )
          {
            supervisor.ChildStarted(child_pid, _reply) -> {
              logging.log(
                logging.Info,
                "[ClientActor] ✅ Spawned metric actor: "
                  <> metric_name
                  <> " PID: "
                  <> string.inspect(child_pid),
              )

              // Try to send the initial metric
              case
                metric_actor.lookup_metric_subject(
                  client_metric_key,
                  metric_name,
                )
              {
                Ok(metric_subject) -> {
                  let metric =
                    metric_types.Metric(
                      account_id: client_metric_key,
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
                    "[ClientActor] ✅ Sent metric to newly spawned actor: "
                      <> metric_name,
                  )
                }
                Error(_) -> {
                  logging.log(
                    logging.Info,
                    "[ClientActor] MetricActor still initializing, will use initial_value",
                  )
                }
              }

              // TRACK STRIPE BILLING METRICS AFTER SPAWNING
              let final_state = case metric_type {
                metric_types.StripeBilling -> {
                  case
                    list.contains(
                      updated_state.stripe_billing_metrics,
                      metric_name,
                    )
                  {
                    True -> updated_state
                    // Already tracked
                    False ->
                      State(..updated_state, stripe_billing_metrics: [
                        metric_name,
                        ..updated_state.stripe_billing_metrics
                      ])
                  }
                }
                _ -> updated_state
              }

              actor.continue(final_state)
            }

            supervisor.StartChildError(error) -> {
              logging.log(
                logging.Error,
                "[ClientActor] ❌ Failed to spawn metric: " <> error,
              )
              actor.continue(updated_state)
            }
          }
        }
      }
    }
    customer_types.GetMetricActor(metric_name, reply_with) -> {
      let client_metric_key =
        updated_state.business_id <> ":" <> updated_state.customer_id
      let result = case
        metric_actor.lookup_metric_subject(client_metric_key, metric_name)
      {
        Ok(subject) -> option.Some(subject)
        Error(_) -> option.None
      }
      process.send(reply_with, result)
      actor.continue(updated_state)
    }

    customer_types.Shutdown -> {
      logging.log(
        logging.Info,
        "[ClientActor] Shutting down: "
          <> updated_state.business_id
          <> "/"
          <> updated_state.customer_id,
      )

      let client_key =
        updated_state.business_id <> ":" <> updated_state.customer_id
      case metric_store.cleanup_store(client_key) {
        Ok(_) ->
          logging.log(
            logging.Info,
            "[ClientActor] ✅ Store cleanup on shutdown: " <> client_key,
          )
        Error(error) ->
          logging.log(
            logging.Error,
            "[ClientActor] ❌ Store cleanup failed on shutdown: "
              <> string.inspect(error),
          )
      }

      actor.stop()
    }

    customer_types.GetMachines(reply) -> {
      process.send(reply, state.machine_ids)
      actor.continue(state)
    }

    customer_types.GetPlan(reply) -> {
      process.send(reply, #(state.plan_id, state.stripe_price_id))
      actor.continue(state)
    }

    // Rename these existing cases for clarity:
    customer_types.SetMachinesList(machine_ids, expires_at) -> {
      // Was UpdateMachines
      logging.log(
        logging.Info,
        "[CustomerActor] Setting machines list for "
          <> state.customer_id
          <> " - "
          <> int.to_string(list.length(machine_ids))
          <> " machines",
      )
      actor.continue(
        State(..state, machine_ids: machine_ids, machines_expire_at: expires_at),
      )
    }

    customer_types.SetPlan(plan_id, stripe_price_id) -> {
      // Was UpdatePlan
      logging.log(
        logging.Info,
        "[CustomerActor] Setting plan for " <> state.customer_id,
      )
      actor.continue(
        State(..state, plan_id: plan_id, stripe_price_id: stripe_price_id),
      )
    }

    // Add new realtime cases:
    customer_types.RealtimeMachineChange(machine, event_type) -> {
      case event_type {
        "insert" -> {
          let new_machines = [machine.machine_id, ..state.machine_ids]
          actor.continue(
            State(
              ..state,
              machine_ids: new_machines,
              machines_expire_at: machine.expires_at,
            ),
          )
        }
        "update" -> {
          case list.contains(state.machine_ids, machine.machine_id) {
            True ->
              actor.continue(
                State(..state, machines_expire_at: machine.expires_at),
              )
            False -> actor.continue(state)
          }
        }
        "delete" -> {
          let new_machines =
            list.filter(state.machine_ids, fn(id) { id != machine.machine_id })
          actor.continue(State(..state, machine_ids: new_machines))
        }
        _ -> actor.continue(state)
      }
    }

    customer_types.RealtimePlanChange(plan_id, price_id) -> {
      actor.continue(
        State(..state, plan_id: plan_id, stripe_price_id: price_id),
      )
    }

    customer_types.SetContextFromDatabase(context) -> {
      logging.log(
        logging.Info,
        "[CustomerActor] Updating context for " <> state.customer_id,
      )

      // Extract machine info
      let machine_ids = list.map(context.machines, fn(m) { m.machine_id })
      let expires_at =
        list.first(context.machines)
        |> result.map(fn(m) { m.expires_at })
        |> result.unwrap(0)

      // Extract customer info
      let plan_id = context.customer.plan_id
      let stripe_price_id = context.customer.stripe_price_id

      // TODO: Could also cache the limits here for quick access

      actor.continue(
        State(
          ..state,
          machine_ids: machine_ids,
          machines_expire_at: expires_at,
          plan_id: plan_id,
          stripe_price_id: stripe_price_id,
        ),
      )
    }
  }
}

pub fn encode_client_args(args: #(String, String)) -> List(dynamic.Dynamic) {
  let #(business_id, customer_id) = args
  [dynamic.string(business_id), dynamic.string(customer_id)]
}

pub fn start_link(
  business_id business_id: String,
  customer_id customer_id: String,
) -> Result(process.Subject(customer_types.Message), actor.StartError) {
  logging.log(
    logging.Info,
    "[ClientActor] Starting for: " <> business_id <> "/" <> customer_id,
  )

  case
    glixir.start_dynamic_supervisor_named_safe(
      "customer_metrics_" <> business_id <> "_" <> customer_id,
    )
  {
    Ok(metrics_supervisor) -> {
      logging.log(
        logging.Debug,
        "[ClientActor] ✅ Metrics supervisor started for "
          <> business_id
          <> "/"
          <> customer_id,
      )

      let current_time = utils.current_timestamp()
      let state =
        State(
          business_id: business_id,
          customer_id: customer_id,
          metrics_supervisor: metrics_supervisor,
          last_accessed: current_time,
          cleanup_threshold: 2_592_000,
          stripe_billing_metrics: [],
          machine_ids: [],
          machines_expire_at: 0,
          plan_id: None,
          stripe_price_id: None,
        )

      case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
        Ok(started) -> {
          let registry_key = "client:" <> business_id <> ":" <> customer_id
          case
            glixir.register_subject_string(
              utils.tracktags_registry(),
              registry_key,
              started.data,
            )
          {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[ClientActor] ✅ Registered: " <> registry_key,
              )
            Error(_) ->
              logging.log(
                logging.Error,
                "[ClientActor] ❌ Failed to register: " <> registry_key,
              )
          }

          case
            glixir.pubsub_subscribe_with_registry_key(
              utils.clock_events_bus(),
              "tick:tick_5s",
              "actors@customer_actor",
              "handle_client_cleanup_tick",
              registry_key,
            )
          {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[ClientActor] ✅ Client cleanup subscription for: "
                  <> registry_key,
              )
            }
            Error(e) -> {
              logging.log(
                logging.Error,
                "[ClientActor] ❌ Failed client cleanup subscription: "
                  <> string.inspect(e),
              )
            }
          }

          let customer_channel = "customers:update:" <> customer_id
          case
            glixir.pubsub_subscribe_with_registry_key(
              utils.realtime_events_bus(),
              customer_channel,
              "actors@customer_actor",
              "handle_realtime_update",
              registry_key,
            )
          {
            Ok(_) ->
              logging.log(logging.Info, "[CustomerActor] Subscribed to updates")
            Error(e) ->
              logging.log(
                logging.Error,
                "[CustomerActor] Subscribe failed: " <> string.inspect(e),
              )
          }

          // Load plan limits and create limit-checking metrics
          case
            load_client_plan_limits(
              business_id,
              customer_id,
              metrics_supervisor,
            )
          {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[ClientActor] ✅ Plan limits loaded and metrics created",
              )
            }
            Error(e) -> {
              logging.log(
                logging.Warning,
                "[ClientActor] ⚠️ Failed to load plan limits: " <> e,
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
        "[ClientActor] ❌ Failed to start metrics supervisor: "
          <> string.inspect(error),
      )
      Error(actor.InitFailed("Failed to start metrics supervisor"))
    }
  }
}

pub fn handle_client_cleanup_tick(
  registry_key: String,
  json_message: String,
) -> Nil {
  logging.log(
    logging.Debug,
    "[ClientActor] 🎯 Cleanup tick for client: " <> registry_key,
  )

  case glixir.lookup_subject_string(utils.tracktags_registry(), registry_key) {
    Ok(client_subject) -> {
      let tick_decoder = {
        use tick_name <- decode.field("tick_name", decode.string)
        use timestamp <- decode.field("timestamp", decode.string)
        decode.success(#(tick_name, timestamp))
      }

      case json.parse(json_message, tick_decoder) {
        Ok(#(tick_name, timestamp)) -> {
          process.send(
            client_subject,
            customer_types.CleanupTick(timestamp, tick_name),
          )
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[ClientActor] ❌ Invalid cleanup tick JSON for: " <> registry_key,
          )
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Debug,
        "[ClientActor] Client not found for cleanup tick: " <> registry_key,
      )
    }
  }
}

pub fn start(
  business_id: String,
  customer_id: String,
) -> glixir.ChildSpec(
  #(String, String),
  process.Subject(customer_types.Message),
) {
  glixir.child_spec(
    id: "client_" <> business_id <> "_" <> customer_id,
    module: "Elixir.CustomerActorBridge",
    function: "start_link",
    args: #(business_id, customer_id),
    restart: glixir.permanent,
    shutdown_timeout: 5000,
    child_type: glixir.worker,
  )
}

pub fn handle_realtime_update(registry_key: String, message: String) -> Nil {
  // First decode the outer message structure
  let message_decoder = {
    use table <- decode.field("table", decode.string)
    use event <- decode.field("event", decode.string)
    use record <- decode.field("record", decode.dynamic)
    decode.success(#(table, event, record))
  }

  case json.parse(message, message_decoder) {
    Ok(#("customers", "update", new_record)) -> {
      // Parse customer update directly from payload
      case decode.run(new_record, customer_types.customer_decoder()) {
        Ok(customer) -> {
          case
            glixir.lookup_subject_string(
              utils.tracktags_registry(),
              registry_key,
            )
          {
            Ok(customer_subject) -> {
              process.send(
                customer_subject,
                customer_types.RealtimePlanChange(
                  customer.plan_id,
                  customer.stripe_price_id,
                ),
              )
            }
            Error(_) -> Nil
          }
        }
        Error(_) -> Nil
      }
    }

    Ok(#("customer_machines", event, new_record)) -> {
      // Parse machine changes directly
      case decode.run(new_record, customer_types.customer_machine_decoder()) {
        Ok(machine) -> {
          case
            glixir.lookup_subject_string(
              utils.tracktags_registry(),
              registry_key,
            )
          {
            Ok(customer_subject) -> {
              process.send(
                customer_subject,
                customer_types.RealtimeMachineChange(machine, event),
              )
            }
            Error(_) -> Nil
          }
        }
        Error(_) -> Nil
      }
    }

    _ -> Nil
  }
}
