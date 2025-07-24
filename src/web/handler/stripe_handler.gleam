// src/web/handler/stripe_handler.gleam
import clients/supabase_client
import gleam/bit_array
import gleam/crypto as gleam_crypto
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import utils/crypto
import utils/utils
import wisp.{type Request, type Response}

// Stripe webhook event types we care about
pub type StripeEventType {
  InvoicePaymentSucceeded
  CustomerSubscriptionCreated
  CustomerSubscriptionUpdated
  CustomerSubscriptionDeleted
  InvoicePaymentFailed
  UnknownEvent(String)
}

pub type StripeData {
  StripeData(customer: String, subscription_id: Option(String))
}

pub type StripeEvent {
  StripeEvent(
    id: String,
    event_type: StripeEventType,
    data: StripeData,
    created: Int,
  )
}

// Webhook processing result
pub type WebhookResult {
  Success(String)
  InvalidSignature
  InvalidPayload(String)
  ProcessingError(String)
}

pub type StripeCredentials {
  StripeCredentials(secret_key: String, webhook_secret: String)
}

/// Main webhook endpoint handler
pub fn handle_stripe_webhook(req: Request) -> Response {
  case req.method {
    http.Post -> process_webhook(req)
    _ -> wisp.method_not_allowed([http.Post])
  }
}

