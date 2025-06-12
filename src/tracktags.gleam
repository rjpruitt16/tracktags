import clients/clockwork_client
import envoy
import gleam/erlang/process
import gleam/io
import gleam/option.{None, Some}

// Helper: get env or return default if not set
pub fn get_env_or(key: String, default: String) -> String {
  option.unwrap(
    case envoy.get(key) {
      Ok(val) -> Some(val)
      Error(_) -> None
    },
    default,
  )
}

// Main entry point for TrackTags
pub fn main() {
  io.println("Starting TrackTags...")

  let clockwork_url =
    get_env_or("CLOCKWORK_URL", "http://localhost:4000/events")
  io.println("Will connect to Clockwork at: " <> clockwork_url)
  io.println("(Launching SSE client)")

  // Start the Elixir SSE client bridge
  clockwork_client.start_sse(
    clockwork_url,
    fn(event: clockwork_client.SSEEvent) {
      io.println("Received SSE event: " <> event.data)
      Nil
    },
  )
  io.println("✅ clockwork_client (SSE) started")

  io.println("\nTrackTags is running. Press Ctrl+C to stop.")
  process.sleep_forever()
}
