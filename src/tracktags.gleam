import actors/application
import actors/metric_actor
import actors/user_actor
import envoy
import gleam/dict
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
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

// Helper to spawn user and send metric  
fn test_user_and_metric(
  app_actor: process.Subject(application.ApplicationMessage),
  account_id: String,
  metric_name: String,
  value: Float,
) -> Nil {
  io.println(
    "[Main] 🚀 Testing user: " <> account_id <> " with metric: " <> metric_name,
  )

  // Send SendMetricToUser - this will spawn user if needed AND send the metric
  io.println(
    "[Main] 📤 Sending SendMetricToUser for: "
    <> account_id
    <> "/"
    <> metric_name,
  )
  process.send(
    app_actor,
    application.SendMetricToUser(account_id, metric_name, value, "tick_1s"),
  )

  io.println("[Main] ✅ Sent complete metric request for " <> account_id)
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}

pub fn main() {
  // Get the Clockwork SSE URL from environment or use default
  let clockwork_url =
    get_env_or("CLOCKWORK_URL", "http://localhost:4000/events")
  io.println("[Main] Using Clockwork URL: " <> clockwork_url)

  // Start the whole application 
  case application.start_app(clockwork_url) {
    Ok(app_actor) -> {
      io.println("[Main] ✅ App started successfully!")

      process.sleep(1000)
      // Wait for setup

      io.println("[Main] 🧪 Starting user and metric tests...")

      // Test 3 users with different metrics
      test_user_and_metric(app_actor, "test_user_001", "api_calls", 42.0)
      test_user_and_metric(app_actor, "test_user_002", "cpu_usage", 75.5)
      test_user_and_metric(app_actor, "test_user_003", "memory_usage", 85.2)

      io.println("[Main] ✅ All tests complete - check for subscribers!")
      process.sleep(5000)
    }
    Error(e) -> io.println("[Main] Failed to start: " <> string.inspect(e))
  }

  process.sleep_forever()
}
