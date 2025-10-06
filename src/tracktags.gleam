import actors/application
import clockwork
import clockwork_schedule
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/string
import logging
import mist
import utils/cachex
import utils/utils
import web/router
import wisp
import wisp/wisp_mist

pub fn main() {
  case start_link() {
    Ok(pid) -> {
      logging.log(
        logging.Info,
        "Server started with PID: " <> string.inspect(pid),
      )
      // Keep the process alive
      process.sleep_forever()
      // or similar blocking call
    }
    Error(msg) -> {
      logging.log(logging.Error, "Failed to start: " <> msg)
    }
  }
}

pub fn start_link() -> Result(process.Pid, String) {
  logging.configure()
  logging.log(logging.Info, "[Main] start_link called")
  // crash if doesn't have resend key
  let _resend_key = utils.require_env("RESEND_API_KEY")

  let port_str = utils.get_env_or("TRACKTAGS_PORT", "4001")
  let port = case int.parse(port_str) {
    Ok(p) -> p
    Error(_) -> 4001
  }

  let bind_address = utils.get_env_or("BIND_ADDRESS", "127.0.0.1")
  logging.log(
    logging.Info,
    "[Main] Config: " <> bind_address <> ":" <> int.to_string(port),
  )

  // In your main application supervisor
  let assert Ok(recon_cron) = clockwork.from_string("0 2 * * *")
  // 2 AM daily

  // In tracktags.gleam - update the reconciliation scheduler
  let _recon_scheduler =
    clockwork_schedule.new("stripe_reconciliation", recon_cron, fn() {
      let _ =
        httpc.send(
          request.new()
          |> request.set_method(http.Post)
          |> request.set_host("127.0.0.1")
          |> request.set_port(port)
          |> request.set_path("/admin/reconcile-platform")
          |> request.set_header(
            "x-admin-key",
            utils.require_env("ADMIN_SECRET_KEY"),
          ),
        )
      Nil
    })
    |> clockwork_schedule.with_logging()
  let cache_opts = []
  // Empty list - use defaults
  case cachex.start_link("domain_cache", cache_opts) {
    Ok(_) -> logging.log(logging.Info, "Domain cache started")
    Error(e) ->
      logging.log(logging.Warning, "Cache start failed: " <> string.inspect(e))
  }
  let self_hosted =
    string.lowercase(utils.get_env_or("SELF_HOSTED", "false")) == "true"

  logging.log(logging.Info, "[Main] Calling application.start_app...")
  case application.start_app(self_hosted) {
    Error(e) -> {
      logging.log(logging.Error, "[Main] App failed: " <> string.inspect(e))
      Error("Failed to start TrackTags: " <> string.inspect(e))
    }
    Ok(_app_actor) -> {
      logging.log(logging.Info, "[Main] App started, configuring wisp...")
      wisp.configure_logger()

      logging.log(logging.Info, "[Main] Creating secret key...")
      let secret_key_base = wisp.random_string(64)

      logging.log(logging.Info, "[Main] Creating handler...")
      let handler = wisp_mist.handler(router.handle_request, secret_key_base)

      logging.log(logging.Info, "[Main] Building mist server...")
      let server = mist.new(handler)

      logging.log(logging.Info, "[Main] Setting bind address...")
      let server = mist.bind(server, bind_address)

      logging.log(logging.Info, "[Main] Setting port...")
      let server = mist.port(server, port)

      logging.log(logging.Info, "[Main] Calling mist.start...")
      case mist.start(server) {
        Ok(started) -> {
          logging.log(
            logging.Info,
            "[Main] MIST STARTED: " <> string.inspect(started),
          )
          Ok(started.pid)
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[Main] MIST FAILED: " <> string.inspect(e),
          )
          Error("Failed to start server: " <> string.inspect(e))
        }
      }
    }
  }
}