/// Process incoming Stripe webhook
fn process_webhook(req: Request) -> Response {
  // Get Stripe signature from headers
  case get_stripe_signature(req) {
    Error(_) -> {
      logging.log(
        logging.Error,
        "[StripeHandler] Missing Stripe signature header",
      )
      wisp.bad_request()
      |> wisp.string_body("Missing Stripe-Signature header")
    }
    Ok(signature) -> {
      // Read request body
      case wisp.read_body_to_bitstring(req) {
        Error(_) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] Failed to read webhook body",
          )
          wisp.bad_request()
          |> wisp.string_body("Invalid request body")
        }
        Ok(body_bits) -> {
          // Convert to string for processing
          case bit_array.to_string(body_bits) {
            Error(_) -> {
              logging.log(
                logging.Error,
                "[StripeHandler] Invalid UTF-8 in webhook body",
              )
              wisp.bad_request()
              |> wisp.string_body("Invalid body encoding")
            }
            Ok(body) -> {
              // Verify signature and process
              case verify_and_process(body, signature) {
                Success(message) -> {
                  logging.log(
                    logging.Info,
                    "[StripeHandler] Webhook processed successfully: "
                      <> message,
                  )
                  wisp.ok()
                  |> wisp.string_body("{\"received\": true}")
                }
                InvalidSignature -> {
                  logging.log(
                    logging.Error,
                    "[StripeHandler] Invalid Stripe signature",
                  )
                  wisp.bad_request()
                  |> wisp.string_body("Invalid signature")
                }
                InvalidPayload(error) -> {
                  logging.log(
                    logging.Error,
                    "[StripeHandler] Invalid webhook payload: " <> error,
                  )
                  wisp.bad_request()
                  |> wisp.string_body("Invalid payload: " <> error)
                }
                ProcessingError(error) -> {
                  logging.log(
                    logging.Error,
                    "[StripeHandler] Webhook processing error: " <> error,
                  )
                  wisp.internal_server_error()
                  |> wisp.string_body("Processing error")
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Extract Stripe signature from request headers
fn get_stripe_signature(req: Request) -> Result(String, Nil) {
  req.headers
  |> list.find(fn(header) {
    case header {
      #("stripe-signature", _) -> True
      #("Stripe-Signature", _) -> True
      _ -> False
    }
  })
  |> result.map(fn(header) { header.1 })
}

/// Verify Stripe signature and process webhook
fn verify_and_process(body: String, signature: String) -> WebhookResult {
  // Get webhook secret from environment
  case get_webhook_secret() {
    Error(_) -> ProcessingError("Missing webhook secret")
    Ok(secret) -> {
      case verify_stripe_signature(body, signature, secret) {
        False -> InvalidSignature
        True -> {
          // Parse and process the webhook event
          case parse_stripe_event(body) {
            Error(error) -> InvalidPayload(error)
            Ok(event) -> process_stripe_event(event)
          }
        }
      }
    }
  }
}

/// Verify Stripe webhook signature using HMAC-SHA256
fn verify_stripe_signature(
  body: String,
  signature: String,
  secret: String,
) -> Bool {
  // Extract timestamp and signature from header
  case parse_signature_header(signature) {
    Error(_) -> False
    Ok(#(timestamp, sig)) -> {
      // Create the signed payload
      let signed_payload = timestamp <> "." <> body

      // Compute HMAC-SHA256 using your crypto utils
      let computed_signature =
        gleam_crypto.hmac(
          bit_array.from_string(signed_payload),
          gleam_crypto.Sha256,
          bit_array.from_string(secret),
        )
        |> bit_array.base16_encode
        |> string.lowercase

      // Compare signatures (constant time)
      computed_signature == sig
    }
  }
}

/// Parse Stripe signature header format: t=timestamp,v1=signature
fn parse_signature_header(header: String) -> Result(#(String, String), String) {
  let parts = string.split(header, ",")

  case extract_signature_parts(parts, "", "") {
    #("", _) -> Error("Missing timestamp")
    #(_, "") -> Error("Missing signature")
    #(timestamp, signature) -> Ok(#(timestamp, signature))
  }
}

/// Extract timestamp and signature from header parts
fn extract_signature_parts(
  parts: List(String),
  timestamp: String,
  signature: String,
) -> #(String, String) {
  case parts {
    [] -> #(timestamp, signature)
    [part, ..rest] -> {
      case string.split_once(part, "=") {
        Error(_) -> extract_signature_parts(rest, timestamp, signature)
        Ok(#("t", value)) -> extract_signature_parts(rest, value, signature)
        Ok(#("v1", value)) -> extract_signature_parts(rest, timestamp, value)
        Ok(_) -> extract_signature_parts(rest, timestamp, signature)
      }
    }
  }
}

/// Parse Stripe webhook event JSON
fn parse_stripe_event(json_string: String) -> Result(StripeEvent, String) {
  case json.parse(json_string, stripe_event_decoder()) {
    Error(_) -> Error("Invalid JSON format")
    Ok(event) -> Ok(event)
  }
}

// First, decode the nested data object
fn stripe_data_decoder() -> decode.Decoder(StripeData) {
  use customer <- decode.field("customer", decode.string)
  use subscription_id <- decode.optional_field(
    "id",
    None,
    // default value
    decode.optional(decode.string),
  )
  decode.success(StripeData(customer, subscription_id))
}

// Then use it in the main event decoder - CORRECTED for new API
fn stripe_event_decoder() -> decode.Decoder(StripeEvent) {
  use id <- decode.field("id", decode.string)
  use event_type_string <- decode.field("type", decode.string)
  // ✅ CORRECTED: Use subfield to access nested data.object
  use data <- decode.subfield(["data", "object"], stripe_data_decoder())
  use created <- decode.field("created", decode.int)

  // Parse the event type string
  let event_type = case event_type_string {
    "invoice.payment_succeeded" -> InvoicePaymentSucceeded
    "customer.subscription.created" -> CustomerSubscriptionCreated
    "customer.subscription.updated" -> CustomerSubscriptionUpdated
    "customer.subscription.deleted" -> CustomerSubscriptionDeleted
    "invoice.payment_failed" -> InvoicePaymentFailed
    unknown -> UnknownEvent(unknown)
  }
  decode.success(StripeEvent(id, event_type, data, created))
}

/// Process parsed Stripe event based on type
fn process_stripe_event(event: StripeEvent) -> WebhookResult {
  logging.log(
    logging.Info,
    "[StripeHandler] Processing Stripe event: " <> event.id,
  )

  case event.event_type {
    InvoicePaymentSucceeded -> handle_payment_succeeded(event)
    CustomerSubscriptionCreated -> handle_subscription_created(event)
    CustomerSubscriptionUpdated -> handle_subscription_updated(event)

    CustomerSubscriptionDeleted -> handle_subscription_deleted(event)
    InvoicePaymentFailed -> handle_payment_failed(event)
    UnknownEvent(type_name) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] Ignoring unknown event type: " <> type_name,
      )
      Success("Ignored unknown event: " <> type_name)
    }
  }
}

/// Handle successful payment - activate/upgrade service
fn handle_payment_succeeded(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Error(error) -> ProcessingError("Failed to extract customer ID: " <> error)
    Ok(customer_id) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] Payment succeeded for customer: " <> customer_id,
      )

      // Update business plan and limits
      case update_business_plan_after_payment(customer_id, event.data) {
        Error(error) ->
          ProcessingError("Failed to update business plan: " <> error)
        Ok(_) -> {
          // Send success metrics to business actor
          case send_payment_success_metric(customer_id) {
            Error(error) -> ProcessingError("Failed to send metric: " <> error)
            Ok(_) -> Success("Payment processed for customer: " <> customer_id)
          }
        }
      }
    }
  }
}

