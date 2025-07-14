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

/// Require an environment variable or crash
pub fn require_env(key: String) -> String {
  case envoy.get(key) {
    Ok(val) -> val
    Error(_) -> {
      logging.log(
        logging.Error,
        "[Main] Required environment variable '" <> key <> "' was not present",
      )
      panic as "Required environment variable missing"
    }
  }
}

pub fn main() {
  // Configure logging first
  logging.configure()

  io.println("[Main] 🚀 Starting TrackTags")

  // Check all required environment variables first
  let supabase_url = require_env("SUPABASE_URL")
  let supabase_key = require_env("SUPABASE_KEY")

  // Optional variables with defaults
  let clockwork_url =
    get_env_or("CLOCKWORK_URL", "http://localhost:4000/events")
  let port = 8080

  io.println("[Main] Using Clockwork URL: " <> clockwork_url)
  io.println("[Main] Using Supabase URL: " <> supabase_url)
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

      io.println("🎉 TrackTags is running!")
      io.println("📡 API: http://localhost:" <> int.to_string(port))

      process.sleep_forever()
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[Main] ❌ Failed to start application: " <> string.inspect(e),
      )
      io.println("[Main] Failed to start: " <> string.inspect(e))
      panic as "Failed to start TrackTags application"
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(exit_code: Int) -> Nil
