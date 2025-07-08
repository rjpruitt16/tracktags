import gleam/http.{Get, Post}
import web/handler/metric_handler
import wisp.{type Request, type Response}

pub fn handle_request(req: Request) -> Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  case wisp.path_segments(req) {
    // Health check
    ["health"] ->
      case req.method {
        Get -> health_check()
        _ -> wisp.method_not_allowed([Get])
      }

    // Metrics API
    ["api", "v1", "metrics"] ->
      case req.method {
        Post -> metric_handler.create_metric(req)
        _ -> wisp.method_not_allowed([Post])
      }

    // 404 for everything else
    _ -> wisp.not_found()
  }
}

fn health_check() -> Response {
  wisp.ok()
  |> wisp.string_body("OK")
}
