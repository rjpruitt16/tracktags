// src/web/router.gleam
import gleam/http.{Delete, Get, Post, Put}
import web/handler/admin_handler
import web/handler/key_handler
import web/handler/metric_handler
import web/handler/plan_limit_handler
import web/handler/proxy_handler
import web/handler/stripe_handler
import web/handler/user_handler
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
    // Admin APIs
    ["admin", "v1", "replay", business_id, event_id] ->
      case req.method {
        Post -> admin_handler.replay_webhook(req, business_id, event_id)
        _ -> wisp.method_not_allowed([Post])
      }

    ["admin", "v1", "business", business_id, "override"] ->
      case req.method {
        Post -> admin_handler.override_subscription_status(req, business_id)
        _ -> wisp.method_not_allowed([Post])
      }

    ["admin", "v1", "business", business_id] ->
      case req.method {
        Get -> admin_handler.get_business_admin(req, business_id)
        _ -> wisp.method_not_allowed([Get])
      }

    ["api", "v1", "webhooks", "stripe"] ->
      case req.method {
        Post -> stripe_handler.handle_stripe_webhook(req)
        _ -> wisp.method_not_allowed([Post])
      }

    ["api", "v1", "webhooks", "stripe", business_id] ->
      case req.method {
        Post -> stripe_handler.handle_business_webhook(req, business_id)
        _ -> wisp.method_not_allowed([Post])
      }

    // Client CRUD API
    ["api", "v1", "customers"] ->
      case req.method {
        Post -> user_handler.create_customer(req)
        Get -> user_handler.list_customers(req)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    // Individual client operations
    ["api", "v1", "customers", customer_id] ->
      case req.method {
        Get -> user_handler.get_customer(req, customer_id)
        Delete -> user_handler.delete_customer(req, customer_id)
        _ -> wisp.method_not_allowed([Get, Delete])
      }

    // Client key management
    ["api", "v1", "customers", customer_id, "keys"] ->
      case req.method {
        Post -> key_handler.create_customer_key(req, customer_id)
        Get -> key_handler.list_customer_keys(req, customer_id)
        _ -> wisp.method_not_allowed([Post, Get])
      }
    // Add business endpoint
    ["api", "v1", "businesses"] ->
      case req.method {
        Post -> user_handler.create_business(req)
        _ -> wisp.method_not_allowed([Post])
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
    ["api", "v1", "plan_limits"] ->
      case req.method {
        http.Get -> plan_limit_handler.list_plan_limits(req)
        http.Post -> plan_limit_handler.create_plan_limit(req)
        _ -> wisp.method_not_allowed([http.Get, http.Post])
      }
    ["api", "v1", "plan_limits", limit_id] ->
      case req.method {
        http.Get -> plan_limit_handler.get_plan_limit(req, limit_id)
        http.Put -> plan_limit_handler.update_plan_limit(req, limit_id)
        http.Delete -> plan_limit_handler.delete_plan_limit(req, limit_id)
        _ -> wisp.method_not_allowed([http.Get, http.Put, http.Delete])
      }

    // 404 for everything else
    // Add this route in your router
    ["api", "v1", "proxy"] ->
      case req.method {
        Post -> proxy_handler.check_and_forward(req)
        _ -> wisp.method_not_allowed([Post])
      }

    _ -> wisp.not_found()
  }
}

fn health_check() -> Response {
  wisp.ok()
  |> wisp.string_body("OK")
}
