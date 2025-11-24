// src/web/router.gleam
import gleam/erlang/process
import gleam/http.{Delete, Get, Post, Put}
import gleam/http/request
import gleam/int
import gleam/json
import gleam/string
import logging
import glixir
import types/application_types
import utils/ip_ban
import utils/utils
import web/handler/admin_handler
import web/handler/key_handler
import web/handler/metric_handler
import web/handler/plan_handler
import web/handler/proxy_handler
import web/handler/stripe_handler
import web/handler/user_handler
import wisp.{type Request, type Response}

// Maximum request body size: 1MB
const max_body_size = 1_000_000

pub fn handle_request(req: Request) -> Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use <- require_ip_not_banned(req)
  use <- require_body_under_limit(req, max_body_size)

  // Set the max body size for wisp's internal body reading
  let req = wisp.set_max_body_size(req, max_body_size)

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
    ["admin", "v1", "customers", business_id, customer_id, "override"] ->
      case req.method {
        Post ->
          admin_handler.override_customer_subscription(
            req,
            business_id,
            customer_id,
          )
        _ -> wisp.method_not_allowed([Post])
      }

    // In router.gleam:
    ["admin", "v1", "customers", business_id, customer_id, "reset-billing"] ->
      case req.method {
        Post ->
          admin_handler.reset_customer_billing(req, business_id, customer_id)
        _ -> wisp.method_not_allowed([Post])
      }
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
    ["api", "v1", "businesses", business_id, "stripe-config"] ->
      case req.method {
        Get -> key_handler.get_stripe_config(req, business_id)
        _ -> wisp.method_not_allowed([Get])
      }

    // Business key management
    ["api", "v1", "businesses", business_id, "keys"] ->
      case req.method {
        Post -> key_handler.create_business_key(req, business_id)
        Get -> key_handler.list_business_keys(req, business_id)
        _ -> wisp.method_not_allowed([Post, Get])
      }

    // BATCH key operations (NEW)
    ["api", "v1", "businesses", business_id, "keys", "batch"] ->
      case req.method {
        Post -> key_handler.batch_upsert_business_keys(req, business_id)
        _ -> wisp.method_not_allowed([Post])
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
        Put -> user_handler.update_customer(req, customer_id)
        Delete -> user_handler.delete_customer(req, customer_id)
        _ -> wisp.method_not_allowed([Get, Put, Delete])
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

    ["api", "v1", "businesses", business_id, "customers", "get-or-create"] ->
      case req.method {
        Post -> user_handler.get_or_create_customer_for_user(req, business_id)
        _ -> wisp.method_not_allowed([Post])
      }

    ["api", "v1", "businesses", _business_id, "customers", customer_id] ->
      case req.method {
        Get -> user_handler.get_customer(req, customer_id)
        Put -> user_handler.update_customer(req, customer_id)
        Delete -> user_handler.delete_customer(req, customer_id)
        _ -> wisp.method_not_allowed([Get, Put, Delete])
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

    // Link user to customer
    [
      "api",
      "v1",
      "businesses",
      business_id,
      "customers",
      customer_id,
      "link-user",
    ] ->
      case req.method {
        Post ->
          user_handler.link_user_to_customer(req, business_id, customer_id)
        _ -> wisp.method_not_allowed([Post])
      }

    // Unlink user from customer  
    [
      "api",
      "v1",
      "businesses",
      business_id,
      "customers",
      customer_id,
      "unlink-user",
    ] ->
      case req.method {
        Post ->
          user_handler.unlink_user_from_customer(req, business_id, customer_id)
        _ -> wisp.method_not_allowed([Post])
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
        Put -> {
          logging.log(
            logging.Error,
            "🔥 ROUTER: Dispatching PUT to update_metric for: " <> metric_name,
          )
          metric_handler.update_metric(req, metric_name)
        }
        Delete -> metric_handler.delete_metric(req, metric_name)
        _ -> wisp.method_not_allowed([Get, Put, Delete])
      }

    ["api", "v1", "metrics", metric_name, "history"] ->
      case req.method {
        Get -> metric_handler.get_metric_history(req, metric_name)
        _ -> wisp.method_not_allowed([Get])
      }

    // The routes stay the same - they already call plan_handler functions:
    ["api", "v1", "plans"] ->
      case req.method {
        http.Post -> plan_handler.create_plan(req)
        http.Get -> plan_handler.list_plans(req)
        _ -> wisp.method_not_allowed([http.Post, http.Get])
      }

    ["api", "v1", "plans", plan_id] ->
      case req.method {
        http.Delete -> plan_handler.delete_plan(req, plan_id)
        _ -> wisp.method_not_allowed([http.Delete])
      }
    // Plan limits API
    ["api", "v1", "plan_limits"] ->
      case req.method {
        Get -> plan_handler.list_plan_limits(req)
        Post -> plan_handler.create_plan_limit(req)
        _ -> wisp.method_not_allowed([Get, Post])
      }

    ["api", "v1", "plan_limits", limit_id] ->
      case req.method {
        Get -> plan_handler.get_plan_limit(req, limit_id)
        Put -> plan_handler.update_plan_limit(req, limit_id)
        Delete -> plan_handler.delete_plan_limit(req, limit_id)
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

/// Middleware to reject requests with bodies exceeding the limit.
/// Checks Content-Length header first for fast rejection without reading body.
fn require_body_under_limit(
  req: Request,
  limit: Int,
  next: fn() -> Response,
) -> Response {
  case request.get_header(req, "content-length") {
    Ok(length_str) -> {
      case int.parse(length_str) {
        Ok(length) if length > limit -> {
          logging.log(
            logging.Warning,
            "[Router] Rejecting oversized request: "
              <> int.to_string(length)
              <> " bytes (limit: "
              <> int.to_string(limit)
              <> ")",
          )
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Request Too Large")),
                #(
                  "message",
                  json.string(
                    "Request body exceeds maximum size of "
                      <> int.to_string(limit / 1_000_000)
                      <> "MB",
                  ),
                ),
                #("max_bytes", json.int(limit)),
              ]),
            ),
            413,
          )
        }
        _ -> next()
      }
    }
    Error(_) -> next()
  }
}