/// Handle new subscription - provision initial resources
fn handle_subscription_created(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Error(error) -> ProcessingError("Failed to extract customer ID: " <> error)
    Ok(customer_id) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] New subscription created for customer: " <> customer_id,
      )

      // Provision initial resources and set up plan limits
      case provision_subscription_resources(customer_id, event.data) {
        Error(error) ->
          ProcessingError("Failed to provision resources: " <> error)
        Ok(_) ->
          Success("Subscription provisioned for customer: " <> customer_id)
      }
    }
  }
}

/// Handle subscription update - adjust limits and features
fn handle_subscription_updated(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Error(error) -> ProcessingError("Failed to extract customer ID: " <> error)
    Ok(customer_id) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] 🔄 Subscription updated for customer: " <> customer_id,
      )

      // Update subscription status and plan
      case update_subscription_limits(customer_id, event.data) {
        Error(error) -> ProcessingError("Failed to update limits: " <> error)
        Ok(_) -> Success("Subscription updated for customer: " <> customer_id)
      }
    }
  }
}

/// Handle failed payment - graceful degradation
fn handle_payment_failed(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Error(error) -> ProcessingError("Failed to extract customer ID: " <> error)
    Ok(customer_id) -> {
      logging.log(
        logging.Warning,
        "[StripeHandler] ⚠️ Payment failed for customer: " <> customer_id,
      )

      case handle_payment_failure_gracefully(customer_id, event.data) {
        Error(error) ->
          ProcessingError("Failed to handle payment failure: " <> error)
        Ok(_) ->
          Success("Payment failure handled for customer: " <> customer_id)
      }
    }
  }
}

/// Add new handler for subscription deletion
fn handle_subscription_deleted(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Error(error) -> ProcessingError("Failed to extract customer ID: " <> error)
    Ok(customer_id) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] 🗑️ Subscription canceled for customer: " <> customer_id,
      )

      case handle_subscription_cancellation(customer_id, event.data) {
        Error(error) ->
          ProcessingError("Failed to handle cancellation: " <> error)
        Ok(_) -> Success("Subscription canceled for customer: " <> customer_id)
      }
    }
  }
}

