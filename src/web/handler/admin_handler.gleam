// src/web/handler/admin_handler.gleam
import clients/supabase_client
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import logging
import web/handler/stripe_handler
import wisp.{type Request, type Response}

// ============================================================================
// ADMIN AUTHENTICATION
// ============================================================================

/// Simple admin token check (expand later if needed)
fn check_admin_auth(req: Request) -> Result(Nil, Response) {
  case list.key_find(req.headers, "x-admin-token") {
    Ok(token) -> {
      let admin_secret = utils.require_env("ADMIN_SECRET_TOKEN")
      case token == admin_secret {
        True -> Ok(Nil)
        False -> unauthorized_response()
      }
    }
    Error(_) -> unauthorized_response()
  }
}

fn unauthorized_response() -> Result(Nil, Response) {
  logging.log(logging.Warning, "[AdminHandler] Unauthorized admin access")
  let error_json =
    json.object([
      #("error", json.string("Unauthorized")),
      #("message", json.string("Invalid admin token")),
    ])
  Error(wisp.json_response(json.to_string_tree(error_json), 401))
}

/// Auth wrapper for admin endpoints
fn with_admin_auth(req: Request, handler: fn() -> Response) -> Response {
  case check_admin_auth(req) {
    Ok(_) -> handler()
    Error(response) -> response
  }
}

// ============================================================================
// ADMIN ENDPOINTS
// ============================================================================

/// Replay a specific Stripe webhook event
pub fn replay_webhook(
  req: Request,
  business_id: String,
  event_id: String,
) -> Response {
  use <- with_admin_auth(req)
  use <- wisp.require_method(req, http.Post)

  logging.log(
    logging.Info,
    "[AdminHandler] Replaying webhook: " <> business_id <> "/" <> event_id,
  )

  case stripe_handler.fetch_and_process_stripe_event(business_id, event_id) {
    Ok(message) -> {
      logging.log(
        logging.Info,
        "[AdminHandler] ✅ Webhook replay successful: " <> message,
      )
      let success_json =
        json.object([
          #("status", json.string("success")),
          #("business_id", json.string(business_id)),
          #("event_id", json.string(event_id)),
          #("message", json.string(message)),
        ])
      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[AdminHandler] ❌ Webhook replay failed: " <> error,
      )
      let error_json =
        json.object([
          #("error", json.string("Replay Failed")),
          #("business_id", json.string(business_id)),
          #("event_id", json.string(event_id)),
          #("message", json.string(error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

/// Override subscription status for emergency fixes
pub fn override_subscription_status(
  req: Request,
  business_id: String,
) -> Response {
  use <- with_admin_auth(req)
  use <- wisp.require_method(req, http.Post)
  use json_data <- wisp.require_json(req)

  logging.log(
    logging.Info,
    "[AdminHandler] Overriding subscription for: " <> business_id,
  )

  // Parse override request
  case parse_override_request(json_data) {
    Ok(#(status, subscription_id)) -> {
      case
        supabase_client.update_business_subscription(
          business_id,
          subscription_id,
          status,
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[AdminHandler] ✅ Subscription override successful: "
              <> business_id
              <> " -> "
              <> status,
          )
          let success_json =
            json.object([
              #("status", json.string("success")),
              #("business_id", json.string(business_id)),
              #("subscription_status", json.string(status)),
              #("message", json.string("Subscription status updated")),
            ])
          wisp.json_response(json.to_string_tree(success_json), 200)
        }
        Error(_) -> {
          let error_json =
            json.object([
              #("error", json.string("Update Failed")),
              #("message", json.string("Failed to update subscription status")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
    Error(error) -> {
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string(error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

/// Get business details for admin dashboard
pub fn get_business_admin(req: Request, business_id: String) -> Response {
  use <- with_admin_auth(req)
  use <- wisp.require_method(req, http.Get)

  logging.log(
    logging.Info,
    "[AdminHandler] Getting business details: " <> business_id,
  )

  case supabase_client.get_business(business_id) {
    Ok(business) -> {
      let business_json =
        json.object([
          #("business_id", json.string(business.business_id)),
          #("business_name", json.string(business.business_name)),
          #("email", json.string(business.email)),
          #("plan_type", json.string(business.plan_type)),
          #("stripe_customer_id", case business.stripe_customer_id {
            Some(id) -> json.string(id)
            None -> json.null()
          }),
        ])
      wisp.json_response(json.to_string_tree(business_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      let error_json =
        json.object([
          #("error", json.string("Not Found")),
          #("message", json.string("Business not found")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 404)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch business")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

// ============================================================================
// HELPERS
// ============================================================================

// Fix parse_override_request function:
fn parse_override_request(
  json_data: Dynamic,
) -> Result(#(String, Option(String)), String) {
  case decode.run(json_data, override_decoder()) {
    Ok(data) -> Ok(data)
    Error(_) -> Error("Invalid override request format")
  }
}

fn override_decoder() {
  use status <- decode.field("status", decode.string)
  use subscription_id <- decode.optional_field(
    "subscription_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(status, subscription_id))
}
