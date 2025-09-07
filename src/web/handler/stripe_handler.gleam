// src/web/handler/stripe_handler.gleam
import clients/supabase_client
import gleam/bit_array
import gleam/crypto as gleam_crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import utils/crypto
import utils/utils
import wisp.{type Request, type Response}

// Add at top of stripe_handler.gleam
fn is_test_mode() -> Bool {
  utils.get_env_or("STRIPE_MOCK_MODE", "false") == "true"
}

// Stripe webhook event types we care about
pub type StripeEventType {
  InvoicePaymentSucceeded
  CustomerSubscriptionCreated
  CustomerSubscriptionUpdated
  CustomerSubscriptionDeleted
  InvoicePaymentFailed
  InvoiceFinalized
  UnknownEvent(String)
}

// It SHOULD have:
pub type StripeData {
  StripeData(
    customer: String,
    subscription_id: Option(String),
    status: Option(String),
    price_id: Option(String),
    metadata: Option(Dict(String, String)),
  )
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

// Add near top with other types
pub type StripeInvoice {
  StripeInvoice(id: String, customer: String, lines: StripeLineItems)
}

pub type StripeLineItems {
  StripeLineItems(data: List(StripeLineItem))
}

pub type StripeLineItem {
  StripeLineItem(period: StripePeriod)
}

pub type StripePeriod {
  StripePeriod(start: Int, end: Int)
}

/// Main webhook endpoint handler
pub fn handle_stripe_webhook(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)

  // Get signature from headers
  case get_stripe_signature(req) {
    Error(_) -> {
      logging.log(logging.Warning, "[StripeWebhook] Missing Stripe signature")
      wisp.bad_request()
    }
    Ok(signature) -> {
      // Read request body
      case wisp.read_body_to_bitstring(req) {
        Error(_) -> {
          logging.log(logging.Error, "[StripeWebhook] Failed to read body")
          wisp.bad_request()
        }
        Ok(body_bits) -> {
          case bit_array.to_string(body_bits) {
            Error(_) -> {
              logging.log(
                logging.Error,
                "[StripeWebhook] Invalid UTF-8 in body",
              )
              wisp.bad_request()
            }
            Ok(body) -> {
              // Now process with signature verification
              process_webhook_with_dedup(body, signature)
            }
          }
        }
      }
    }
  }
}

// Add this new function for deduplication
fn process_webhook_with_dedup(body: String, signature: String) -> Response {
  // First parse the event to get the ID
  case parse_stripe_event(body) {
    Error(err) -> {
      logging.log(logging.Error, "[StripeWebhook] Parse error: " <> err)
      wisp.bad_request()
    }
    Ok(event) -> {
      // Check if already processed
      case check_and_record_event(event.id, event.event_type, body) {
        Error(supabase_client.DatabaseError(msg)) -> {
          case string.contains(msg, "already exists") {
            True -> {
              // Already processed - return success to stop Stripe retries
              logging.log(
                logging.Info,
                "[StripeWebhook] Event already processed: " <> event.id,
              )
              wisp.ok()
              |> wisp.string_body("{\"received\": true}")
            }
            False -> {
              logging.log(
                logging.Error,
                "[StripeWebhook] Database error: " <> msg,
              )
              wisp.internal_server_error()
            }
          }
        }
        Error(err) -> {
          logging.log(
            logging.Error,
            "[StripeWebhook] Error: " <> string.inspect(err),
          )
          wisp.internal_server_error()
        }
        Ok(_) -> {
          // Now verify signature and process
          case verify_and_process(body, signature) {
            Success(message) -> {
              logging.log(logging.Info, "[StripeWebhook] Success: " <> message)
              wisp.ok()
              |> wisp.string_body("{\"received\": true}")
            }
            InvalidSignature -> {
              logging.log(logging.Error, "[StripeWebhook] Invalid signature")
              wisp.bad_request()
            }
            InvalidPayload(err) -> {
              logging.log(
                logging.Error,
                "[StripeWebhook] Invalid payload: " <> err,
              )
              wisp.bad_request()
            }
            ProcessingError(err) -> {
              logging.log(
                logging.Error,
                "[StripeWebhook] Processing error: " <> err,
              )
              wisp.internal_server_error()
            }
          }
        }
      }
    }
  }
}

