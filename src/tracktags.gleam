import actors/application
import actors/metric_actor
import actors/user_actor
import envoy
import gleam/dict
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string

pub fn get_env_or(key: String, default: String) -> String {
  option.unwrap(
    case envoy.get(key) {
      Ok(val) -> Some(val)
      Error(_) -> None
    },
    default,
  )
}

// In your main function or test
pub fn main() {
  // Get the Clockwork SSE URL from environment or use default
  let clockwork_url =
    get_env_or("CLOCKWORK_URL", "http://localhost:4000/events")
  io.println("[Main] Using Clockwork URL: " <> clockwork_url)

  // Create a test metric actor state
  let test_metric =
    metric_actor.Metric(
      account_id: "test_account_123",
      metric_name: "api_calls",
      value: 0.0,
      tags: dict.new(),
      timestamp: current_timestamp(),
    )

  let metric_state =
    metric_actor.State(
      default_metric: test_metric,
      current_metric: test_metric,
      tick_type: "tick_1s",
    )

  // Create user actor state - starts with empty metric_actors dict
  // The supervisor will handle starting the actual actors
  let user_state =
    user_actor.State(metric_actors: dict.new(), account_id: "test_account_123")

  // Start the whole application with the test state and SSE URL
  case
    application.start_app(
      dict.new() |> dict.insert(user_state, [metric_state]),
      clockwork_url,
    )
  {
    Ok(actor) -> {
      io.println(
        "[Main] App started, waiting a bit then sending test messages...",
      )
      process.sleep(2000)
      // Wait 2 seconds
      // TODO: Send some test messages to user actor
      io.println("[Main] Would send test messages here")
    }
    Error(e) -> io.println("[Main] Failed to start: " <> string.inspect(e))
  }

  process.sleep_forever()
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