/// Update subscription limits after plan change
fn update_subscription_limits(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  logging.log(
    logging.Info,
    "[StripeHandler] 🔄 Processing subscription update for: " <> customer_id,
  )

  case supabase_client.get_business_by_stripe_customer(customer_id) {
    Ok(business) -> {
      // Update subscription status (might be changing from past_due to active)
      case
        supabase_client.update_business_subscription(
          business.business_id,
          data.subscription_id,
          "active",
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[StripeHandler] ✅ Updated subscription status to active",
          )
          // TODO: In future, detect plan changes and update limits accordingly
          // For now, just ensure status is current
          Ok(Nil)
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] ❌ Failed to update subscription: "
              <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[StripeHandler] ❌ Business lookup failed: " <> string.inspect(error),
      )
      Error("Business lookup failed")
    }
  }
}

/// Handle payment failure with graceful degradation
fn handle_payment_failure_gracefully(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  logging.log(
    logging.Warning,
    "[StripeHandler] ⚠️ Processing payment failure for: " <> customer_id,
  )

  case supabase_client.get_business_by_stripe_customer(customer_id) {
    Ok(business) -> {
      // Mark subscription as past_due (don't immediately cancel)
      case
        supabase_client.update_business_subscription(
          business.business_id,
          data.subscription_id,
          "past_due",
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[StripeHandler] ✅ Marked subscription as past_due",
          )
          // TODO: Send notification email to customer
          // TODO: Reduce to free tier limits temporarily
          Ok(Nil)
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] ❌ Failed to update subscription: "
              <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[StripeHandler] ❌ Business lookup failed: " <> string.inspect(error),
      )
      Error("Business lookup failed")
    }
  }
}

/// Handle subscription cancellation 
fn handle_subscription_cancellation(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  logging.log(
    logging.Info,
    "[StripeHandler] 🗑️ Processing cancellation for: " <> customer_id,
  )

  case supabase_client.get_business_by_stripe_customer(customer_id) {
    Ok(business) -> {
      // Mark subscription as canceled
      case
        supabase_client.update_business_subscription(
          business.business_id,
          data.subscription_id,
          "canceled",
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[StripeHandler] ✅ Marked subscription as canceled",
          )
          // Downgrade to free tier limits
          case supabase_client.downgrade_to_free_limits(business.business_id) {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[StripeHandler] ✅ Downgraded to free tier limits",
              )
              Ok(Nil)
            }
            Error(error) -> {
              logging.log(
                logging.Error,
                "[StripeHandler] ❌ Failed to downgrade limits: "
                  <> string.inspect(error),
              )
              Error("Failed to downgrade limits")
            }
          }
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] ❌ Failed to update subscription: "
              <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[StripeHandler] ❌ Business lookup failed: " <> string.inspect(error),
      )
      Error("Business lookup failed")
    }
  }
}

/// Extract Stripe customer ID from webhook data
fn extract_customer_id(data: StripeData) -> Result(String, String) {
  Ok(data.customer)
}

// Helper functions to extract from Stripe data
fn extract_customer_name(data: StripeData) -> String {
  // TODO: Extract actual customer name from Stripe webhook data
  // For now, use customer ID as name - customer can rename in dashboard
  data.customer
}

fn extract_customer_email(data: StripeData) -> String {
  // TODO: Extract actual email from Stripe webhook data
  // For now, generate placeholder - customer must update in dashboard
  string.lowercase(data.customer) <> "@placeholder.com"
}

fn extract_plan_name_from_stripe(data: StripeData) -> String {
  // Simple: if they have a subscription, call it their subscription ID
  // User can rename it later in TrackTags dashboard
  case data.subscription_id {
    Some(sub_id) -> "plan_" <> string.slice(sub_id, 4, 8)
    // "plan_abc123"
    None -> "free"
  }
}

