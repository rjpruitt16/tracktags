// src/actors/application.gleam
import actors/business_actor
import actors/clock_actor
import actors/metric_actor
import actors/supabase_actor
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/float
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import glixir/supervisor
import logging
import types/business_types
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

pub type TierLimit {
  TierLimit(
    daily_calls: Float,
    breach_action: String,
    // "deny" or "allow_overage"
  )
}

fn tier_limits() -> Dict(String, TierLimit) {
  dict.from_list([
    #("free", TierLimit(1000.0, "deny")),
    #("pro", TierLimit(100_000.0, "allow_overage")),
    #("enterprise", TierLimit(-1.0, "allow_overage")),
  ])
}

pub type ApplicationMessage {
  SendMetricToBusiness(
    business_id: String,
    metric_name: String,
    tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    initial_value: Float,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
  SendMetricToCustomer(
    business_id: String,
    customer_id: String,
    metric_name: String,
    tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    initial_value: Float,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
  Shutdown
}

// Updated state to include SupabaseActor reference
pub type ApplicationState {
  ApplicationState(
    business_supervisor: glixir.DynamicSupervisor(
      String,
      process.Subject(business_types.Message),
    ),
    clock_actor: process.Subject(clock_actor.Message),
    supabase_actor: process.Subject(supabase_actor.Message),
    self_hosted: Bool,
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
  )
}

// Update handle_application_message to use the new functions
fn handle_application_message(
  state: ApplicationState,
  message: ApplicationMessage,
) -> actor.Next(ApplicationState, ApplicationMessage) {
  case message {
    SendMetricToBusiness(
      business_id,
      metric_name,
      tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
      initial_value,
      tags,
      metadata,
      limit_value,
      limit_operator,
      breach_action,
    ) -> {
      case state.self_hosted {
        True -> {
          forward_to_business(
            state,
            business_id,
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
          )
        }
        False -> {
          case check_and_increment_usage(business_id, state) {
            Ok(_) ->
              forward_to_business(
                state,
                business_id,
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
              )
            Error(msg) -> {
              logging.log(
                logging.Warning,
                "🚫 BLOCKED: " <> business_id <> " - " <> msg,
              )
            }
          }
        }
      }
      actor.continue(state)
    }

    SendMetricToCustomer(
      business_id,
      customer_id,
      metric_name,
      tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
      initial_value,
      tags,
      metadata,
      limit_value,
      limit_operator,
      breach_action,
    ) -> {
      case state.self_hosted {
        True -> {
          forward_to_customer(
            state,
            business_id,
            customer_id,
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
          )
        }
        False -> {
          case check_and_increment_usage(business_id, state) {
            Ok(_) ->
              forward_to_customer(
                state,
                business_id,
                customer_id,
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
              )
            Error(msg) -> {
              logging.log(
                logging.Warning,
                "🚫 BLOCKED: " <> business_id <> " - " <> msg,
              )
            }
          }
        }
      }
      actor.continue(state)
    }

    Shutdown -> {
      logging.log(logging.Info, "[ApplicationActor] Shutting down")
      process.send(state.clock_actor, clock_actor.Shutdown)
      process.send(state.supabase_actor, supabase_actor.Shutdown)
      actor.stop()
    }
  }
}

// Decoder function for user actor replies
fn decode_user_reply(
  _reply: dynamic.Dynamic,
) -> Result(process.Subject(business_types.Message), String) {
  Ok(process.new_subject())
}

// Simple helper to get or spawn a user - NO BLOCKING!
fn get_or_spawn_business_simple(
  supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(business_types.Message),
  ),
  account_id: String,
) -> Result(process.Subject(business_types.Message), String) {
  // First try to find existing user
  case business_actor.lookup_business_subject(account_id) {
    Ok(user_subject) -> {
      logging.log(
        logging.Debug,
        "[Application] ✅ Found existing user: " <> account_id,
      )
      Ok(user_subject)
    }
    Error(_) -> {
      // Spawn new user WITHOUT blocking
      logging.log(
        logging.Debug,
        "[Application] Spawning new user: " <> account_id,
      )

      let user_spec = business_actor.start(account_id)
      case
        glixir.start_dynamic_child(
          supervisor,
          user_spec,
          business_actor.encode_business_args,
          decode_user_reply,
        )
      {
        supervisor.ChildStarted(child_pid, _reply) -> {
          logging.log(
            logging.Info,
            "[Application] ✅ User spawned: "
              <> account_id
              <> " PID: "
              <> string.inspect(child_pid),
          )

          // Instead of blocking, just try lookup immediately
          // The UserActor will handle the "first metric send" internally
          case business_actor.lookup_business_subject(account_id) {
            Ok(user_subject) -> {
              logging.log(
                logging.Info,
                "[Application] ✅ Found newly spawned user: " <> account_id,
              )
              Ok(user_subject)
            }
            Error(_) -> {
              // If not ready yet, that's OK - the UserActor will handle first metric
              logging.log(
                logging.Info,
                "[Application] User spawning, will receive metric via UserActor",
              )
              Error("User still registering")
            }
          }
        }
        supervisor.StartChildError(error) -> {
          logging.log(
            logging.Error,
            "[Application] ❌ Failed to spawn user: " <> error,
          )
          Error("Failed to spawn user " <> account_id <> ": " <> error)
        }
      }
    }
  }
}

// In application.gleam - check_and_increment_usage
fn check_and_increment_usage(
  business_id: String,
  state: ApplicationState,
) -> Result(Nil, String) {
  case ensure_usage_metric(business_id, state) {
    Ok(usage_subject) -> {
      let reply = process.new_subject()
      process.send(usage_subject, metric_types.CheckAndAdd(1.0, reply))

      case process.receive(reply, 800) {
        Ok(True) -> Ok(Nil)
        Ok(False) -> Error("Limit exceeded")
        Error(_) -> Error("Timeout checking usage")
      }
    }
    Error(e) -> {
      // Decide policy: deny on failure (recommended) or allow?
      Error("Usage metric unavailable: " <> e)
    }
  }
}

// Fix the type error - business.plan_type is already a String, not Option(String)
fn get_business_limit(business_id: String) -> #(Float, String) {
  case supabase_client.get_business(business_id) {
    Ok(business) -> {
      let limits = tier_limits()
      let tier = business.plan_type
      // It's already a String!

      case dict.get(limits, tier) {
        Ok(TierLimit(daily_calls, breach_action)) -> #(
          daily_calls,
          breach_action,
        )
        Error(_) -> #(1000.0, "deny")
        // Default to free
      }
    }
    Error(_) -> #(1000.0, "deny")
  }
}

