// src/web/router.gleam
import gleam/http.{Delete, Get, Post, Put}
import web/handler/client_handler
import web/handler/key_handler
import web/handler/metric_handler
import web/handler/stripe_handler
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

    // Stripe webhooks
    // In your router.gleam, add:
    ["api", "v1", "webhooks", "stripe"] ->
      case req.method {
        Post -> stripe_handler.handle_stripe_webhook(req)
        _ -> wisp.method_not_allowed([Post])
      }
    // Client CRUD API
    ["api", "v1", "clients"] ->
      case req.method {
        Post -> client_handler.create_client(req)
        Get -> client_handler.list_clients(req)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    // Individual client operations
    ["api", "v1", "clients", client_id] ->
      case req.method {
        Get -> client_handler.get_client(req, client_id)
        Delete -> client_handler.delete_client(req, client_id)
        _ -> wisp.method_not_allowed([Get, Delete])
      }

    // Client key management
    ["api", "v1", "clients", client_id, "keys"] ->
      case req.method {
        Post -> client_handler.create_client_key(req, client_id)
        Get -> client_handler.list_client_keys(req, client_id)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    // Individual client key operations
    ["api", "v1", "clients", client_id, "keys", key_id] ->
      case req.method {
        Delete -> client_handler.delete_client_key(req, client_id, key_id)
        _ -> wisp.method_not_allowed([Delete])
      }

    // Metrics CRUD API
    ["api", "v1", "metrics"] ->
      case req.method {
        Post -> metric_handler.create_metric(req)
        Get -> metric_handler.list_metrics(req)
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

    // key management - unified API
    ["api", "v1", "keys"] ->
      case req.method {
        Post -> key_handler.create_key(req)
        Get -> key_handler.list_key(req)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    // Individual key operations
    ["api", "v1", "keys", key_type] ->
      case req.method {
        Get -> key_handler.get_key_by_type(req, key_type)
        _ -> wisp.method_not_allowed([Get])
      }

    // Specific key by type and name
    ["api", "v1", "keys", key_type, key_name] ->
      case req.method {
        Get -> key_handler.get_key(req, key_type, key_name)
        Put -> key_handler.update_key(req, key_type, key_name)
        Delete -> key_handler.delete_key(req, key_type, key_name)
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
