// Fixed application.gleam - Simple non-blocking approach
import actors/clock_actor
import actors/metric_actor
import actors/user_actor
import gleam/dict
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import glixir/supervisor
import logging

pub type ApplicationMessage {
  SendMetricToUser(
    account_id: String,
    metric_name: String,
    value: Float,
    tick_type: String,
    operation: String,
  )
  Shutdown
}

// Simplified state - phantom-typed supervisor  
pub type ApplicationState {
  ApplicationState(
    supervisor: glixir.DynamicSupervisor(
      String,
      process.Subject(user_actor.Message),
    ),
  )
}

// Encoder function for user actor arguments
fn encode_user_args(account_id: String) -> List(dynamic.Dynamic) {
  [dynamic.string(account_id)]
}

// Decoder function for user actor replies
fn decode_user_reply(
  reply: dynamic.Dynamic,
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
  let processing_id = string.inspect(system_time())
  logging.log(
    logging.Info,
    "[ApplicationActor] 🔍 PROCESSING START - ID: " <> processing_id,
  )

  case message {
    SendMetricToUser(account_id, metric_name, value, tick_type, operation) -> {
      let message_id = string.inspect(system_time())
      logging.log(
        logging.Info,
        "[ApplicationActor] 🎯 Processing SendMetricToUser ID: " <> message_id,
      )

      // Create the metric once
      let test_metric =
        metric_actor.Metric(
          account_id: account_id,
          metric_name: metric_name,
          value: value,
          tags: dict.new(),
          timestamp: current_timestamp(),
        )

      // Try to get existing user first
      case user_actor.lookup_user_subject(account_id) {
        Ok(user_subject) -> {
          logging.log(
            logging.Info,
            "[ApplicationActor] ✅ Found existing user, sending metric: "
              <> account_id,
          )

          // Send RecordMetric to the existing user actor
          process.send(
            user_subject,
            user_actor.RecordMetric(
              metric_name,
              test_metric,
              value,
              tick_type,
              operation,
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

              // Send metric to newly spawned user - it will queue in mailbox
              process.send(
                user_subject,
                user_actor.RecordMetric(
                  metric_name,
                  test_metric,
                  value,
                  tick_type,
                  operation,
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
      actor.stop()
    }
  }
}

// Start application actor that manages the supervisor
pub fn start_application_actor(
  supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(user_actor.Message),
  ),
) -> Result(process.Subject(ApplicationMessage), actor.StartError) {
  let initial_state = ApplicationState(supervisor: supervisor)

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
          atom.create("tracktags_actors"),
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

// Update the start_app function
pub fn start_app(
  sse_url: String,
) -> Result(process.Subject(ApplicationMessage), String) {
  logging.log(
    logging.Info,
    "[Application] Starting TrackTags application with SSE URL: " <> sse_url,
  )

  // Start the registry with phantom types
  let assert Ok(_) = glixir.start_registry(atom.create("tracktags_actors"))
  logging.log(logging.Info, "[Application] ✅ Registry started")

  // Start dynamic supervisor with phantom types
  case glixir.start_dynamic_supervisor_named(atom.create("main_supervisor")) {
    Ok(glixir_supervisor) -> {
      logging.log(logging.Info, "[Application] ✅ Dynamic supervisor started")

      // Start ClockActor (pure Gleam version)
      case clock_actor.start(sse_url) {
        Ok(_clock_subject) -> {
          logging.log(logging.Info, "[Application] ✅ ClockActor started")

          // Start application actor to manage state
          case start_application_actor(glixir_supervisor) {
            Ok(app_actor) -> {
              logging.log(
                logging.Info,
                "[Application] ✅ Application actor started and registered",
              )
              Ok(app_actor)
            }
            Error(_error) -> {
              logging.log(
                logging.Error,
                "[Application] ❌ Failed to start application actor",
              )
              Error("Failed to start application actor")
            }
          }
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[Application] ❌ Failed to start ClockActor: " <> string.inspect(e),
          )
          Error("Failed to start ClockActor")
        }
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[Application] ❌ Supervisor start failed: " <> string.inspect(error),
      )
      Error("Failed to start supervisor: " <> string.inspect(error))
    }
  }
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