// For overage tracking, update ensure_usage_metric to include metadata:
fn ensure_usage_metric(
  business_id: String,
  state: ApplicationState,
) -> Result(process.Subject(metric_types.Message), String) {
  case metric_actor.lookup_metric_subject(business_id, "daily_api_calls") {
    Ok(subject) -> Ok(subject)
    Error(_) -> {
      let #(limit, action) = get_business_limit(business_id)

      // Get metadata based on business plan
      let metadata = case supabase_client.get_business(business_id) {
        Ok(business) -> {
          case business.plan_type {
            "pro" -> {
              // Pro tier - create Stripe config structure (but no overage yet)
              metric_types.encode_metadata_to_string(
                Some(metric_types.MetricMetadata(
                  integrations: Some(metric_types.IntegrationConfig(
                    supabase: None,
                    stripe: Some(metric_types.StripeConfig(
                      enabled: True,
                      key_name: None,
                      price_id: None,
                      billing_threshold: None,
                      overage_item_id: None,
                      overage_threshold: None,
                    )),
                    fly: None,
                  )),
                  billing: None,
                  custom: None,
                )),
              )
            }
            _ -> "{}"
            // Free/enterprise tiers - no metadata
          }
        }
        Error(_) -> "{}"
        // No business found - no metadata
      }

      let spec =
        metric_actor.start(
          account_id: business_id,
          metric_name: "daily_api_calls",
          tick_type: "tick_1d",
          initial_value: 0.0,
          tags: "{}",
          operation: "SUM",
          cleanup_after_seconds: 2_592_000,
          // 30 days
          metric_type: "reset",
          metadata: metadata,
          limit_value: limit,
          limit_operator: "gte",
          breach_action: action,
        )

      case
        glixir.start_dynamic_child(
          state.metrics_supervisor,
          spec,
          metric_types.encode_metric_args,
          fn(_) { Ok(process.new_subject()) },
        )
      {
        supervisor.ChildStarted(_, _) -> {
          metric_actor.lookup_metric_subject(business_id, "daily_api_calls")
        }
        supervisor.StartChildError(e) ->
          Error("Failed to create usage metric: " <> e)
      }
    }
  }
}

fn increment_usage(usage_subject: process.Subject(metric_types.Message)) -> Nil {
  process.send(
    usage_subject,
    metric_types.RecordMetric(metric_types.Metric(
      account_id: "",
      // Already in the metric actor
      metric_name: "daily_api_calls",
      value: 1.0,
      tags: dict.new(),
      timestamp: utils.current_timestamp(),
    )),
  )
}

// Add forward_to_customer
fn forward_to_customer(
  state: ApplicationState,
  business_id: String,
  customer_id: String,
  metric_name: String,
  initial_value: Float,
  tick_type: String,
  operation: String,
  cleanup_after_seconds: Int,
  metric_type: MetricType,
  tags: Dict(String, String),
  metadata: Option(MetricMetadata),
  limit_value: Float,
  limit_operator: String,
  breach_action: String,
) -> Nil {
  case business_actor.lookup_business_subject(business_id) {
    Ok(business_subject) -> {
      process.send(
        business_subject,
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
          limit_value,
          limit_operator,
          breach_action,
        ),
      )
    }
    Error(_) -> {
      case
        get_or_spawn_business_simple(state.business_supervisor, business_id)
      {
        Ok(business_subject) -> {
          process.send(
            business_subject,
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
              limit_value,
              limit_operator,
              breach_action,
            ),
          )
        }
        Error(e) -> {
          logging.log(logging.Error, "Failed to spawn business: " <> e)
        }
      }
    }
  }
}

