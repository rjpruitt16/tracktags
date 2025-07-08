// Refactored application.gleam - Clean and stateless with lookup pattern
import actors/metric_actor
import actors/user_actor
import gleam/dict
import gleam/dynamic
import gleam/erlang/process
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import logging

// Simplified application messages - removed GetOrSpawnUser since we use direct lookup
pub type ApplicationMessage {
  SendMetricToUser(
    account_id: String,
    metric_name: String,
    value: Float,
    tick_type: String,
  )
  Shutdown
}

// Simplified state - just need the supervisor, no user tracking
pub type ApplicationState {
  ApplicationState(supervisor: glixir.Supervisor)
}

// External function to start Elixir application with URL - returns a Result
@external(erlang, "Elixir.TrackTagsApplication", "start")
fn start_elixir_application_raw(url: String) -> dynamic.Dynamic

// Wrapper to handle the Elixir return value properly
fn start_elixir_application(url: String) -> Result(dynamic.Dynamic, String) {
  let result = start_elixir_application_raw(url)

  // The Elixir function returns {:ok, pid} or {:error, reason}
  // We just need it to succeed, we don't need the pid
  case result {
    _ -> {
      logging.log(logging.Info, "[Application] ✅ Elixir application started")
      Ok(result)
    }
  }
}

// Helper function to get or spawn a user using lookup pattern
fn get_or_spawn_user(
  supervisor: glixir.Supervisor,
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
      // Need to spawn new user
      logging.log(
        logging.Debug,
        "[Application] Spawning new user: " <> account_id,
      )

      let user_spec = user_actor.start(account_id)
      case glixir.start_child(supervisor, user_spec) {
        Ok(_child_pid) -> {
          logging.log(
            logging.Info,
            "[Application] ✅ User spawned: " <> account_id,
          )

          // Give it a moment to register, then look it up
          process.sleep(50)
          case user_actor.lookup_user_subject(account_id) {
            Ok(user_subject) -> {
              logging.log(
                logging.Info,
                "[Application] ✅ Found newly spawned user: " <> account_id,
              )
              Ok(user_subject)
            }
            Error(_) -> {
              let error_msg =
                "User spawned but not found in registry: " <> account_id
              logging.log(logging.Error, "[Application] ❌ " <> error_msg)
              Error(error_msg)
            }
          }
        }
        Error(error) -> {
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

// Simplified application actor message handler
fn handle_application_message(
  state: ApplicationState,
  message: ApplicationMessage,
) -> actor.Next(ApplicationState, ApplicationMessage) {
  logging.log(
    logging.Info,
    "[ApplicationActor] Received message: " <> string.inspect(message),
  )

  case message {
    SendMetricToUser(account_id, metric_name, value, tick_type) -> {
      logging.log(
        logging.Info,
        "[ApplicationActor] Sending metric "
          <> metric_name
          <> " to user "
          <> account_id,
      )

      // Get or spawn the user
      case get_or_spawn_user(state.supervisor, account_id) {
        Ok(user_subject) -> {
          // Create the metric
          let test_metric =
            metric_actor.Metric(
              account_id: account_id,
              metric_name: metric_name,
              value: value,
              tags: dict.new(),
              timestamp: current_timestamp(),
            )

          // Send RecordMetric to the user actor
          process.send(
            user_subject,
            user_actor.RecordMetric(metric_name, test_metric, value, tick_type),
          )
          logging.log(
            logging.Info,
            "[ApplicationActor] ✅ Sent RecordMetric to user " <> account_id,
          )

          actor.continue(state)
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[ApplicationActor] Failed to get user for metric: " <> error,
          )
          actor.continue(state)
        }
      }
    }

    Shutdown -> {
      logging.log(logging.Info, "[ApplicationActor] Shutting down")
      actor.stop()
    }
  }
}

// Start application actor that manages the supervisor
pub fn start_application_actor(
  supervisor: glixir.Supervisor,
) -> Result(process.Subject(ApplicationMessage), actor.StartError) {
  let initial_state = ApplicationState(supervisor: supervisor)

  actor.new(initial_state)
  |> actor.on_message(handle_application_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

pub fn start_app(
  sse_url: String,
) -> Result(process.Subject(ApplicationMessage), String) {
  logging.log(
    logging.Info,
    "[TrackTagsApplication] Starting application with SSE URL: " <> sse_url,
  )

  // Start the Elixir application first and handle the result properly
  case start_elixir_application(sse_url) {
    Ok(_) -> {
      logging.log(logging.Info, "[Application] ✅ Elixir application started")

      // Start the registry
      let assert Ok(_) = glixir.start_registry("tracktags_actors")
      logging.log(logging.Info, "[Application] ✅ Registry started")

      // Start dynamic supervisor
      case glixir.start_supervisor_simple() {
        Ok(glixir_supervisor) -> {
          logging.log(
            logging.Info,
            "[Application] ✅ Dynamic supervisor started",
          )

          // Start application actor to manage state
          case start_application_actor(glixir_supervisor) {
            Ok(app_actor) -> {
              logging.log(
                logging.Info,
                "[Application] ✅ Application actor started",
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
        Error(error) -> {
          logging.log(
            logging.Error,
            "[Application] ❌ Supervisor start failed: " <> string.inspect(error),
          )
          Error("Failed to start supervisor: " <> string.inspect(error))
        }
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[Application] ❌ Failed to start Elixir application: " <> error,
      )
      Error("Failed to start Elixir application: " <> error)
    }
  }
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
