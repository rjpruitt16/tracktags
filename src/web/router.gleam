// src/web/router.gleam
import gleam/http.{Delete, Get, Post, Put}
import web/handler/integration_handler
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

    // Metrics CRUD API
    ["api", "v1", "metrics"] ->
      case req.method {
        Post -> metric_handler.create_metric(req)
        Get -> metric_handler.list_metrics(req)
        // TODO: Implement
        _ -> wisp.method_not_allowed([Post, Get])
      }

    // Individual metric operations
    ["api", "v1", "metrics", metric_name] ->
      case req.method {
        Get -> metric_handler.get_metric(req, metric_name)
        Put -> metric_handler.update_metric(req, metric_name)
        Delete -> metric_handler.delete_metric(req, metric_name)
        _ -> wisp.method_not_allowed([Get, Put, Delete])
      }

    // Integration management - unified API
    ["api", "v1", "integrations"] ->
      case req.method {
        Post -> integration_handler.create_integration(req)
        Get -> integration_handler.list_integrations(req)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    // Individual integration operations
    ["api", "v1", "integrations", integration_type] ->
      case req.method {
        Get ->
          integration_handler.get_integrations_by_type(req, integration_type)
        _ -> wisp.method_not_allowed([Get])
      }

    // Specific integration by type and name
    ["api", "v1", "integrations", integration_type, key_name] ->
      case req.method {
        Get ->
          integration_handler.get_integration(req, integration_type, key_name)
        Put ->
          integration_handler.update_integration(
            req,
            integration_type,
            key_name,
          )
        Delete ->
          integration_handler.delete_integration(
            req,
            integration_type,
            key_name,
          )
        _ -> wisp.method_not_allowed([Get, Put, Delete])
      }

    // Metric history/analytics
    ["api", "v1", "metrics", metric_name, "history"] ->
      case req.method {
        Get -> metric_handler.get_metric_history(req, metric_name)
        _ -> wisp.method_not_allowed([Get])
      }

    // 404 for everything else
    _ -> wisp.not_found()
  }
}

fn health_check() -> Response {
  wisp.ok()
  |> wisp.string_body("OK")
}