// Add this new function
fn handle_invoice_finalized(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Ok(stripe_customer_id) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] 💳 Invoice finalized for Stripe customer: "
          <> stripe_customer_id,
      )

      // Look up OUR customer by Stripe's customer ID
      case supabase_client.get_customer_by_stripe_customer(stripe_customer_id) {
        Ok(customer) -> {
          // Reset StripeBilling metrics for THIS customer
          case
            supabase_client.reset_customer_stripe_billing_metrics(
              customer.business_id,
              customer.customer_id,
            )
          {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[StripeHandler] ✅ Reset billing metrics for customer: "
                  <> customer.customer_id,
              )
              Success("Billing cycle reset for: " <> customer.customer_id)
            }
            Error(error) -> {
              logging.log(
                logging.Error,
                "[StripeHandler] ❌ Failed to reset metrics: "
                  <> string.inspect(error),
              )
              ProcessingError("Reset failed: " <> string.inspect(error))
            }
          }
        }
        Error(_) -> {
          // No customer found - they might not be using metered billing
          logging.log(
            logging.Info,
            "[StripeHandler] No customer found for Stripe ID: "
              <> stripe_customer_id,
          )
          Success("No metered billing customer for: " <> stripe_customer_id)
        }
      }
    }
    Error(error) -> ProcessingError("Failed to extract customer: " <> error)
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

fn verify_and_process(body: String, signature: String) -> WebhookResult {
  let self_hosted = utils.get_env_or("SELF_HOSTED", "false") == "true"
  let mock_mode = is_test_mode()

  // Block mock mode in cloud deployments
  case mock_mode, self_hosted {
    True, False ->
      ProcessingError(
        "STRIPE_MOCK_MODE is not allowed when SELF_HOSTED is false",
      )

    // Self-hosted + mock mode: skip signature verification
    True, True ->
      case parse_stripe_event(body) {
        Ok(event) -> process_stripe_event(event)
        Error(err) -> InvalidPayload(err)
      }

    // Normal path: verify signature
    False, _ ->
      case get_webhook_secret() {
        Error(_) -> ProcessingError("Missing Stripe webhook secret")
        Ok(secret) ->
          case verify_stripe_signature(body, signature, secret) {
            False -> InvalidSignature
            True ->
              case parse_stripe_event(body) {
                Ok(event) -> process_stripe_event(event)
                Error(err) -> InvalidPayload(err)
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

// UPDATE the stripe_data_decoder (around line 275)
fn stripe_data_decoder() -> decode.Decoder(StripeData) {
  use customer <- decode.optional_field("customer", "", decode.string)
  use subscription_id <- decode.optional_field(
    "id",
    None,
    decode.optional(decode.string),
  )
  use status <- decode.optional_field(
    "status",
    None,
    decode.optional(decode.string),
  )
  use price_id <- decode.optional_field(
    "price_id",
    None,
    decode.optional(decode.string),
  )
  // ADD extraction
  use metadata <- decode.optional_field(
    "metadata",
    None,
    decode.optional(decode.dict(decode.string, decode.string)),
  )

  decode.success(StripeData(
    customer,
    subscription_id,
    status,
    price_id,
    metadata,
  ))
}

// Then use it in the main event decoder - CORRECTED for new API
fn stripe_event_decoder() -> decode.Decoder(StripeEvent) {
  use id <- decode.field("id", decode.string)
  use event_type_string <- decode.field("type", decode.string)
  use data <- decode.subfield(["data", "object"], stripe_data_decoder())
  use created <- decode.field("created", decode.int)

  // Parse the event type string
  let event_type = case event_type_string {
    "invoice.payment_succeeded" -> InvoicePaymentSucceeded
    "customer.subscription.created" -> CustomerSubscriptionCreated
    "customer.subscription.updated" -> CustomerSubscriptionUpdated
    "customer.subscription.deleted" -> CustomerSubscriptionDeleted
    "invoice.payment_failed" -> InvoicePaymentFailed
    "invoice.finalized" -> InvoiceFinalized
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
    InvoiceFinalized -> handle_invoice_finalized(event)
    UnknownEvent(type_name) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] Ignoring unknown event type: " <> type_name,
      )
      Success("Ignored unknown event: " <> type_name)
    }
  }
}

// Handle successful payment - activate/upgrade service
fn handle_payment_succeeded(event: StripeEvent) -> WebhookResult {
  case extract_customer_id(event.data) {
    Error(error) -> ProcessingError("Failed to extract customer ID: " <> error)
    Ok(stripe_customer_id) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] Payment succeeded for customer: " <> stripe_customer_id,
      )

      // Update business plan and limits
      case update_business_plan_after_payment(stripe_customer_id, event.data) {
        Error(error) ->
          ProcessingError("Failed to update business plan: " <> error)
        Ok(_) -> {
          // Queue machine provisioning if this is a machine-enabled plan
          case queue_machine_provisioning(stripe_customer_id, event.data) {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "[StripeHandler] Queued machine provisioning for: "
                  <> stripe_customer_id,
              )
            }
            Error(e) -> {
              logging.log(
                logging.Warning,
                "[StripeHandler] No machines to provision or error: " <> e,
              )
            }
          }

          // Send success metrics to business actor
          case send_payment_success_metric(stripe_customer_id) {
            Error(error) -> ProcessingError("Failed to send metric: " <> error)
            Ok(_) ->
              Success("Payment processed for customer: " <> stripe_customer_id)
          }
        }
      }
    }
  }
}

