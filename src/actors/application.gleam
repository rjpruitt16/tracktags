// src/actors/application.gleam
import actors/business_actor
import actors/clock_actor
import actors/supabase_actor
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import glixir/supervisor
import logging
import types/business_types
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

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
    plan_limit_value: Float,
    plan_limit_operator: String,
    plan_breach_action: String,
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
    plan_limit_value: Float,
    plan_limit_operator: String,
    plan_breach_action: String,
  )
  Shutdown
}

// Updated state to include SupabaseActor reference
pub type ApplicationState {
  ApplicationState(
    supervisor: glixir.DynamicSupervisor(
      String,
      process.Subject(business_types.Message),
    ),
    clock_actor: process.Subject(clock_actor.Message),
    supabase_actor: process.Subject(supabase_actor.Message),
  )
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

// Much simpler application actor message handler
fn handle_application_message(
  state: ApplicationState,
  message: ApplicationMessage,
) -> actor.Next(ApplicationState, ApplicationMessage) {
  let processing_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[ApplicationActor] 🔍 PROCESSING START - ID: " <> processing_id,
  )

  case message {
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
      plan_limit_value,
      plan_limit_operator,
      plan_breach_action,
    ) -> {
      case business_actor.lookup_business_subject(business_id) {
        Ok(business_subject) ->
          // Send client metric to existing BusinessActor
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
              plan_limit_value,
              plan_limit_operator,
              plan_breach_action,
            ),
          )
        Error(_) ->
          // Spawn BusinessActor, then send client metric
          case get_or_spawn_business_simple(state.supervisor, business_id) {
            Ok(business_subject) -> {
              logging.log(
                logging.Info,
                "[ApplicationActor] ✅ Business spawned, sending metric to mailbox: "
                  <> business_id,
              )
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
                  plan_limit_value,
                  plan_limit_operator,
                  plan_breach_action,
                ),
              )
            }
            Error(error) -> {
              logging.log(
                logging.Error,
                "[ApplicationActor] ❌ Failed to spawn business: " <> error,
              )
            }
          }
      }
      actor.continue(state)
    }
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
      plan_limit_value,
      plan_limit_operator,
      plan_breach_action,
    ) -> {
      let message_id = string.inspect(utils.system_time())
      logging.log(
        logging.Info,
        "[ApplicationActor] 🎯 Processing SendMetricToUser ID: " <> message_id,
      )

      // Try to get existing user first
      case business_actor.lookup_business_subject(business_id) {
        Ok(business_subject) -> {
          logging.log(
            logging.Info,
            "[ApplicationActor] ✅ Found existing business_id, sending metric: "
              <> business_id,
          )

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
              plan_limit_value,
              plan_limit_operator,
              plan_breach_action,
            ),
          )
          logging.log(
            logging.Info,
            "[ApplicationActor] ✅ Metric sent to existing user: " <> business_id,
          )
        }
        Error(_) -> {
          // User doesn't exist - spawn it AND send metric to its mailbox
          logging.log(
            logging.Info,
            "[ApplicationActor] Business not found, spawning: " <> business_id,
          )

          case get_or_spawn_business_simple(state.supervisor, business_id) {
            Ok(business_subject) -> {
              logging.log(
                logging.Info,
                "[ApplicationActor] ✅ Business spawned, sending metric to mailbox: "
                  <> business_id,
              )

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
                  plan_limit_value,
                  plan_limit_operator,
                  plan_breach_action,
                ),
              )
              logging.log(
                logging.Info,
                "[ApplicationActor] ✅ Metric queued in new business's mailbox: "
                  <> business_id,
              )
            }
            Error(error) -> {
              logging.log(
                logging.Error,
                "[ApplicationActor] ❌ Failed to spawn business: " <> error,
              )
            }
          }
        }
      }

      logging.log(
        logging.Info,
        "[ApplicationActor] 🔍 PROCESSING END - ID: " <> processing_id,
      )
      actor.continue(state)
    }
    Shutdown -> {
      logging.log(logging.Info, "[ApplicationActor] Shutting down")
      // Shutdown all actors gracefully
      process.send(state.clock_actor, clock_actor.Shutdown)
      process.send(state.supabase_actor, supabase_actor.Shutdown)
      actor.stop()
    }
  }
}

// Start application actor that manages supervisor, clock, AND supabase actors
pub fn start_application_actor(
  supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(business_types.Message),
  ),
  clock_actor_subject: process.Subject(clock_actor.Message),
  supabase_actor_subject: process.Subject(supabase_actor.Message),
) -> Result(process.Subject(ApplicationMessage), actor.StartError) {
  let initial_state =
    ApplicationState(
      supervisor: supervisor,
      clock_actor: clock_actor_subject,
      supabase_actor: supabase_actor_subject,
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
pub fn start_app() -> Result(process.Subject(ApplicationMessage), String) {
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

  // Start application actor to manage all actors
  use app_actor <- result.try(
    start_application_actor(glixir_supervisor, clock_subject, supabase_subject)
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
