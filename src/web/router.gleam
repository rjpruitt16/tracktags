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

    // Admin webhooks
    ["admin", "webhooks", "failed"] ->
      case req.method {
        Get -> admin_handler.list_failed_webhooks(req)
        _ -> wisp.method_not_allowed([Get])
      }

    ["admin", "webhooks", "retry", event_id] ->
      case req.method {
        Post -> admin_handler.retry_webhook(req, event_id)
        _ -> wisp.method_not_allowed([Post])
      }

    ["admin", "audit-logs"] ->
      case req.method {
        Get -> admin_handler.list_audit_logs(req)
        _ -> wisp.method_not_allowed([Get])
      }

    ["admin", "reconcile-platform"] ->
      case req.method {
        Post -> admin_handler.reconcile_platform(req)
        _ -> wisp.method_not_allowed([Post])
      }

    // Admin v1 APIs
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

    ["admin", "provision", "test"] -> admin_handler.provision_test(req)
    ["admin", "terminate", "test"] -> admin_handler.terminate_test(req)
    ["admin", "force-provision"] -> admin_handler.force_provision(req)

    // Business management
    ["api", "v1", "businesses"] ->
      case req.method {
        Post -> user_handler.create_business(req)
        _ -> wisp.method_not_allowed([Post])
      }

    ["api", "v1", "businesses", business_id] ->
      case req.method {
        Delete -> user_handler.delete_business(req, business_id)
        Put -> user_handler.update_business_info(req, business_id)
        _ -> wisp.method_not_allowed([Delete, Put])
      }

    ["api", "v1", "businesses", business_id, "restore"] ->
      case req.method {
        Post -> user_handler.restore_business(req, business_id)
        _ -> wisp.method_not_allowed([Post])
      }

    // Business key management
    ["api", "v1", "businesses", business_id, "keys"] ->
      case req.method {
        Post -> key_handler.create_business_key(req, business_id)
        Get -> key_handler.list_business_keys(req, business_id)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    ["api", "v1", "businesses", business_id, "keys", key_type, key_name] ->
      case req.method {
        Get ->
          key_handler.get_business_key(req, business_id, key_type, key_name)
        Put ->
          key_handler.update_business_key(req, business_id, key_type, key_name)
        Delete ->
          key_handler.delete_business_key(req, business_id, key_type, key_name)
        _ -> wisp.method_not_allowed([Get, Put, Delete])
      }

    // Customer management (OLD ROUTES - kept for backwards compatibility)
    ["api", "v1", "customers"] ->
      case req.method {
        Post -> user_handler.create_customer(req)
        Get -> user_handler.list_customers(req)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    ["api", "v1", "customers", customer_id] ->
      case req.method {
        Get -> user_handler.get_customer(req, customer_id)
        Delete -> user_handler.delete_customer(req, customer_id)
        _ -> wisp.method_not_allowed([Get, Delete])
      }

    ["api", "v1", "customers", customer_id, "machines"] ->
      case req.method {
        Get -> user_handler.get_customer_machines(req, customer_id)
        _ -> wisp.method_not_allowed([Get])
      }

    // Customer management (NEW ROUTES - business scoped)
    ["api", "v1", "businesses", _business_id, "customers"] ->
      case req.method {
        Post -> user_handler.create_customer(req)
        Get -> user_handler.list_customers(req)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    ["api", "v1", "businesses", _business_id, "customers", customer_id] ->
      case req.method {
        Get -> user_handler.get_customer(req, customer_id)
        Delete -> user_handler.delete_customer(req, customer_id)
        _ -> wisp.method_not_allowed([Get, Delete])
      }

    [
      "api",
      "v1",
      "businesses",
      _business_id,
      "customers",
      customer_id,
      "machines",
    ] ->
      case req.method {
        Get -> user_handler.get_customer_machines(req, customer_id)
        _ -> wisp.method_not_allowed([Get])
      }

    // Customer key management
    ["api", "v1", "businesses", business_id, "customers", customer_id, "keys"] ->
      case req.method {
        Post -> key_handler.create_customer_key(req, business_id, customer_id)
        Get -> key_handler.list_customer_keys(req, business_id, customer_id)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    [
      "api",
      "v1",
      "businesses",
      business_id,
      "customers",
      customer_id,
      "keys",
      key_name,
    ] ->
      case req.method {
        Get ->
          key_handler.get_business_key(
            req,
            business_id,
            "customer_api",
            key_name,
          )
        Delete ->
          key_handler.delete_customer_key(
            req,
            business_id,
            customer_id,
            key_name,
          )
        _ -> wisp.method_not_allowed([Get, Delete])
      }

    // Stripe webhooks
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

    // Metrics API
    ["api", "v1", "metrics"] ->
      case req.method {
        Post -> metric_handler.create_metric(req)
        Get -> metric_handler.list_metrics(req)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    ["api", "v1", "metrics", metric_name] ->
      case req.method {
        Get -> metric_handler.get_metric(req, metric_name)
        Put -> metric_handler.update_metric(req, metric_name)
        Delete -> metric_handler.delete_metric(req, metric_name)
        _ -> wisp.method_not_allowed([Get, Put, Delete])
      }

    ["api", "v1", "metrics", metric_name, "history"] ->
      case req.method {
        Get -> metric_handler.get_metric_history(req, metric_name)
        _ -> wisp.method_not_allowed([Get])
      }

    // Plan limits API
    ["api", "v1", "plan_limits"] ->
      case req.method {
        Get -> plan_limit_handler.list_plan_limits(req)
        Post -> plan_limit_handler.create_plan_limit(req)
        _ -> wisp.method_not_allowed([Get, Post])
      }

    ["api", "v1", "plan_limits", limit_id] ->
      case req.method {
        Get -> plan_limit_handler.get_plan_limit(req, limit_id)
        Put -> plan_limit_handler.update_plan_limit(req, limit_id)
        Delete -> plan_limit_handler.delete_plan_limit(req, limit_id)
        _ -> wisp.method_not_allowed([Get, Put, Delete])
      }

    // Proxy API
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
