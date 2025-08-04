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

pub fn main() {
  // Configure logging first
  logging.configure()

  let port = 8080

  // Start the TrackTags application (actors, registry, etc.)
  case application.start_app() {
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