/// Middleware to reject requests from banned IPs (429 Too Many Requests)
/// Also fires off async IP request recording (fire and forget)
fn require_ip_not_banned(req: Request, next: fn() -> Response) -> Response {
  let client_ip = get_client_ip(req)

  // Check if banned first (fast cache lookup)
  case ip_ban.is_banned(client_ip) {
    True -> {
      logging.log(
        logging.Warning,
        "[Router] Rejecting banned IP: " <> client_ip,
      )
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Too Many Requests")),
            #("message", json.string("Rate limit exceeded. Try again later.")),
            #("retry_after_seconds", json.int(300)),
          ]),
        ),
        429,
      )
    }
    False -> {
      // Fire and forget: record this IP request asynchronously
      let _ = process.spawn(fn() { record_ip_request(client_ip) })
      next()
    }
  }
}

/// Record an IP request to the application actor (fire and forget)
fn record_ip_request(ip_address: String) -> Nil {
  case get_application_actor() {
    Ok(app_actor) -> {
      process.send(app_actor, application_types.RecordIpRequest(ip_address))
    }
    Error(_) -> Nil
  }
}

fn get_application_actor() -> Result(
  process.Subject(application_types.ApplicationMessage),
  String,
) {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.application_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Application actor not found")
  }
}

/// Extract client IP from request headers
/// Checks x-forwarded-for (for reverse proxy), x-real-ip, then falls back
fn get_client_ip(req: Request) -> String {
  // Try x-forwarded-for first (comma-separated, first is client)
  case request.get_header(req, "x-forwarded-for") {
    Ok(forwarded) -> {
      // Take first IP before comma
      case string.split_once(forwarded, ",") {
        Ok(#(first_ip, _rest)) -> string.trim(first_ip)
        Error(_) -> string.trim(forwarded)
      }
    }
    Error(_) -> {
      // Try x-real-ip
      case request.get_header(req, "x-real-ip") {
        Ok(ip) -> ip
        Error(_) -> {
          // Try fly-client-ip (Fly.io specific)
          case request.get_header(req, "fly-client-ip") {
            Ok(ip) -> ip
            Error(_) -> "unknown"
          }
        }
      }
    }
  }
}
