// src/actors/application.gleam
import actors/business_actor
import actors/clock_actor
import actors/machine_actor
import actors/metric_actor
import actors/supabase_actor
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import glixir/supervisor
import logging
import types/application_types.{type ApplicationMessage}
import types/business_types
import types/customer_types
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/auth
import utils/utils

// Now we can import auth!
pub type TierLimit {
  TierLimit(
    daily_calls: Float,
    breach_action: String,
    supabase_writes: Float,
    daily_metrics: Float,
  )
}

// In your tier_limits function:
fn tier_limits() -> Dict(String, TierLimit) {
  dict.from_list([
    #(
      "free",
      TierLimit(
        daily_calls: 333.0,
        // ~10K/month
        daily_metrics: 33.0,
        // ~1K/month
        supabase_writes: 0.0,
        breach_action: "deny",
      ),
    ),
    #(
      "pro",
      TierLimit(
        daily_calls: 3333.0,
        // ~100K/month
        daily_metrics: 333.0,
        // ~10K/month
        supabase_writes: 33.0,
        // ~1K/month
        breach_action: "allow_overage",
        // Bill for extra
      ),
    ),
    #(
      "scale",
      TierLimit(
        daily_calls: 33_333.0,
        // ~1M/month
        daily_metrics: 3333.0,
        // ~100K/month
        supabase_writes: 333.0,
        // ~10K/month
        breach_action: "allow_overage",
      ),
    ),
    #(
      "enterprise",
      TierLimit(
        daily_calls: -1.0,
        // Unlimited
        daily_metrics: -1.0,
        supabase_writes: -1.0,
        breach_action: "allow",
      ),
    ),
  ])
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
    application_types.SendMetricToBusiness(
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

    application_types.SendMetricToCustomer(
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

    application_types.EnsureBusinessActor(business_id, api_key, reply_to) -> {
      let result =
        get_or_spawn_business_simple(state.business_supervisor, business_id)

      // Send API key to business actor for registration
      case result {
        Ok(business_subject) -> {
          process.send(business_subject, business_types.RegisterApiKey(api_key))
        }
        Error(_) -> Nil
      }

      process.send(reply_to, result)
      actor.continue(state)
    }

    application_types.EnsureCustomerActor(
      business_id,
      customer_id,
      context,
      api_key,
      reply_to,
    ) -> {
      let result =
        ensure_customer_with_context(
          state.business_supervisor,
          business_id,
          customer_id,
          context,
        )

      // Send API key to customer actor for registration
      case result {
        Ok(customer_subject) -> {
          process.send(customer_subject, customer_types.RegisterApiKey(api_key))
        }
        Error(_) -> Nil
      }

      process.send(reply_to, result)
      actor.continue(state)
    }
    application_types.Shutdown -> {
      logging.log(logging.Info, "[ApplicationActor] Shutting down")
      process.send(state.clock_actor, clock_actor.Shutdown)
      process.send(state.supabase_actor, supabase_actor.Shutdown)
      actor.stop()
    }
  }
}

// Decoder function for business actor replies
fn decode_business_reply(
  _reply: dynamic.Dynamic,
) -> Result(process.Subject(business_types.Message), String) {
  Ok(process.new_subject())
}

// Simple helper to get or spawn a business - NO BLOCKING!
fn get_or_spawn_business_simple(
  supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(business_types.Message),
  ),
  account_id: String,
) -> Result(process.Subject(business_types.Message), String) {
  // First try to find existing business
  case business_actor.lookup_business_subject(account_id) {
    Ok(business_subject) -> {
      logging.log(
        logging.Debug,
        "[Application] ✅ Found existing business: " <> account_id,
      )
      Ok(business_subject)
    }
    Error(_) -> {
      // Spawn new business WITHOUT blocking
      logging.log(
        logging.Debug,
        "[Application] Spawning new business: " <> account_id,
      )

      let business_spec = business_actor.start(account_id)
      case
        glixir.start_dynamic_child(
          supervisor,
          business_spec,
          business_actor.encode_business_args,
          decode_business_reply,
        )
      {
        supervisor.ChildStarted(child_pid, _reply) -> {
          logging.log(
            logging.Info,
            "[Application] ✅ business spawned: "
              <> account_id
              <> " PID: "
              <> string.inspect(child_pid),
          )

          // Instead of blocking, just try lookup immediately
          // The businessActor will handle the "first metric send" internally
          case business_actor.lookup_business_subject(account_id) {
            Ok(business_subject) -> {
              logging.log(
                logging.Info,
                "[Application] ✅ Found newly spawned business: " <> account_id,
              )
              Ok(business_subject)
            }
            Error(_) -> {
              // If not ready yet, that's OK - the businessActor will handle first metric
              logging.log(
                logging.Info,
                "[Application] business spawning, will receive metric via BusinessActor",
              )
              Error("business still registering")
            }
          }
        }
        supervisor.StartChildError(error) -> {
          logging.log(
            logging.Error,
            "[Application] ❌ Failed to spawn business: " <> error,
          )
          Error("Failed to spawn business " <> account_id <> ": " <> error)
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
        Ok(TierLimit(daily_calls, breach_action, _, _)) -> #(
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

fn ensure_customer_with_context(
  business_supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(business_types.Message),
  ),
  business_id: String,
  customer_id: String,
  context: customer_types.CustomerContext,
) -> Result(process.Subject(customer_types.Message), String) {
  // Check if customer actor already exists
  case customer_types.lookup_client_subject(business_id, customer_id) {
    Ok(customer_subject) -> {
      // Update with fresh context
      process.send(
        customer_subject,
        customer_types.SetContextFromDatabase(context),
      )
      Ok(customer_subject)
    }
    Error(_) -> {
      // Need to spawn via business actor first
      case get_or_spawn_business_simple(business_supervisor, business_id) {
        Ok(business_subject) -> {
          // Have business spawn the customer
          let reply = process.new_subject()
          process.send(
            business_subject,
            business_types.EnsureCustomerExists(customer_id, context, reply),
          )

          case process.receive(reply, 1000) {
            Ok(customer_subject) -> Ok(customer_subject)
            Error(_) -> Error("Failed to spawn customer actor")
          }
        }
        Error(e) -> Error("Failed to get business actor: " <> e)
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

  // Initialize auth registries FIRST
  case auth.init_auth_registries() {
    Ok(_) -> logging.log(logging.Info, "[Main] Auth registries initialized")
    Error(e) -> {
      logging.log(logging.Error, "[Main] Failed to init auth registries: " <> e)
      panic as "Failed to initialize auth registries"
    }
  }

  // Initialize realtime events bus
  case glixir.pubsub_start(utils.realtime_events_bus()) {
    Ok(_) -> logging.log(logging.Info, "[Main] Realtime events bus started")
    Error(e) -> {
      logging.log(
        logging.Error,
        "[Main] Failed to start realtime bus: " <> string.inspect(e),
      )
      panic as "Failed to start realtime events bus"
    }
  }

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
  // Start MachineActor for provisioning
  use _machine_subject <- result.try(
    machine_actor.start()
    |> result.map_error(fn(e) {
      "MachineActor start failed: " <> string.inspect(e)
    }),
  )
  logging.log(logging.Info, "[Application] ✅ MachineActor started")
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

  logging.log(
    logging.Info,
    "[Application] ✅ Application actor started and registered",
  )
  Ok(app_actor)
}
