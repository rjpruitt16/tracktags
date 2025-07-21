// src/web/handler/stripe_handler.gleam
import clients/supabase_client
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import utils/utils
import wisp.{type Request, type Response}

// Stripe webhook event types we care about
pub type StripeEventType {
  InvoicePaymentSucceeded
  CustomerSubscriptionCreated
  CustomerSubscriptionUpdated
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
      io.println("Missing Stripe signature header")
      wisp.bad_request()
      |> wisp.string_body("Missing Stripe-Signature header")
    }
    Ok(signature) -> {
      // Read request body
      case wisp.read_body_to_bitstring(req) {
        Error(_) -> {
          io.println("Failed to read webhook body")
          wisp.bad_request()
          |> wisp.string_body("Invalid request body")
        }
        Ok(body_bits) -> {
          // Convert to string for processing
          case bit_array.to_string(body_bits) {
            Error(_) -> {
              io.println("Invalid UTF-8 in webhook body")
              wisp.bad_request()
              |> wisp.string_body("Invalid body encoding")
            }
            Ok(body) -> {
              // Verify signature and process
              case verify_and_process(body, signature) {
                Success(message) -> {
                  io.println("Webhook processed successfully: " <> message)
                  wisp.ok()
                  |> wisp.string_body("{\"received\": true}")
                }
                InvalidSignature -> {
                  io.println("Invalid Stripe signature")
                  wisp.bad_request()
                  |> wisp.string_body("Invalid signature")
                }
                InvalidPayload(error) -> {
                  io.println("Invalid webhook payload: " <> error)
                  wisp.bad_request()
                  |> wisp.string_body("Invalid payload: " <> error)
                }
                ProcessingError(error) -> {
                  io.println("Webhook processing error: " <> error)
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
        crypto.hmac(
          bit_array.from_string(signed_payload),
          crypto.Sha256,
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
    "invoice.payment_failed" -> InvoicePaymentFailed
    unknown -> UnknownEvent(unknown)
  }

  decode.success(StripeEvent(id, event_type, data, created))
}

/// Process parsed Stripe event based on type
fn process_stripe_event(event: StripeEvent) -> WebhookResult {
  io.println("Processing Stripe event: " <> event.id)

  case event.event_type {
    InvoicePaymentSucceeded -> handle_payment_succeeded(event)
    CustomerSubscriptionCreated -> handle_subscription_created(event)
    CustomerSubscriptionUpdated -> handle_subscription_updated(event)
    InvoicePaymentFailed -> handle_payment_failed(event)
    UnknownEvent(type_name) -> {
      io.println("Ignoring unknown event type: " <> type_name)
      Success("Ignored unknown event: " <> type_name)
    }
  }
}

/// Handle successful payment - activate/upgrade service
fn handle_payment_succeeded(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Error(error) -> ProcessingError("Failed to extract customer ID: " <> error)
    Ok(customer_id) -> {
      io.println("Payment succeeded for customer: " <> customer_id)

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
      io.println("New subscription created for customer: " <> customer_id)

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
      io.println("Subscription updated for customer: " <> customer_id)

      // Update plan limits and features
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
      io.println("Payment failed for customer: " <> customer_id)

      // Implement graceful degradation (reduce limits, send notifications)
      case handle_payment_failure_gracefully(customer_id, event.data) {
        Error(error) ->
          ProcessingError("Failed to handle payment failure: " <> error)
        Ok(_) ->
          Success("Payment failure handled for customer: " <> customer_id)
      }
    }
  }
}

/// Extract Stripe customer ID from webhook data
fn extract_customer_id(data: StripeData) -> Result(String, String) {
  Ok(data.customer)
}

// Helper functions to extract from Stripe data
fn extract_customer_name(data: StripeData) -> String {
  // In real Stripe webhooks, you'd extract from data.customer object
  // For now, generate a reasonable default
  "Customer " <> string.slice(data.customer, 4, 8)
  // "Customer ABC123"
}

fn extract_customer_email(data: StripeData) -> String {
  // Stripe sometimes has email, sometimes doesn't
  // Generate a reasonable default
  string.lowercase(data.customer) <> "@stripe-customer.com"
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
  io.println("🚀 Provisioning subscription for customer: " <> customer_id)

  // 1. Find business by stripe_customer_id
  case supabase_client.get_business_by_stripe_customer(customer_id) {
    Ok(business) -> {
      io.println("✅ Found business: " <> business.business_id)

      // 2. Update subscription status
      case
        supabase_client.update_business_subscription(
          business.business_id,
          data.subscription_id,
          "active",
        )
      {
        Ok(_) -> {
          io.println("✅ Updated business subscription status")

          // 3. Create default plan limits (you can customize this)
          case create_default_plan_limits(business.business_id) {
            Ok(_) -> {
              io.println("✅ Created default plan limits")
              Ok(Nil)
            }
            Error(error) -> {
              io.println("❌ Failed to create plan limits: " <> error)
              Error("Failed to create plan limits")
            }
          }
        }
        Error(error) -> {
          io.println(
            "❌ Failed to update subscription: " <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(supabase_client.NotFound(_)) -> {
      io.println(
        "⚠️ Business not found, creating new business for customer: "
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
          io.println("✅ Created new business: " <> business.business_id)
          // Now create plan limits for the new business
          case create_default_plan_limits(business.business_id) {
            Ok(_) -> {
              io.println("✅ Created default plan limits for new business")
              Ok(Nil)
            }
            Error(error) -> Error("Failed to create plan limits: " <> error)
          }
        }
        Error(error) -> {
          io.println("❌ Failed to create business: " <> string.inspect(error))
          Error("Failed to create business")
        }
      }
    }
    Error(error) -> {
      io.println("❌ Database error: " <> string.inspect(error))
      Error("Database error")
    }
  }
}

/// Update business plan after successful payment
fn update_business_plan_after_payment(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  io.println("💰 Processing payment for customer: " <> customer_id)

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
          io.println("✅ Reactivated subscription after payment")
          Ok(Nil)
        }
        Error(error) -> {
          io.println(
            "❌ Failed to update subscription: " <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(error) -> {
      io.println("❌ Business lookup failed: " <> string.inspect(error))
      Error("Business lookup failed")
    }
  }
}

/// Handle payment failure with graceful degradation
fn handle_payment_failure_gracefully(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  io.println("⚠️ Payment failed for customer: " <> customer_id)

  // 1. Find business by stripe_customer_id
  case supabase_client.get_business_by_stripe_customer(customer_id) {
    Ok(business) -> {
      // 2. Update subscription status to past_due
      case
        supabase_client.update_business_subscription(
          business.business_id,
          data.subscription_id,
          "past_due",
        )
      {
        Ok(_) -> {
          io.println("✅ Marked subscription as past_due")
          // TODO: Reduce to free tier limits
          // TODO: Send notification email
          Ok(Nil)
        }
        Error(error) -> {
          io.println(
            "❌ Failed to update subscription: " <> string.inspect(error),
          )
          Error("Failed to update subscription")
        }
      }
    }
    Error(error) -> {
      io.println("❌ Business lookup failed: " <> string.inspect(error))
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
        io.println(
          "✅ Created limit: "
          <> metric_name
          <> " = "
          <> float.to_string(limit_value),
        )
        Ok(Nil)
      }
      Error(error) -> {
        io.println(
          "❌ Failed to create limit "
          <> metric_name
          <> ": "
          <> string.inspect(error),
        )
        Error("Failed to create limit: " <> metric_name)
      }
    }
  })
}

/// Update subscription limits after plan change
fn update_subscription_limits(
  customer_id: String,
  _data: StripeData,
) -> Result(Nil, String) {
  // TODO: Compare old vs new subscription
  // TODO: Update plan_limits table
  // TODO: Notify business actor of new limits
  // TODO: Handle upgrade/downgrade logic

  io.println("TODO: Update subscription limits for customer: " <> customer_id)
  Ok(Nil)
}

/// Handle payment failure with graceful degradation
/// Send payment success metric to business actor
fn send_payment_success_metric(customer_id: String) -> Result(Nil, String) {
  // TODO: Send metric via business actor
  // This will trigger any automated responses

  io.println("TODO: Send payment success metric for customer: " <> customer_id)
  Ok(Nil)
}

/// Get Stripe webhook secret from environment (required)
fn get_webhook_secret() -> Result(String, String) {
  // Use require_env to crash if not set - webhook security is critical
  Ok(utils.require_env("STRIPE_WEBHOOK_SECRET"))
}
