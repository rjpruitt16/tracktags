// src/web/handler/admin_handler.gleam
import actors/machine_actor
import clients/supabase_client
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import utils/audit
import utils/auth
import utils/utils
import web/handler/stripe_handler
import wisp.{type Request, type Response}

// ============================================================================
// ADMIN AUTHENTICATION
// ============================================================================

fn with_admin_auth(req: Request, handler: fn() -> Response) -> Response {
  auth.with_auth(req, fn(_auth_result, _api_key, is_admin) {
    case is_admin {
      True -> handler()
      // Admin authenticated
      False -> {
        let error_json =
          json.object([
            #("error", json.string("Unauthorized")),
            #("message", json.string("Admin authentication required")),
          ])
        wisp.json_response(json.to_string_tree(error_json), 401)
      }
    }
  })
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
    Ok(#(status, price_id)) -> {
      // First, get the business to find stripe_customer_id
      case supabase_client.get_business(business_id) {
        Ok(business) -> {
          case business.stripe_customer_id {
            Some(stripe_customer_id) -> {
              case
                supabase_client.update_business_subscription(
                  stripe_customer_id,
                  // Use stripe_customer_id
                  status,
                  // status second
                  option.unwrap(price_id, "price_unknown"),
                  // price_id third
                  None,
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
                  let _ =
                    audit.log_action(
                      "override_subscription",
                      "business",
                      business_id,
                      dict.from_list([
                        #("new_status", json.string(status)),
                      ]),
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
                      #(
                        "message",
                        json.string("Failed to update subscription status"),
                      ),
                    ])
                  wisp.json_response(json.to_string_tree(error_json), 500)
                }
              }
            }
            None -> {
              let error_json =
                json.object([
                  #("error", json.string("No Stripe Customer")),
                  #(
                    "message",
                    json.string("Business has no Stripe customer ID"),
                  ),
                ])
              wisp.json_response(json.to_string_tree(error_json), 400)
            }
          }
        }
        Error(_) -> {
          let error_json =
            json.object([
              #("error", json.string("Business Not Found")),
              #("message", json.string("Could not find business")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 404)
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

pub fn provision_test(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)

  let timestamp = utils.current_timestamp()
  let test_business_id = "test_biz_" <> int.to_string(timestamp)
  let test_customer_id = "test_cust_" <> int.to_string(timestamp)

  // Create test business first
  let _ =
    supabase_client.create_business(
      test_business_id,
      "Test Business",
      "test@business.com",
    )

  // Create test customer using the existing function (it handles plan_id correctly)
  let _ =
    supabase_client.create_customer(
      test_business_id,
      test_customer_id,
      "Test Customer",
      "",
      // The create_customer function will handle empty string -> null conversion
    )

  // Now create the provisioning task
  let _result =
    supabase_client.insert_provisioning_queue(
      test_business_id,
      test_customer_id,
      "provision",
      "fly",
      dict.from_list([
        #("expires_at", int.to_string(timestamp + 86_400)),
        #("mock_mode", "true"),
      ]),
    )

  // Trigger processing
  case machine_actor.lookup_machine_actor() {
    Ok(actor) -> {
      process.send(actor, machine_actor.PollProvisioningQueue)
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("status", json.string("queued")),
            #("customer_id", json.string(test_customer_id)),
          ]),
        ),
        200,
      )
    }
    Error(e) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Machine actor not found")),
            #("details", json.string(e)),
          ]),
        ),
        500,
      )
    }
  }
}

pub fn terminate_test(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)
  use json_data <- wisp.require_json(req)

  let decoder = decode.field("customer_id", decode.string, decode.success)

  case decode.run(json_data, decoder) {
    Ok(customer_id) -> {
      // Queue terminate task with mock_mode
      let _ =
        supabase_client.insert_provisioning_queue(
          "test_business",
          customer_id,
          "terminate",
          "fly",
          dict.from_list([
            #("mock_mode", "true"),
          ]),
        )

      // Trigger processing
      case machine_actor.lookup_machine_actor() {
        Ok(actor) -> {
          process.send(actor, machine_actor.PollProvisioningQueue)
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("status", json.string("queued")),
                #("customer_id", json.string(customer_id)),
              ]),
            ),
            200,
          )
        }
        Error(_) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Machine actor not found")),
              ]),
            ),
            500,
          )
        }
      }
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Invalid request")),
          ]),
        ),
        400,
      )
    }
  }
}

