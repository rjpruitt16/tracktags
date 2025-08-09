import actors/application
import gleam/erlang/process
import gleam/result
import gleam/string
import logging
import mist
import utils/utils
import web/router
import wisp
import wisp/wisp_mist

pub fn main() {
  case start_link() {
    Ok(_pid) -> process.sleep_forever()
    Error(_e) -> panic as "TrackTags failed to boot"
  }
}

pub fn start_link() -> Result(process.Pid, String) {
  logging.configure()
  let port = 8080
  let self_hosted =
    string.lowercase(utils.get_env_or("SELF_HOSTED", "false")) == "true"

  // boot actor tree
  use _app_actor <- result.try(
    application.start_app(self_hosted)
    |> result.map_error(fn(e) {
      "Failed to start TrackTags: " <> string.inspect(e)
    }),
  )

  // boot HTTP server
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)
  let handler = wisp_mist.handler(router.handle_request, secret_key_base)

  handler
  |> mist.new
  |> mist.port(port)
  |> mist.start()
  |> result.map(fn(started) { started.pid })
  |> result.map_error(fn(e) { "Failed to start Mist: " <> string.inspect(e) })
}