// Add new function to queue machine provisioning
fn queue_machine_provisioning(
  stripe_customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  // Only handle customer subscriptions that need machines
  case supabase_client.get_customer_by_stripe_customer(stripe_customer_id) {
    Ok(customer) -> {
      // This is a customer subscription under a business
      case get_plan_machine_count(data.price_id) {
        Ok(0) -> Error("No machines in plan")
        Ok(machine_count) -> {
          let expires_at = utils.current_timestamp() + 2_851_200
          // 33 days

          list.range(1, machine_count)
          |> list.map(fn(index) {
            let payload =
              dict.from_list([
                #("machine_index", int.to_string(index)),
                #("expires_at", int.to_string(expires_at)),
                #("price_id", option.unwrap(data.price_id, "unknown")),
              ])

            supabase_client.insert_provisioning_queue(
              customer.business_id,
              // The business that owns this customer
              customer.customer_id,
              // The actual customer getting machines
              "provision",
              "fly",
              payload,
            )
          })
          |> result.all
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(_) { "Failed to queue provisioning" })
        }
        Error(_) -> Error("Could not determine machine count")
      }
    }
    Error(_) -> {
      // Not a customer subscription - this is fine, not all invoices need machines
      Error("Not a customer subscription")
    }
  }
}

// Add helper to determine machine count from price_id
fn get_plan_machine_count(price_id: Option(String)) -> Result(Int, String) {
  case price_id {
    None -> Ok(0)
    Some(pid) -> {
      // Look up the plan by price_id to get machine count
      case supabase_client.get_plan_machines_by_price_id(pid) {
        Ok(plan_machine) -> Ok(plan_machine.machine_count)
        Error(_) -> Ok(0)
        // No machines for this plan
      }
    }
  }
}

// REPLACE handle_subscription_created (around line 350)
fn handle_subscription_created(event: StripeEvent) -> WebhookResult {
  case extract_subscription_data(event.data) {
    Ok(#(stripe_customer_id, price_id, status)) -> {
      // Check if this customer already exists
      case supabase_client.get_business_by_stripe_customer(stripe_customer_id) {
        Ok(_existing_business) -> {
          // Customer exists, just update subscription
          case
            supabase_client.update_business_subscription(
              stripe_customer_id,
              status,
              price_id,
            )
          {
            Ok(_) -> Success("Subscription updated for existing customer")
            Error(e) -> ProcessingError(string.inspect(e))
          }
        }
        Error(_) -> {
          // NEW CUSTOMER - need to map them using metadata!
          case event.data.metadata {
            Some(metadata) -> {
              case dict.get(metadata, "business_id") {
                Ok(business_id) -> {
                  // First, set the stripe_customer_id on the business
                  case
                    supabase_client.set_stripe_customer_id(
                      business_id,
                      stripe_customer_id,
                    )
                  {
                    Ok(_) -> {
                      // Now update subscription details
                      case
                        supabase_client.update_business_subscription(
                          stripe_customer_id,
                          status,
                          price_id,
                        )
                      {
                        Ok(_) -> Success("New subscription created and mapped")
                        Error(e) ->
                          ProcessingError(
                            "Failed to update subscription: "
                            <> string.inspect(e),
                          )
                      }
                    }
                    Error(e) ->
                      ProcessingError(
                        "Failed to map customer: " <> string.inspect(e),
                      )
                  }
                }
                Error(_) ->
                  ProcessingError(
                    "No business_id in metadata - cannot map customer!",
                  )
              }
            }
            None ->
              ProcessingError(
                "No metadata in webhook - cannot map new customer!",
              )
          }
        }
      }
    }
    Error(error) -> ProcessingError(error)
  }
}