fn forward_to_business(
  state: ApplicationState,
  business_id: String,
  metric_name: String,
  initial_value: Float,
  tick_type: String,
  operation: String,
  cleanup_after_seconds: Int,
  metric_type: MetricType,
  tags: Dict(String, String),
  metadata: Option(MetricMetadata),
  limit_value: Float,
  limit_operator: String,
  breach_action: String,
) -> Nil {
  case business_actor.lookup_business_subject(business_id) {
    Ok(business_subject) -> {
      process.send(
        business_subject,
        business_types.RecordMetric(
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
        ),
      )
    }
    Error(_) -> {
      case
        get_or_spawn_business_simple(state.business_supervisor, business_id)
      {
        Ok(business_subject) -> {
          process.send(
            business_subject,
            business_types.RecordMetric(
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
            ),
          )
        }
        Error(e) -> {
          logging.log(logging.Error, "Failed to spawn business: " <> e)
        }
      }
    }
  }
}

// Fix start_application_actor - use the original pattern
pub fn start_application_actor(
  business_supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(business_types.Message),
  ),
  clock_actor_subject: process.Subject(clock_actor.Message),
  supabase_actor_subject: process.Subject(supabase_actor.Message),
  self_hosted: Bool,
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
) -> Result(process.Subject(ApplicationMessage), actor.StartError) {
  let initial_state =
    ApplicationState(
      business_supervisor: business_supervisor,
      clock_actor: clock_actor_subject,
      supabase_actor: supabase_actor_subject,
      self_hosted: self_hosted,
      metrics_supervisor: metrics_supervisor,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_application_message)
    |> actor.start
  {
    Ok(started) -> {
      let subject = started.data

      // Register the application actor in the registry so handlers can find it
      logging.log(
        logging.Info,
        "[Application] 📝 Registering application actor in registry",
      )

      case
        glixir.register_subject(
          utils.tracktags_registry(),
          utils.application_actor_key(),
          subject,
          glixir.atom_key_encoder,
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[Application] ✅ Application actor registered successfully",
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[Application] ❌ Failed to register application actor: "
              <> string.inspect(e),
          )
        }
      }

      Ok(subject)
    }
    Error(error) -> Error(error)
  }
}

// Updated start_app function with proper actor startup sequence
pub fn start_app(
  self_hosted: Bool,
) -> Result(process.Subject(ApplicationMessage), String) {
  // Start the registry with phantom types
  use _registry <- result.try(
    glixir.start_registry(utils.tracktags_registry())
    |> result.map_error(fn(e) { "Registry start failed: " <> string.inspect(e) }),
  )
  logging.log(logging.Info, "[Application] ✅ Registry started")

  // Start dynamic supervisor with phantom types
  use glixir_supervisor <- result.try(
    glixir.start_dynamic_supervisor_named(atom.create("main_supervisor"))
    |> result.map_error(fn(e) {
      "Supervisor start failed: " <> string.inspect(e)
    }),
  )
  logging.log(logging.Info, "[Application] ✅ Dynamic supervisor started")

  // Start ClockActor
  use clock_subject <- result.try(
    clock_actor.start()
    |> result.map_error(fn(e) {
      "ClockActor start failed: " <> string.inspect(e)
    }),
  )
  logging.log(logging.Info, "[Application] ✅ ClockActor started")

  // Start SupabaseActor FIRST (metrics will need it)
  use supabase_subject <- result.try(
    supabase_actor.start()
    |> result.map_error(fn(e) {
      "SupabaseActor start failed: " <> string.inspect(e)
    }),
  )
  logging.log(logging.Info, "[Application] ✅ SupabaseActor started")

  use metrics_supervisor <- result.try(
    glixir.start_dynamic_supervisor_named(atom.create("metrics_supervisor"))
    |> result.map_error(fn(e) {
      "Metrics supervisor failed: " <> string.inspect(e)
    }),
  )
  // Start application actor to manage all actors
  use app_actor <- result.try(
    start_application_actor(
      glixir_supervisor,
      clock_subject,
      supabase_subject,
      self_hosted,
      metrics_supervisor,
    )
    |> result.map_error(fn(e) {
      "ApplicationActor start failed: " <> string.inspect(e)
    }),
  )

  process.send(supabase_subject, supabase_actor.StartRealtimeConnection)

  logging.log(
    logging.Info,
    "[Application] ✅ Application actor started and registered",
  )
  Ok(app_actor)
}
