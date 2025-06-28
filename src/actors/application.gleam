// In src/actors/application.gleam - Dynamic user spawning
import actors/metric_actor
import actors/user_actor.{type State}
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleam/string
import glixir
import logging

// External function to start Elixir application with URL
@external(erlang, "Elixir.TrackTagsApplication", "start")
fn start_elixir_application(url: String) -> dynamic.Dynamic

// Helper function to spawn a test user
fn spawn_test_user(
  supervisor: glixir.Supervisor,
  account_id: String,
) -> Result(Nil, String) {
  logging.log(logging.Debug, "[Application] Spawning test user: " <> account_id)

  let user_spec = user_actor.start(account_id)
  case glixir.start_child(supervisor, user_spec) {
    Ok(_child_pid) -> {
      logging.log(
        logging.Info,
        "[Application] ✅ Test user spawned: " <> account_id,
      )
      Ok(Nil)
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

// Helper function to spawn multiple test users
fn spawn_test_users(supervisor: glixir.Supervisor) -> Result(Nil, String) {
  let test_users = ["test_user_001", "test_user_002", "test_user_003"]

  logging.log(
    logging.Info,
    "[Application] Spawning "
      <> int.to_string(list.length(test_users))
      <> " test users",
  )

  test_users
  |> list.try_each(fn(account_id) { spawn_test_user(supervisor, account_id) })
}

pub fn start_app(
  users_to_metrics: dict.Dict(user_actor.State, List(metric_actor.State)),
  sse_url: String,
) {
  logging.log(
    logging.Debug,
    "[Application] Starting elixir application with SSE URL: " <> sse_url,
  )
  start_elixir_application(sse_url)

  logging.log(
    logging.Debug,
    "[Application] Original user count from static data: "
      <> int.to_string(list.length(dict.to_list(users_to_metrics))),
  )

  // Start dynamic supervisor
  let supervisor_result = case glixir.start_supervisor_simple() {
    Ok(glixir_supervisor) -> {
      logging.log(logging.Info, "[Application] ✅ Dynamic supervisor started")

      // Spawn test users to verify dynamic spawning works
      case spawn_test_users(glixir_supervisor) {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[Application] ✅ All test users spawned successfully",
          )
          Ok(glixir_supervisor)
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[Application] ❌ Test user spawning failed: " <> error,
          )
          // Continue anyway - the supervisor is working, just user spawning failed
          Ok(glixir_supervisor)
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

  logging.log(
    logging.Debug,
    "[Application] Final supervisor result: "
      <> string.inspect(supervisor_result),
  )
  supervisor_result
}