pub fn force_provision(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)

  case machine_actor.lookup_machine_actor() {
    Ok(actor) -> {
      process.send(actor, machine_actor.PollProvisioningQueue)
      wisp.ok() |> wisp.string_body("Polling triggered")
    }
    Error(_) -> wisp.internal_server_error()
  }
}

// ============================================================================
// HELPERS
// ============================================================================

fn parse_override_request(
  data: Dynamic,
) -> Result(#(String, Option(String)), String) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    use price_id_opt <- decode.optional_field(
      "price_id",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(status, price_id_opt))
  }

  case decode.run(data, decoder) {
    Ok(result) -> Ok(result)
    Error(errors) ->
      Error("Invalid override payload: " <> string.inspect(errors))
  }
}

// ============================================================================
// DLQ (DEAD LETTER QUEUE) ENDPOINTS
// ============================================================================

pub fn list_failed_webhooks(req: Request) -> Response {
  use <- with_admin_auth(req)
  use <- wisp.require_method(req, http.Get)

  case supabase_client.get_failed_stripe_events(50) {
    Ok(events) -> {
      let events_json =
        events
        |> list.map(fn(event) {
          json.object([
            #("event_id", json.string(event.event_id)),
            #("event_type", json.string(event.event_type)),
            #("status", json.string(event.status)),
            #("retry_count", json.int(event.retry_count)),
            #("error_message", case event.error_message {
              Some(msg) -> json.string(msg)
              None -> json.null()
            }),
            #("created_at", json.string(event.created_at)),
          ])
        })
        |> json.array(from: _, of: fn(x) { x })

      wisp.json_response(
        json.to_string_tree(json.object([#("events", events_json)])),
        200,
      )
    }
    Error(_) -> wisp.internal_server_error()
  }
}

pub fn retry_webhook(req: Request, event_id: String) -> Response {
  use <- with_admin_auth(req)
  use <- wisp.require_method(req, http.Post)

  logging.log(logging.Info, "[AdminHandler] Retrying webhook: " <> event_id)

  case supabase_client.get_stripe_event_by_id(event_id) {
    Ok(event) -> {
      // Reprocess it
      case parse_stripe_event(event.raw_payload) {
        Ok(parsed_event) -> {
          case stripe_handler.process_stripe_event(parsed_event) {
            stripe_handler.Success(_) -> {
              let _ =
                supabase_client.update_stripe_event_status(
                  event_id,
                  "completed",
                  None,
                )
              let _ =
                audit.log_action(
                  "retry_webhook",
                  "stripe_event",
                  event_id,
                  dict.new(),
                )
              wisp.ok() |> wisp.string_body("Retry successful")
            }
            _ -> {
              let _ = supabase_client.increment_retry_count(event_id)
              wisp.internal_server_error()
              |> wisp.string_body("Retry failed")
            }
          }
        }
        Error(e) -> wisp.bad_request() |> wisp.string_body(e)
      }
    }
    Error(_) -> wisp.not_found()
  }
}

// ============================================================================
// AUDIT LOG ENDPOINTS
// ============================================================================

pub fn list_audit_logs(req: Request) -> Response {
  use <- with_admin_auth(req)
  use <- wisp.require_method(req, http.Get)

  // TODO: Add query params for filtering
  case supabase_client.get_audit_logs(100, None, None) {
    Ok(_logs) -> {
      // Return audit logs
      wisp.ok() |> wisp.string_body("Audit logs endpoint")
    }
    Error(_) -> wisp.internal_server_error()
  }
}

// Helper to parse Stripe event (make public in stripe_handler)
fn parse_stripe_event(json_string: String) {
  stripe_handler.parse_stripe_event(json_string)
}
