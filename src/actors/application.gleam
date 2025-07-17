// src/actors/application.gleam
import actors/clock_actor
import actors/supabase_actor
import actors/user_actor
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
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

pub type ApplicationMessage {
  SendMetricToUser(
    account_id: String,
    metric_name: String,
    tick_type: String,
    supabase_tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    initial_value: Float,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
  )
  Shutdown
}

// Updated state to include SupabaseActor reference
pub type ApplicationState {
  ApplicationState(
    supervisor: glixir.DynamicSupervisor(
      String,
      process.Subject(user_actor.Message),
    ),
    clock_actor: process.Subject(clock_actor.Message),
    supabase_actor: process.Subject(supabase_actor.Message),
  )
}

// Encoder function for user actor arguments
fn encode_user_args(account_id: String) -> List(dynamic.Dynamic) {
  [dynamic.string(account_id)]
}

// Decoder function for user actor replies
fn decode_user_reply(
  _reply: dynamic.Dynamic,
) -> Result(process.Subject(user_actor.Message), String) {
  Ok(process.new_subject())
}

// Simple helper to get or spawn a user - NO BLOCKING!
fn get_or_spawn_user_simple(
  supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(user_actor.Message),
  ),
  account_id: String,
) -> Result(process.Subject(user_actor.Message), String) {
  // First try to find existing user
  case user_actor.lookup_user_subject(account_id) {
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

      let user_spec = user_actor.start(account_id)
      case
        glixir.start_dynamic_child(
          supervisor,
          user_spec,
          encode_user_args,
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
          case user_actor.lookup_user_subject(account_id) {
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
    SendMetricToUser(
      account_id,
      metric_name,
      tick_type,
      supabase_tick_type,
      operation,
      cleanup_after_seconds,
      metric_type,
      initial_value,
      tags,
      metadata,
    ) -> {
      let message_id = string.inspect(utils.system_time())
      logging.log(
        logging.Info,
        "[ApplicationActor] 🎯 Processing SendMetricToUser ID: " <> message_id,
      )

      // Try to get existing user first
      case user_actor.lookup_user_subject(account_id) {
        Ok(user_subject) -> {
          logging.log(
            logging.Info,
            "[ApplicationActor] ✅ Found existing user, sending metric: "
              <> account_id,
          )

          process.send(
            user_subject,
            user_actor.RecordMetric(
              metric_name,
              initial_value,
              tick_type,
              supabase_tick_type,
              operation,
              cleanup_after_seconds,
              metric_type,
              tags,
              metadata,
            ),
          )
          logging.log(
            logging.Info,
            "[ApplicationActor] ✅ Metric sent to existing user: " <> account_id,
          )
        }
        Error(_) -> {
          // User doesn't exist - spawn it AND send metric to its mailbox
          logging.log(
            logging.Info,
            "[ApplicationActor] User not found, spawning: " <> account_id,
          )

          case get_or_spawn_user_simple(state.supervisor, account_id) {
            Ok(user_subject) -> {
              logging.log(
                logging.Info,
                "[ApplicationActor] ✅ User spawned, sending metric to mailbox: "
                  <> account_id,
              )

              process.send(
                user_subject,
                user_actor.RecordMetric(
                  metric_name,
                  initial_value,
                  tick_type,
                  supabase_tick_type,
                  operation,
                  cleanup_after_seconds,
                  metric_type,
                  tags,
                  metadata,
                ),
              )
              logging.log(
                logging.Info,
                "[ApplicationActor] ✅ Metric queued in new user's mailbox: "
                  <> account_id,
              )
            }
            Error(error) -> {
              logging.log(
                logging.Error,
                "[ApplicationActor] ❌ Failed to spawn user: " <> error,
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
    process.Subject(user_actor.Message),
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
          atom.create("application_actor"),
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
  sse_url: String,
) -> Result(process.Subject(ApplicationMessage), String) {
  logging.log(
    logging.Info,
    "[Application] Starting TrackTags application with SSE URL: " <> sse_url,
  )

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
    clock_actor.start(sse_url)
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

  logging.log(
    logging.Info,
    "[Application] ✅ Application actor started and registered",
  )
  Ok(app_actor)
}
