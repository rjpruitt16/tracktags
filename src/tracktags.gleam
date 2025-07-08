import actors/application
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/string
import logging
import mist
import web/router
import wisp
import wisp/wisp_mist

pub fn get_env_or(key: String, default: String) -> String {
  option.unwrap(
    case envoy.get(key) {
      Ok(val) -> Some(val)
      Error(_) -> None
    },
    default,
  )
}

pub fn main() {
  // Configure logging
  logging.configure()

  // Get configuration from environment
  let clockwork_url =
    get_env_or("CLOCKWORK_URL", "http://localhost:4000/events")
  let port = 8080

  io.println("[Main] 🚀 Starting TrackTags")
  io.println("[Main] Using Clockwork URL: " <> clockwork_url)
  io.println("[Main] API will be available on port: " <> int.to_string(port))

  // Start the TrackTags application (actors, registry, etc.)
  case application.start_app(clockwork_url) {
    Ok(_app_actor) -> {
      logging.log(
        logging.Info,
        "[Main] ✅ TrackTags application started successfully!",
      )

      // Configure Wisp
      wisp.configure_logger()
      let secret_key_base = wisp.random_string(64)

      // Create the Wisp handler for Mist using wisp_mist submodule
      let handler = wisp_mist.handler(router.handle_request, secret_key_base)

      // Start the web server
      let assert Ok(_) =
        handler
        |> mist.new
        |> mist.port(port)
        |> mist.start

      logging.log(logging.Info, "[Main] ✅ Web server started successfully!")

      io.println("")
      io.println("🎉 TrackTags is running!")
      io.println(
        "📡 Metrics API: http://localhost:"
        <> int.to_string(port)
        <> "/api/v1/metrics",
      )
      io.println(
        "❤️  Health Check: http://localhost:" <> int.to_string(port) <> "/health",
      )
      io.println("")
      io.println("📖 Test with curl:")
      io.println(
        "curl -X POST http://localhost:"
        <> int.to_string(port)
        <> "/api/v1/metrics \\",
      )
      io.println("  -H \"Authorization: Bearer tk_live_test123\" \\")
      io.println("  -H \"Content-Type: application/json\" \\")
      io.println("  -d '{\"metric_name\": \"api_calls\", \"value\": 1.0}'")
      io.println("")

      process.sleep_forever()
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[Main] ❌ Failed to start application: " <> string.inspect(e),
      )
      io.println("[Main] Failed to start: " <> string.inspect(e))
    }
  }
}