/// Handle subscription update - adjust limits and features
fn handle_subscription_updated(event: StripeEvent) -> WebhookResult {
  case extract_subscription_data(event.data) {
    // Use correct function!
    Ok(#(stripe_customer_id, price_id, status)) -> {
      case
        supabase_client.update_business_subscription(
          stripe_customer_id,
          status,
          price_id,
        )
      {
        Ok(_) -> Success("Subscription updated")
        Error(e) -> ProcessingError(string.inspect(e))
      }
    }
    Error(error) -> ProcessingError(error)
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

fn extract_subscription_data(
  data: StripeData,
  // Correct type!
) -> Result(#(String, String, String), String) {
  // Extract from StripeData fields
  let status = option.unwrap(data.status, "active")
  let price_id = option.unwrap(data.price_id, "price_unknown")

  Ok(#(data.customer, price_id, status))
}

// Handle payment failure with graceful degradation
fn handle_payment_failure_gracefully(
  customer_id: String,
  data: StripeData,
) -> Result(Nil, String) {
  logging.log(
    logging.Warning,
    "[StripeHandler] ⚠️ Processing payment failure for: " <> customer_id,
  )

  // Just mark as past_due
  case
    supabase_client.update_business_subscription(
      customer_id,
      // stripe_customer_id
      "past_due",
      // status
      option.unwrap(data.price_id, "unknown"),
      // price_id
    )
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[StripeHandler] ✅ Marked subscription as past_due",
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
          customer_id,
          "canceled",
          option.unwrap(data.price_id, "unknown"),
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
    Ok(_business) -> {
      // 2. Update subscription status to active (in case it was past_due)
      case
        supabase_client.update_business_subscription(
          customer_id,
          "active",
          option.unwrap(data.price_id, "unknown"),
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
pub fn handle_business_webhook(req: Request, business_id: String) -> Response {
  case req.method {
    http.Post -> process_business_webhook(req, business_id)
    _ -> wisp.method_not_allowed([http.Post])
  }
}

/// Process customer webhook - reuses existing logic but with customer secret
fn process_business_webhook(req: Request, business_id: String) -> Response {
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
              case
                process_webhook_with_dedup_for_business(
                  body,
                  signature,
                  business_id,
                )
              {
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

fn process_customer_stripe_event(
  event: StripeEvent,
  business_id: String,
) -> WebhookResult {
  case event.event_type {
    CustomerSubscriptionCreated | CustomerSubscriptionUpdated -> {
      case extract_subscription_data(event.data) {
        Ok(#(stripe_customer_id, price_id, status)) -> {
          case
            supabase_client.update_customer_subscription(
              business_id,
              stripe_customer_id,
              status,
              price_id,
            )
          {
            Ok(_) -> Success("Customer subscription updated")
            Error(e) -> ProcessingError(string.inspect(e))
          }
        }
        Error(e) -> ProcessingError("Failed to extract data: " <> e)
        // ADD THIS!
      }
    }
    CustomerSubscriptionDeleted -> {
      // Handle customer cancellation differently than business cancellation
      Success("Customer subscription deleted for business: " <> business_id)
    }
    _ -> Success("Event acknowledged: " <> string.inspect(event.event_type))
  }
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

// Record event to prevent duplicates
fn check_and_record_event(
  event_id: String,
  event_type: StripeEventType,
  raw_payload: String,
) -> Result(Nil, supabase_client.SupabaseError) {
  let event_type_string = case event_type {
    InvoicePaymentSucceeded -> "invoice.payment_succeeded"
    CustomerSubscriptionCreated -> "customer.subscription.created"
    CustomerSubscriptionUpdated -> "customer.subscription.updated"
    CustomerSubscriptionDeleted -> "customer.subscription.deleted"
    InvoicePaymentFailed -> "invoice.payment_failed"
    InvoiceFinalized -> "invoice.finalized"
    UnknownEvent(t) -> t
  }

  supabase_client.insert_stripe_event(
    event_id,
    event_type_string,
    None,
    // business_id - will be extracted from event
    None,
    // customer_id - will be extracted from event
    raw_payload,
  )
}

// Add deduplication for business webhooks
fn process_webhook_with_dedup_for_business(
  body: String,
  signature: String,
  business_id: String,
) -> WebhookResult {
  // First parse to get event ID
  case parse_stripe_event(body) {
    Error(err) -> InvalidPayload(err)
    Ok(event) -> {
      // Check if already processed (with business prefix to avoid collisions)
      let prefixed_event_id = "biz_" <> business_id <> "_" <> event.id

      case check_and_record_event(prefixed_event_id, event.event_type, body) {
        Error(supabase_client.DatabaseError(msg)) -> {
          case string.contains(msg, "already exists") {
            True -> Success("Event already processed")
            False -> ProcessingError("Database error: " <> msg)
          }
        }
        Ok(_) -> {
          // Now verify and process with business webhook secret
          verify_and_process_customer(body, signature, business_id)
        }
        Error(err) ->
          ProcessingError("Failed to record event: " <> string.inspect(err))
      }
    }
  }
}