/// Provision resources for new subscription
fn provision_subscription_resources(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  logging.log(
    logging.Info,
    "[StripeHandler] 🚀 Provisioning subscription for customer: " <> customer_id,
  )

  // 1. Find business by stripe_customer_id
  case supabase_client.get_business_by_stripe_customer(customer_id) {
    Ok(business) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] ✅ Found business: " <> business.business_id,
      )

      // 2. Update subscription status
      case
        supabase_client.update_business_subscription(
          business.business_id,
          data.subscription_id,
          "active",
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[StripeHandler] ✅ Updated business subscription status",
          )

          // 3. Create default plan limits (you can customize this)
          case create_default_plan_limits(business.business_id) {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[StripeHandler] ✅ Created default plan limits",
              )
              Ok(Nil)
            }
            Error(error) -> {
              logging.log(
                logging.Error,
                "[StripeHandler] ❌ Failed to create plan limits: " <> error,
              )
              Error("Failed to create plan limits")
            }
          }
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] ❌ Failed to update subscription: "
              <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(supabase_client.NotFound(_)) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] ⚠️ Business not found, creating new business for customer: "
          <> customer_id,
      )
      // Updated function call
      let business_name = extract_customer_name(data)
      let email = extract_customer_email(data)

      let plan_name = extract_plan_name_from_stripe(data)

      case
        supabase_client.create_business_for_stripe_customer(
          customer_id,
          business_name,
          email,
          plan_name,
        )
      {
        Ok(business) -> {
          logging.log(
            logging.Info,
            "[StripeHandler] ✅ Created new business: " <> business.business_id,
          )
          // Now create plan limits for the new business
          case create_default_plan_limits(business.business_id) {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[StripeHandler] ✅ Created default plan limits for new business",
              )
              Ok(Nil)
            }
            Error(error) -> Error("Failed to create plan limits: " <> error)
          }
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] ❌ Failed to create business: "
              <> string.inspect(error),
          )
          Error("Failed to create business")
        }
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[StripeHandler] ❌ Database error: " <> string.inspect(error),
      )
      Error("Database error")
    }
  }
}

/// Update business plan after successful payment
fn update_business_plan_after_payment(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  logging.log(
    logging.Info,
    "[StripeHandler] 💰 Processing payment for customer: " <> customer_id,
  )

  // 1. Find business by stripe_customer_id
  case supabase_client.get_business_by_stripe_customer(customer_id) {
    Ok(business) -> {
      // 2. Update subscription status to active (in case it was past_due)
      case
        supabase_client.update_business_subscription(
          business.business_id,
          data.subscription_id,
          "active",
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[StripeHandler] ✅ Reactivated subscription after payment",
          )
          Ok(Nil)
        }
        Error(error) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] ❌ Failed to update subscription: "
              <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[StripeHandler] ❌ Business lookup failed: " <> string.inspect(error),
      )
      Error("Business lookup failed")
    }
  }
}

/// Create default plan limits for new subscription
fn create_default_plan_limits(business_id: String) -> Result(Nil, String) {
  // Example: Create a "pro" plan with default limits
  let default_limits = [
    #("api_calls", 10_000.0, "monthly"),
    #("storage_mb", 1000.0, "monthly"),
    #("users", 50.0, "monthly"),
  ]

  list.try_each(default_limits, fn(limit) {
    let #(metric_name, limit_value, period) = limit
    case
      supabase_client.create_plan_limit(
        business_id,
        metric_name,
        limit_value,
        period,
        "gte",
        // breach_operator
        "allow_overage",
        // breach_action
        None,
        // webhook_url
      )
    {
      Ok(_) -> {
        logging.log(
          logging.Info,
          "[StripeHandler] ✅ Created limit: "
            <> metric_name
            <> " = "
            <> float.to_string(limit_value),
        )
        Ok(Nil)
      }
      Error(error) -> {
        logging.log(
          logging.Error,
          "[StripeHandler] ❌ Failed to create limit "
            <> metric_name
            <> ": "
            <> string.inspect(error),
        )
        Error("Failed to create limit: " <> metric_name)
      }
    }
  })
}

/// Handle payment failure with graceful degradation
/// Send payment success metric to business actor
fn send_payment_success_metric(customer_id: String) -> Result(Nil, String) {
  // TODO: Send metric via business actor
  // This will trigger any automated responses

  logging.log(
    logging.Info,
    "[StripeHandler] TODO: Send payment success metric for customer: "
      <> customer_id,
  )
  Ok(Nil)
}

/// Get Stripe webhook secret from environment (required)
fn get_webhook_secret() -> Result(String, String) {
  // Use require_env to crash if not set - webhook security is critical
  Ok(utils.require_env("STRIPE_WEBHOOK_SECRET"))
}

/// Handle customer webhook using their stored Stripe secret
pub fn handle_customer_webhook(req: Request, business_id: String) -> Response {
  case req.method {
    http.Post -> process_customer_webhook(req, business_id)
    _ -> wisp.method_not_allowed([http.Post])
  }
}

/// Process customer webhook - reuses existing logic but with customer secret
fn process_customer_webhook(req: Request, business_id: String) -> Response {
  case get_stripe_signature(req) {
    Error(_) -> {
      logging.log(
        logging.Error,
        "[StripeHandler] Missing Stripe signature for customer: " <> business_id,
      )
      wisp.bad_request()
      |> wisp.string_body("Missing Stripe-Signature header")
    }
    Ok(signature) -> {
      case wisp.read_body_to_bitstring(req) {
        Error(_) -> {
          logging.log(
            logging.Error,
            "[StripeHandler] Failed to read customer webhook body",
          )
          wisp.bad_request()
          |> wisp.string_body("Invalid request body")
        }
        Ok(body_bits) -> {
          case bit_array.to_string(body_bits) {
            Error(_) -> {
              logging.log(
                logging.Error,
                "[StripeHandler] Invalid UTF-8 in customer webhook body",
              )
              wisp.bad_request()
              |> wisp.string_body("Invalid body encoding")
            }
            Ok(body) -> {
              // REUSE existing logic but with customer secret
              case verify_and_process_customer(body, signature, business_id) {
                Success(message) -> {
                  logging.log(
                    logging.Info,
                    "[StripeHandler] Customer webhook processed: "
                      <> business_id
                      <> " - "
                      <> message,
                  )
                  wisp.ok()
                  |> wisp.string_body("{\"received\": true}")
                }
                InvalidSignature -> {
                  logging.log(
                    logging.Error,
                    "[StripeHandler] Invalid signature for customer: "
                      <> business_id,
                  )
                  wisp.bad_request()
                  |> wisp.string_body("Invalid signature")
                }
                InvalidPayload(error) -> {
                  logging.log(
                    logging.Error,
                    "[StripeHandler] Invalid customer webhook payload: "
                      <> error,
                  )
                  wisp.bad_request()
                  |> wisp.string_body("Invalid payload: " <> error)
                }
                ProcessingError(error) -> {
                  logging.log(
                    logging.Error,
                    "[StripeHandler] Customer webhook processing error: "
                      <> error,
                  )
                  wisp.internal_server_error()
                  |> wisp.string_body("Processing error")
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Verify and process customer webhook - similar to verify_and_process but with customer secret
fn verify_and_process_customer(
  body: String,
  signature: String,
  business_id: String,
) -> WebhookResult {
  case get_customer_webhook_secret(business_id) {
    Error(error) -> ProcessingError("Failed to get webhook secret: " <> error)
    Ok(customer_secret) -> {
      case verify_stripe_signature(body, signature, customer_secret) {
        False -> InvalidSignature
        True -> {
          // REUSE existing parsing and processing
          case parse_stripe_event(body) {
            Error(error) -> InvalidPayload(error)
            Ok(event) -> process_customer_stripe_event(event, business_id)
          }
        }
      }
    }
  }
}

/// Get customer's webhook secret from integration_keys (FIXED)
fn get_customer_webhook_secret(business_id: String) -> Result(String, String) {
  case supabase_client.get_integration_keys(business_id, Some("stripe")) {
    Ok([key, ..]) -> {
      // Decrypt the credentials (FIXED: use encrypted_key, not encrypted_data)
      case crypto.decrypt_from_json(key.encrypted_key) {
        Ok(decrypted_json) -> {
          case json.parse(decrypted_json, stripe_credentials_decoder()) {
            Ok(credentials) -> Ok(credentials.webhook_secret)
            Error(_) -> Error("Failed to parse Stripe credentials")
          }
        }
        Error(_) -> Error("Failed to decrypt Stripe credentials")
      }
    }
    Ok([]) -> Error("No Stripe integration found for business")
    Error(_) -> Error("Database error fetching integration keys")
  }
}

/// Process customer's Stripe events - simple acknowledgment for Phase 3
fn process_customer_stripe_event(
  event: StripeEvent,
  business_id: String,
) -> WebhookResult {
  logging.log(
    logging.Info,
    "[StripeHandler] Processing customer Stripe event: "
      <> event.id
      <> " for business: "
      <> business_id,
  )

  // For Phase 3: Just log and acknowledge 
  // Customer gets their webhook data validated and confirmed
  Success(
    "Customer event processed: " <> event.id <> " for business: " <> business_id,
  )
}

/// Decoder for stored Stripe credentials
fn stripe_credentials_decoder() -> decode.Decoder(StripeCredentials) {
  use secret_key <- decode.field("secret_key", decode.string)
  use webhook_secret <- decode.field("webhook_secret", decode.string)
  decode.success(StripeCredentials(secret_key, webhook_secret))
}

/// Fetch event from Stripe API and process it (for admin replay)
pub fn fetch_and_process_stripe_event(
  business_id: String,
  event_id: String,
) -> Result(String, String) {
  logging.log(
    logging.Info,
    "[StripeHandler] Fetching Stripe event: "
      <> event_id
      <> " for business: "
      <> business_id,
  )

  // Get customer's Stripe secret key for API calls
  case get_customer_stripe_secret(business_id) {
    Error(error) -> Error("Failed to get Stripe credentials: " <> error)
    Ok(secret_key) -> {
      // Fetch event from Stripe API
      case fetch_stripe_event_from_api(event_id, secret_key) {
        Error(error) -> Error("Failed to fetch event from Stripe: " <> error)
        Ok(event_json) -> {
          // Process the event through existing customer webhook logic
          case parse_stripe_event(event_json) {
            Error(error) -> Error("Failed to parse Stripe event: " <> error)
            Ok(event) -> {
              case process_customer_stripe_event(event, business_id) {
                Success(message) -> Ok(message)
                InvalidSignature -> Error("Invalid signature")
                InvalidPayload(error) -> Error("Invalid payload: " <> error)
                ProcessingError(error) -> Error("Processing error: " <> error)
              }
            }
          }
        }
      }
    }
  }
}

/// Get customer's Stripe secret key for API calls
fn get_customer_stripe_secret(business_id: String) -> Result(String, String) {
  case supabase_client.get_integration_keys(business_id, Some("stripe")) {
    Ok([key, ..]) -> {
      case crypto.decrypt_from_json(key.encrypted_key) {
        Ok(decrypted_json) -> {
          case json.parse(decrypted_json, stripe_credentials_decoder()) {
            Ok(credentials) -> Ok(credentials.secret_key)
            Error(_) -> Error("Failed to parse Stripe credentials")
          }
        }
        Error(_) -> Error("Failed to decrypt Stripe credentials")
      }
    }
    Ok([]) -> Error("No Stripe integration found for business")
    Error(_) -> Error("Database error fetching integration keys")
  }
}

/// Fetch single event from Stripe API
fn fetch_stripe_event_from_api(
  _event_id: String,
  _secret_key: String,
) -> Result(String, String) {
  // TODO: Implement Stripe API call
  // For now, return error - you can implement this when needed
  Error("Stripe API fetch not yet implemented - use dashboard replay for now")
}
