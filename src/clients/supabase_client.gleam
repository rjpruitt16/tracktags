// src/customers/supabase_client.gleam
import birl
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import glixir
import logging
import storage/metric_store
import types/application_types
import types/business_types
import types/customer_types.{type CustomerContext}
import types/metric_types
import utils/crypto
import utils/utils

//
// TYPES
// ============================================================================

pub type SupabaseError {
  NetworkError(String)
  DatabaseError(String)
  ParseError(String)
  NotFound(String)
  Unauthorized
  HttpError(httpc.HttpError)
}

pub type IntegrationKey {
  IntegrationKey(
    id: String,
    business_id: String,
    key_type: String,
    key_name: String,
    encrypted_key: String,
    key_hash: String,
    is_active: Bool,
    created_at: String,
  )
}

pub type MetricRecord {
  MetricRecord(
    id: String,
    business_id: String,
    customer_id: Option(String),
    metric_name: String,
    value: String,
    metric_type: String,
    scope: String,
    adapters: Option(Dict(String, json.Json)),
    flushed_at: String,
  )
}

pub type KeyValidation {
  BusinessKey(business_id: String)
  CustomerKey(business_id: String, customer_id: String)
}

pub type ProvisioningTask {
  ProvisioningTask(
    id: String,
    customer_id: String,
    business_id: String,
    action: String,
    provider: String,
    status: String,
    attempt_count: Int,
    max_attempts: Int,
    payload: Dict(String, String),
  )
}

// Add type and decoder
pub type PlanMachine {
  PlanMachine(
    id: String,
    plan_id: String,
    machine_count: Int,
    machine_size: String,
    docker_image: Option(String),
    grace_period_days: Int,
  )
}

// Add new combined validation function
pub type ValidationResult {
  BusinessValidation(business_id: String)
  CustomerValidation(
    business_id: String,
    customer_id: String,
    context: CustomerContext,
  )
  InvalidKey
}

pub type Plan {
  Plan(
    id: String,
    business_id: String,
    plan_name: String,
    stripe_price_id: option.Option(String),
    plan_status: String,
    created_at: String,
  )
}

pub fn validate_key_with_context(
  api_key: String,
) -> Result(ValidationResult, SupabaseError) {
  let key_hash = crypto.hash_api_key(api_key)
  let encoded_hash = uri.percent_encode(key_hash)

  let body =
    json.object([#("p_api_key_hash", json.string(encoded_hash))])
    |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/rpc/validate_key_and_get_context",
    Some(body),
  ))

  case response.status {
    200 -> {
      case json.parse(response.body, validation_result_decoder()) {
        Ok(result) -> Ok(result)
        Error(_) -> Error(ParseError("Invalid validation response"))
      }
    }
    _ -> Error(Unauthorized)
  }
}

// Add this helper function at the top
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

pub fn deactivate_integration_key(
  business_id: String,
  key_type: String,
  key_name: String,
) -> Result(Nil, SupabaseError) {
  let composite_key = business_id <> "/" <> key_type <> "/" <> key_name

  use integration_key <- result.try(get_integration_key_by_composite(
    composite_key,
  ))

  let body = json.object([#("is_active", json.bool(False))]) |> json.to_string()
  let path =
    "/integration_keys?business_id=eq."
    <> business_id
    <> "&key_type=eq."
    <> key_type
    <> "&key_name=eq."
    <> key_name

  use response <- result.try(make_request(http.Patch, path, Some(body)))

  case response.status {
    200 | 204 -> {
      // CRITICAL: Unregister from auth cache via application actor
      case get_application_actor() {
        Ok(app_actor) -> {
          let reply = process.new_subject()

          case key_type {
            "business" | "api" ->
              process.send(
                app_actor,
                application_types.UnregisterBusinessKey(
                  integration_key.key_hash,
                  reply,
                ),
              )
            "customer_api" ->
              process.send(
                app_actor,
                application_types.UnregisterCustomerKey(
                  integration_key.key_hash,
                  reply,
                ),
              )
            _ -> Nil
          }

          // Wait for response (optional - could be fire-and-forget)
          let _ = process.receive(reply, 1000)
          Nil
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[SupabaseClient] Could not unregister key - app actor not found",
          )
          Nil
        }
      }

      Ok(Nil)
    }
    _ -> Error(DatabaseError("Failed to deactivate key: " <> response.body))
  }
}

// ============================================================================
// CONFIGURATION
// ============================================================================

fn get_supabase_config() -> Result(#(String, String), SupabaseError) {
  // Much cleaner - will panic on startup if missing
  let url = utils.require_env("SUPABASE_URL")
  let key = utils.require_env("SUPABASE_KEY")
  Ok(#(url, key))
}

pub fn get_supabase_realtime_url() -> String {
  utils.require_env("SUPABASE_REALTIME_URL")
}

pub fn get_supabase_anon_key() -> String {
  utils.require_env("SUPABASE_ANON_KEY")
}

// ============================================================================
// HTTP HELPERS
// ============================================================================

fn make_request(
  method: http.Method,
  path: String,
  body: Option(String),
) -> Result(response.Response(String), SupabaseError) {
  use #(base_url, api_key) <- result.try(get_supabase_config())

  let url = base_url <> "/rest/v1" <> path

  logging.log(
    logging.Info,
    "[SupabaseClient] Making "
      <> string.inspect(method)
      <> " request to: "
      <> path,
  )

  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("Invalid URL: " <> url) }),
  )

  let req_with_headers =
    req
    |> request.set_header("apikey", api_key)
    |> request.set_header("Authorization", "Bearer " <> api_key)
    |> request.set_header("Content-Type", "application/json")
    |> request.set_header("User-Agent", "TrackTags/1.0")

  let final_req = case method, body {
    http.Post, Some(json_body) -> {
      req_with_headers
      |> request.set_method(http.Post)
      |> request.set_header("Prefer", "return=representation")
      |> request.set_body(json_body)
    }
    http.Patch, Some(json_body) -> {
      req_with_headers
      |> request.set_method(http.Patch)
      |> request.set_header("Prefer", "return=representation")
      |> request.set_body(json_body)
    }
    http.Get, None -> {
      req_with_headers
      |> request.set_method(http.Get)
    }
    http.Delete, None -> {
      req_with_headers
      |> request.set_method(http.Delete)
    }
    _, _ -> req_with_headers |> request.set_method(method)
  }
  case httpc.send(final_req) {
    Ok(response) -> Ok(response)
    Error(http_error) -> {
      logging.log(
        logging.Error,
        "[SupabaseClient] HTTP error: " <> string.inspect(http_error),
      )
      Error(HttpError(http_error))
    }
  }
}

/// Make request with query parameters
fn make_request_with_params(
  method: http.Method,
  path: String,
  body: Option(String),
  params: List(#(String, String)),
) -> Result(response.Response(String), SupabaseError) {
  let query_string = case params {
    [] -> ""
    _ -> "?" <> string.join(list.map(params, fn(p) { p.0 <> "=" <> p.1 }), "&")
  }

  make_request(method, path <> query_string, body)
}

// ============================================================================
// JSON DECODERS
// ============================================================================

fn customer_context_decoder() -> decode.Decoder(customer_types.CustomerContext) {
  use customer <- decode.field("customer", customer_types.customer_decoder())
  use machines <- decode.field(
    "machines",
    decode.list(customer_types.customer_machine_decoder()),
  )
  use limits <- decode.field("plan_limits", decode.list(plan_limit_decoder()))

  decode.success(customer_types.CustomerContext(
    customer: customer,
    machines: machines,
    plan_limits: limits,
  ))
}

// Add the decoder to the JSON DECODERS section (around line 250):
fn plan_decoder() -> decode.Decoder(Plan) {
  use id <- decode.field("id", decode.string)
  use business_id <- decode.field("business_id", decode.string)
  use plan_name <- decode.field("plan_name", decode.string)
  use stripe_price_id <- decode.optional_field(
    "stripe_price_id",
    None,
    decode.optional(decode.string),
  )
  use plan_status <- decode.field("plan_status", decode.string)
  use created_at <- decode.field("created_at", decode.string)

  decode.success(Plan(
    id: id,
    business_id: business_id,
    plan_name: plan_name,
    stripe_price_id: stripe_price_id,
    plan_status: plan_status,
    created_at: created_at,
  ))
}

fn plan_machine_decoder() -> decode.Decoder(PlanMachine) {
  use id <- decode.field("id", decode.string)
  use plan_id <- decode.field("plan_id", decode.string)
  use machine_count <- decode.field("machine_count", decode.int)
  use machine_size <- decode.field("machine_size", decode.string)
  use docker_image <- decode.optional_field(
    "docker_image",
    None,
    decode.optional(decode.string),
  )
  use grace_period_days <- decode.field("grace_period_days", decode.int)

  decode.success(PlanMachine(
    id,
    plan_id,
    machine_count,
    machine_size,
    docker_image,
    grace_period_days,
  ))
}

fn provisioning_task_decoder() -> decode.Decoder(ProvisioningTask) {
  use id <- decode.field("id", decode.string)
  use customer_id <- decode.field("customer_id", decode.string)
  use business_id <- decode.field("business_id", decode.string)
  use action <- decode.field("action", decode.string)
  use provider <- decode.field("provider", decode.string)
  use status <- decode.field("status", decode.string)
  use attempt_count <- decode.field("attempt_count", decode.int)
  use max_attempts <- decode.optional_field("max_attempts", 3, decode.int)
  // Default to 3
  use payload <- decode.field(
    "payload",
    decode.dict(decode.string, decode.string),
  )

  decode.success(ProvisioningTask(
    id: id,
    customer_id: customer_id,
    business_id: business_id,
    action: action,
    provider: provider,
    status: status,
    attempt_count: attempt_count,
    max_attempts: max_attempts,
    payload: payload,
  ))
}

fn validation_result_decoder() -> decode.Decoder(ValidationResult) {
  use key_type <- decode.field("key_type", decode.string)

  case key_type {
    "business" -> {
      use business_id <- decode.field("business_id", decode.string)
      decode.success(BusinessValidation(business_id))
    }
    "customer" -> {
      use business_id <- decode.field("business_id", decode.string)
      use customer_id <- decode.field("customer_id", decode.string)
      use context <- decode.field("context", customer_context_decoder())
      decode.success(CustomerValidation(business_id, customer_id, context))
    }
    _ -> {
      decode.success(InvalidKey)
    }
  }
}

fn integration_key_decoder() -> decode.Decoder(IntegrationKey) {
  use id <- decode.field("id", decode.string)
  use business_id <- decode.field("business_id", decode.string)
  use key_type <- decode.field("key_type", decode.string)
  use key_name <- decode.field("key_name", decode.string)
  use encrypted_key <- decode.field("encrypted_key", decode.string)
  use key_hash <- decode.field("key_hash", decode.optional(decode.string))
  use is_active <- decode.field("is_active", decode.bool)
  use created_at <- decode.field("created_at", decode.optional(decode.string))

  decode.success(IntegrationKey(
    id: id,
    business_id: business_id,
    key_type: key_type,
    key_name: key_name,
    encrypted_key: encrypted_key,
    key_hash: key_hash |> option.unwrap(""),
    is_active: is_active,
    created_at: created_at |> option.unwrap(""),
  ))
}

// ============================================================================
// API KEY VALIDATION
// ============================================================================

pub fn validate_api_key(api_key: String) -> Result(KeyValidation, SupabaseError) {
  validate_api_key_with_retry(api_key, 3)
}

pub fn validate_api_key_with_retry(
  api_key: String,
  retries: Int,
) -> Result(KeyValidation, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Validating key by hash: "
      <> string.slice(api_key, 0, 10)
      <> "...",
  )

  let key_hash = crypto.hash_api_key(api_key)

  // Manual encoding because uri.percent_encode doesn't handle + correctly
  let encoded_hash =
    key_hash
    |> string.replace("+", "%2B")
    |> string.replace("/", "%2F")
    |> string.replace("=", "%3D")

  let path =
    "/integration_keys?key_hash=eq." <> encoded_hash <> "&is_active=eq.true"
  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(integration_key_decoder())) {
        Ok([]) -> {
          logging.log(logging.Warning, "[SupabaseClient] API key not found")
          Error(NotFound("API key not found"))
        }
        Ok([integration_key, ..]) -> {
          case integration_key.key_type {
            "api" | "business" -> {
              logging.log(
                logging.Info,
                "[SupabaseClient] Business key validated",
              )
              Ok(BusinessKey(integration_key.business_id))
            }
            "customer_api" -> {
              logging.log(
                logging.Info,
                "[SupabaseClient] Customer key validated for: "
                  <> integration_key.key_name,
              )
              Ok(CustomerKey(
                integration_key.business_id,
                integration_key.key_name,
              ))
            }
            _ -> {
              case retries > 0 {
                True -> {
                  process.sleep(1000)
                  validate_api_key_with_retry(api_key, retries - 1)
                }
                False -> Error(NotFound("Invalid key type"))
              }
            }
          }
        }
        Error(_) -> {
          case retries > 0 {
            True -> {
              process.sleep(1000)
              validate_api_key_with_retry(api_key, retries - 1)
            }
            False -> Error(ParseError("Invalid response format"))
          }
        }
      }
    }
    401 -> {
      case retries > 0 {
        True -> {
          process.sleep(1000)
          validate_api_key_with_retry(api_key, retries - 1)
        }
        False -> Error(Unauthorized)
      }
    }
    _ -> {
      case retries > 0 {
        True -> {
          process.sleep(1000)
          validate_api_key_with_retry(api_key, retries - 1)
        }
        False -> Error(DatabaseError("Key validation failed"))
      }
    }
  }
}

// ============================================================================
// SUBSCRIPTION CANCELLATION - Customer Controlled
// ============================================================================
/// Get customer by user_id
pub fn get_customer_by_user_id(
  user_id: String,
  business_id: String,
) -> Result(customer_types.Customer, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting customer by user_id: " <> user_id,
  )

  let path =
    "/customers?user_id=eq."
    <> user_id
    <> "&business_id=eq."
    <> business_id
    <> "&deleted_at=is.null"

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Customer not found"))
        Ok([customer, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Retrieved customer: " <> customer.customer_id,
          )
          Ok(customer)
        }
        Error(_) -> Error(ParseError("Invalid customer format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch customer"))
  }
}

/// Get customer's configured free plan limits
pub fn get_customer_free_limits(
  business_id: String,
) -> Result(List(#(String, Float, String)), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting customer free plan for: " <> business_id,
  )

  // Find their free plan
  let query_params = [
    #("business_id", "eq." <> business_id),
    #("plan_name", "eq.free"),
  ]

  use response <- result.try(make_request_with_params(
    http.Get,
    "/plans",
    None,
    query_params,
  ))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(decode.field("id", decode.string, decode.success)),
        )
      {
        Ok([plan_id]) -> get_plan_limits(plan_id)
        Ok([]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] No free plan found, using defaults",
          )
          // Return reasonable defaults if no free plan configured
          Ok([
            #("api_calls", 1000.0, "monthly"),
            #("storage_mb", 100.0, "monthly"),
          ])
        }
        Ok([_, _, ..]) -> {
          logging.log(
            logging.Warning,
            "[SupabaseClient] Multiple free plans found, using first one",
          )
          // If somehow multiple free plans exist, just use the first
          case
            json.parse(
              response.body,
              decode.list(decode.field("id", decode.string, decode.success)),
            )
          {
            Ok([first_plan, ..]) -> get_plan_limits(first_plan)
            _ -> Error(ParseError("Failed to extract first plan"))
          }
        }
        Error(_) -> Error(ParseError("Invalid plan response"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch customer plans"))
  }
}

// Create a new plan
pub fn create_plan(
  business_id: String,
  plan_name: String,
  stripe_price_id: option.Option(String),
) -> Result(Plan, SupabaseError) {
  let body =
    json.object([
      #("business_id", json.string(business_id)),
      #("plan_name", json.string(plan_name)),
      #("stripe_price_id", case stripe_price_id {
        Some(id) -> json.string(id)
        None -> json.null()
      }),
      #("plan_status", json.string("active")),
    ])

  use response <- result.try(make_request(
    http.Post,
    "/plans",
    Some(json.to_string(body)),
  ))

  case response.status {
    201 | 200 -> {
      case json.parse(response.body, decode.list(plan_decoder())) {
        Ok([plan, ..]) -> Ok(plan)
        Ok([]) -> Error(DatabaseError("No plan returned"))
        Error(_) -> Error(ParseError("Invalid plan response"))
      }
    }
    _ -> Error(DatabaseError("Failed to create plan"))
  }
}

// Get all plans for a business
pub fn get_plans_for_business(
  business_id: String,
) -> Result(List(Plan), SupabaseError) {
  let path = "/plans?business_id=eq." <> business_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(plan_decoder())) {
        Ok(plans) -> Ok(plans)
        Error(_) -> Error(ParseError("Invalid plans response"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch plans"))
  }
}

// Delete a plan
pub fn delete_plan(
  business_id: String,
  plan_id: String,
) -> Result(Nil, SupabaseError) {
  let path = "/plans?id=eq." <> plan_id <> "&business_id=eq." <> business_id

  use response <- result.try(make_request(http.Delete, path, None))

  case response.status {
    200 | 204 -> Ok(Nil)
    404 -> Error(NotFound("Plan not found"))
    _ -> Error(DatabaseError("Failed to delete plan"))
  }
}

/// Get limits for a specific plan
fn get_plan_limits(
  plan_id: String,
) -> Result(List(#(String, Float, String)), SupabaseError) {
  let query_params = [#("plan_id", "eq." <> plan_id)]

  use response <- result.try(make_request_with_params(
    http.Get,
    "/plan_limits",
    None,
    query_params,
  ))

  case response.status {
    200 -> {
      let limit_decoder =
        decode.field("metric_name", decode.string, fn(metric_name) {
          decode.field("limit_value", decode.float, fn(limit_value) {
            decode.field("limit_period", decode.string, fn(limit_period) {
              decode.success(#(metric_name, limit_value, limit_period))
            })
          })
        })

      case json.parse(response.body, decode.list(limit_decoder)) {
        Ok(limits) -> Ok(limits)
        Error(_) -> Error(ParseError("Invalid limits format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch plan limits"))
  }
}

/// Downgrade business to their configured free tier limits
pub fn downgrade_to_free_limits(
  business_id: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Downgrading to customer's free limits: " <> business_id,
  )

  // Get customer's free tier configuration
  use free_limits <- result.try(get_customer_free_limits(business_id))

  // Deactivate existing business-level limits (soft delete)
  let deactivate_data = json.object([#("is_active", json.bool(False))])
  let update_path = "/plan_limits?business_id=eq." <> business_id
  use _response <- result.try(make_request(
    http.Patch,
    update_path,
    Some(json.to_string(deactivate_data)),
  ))

  // Create new business-level limits based on their free plan (avoiding duplicates)
  use _ <- result.try(
    list.try_each(free_limits, fn(limit) {
      let #(metric_name, limit_value, period) = limit

      // Delete any existing limit for this metric first
      let delete_path =
        "/plan_limits?business_id=eq."
        <> business_id
        <> "&metric_name=eq."
        <> metric_name
      let _ = make_request(http.Delete, delete_path, None)

      create_plan_limit(
        business_id,
        metric_name,
        limit_value,
        period,
        "gte",
        "deny",
        None,
      )
    })
    |> result.map_error(fn(_) { DatabaseError("Failed to create free limits") }),
  )
  logging.log(
    logging.Info,
    "[SupabaseClient] ✅ Successfully downgraded to customer's free limits: "
      <> business_id,
  )

  Ok(Nil)
}

// Add to supabase_client.gleam
pub fn get_plan_limits_by_stripe_price_id(
  stripe_price_id: String,
) -> Result(List(customer_types.PlanLimit), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting plan limits for Stripe price: " <> stripe_price_id,
  )

  // First, find the plan by stripe_price_id
  let plan_query = "/plans?stripe_price_id=eq." <> stripe_price_id

  use plan_response <- result.try(make_request(http.Get, plan_query, None))

  case plan_response.status {
    200 -> {
      // Parse to get plan_id
      let plan_id_decoder = decode.field("id", decode.string, decode.success)

      case json.parse(plan_response.body, decode.list(plan_id_decoder)) {
        Ok([plan_id]) -> {
          // Now get limits for this plan_id (function already exists!)
          get_plan_limits_by_plan_id(plan_id)
        }
        Ok([]) -> {
          logging.log(
            logging.Info,
            "No plan found for price: " <> stripe_price_id,
          )
          Ok([])
          // No plan configured for this price
        }
        Ok([_, _, ..]) ->
          Error(DatabaseError("Multiple plans with same price_id"))
        Error(_) -> Error(ParseError("Invalid plan response"))
      }
    }
    _ -> Error(DatabaseError("Failed to lookup plan by price_id"))
  }
}

// ============================================================================
// DLQ FUNCTIONS
// ============================================================================

pub type StripeEventRecord {
  StripeEventRecord(
    event_id: String,
    event_type: String,
    status: String,
    retry_count: Int,
    raw_payload: String,
    error_message: Option(String),
    created_at: String,
  )
}

fn stripe_event_decoder() -> decode.Decoder(StripeEventRecord) {
  use event_id <- decode.field("event_id", decode.string)
  use event_type <- decode.field("event_type", decode.string)
  use status <- decode.field("status", decode.string)
  use retry_count <- decode.optional_field("retry_count", 0, decode.int)
  use raw_payload <- decode.field("raw_payload", decode.string)
  use error_message <- decode.optional_field(
    "error_message",
    None,
    decode.optional(decode.string),
  )
  use created_at <- decode.field("created_at", decode.string)

  decode.success(StripeEventRecord(
    event_id,
    event_type,
    status,
    retry_count,
    raw_payload,
    error_message,
    created_at,
  ))
}

pub fn get_failed_stripe_events_for_business(
  business_id: String,
  limit: Int,
) -> Result(List(StripeEventRecord), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting failed events for business: " <> business_id,
  )

  let path = case business_id {
    "" ->
      "/stripe_events?status=eq.failed&order=created_at.desc&limit="
      <> int.to_string(limit)
      <> "&select=event_id,event_type,status,retry_count,raw_payload::text,error_message,created_at"
    _ ->
      "/stripe_events?business_id=eq."
      <> business_id
      <> "&status=eq.failed&order=created_at.desc&limit="
      <> int.to_string(limit)
      <> "&select=event_id,event_type,status,retry_count,raw_payload::text,error_message,created_at"
  }

  use response <- result.try(make_request(http.Get, path, None))

  // ✅ ADD THIS LOGGING
  logging.log(
    logging.Info,
    "[SupabaseClient] Response status: " <> int.to_string(response.status),
  )
  logging.log(logging.Info, "[SupabaseClient] Response body: " <> response.body)

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(stripe_event_decoder())) {
        Ok(events) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] Successfully parsed "
              <> int.to_string(list.length(events))
              <> " events",
          )
          Ok(events)
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[SupabaseClient] Parse error: " <> string.inspect(e),
          )
          Error(ParseError("Invalid events"))
        }
      }
    }
    _ -> Error(DatabaseError("Failed to get failed events"))
  }
}

pub fn get_stripe_event_by_id(
  event_id: String,
) -> Result(StripeEventRecord, SupabaseError) {
  let path = "/stripe_events?event_id=eq." <> event_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(stripe_event_decoder())) {
        Ok([event]) -> Ok(event)
        Ok([]) -> Error(NotFound("Event not found"))
        _ -> Error(ParseError("Invalid response"))
      }
    }
    _ -> Error(DatabaseError("Failed to get event"))
  }
}

pub fn increment_retry_count(event_id: String) -> Result(Nil, SupabaseError) {
  let body =
    json.object([#("p_event_id", json.string(event_id))]) |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/rpc/increment_stripe_event_retry",
    Some(body),
  ))

  case response.status {
    200 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to increment retry count"))
  }
}

// ============================================================================
// AUDIT LOG FUNCTIONS
// ============================================================================

pub fn insert_audit_log(
  actor_id: String,
  action: String,
  resource_type: String,
  resource_id: String,
  details: json.Json,
) -> Result(Nil, SupabaseError) {
  let body =
    json.object([
      #("actor_id", json.string(actor_id)),
      #("action", json.string(action)),
      #("resource_type", json.string(resource_type)),
      #("resource_id", json.string(resource_id)),
      #("details", details),
    ])
    |> json.to_string()

  use response <- result.try(make_request(http.Post, "/audit_logs", Some(body)))

  case response.status {
    201 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to insert audit log"))
  }
}

pub fn update_business_info(
  business_id: String,
  business_name: String,
  email: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Updating business info: " <> business_id,
  )

  let update_json =
    json.object([
      #("business_name", json.string(business_name)),
      #("email", json.string(email)),
    ])

  let url = "/businesses?business_id=eq." <> business_id

  use response <- result.try(make_request(
    http.Patch,
    url,
    Some(json.to_string(update_json)),
  ))

  case response.status {
    200 | 204 -> {
      logging.log(logging.Info, "[SupabaseClient] ✅ Business info updated")
      Ok(Nil)
    }
    404 -> Error(NotFound("Business not found: " <> business_id))
    _ -> Error(DatabaseError("Failed to update business info"))
  }
}

pub fn get_audit_logs(
  limit: Int,
  actor_id: Option(String),
  resource_type: Option(String),
) -> Result(List(json.Json), SupabaseError) {
  let base_path =
    "/audit_logs?order=created_at.desc&limit=" <> int.to_string(limit)

  let actor_filter = case actor_id {
    Some(id) -> "&actor_id=eq." <> id
    None -> ""
  }

  let type_filter = case resource_type {
    Some(rt) -> "&resource_type=eq." <> rt
    None -> ""
  }

  let path = base_path <> actor_filter <> type_filter

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      // Return raw JSON - frontend will decode
      Ok([])
    }
    _ -> Error(DatabaseError("Failed to get audit logs"))
  }
}

// ============================================================================
// RECONCILIATION FUNCTIONS
// ============================================================================

pub fn get_active_stripe_subscriptions() -> Result(
  List(business_types.Business),
  SupabaseError,
) {
  use response <- result.try(make_request(
    http.Post,
    "/rpc/get_active_stripe_subscriptions",
    None,
  ))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(business_types.business_decoder()),
        )
      {
        Ok(businesses) -> Ok(businesses)
        Error(_) -> Error(ParseError("Invalid businesses"))
      }
    }
    _ -> Error(DatabaseError("Failed to get active subscriptions"))
  }
}

pub fn get_businesses_with_stripe_integration() -> Result(
  List(String),
  SupabaseError,
) {
  use response <- result.try(make_request(
    http.Post,
    "/rpc/get_businesses_with_stripe_integration",
    None,
  ))

  case response.status {
    200 -> {
      let decoder = decode.field("business_id", decode.string, decode.success)
      case json.parse(response.body, decode.list(decoder)) {
        Ok(business_ids) -> Ok(business_ids)
        Error(_) -> Error(ParseError("Invalid business IDs"))
      }
    }
    _ -> Error(DatabaseError("Failed to get businesses"))
  }
}

pub fn get_business_active_customers(
  business_id: String,
) -> Result(List(customer_types.Customer), SupabaseError) {
  let body =
    json.object([#("p_business_id", json.string(business_id))])
    |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/rpc/get_business_active_customers",
    Some(body),
  ))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok(customers) -> Ok(customers)
        Error(_) -> Error(ParseError("Invalid customers"))
      }
    }
    _ -> Error(DatabaseError("Failed to get active customers"))
  }
}

pub fn insert_reconciliation_record(
  reconciliation_type: String,
  business_id: Option(String),
  total_checked: Int,
  mismatches_found: Int,
  mismatches_fixed: Int,
  errors_encountered: Int,
  details: json.Json,
) -> Result(Nil, SupabaseError) {
  let body =
    json.object([
      #("reconciliation_type", json.string(reconciliation_type)),
      #("business_id", case business_id {
        Some(id) -> json.string(id)
        None -> json.null()
      }),
      #("total_checked", json.int(total_checked)),
      #("mismatches_found", json.int(mismatches_found)),
      #("mismatches_fixed", json.int(mismatches_fixed)),
      #("errors_encountered", json.int(errors_encountered)),
      #("details", details),
      #("started_at", json.string("NOW()")),
    ])
    |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/stripe_reconciliation",
    Some(body),
  ))

  case response.status {
    201 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to insert reconciliation record"))
  }
}

// ============================================================================
// BUSINESS MANAGEMENT
// ============================================================================

/// Soft delete a business (30-day recovery window)
pub fn soft_delete_business(
  business_id: String,
  user_id: Option(String),
  reason: Option(String),
) -> Result(String, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Soft deleting business: " <> business_id,
  )

  let params = [
    #("p_business_id", json.string(business_id)),
    #("p_user_id", case user_id {
      Some(uid) -> json.string(uid)
      None -> json.null()
    }),
    #("p_reason", case reason {
      Some(r) -> json.string(r)
      None -> json.null()
    }),
  ]

  let body = json.object(params) |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/rpc/soft_delete_business",
    Some(body),
  ))

  case response.status {
    200 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Business soft deleted: " <> business_id,
      )
      Ok("Business scheduled for deletion in 30 days")
    }
    _ -> Error(DatabaseError("Failed to soft delete business"))
  }
}

/// Restore a soft-deleted business (within 30-day window)
pub fn restore_deleted_business(
  business_id: String,
) -> Result(String, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Restoring business: " <> business_id,
  )

  let body =
    json.object([#("p_business_id", json.string(business_id))])
    |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/rpc/restore_deleted_business",
    Some(body),
  ))

  case response.status {
    200 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Business restored: " <> business_id,
      )
      Ok("Business restored successfully")
    }
    _ -> Error(DatabaseError("Failed to restore business"))
  }
}

/// Get list of businesses pending permanent deletion
pub fn get_pending_deletions() -> Result(List(String), SupabaseError) {
  let path =
    "/businesses?deleted_at=not.is.null&deletion_scheduled_for=lte.now()"

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      let decoder = decode.field("business_id", decode.string, decode.success)
      case json.parse(response.body, decode.list(decoder)) {
        Ok(business_ids) -> Ok(business_ids)
        Error(_) -> Error(ParseError("Invalid deletion list"))
      }
    }
    _ -> Error(DatabaseError("Failed to get pending deletions"))
  }
}

// ADD this function (around line 900, near other business functions)
/// Set stripe_customer_id for a business (initial mapping from Stripe webhook)
pub fn set_stripe_customer_id(
  business_id: String,
  stripe_customer_id: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Mapping Stripe customer "
      <> stripe_customer_id
      <> " to business "
      <> business_id,
  )

  let update_json =
    json.object([
      #("stripe_customer_id", json.string(stripe_customer_id)),
      #("stripe_subscription_status", json.string("active")),
    ])

  let url = "/businesses?business_id=eq." <> business_id

  use response <- result.try(make_request(
    http.Patch,
    url,
    Some(json.to_string(update_json)),
  ))

  case response.status {
    200 | 204 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Mapped Stripe customer to business",
      )
      Ok(Nil)
    }
    404 -> Error(NotFound("Business not found: " <> business_id))
    _ -> Error(DatabaseError("Failed to set stripe_customer_id"))
  }
}

// In supabase_client.gleam
pub fn create_business(
  business_id: String,
  business_name: String,
  email: String,
) -> Result(business_types.Business, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Creating business: " <> business_id,
  )

  let business_data =
    json.object([
      #("business_id", json.string(business_id)),
      #("business_name", json.string(business_name)),
      #("email", json.string(email)),
      #("plan_type", json.string("free")),
      #("subscription_status", json.string("free")),
    ])

  use response <- result.try(make_request(
    http.Post,
    "/businesses",
    Some(json.to_string(business_data)),
  ))

  case response.status {
    201 | 200 -> {
      case
        json.parse(
          response.body,
          decode.list(business_types.business_decoder()),
        )
      {
        Ok([new_business, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Business created: " <> new_business.business_id,
          )
          Ok(new_business)
        }
        Ok([]) -> Error(ParseError("No business returned"))
        Error(_) -> Error(ParseError("Invalid response format"))
      }
    }
    409 -> Error(DatabaseError("Business already exists"))
    _ -> Error(DatabaseError("Failed to create business"))
  }
}

fn timestamp_to_iso(timestamp: Int) -> String {
  // Convert Unix timestamp to ISO8601 string
  let datetime = birl.from_unix(timestamp)
  birl.to_iso8601(datetime)
}

/// Update customer subscription (for admin override)
pub fn update_customer_subscription(
  business_id: String,
  customer_id: String,
  status: String,
  price_id: String,
  subscription_ends_at: Option(Int),
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Updating customer subscription: " <> customer_id,
  )

  let update_json = case subscription_ends_at {
    Some(timestamp) ->
      json.object([
        #("subscription_status", json.string(status)),
        #("stripe_price_id", json.string(price_id)),
        #("subscription_ends_at", json.string(timestamp_to_iso(timestamp))),
      ])
    None ->
      json.object([
        #("subscription_status", json.string(status)),
        #("stripe_price_id", json.string(price_id)),
      ])
  }

  let url =
    "/customers?business_id=eq."
    <> business_id
    <> "&customer_id=eq."
    <> customer_id

  use response <- result.try(make_request(
    http.Patch,
    url,
    Some(json.to_string(update_json)),
  ))

  case response.status {
    200 | 204 -> Ok(Nil)
    404 -> Error(NotFound("Customer not found"))
    _ -> Error(DatabaseError("Failed to update customer subscription"))
  }
}

// For business's own Stripe webhooks
pub fn update_business_subscription_by_stripe_customer(
  business_id: String,
  stripe_customer_id: String,
  status: String,
  price_id: String,
) -> Result(response.Response(String), SupabaseError) {
  // Update customers table WHERE business_id AND stripe_customer_id match
  let update_json =
    json.object([
      #("stripe_subscription_status", json.string(status)),
      #("stripe_price_id", json.string(price_id)),
    ])

  let url =
    "/customers?business_id=eq."
    <> business_id
    <> "&stripe_customer_id=eq."
    <> stripe_customer_id
  make_request(http.Patch, url, Some(json.to_string(update_json)))
}

/// Update business subscription with optional override expiration
pub fn update_business_subscription_with_override(
  stripe_customer_id: String,
  status: String,
  price_id: String,
  subscription_ends_at: Option(Int),
  override_expires_at: Option(Int),
) -> Result(response.Response(String), SupabaseError) {
  let base_fields = [
    #("subscription_status", json.string(status)),
    #("stripe_price_id", json.string(price_id)),
  ]

  let with_subscription_end = case subscription_ends_at {
    Some(timestamp) -> [
      #("subscription_ends_at", json.string(utils.unix_to_iso8601(timestamp))),
      ..base_fields
    ]
    None -> base_fields
  }

  let all_fields = case override_expires_at {
    Some(timestamp) -> [
      #(
        "subscription_override_expires_at",
        json.string(utils.unix_to_iso8601(timestamp)),
      ),
      ..with_subscription_end
    ]
    None -> with_subscription_end
  }

  let update_json = json.object(all_fields)
  let url = "/businesses?stripe_customer_id=eq." <> stripe_customer_id
  make_request(http.Patch, url, Some(json.to_string(update_json)))
}

// For TrackTags platform webhooks
pub fn update_business_subscription(
  stripe_customer_id: String,
  status: String,
  price_id: String,
  subscription_ends_at: Option(Int),
) -> Result(response.Response(String), SupabaseError) {
  let base_fields = [
    #("subscription_status", json.string(status)),
    #("stripe_price_id", json.string(price_id)),
  ]

  let all_fields = case subscription_ends_at {
    Some(timestamp) -> [
      #("subscription_ends_at", json.string(utils.unix_to_iso8601(timestamp))),
      ..base_fields
    ]
    None -> base_fields
  }

  let update_json = json.object(all_fields)
  let url = "/businesses?stripe_customer_id=eq." <> stripe_customer_id
  make_request(http.Patch, url, Some(json.to_string(update_json)))
}

/// Update customer subscription period tracking
pub fn update_customer_subscription_period(
  business_id: String,
  customer_id: String,
  last_invoice_date: Int,
  subscription_ends_at: Int,
) -> Result(Nil, SupabaseError) {
  let update_json =
    json.object([
      #(
        "last_invoice_date",
        json.string(utils.unix_to_iso8601(last_invoice_date)),
      ),
      #(
        "subscription_ends_at",
        json.string(utils.unix_to_iso8601(subscription_ends_at)),
      ),
    ])

  let path =
    "/customers?business_id=eq."
    <> business_id
    <> "&customer_id=eq."
    <> customer_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_json)),
  ))

  case response.status {
    200 | 204 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to update customer subscription period"))
  }
}

/// Get business by Stripe customer ID (for webhook processing)
pub fn get_business_by_stripe_customer(
  stripe_customer_id: String,
) -> Result(business_types.Business, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting business by Stripe customer: "
      <> stripe_customer_id,
  )

  let path = "/businesses?stripe_customer_id=eq." <> stripe_customer_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(business_types.business_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Business not found for Stripe customer"))
        Ok([business, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Found business: " <> business.business_id,
          )
          Ok(business)
        }
        Error(_) -> Error(ParseError("Invalid business format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch business by Stripe customer"))
  }
}

/// Get business details by business_id
pub fn get_business(
  business_id: String,
) -> Result(business_types.Business, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting business: " <> business_id,
  )

  let path = "/businesses?business_id=eq." <> business_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(business_types.business_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Business not found"))
        Ok([business, ..]) -> Ok(business)
        Error(_) -> Error(ParseError("Invalid business format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch business"))
  }
}

/// Create plan limit for subscription provisioning
pub fn create_plan_limit(
  business_id: String,
  metric_name: String,
  limit_value: Float,
  period: String,
  operator: String,
  action: String,
  webhook_url: Option(String),
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Creating plan limit: "
      <> metric_name
      <> " = "
      <> float.to_string(limit_value),
  )

  let base_fields = [
    #("business_id", json.string(business_id)),
    #("plan_id", json.null()),
    #("customer_id", json.null()),
    #("metric_name", json.string(metric_name)),
    #("limit_value", json.float(limit_value)),
    #("limit_period", json.string(period)),
    #("breach_operator", json.string(operator)),
    #("breach_action", json.string(action)),
  ]
  let all_fields = case webhook_url {
    Some(url) -> [#("webhook_url", json.string(url)), ..base_fields]
    None -> base_fields
  }

  let limit_data = json.object(all_fields)

  use response <- result.try(make_request(
    http.Post,
    "/plan_limits",
    Some(json.to_string(limit_data)),
  ))

  case response.status {
    201 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Created plan limit: " <> metric_name,
      )
      Ok(Nil)
    }
    _ -> Error(DatabaseError("Failed to create plan limit"))
  }
}

// ============================================================================
// PLAN
// ============================================================================

pub fn get_plan_machines_by_price_id(
  price_id: String,
) -> Result(PlanMachine, SupabaseError) {
  // First get plan by price_id
  let path = "/plans?stripe_price_id=eq." <> price_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(decode.field("id", decode.string, decode.success)),
        )
      {
        Ok([plan_id]) -> {
          // Now get machine config for this plan
          let machine_path = "/plan_machines?plan_id=eq." <> plan_id
          use machine_response <- result.try(make_request(
            http.Get,
            machine_path,
            None,
          ))

          case
            json.parse(
              machine_response.body,
              decode.list(plan_machine_decoder()),
            )
          {
            Ok([machine]) -> Ok(machine)
            Ok([]) -> Error(NotFound("No machine config for plan"))
            _ -> Error(ParseError("Invalid machine config"))
          }
        }
        Ok([]) -> Error(NotFound("Plan not found for price_id"))
        _ -> Error(ParseError("Multiple plans with same price_id"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch plan"))
  }
}

/// Get plan limits for a specific plan_id (used by customer_actor)
pub fn get_plan_limits_by_plan_id(
  plan_id: String,
) -> Result(List(customer_types.PlanLimit), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting plan limits for plan: " <> plan_id,
  )

  let path = "/plan_limits?plan_id=eq." <> plan_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(plan_limit_decoder())) {
        Ok(limits) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Retrieved "
              <> string.inspect(list.length(limits))
              <> " plan limits for plan: "
              <> plan_id,
          )
          Ok(limits)
        }
        Error(_) -> Error(ParseError("Invalid plan limits format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch plan limits"))
  }
}

// ============================================================================
// PLAN LIMITS JSON DECODERS (Add to decoders section)
// ============================================================================

fn plan_limit_decoder() -> decode.Decoder(customer_types.PlanLimit) {
  use id <- decode.field("id", decode.string)
  use business_id <- decode.field("business_id", decode.optional(decode.string))
  use plan_id <- decode.field("plan_id", decode.optional(decode.string))
  use metric_name <- decode.field("metric_name", decode.string)
  use limit_value <- decode.field(
    "limit_value",
    decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)]),
  )
  use limit_period <- decode.field("limit_period", decode.string)
  use breach_operator <- decode.field("breach_operator", decode.string)
  use breach_action <- decode.field("breach_action", decode.string)
  use webhook_urls <- decode.field(
    "webhook_urls",
    decode.optional(decode.string),
  )
  use created_at <- decode.field("created_at", decode.string)

  use metric_type <- decode.optional_field(
    "metric_type",
    "reset",
    decode.string,
  )

  decode.success(customer_types.PlanLimit(
    id: id,
    business_id: business_id,
    plan_id: plan_id,
    metric_name: metric_name,
    limit_value: limit_value,
    limit_period: limit_period,
    breach_operator: breach_operator,
    breach_action: breach_action,
    webhook_urls: webhook_urls,
    created_at: created_at,
    metric_type: metric_type,
  ))
}

// ============================================================================
// BUSINESS PLAN LIMITS MANAGEMENT
// ============================================================================

/// Link a user to a business
pub fn link_user_to_business(
  user_id: String,
  business_id: String,
  role: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Linking user "
      <> user_id
      <> " to business "
      <> business_id
      <> " with role "
      <> role,
  )

  let link_data =
    json.object([
      #("user_id", json.string(user_id)),
      #("business_id", json.string(business_id)),
      #("role", json.string(role)),
    ])

  use response <- result.try(make_request(
    http.Post,
    "/user_businesses",
    Some(json.to_string(link_data)),
  ))

  case response.status {
    201 | 200 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ User linked to business successfully",
      )
      Ok(Nil)
    }
    409 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] User already linked to business",
      )
      Ok(Nil)
      // Not an error - idempotent
    }
    _ -> Error(DatabaseError("Failed to link user to business"))
  }
}

/// Create a business-level plan limit
pub fn create_business_plan_limit(
  business_id: String,
  metric_name: String,
  limit_value: Float,
  limit_period: String,
  breach_operator: String,
  breach_action: String,
  webhook_urls: Option(String),
) -> Result(customer_types.PlanLimit, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Creating business plan limit: "
      <> business_id
      <> "/"
      <> metric_name
      <> " = "
      <> float.to_string(limit_value),
  )

  let base_fields = [
    #("business_id", json.string(business_id)),
    #("plan_id", json.null()),
    #("customer_id", json.null()),
    #("metric_name", json.string(metric_name)),
    #("limit_value", json.float(limit_value)),
    #("limit_period", json.string(limit_period)),
    #("breach_operator", json.string(breach_operator)),
    #("breach_action", json.string(breach_action)),
  ]

  let all_fields = case webhook_urls {
    Some(urls) -> [#("webhook_urls", json.string(urls)), ..base_fields]
    None -> base_fields
  }

  let limit_data = json.object(all_fields)

  use response <- result.try(make_request(
    http.Post,
    "/plan_limits",
    Some(json.to_string(limit_data)),
  ))

  case response.status {
    201 -> {
      case json.parse(response.body, decode.list(plan_limit_decoder())) {
        Ok([new_limit, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Created business plan limit: " <> new_limit.id,
          )
          Ok(new_limit)
        }
        Ok([]) -> Error(ParseError("No plan limit returned from server"))
        Error(_) -> Error(ParseError("Invalid plan limit response format"))
      }
    }
    409 -> Error(DatabaseError("Plan limit already exists for this metric"))
    _ -> Error(DatabaseError("Failed to create business plan limit"))
  }
}

/// Get all business-level plan limits
pub fn get_business_plan_limits(
  business_id: String,
) -> Result(List(customer_types.PlanLimit), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting business plan limits for: " <> business_id,
  )

  let path = "/plan_limits?business_id=eq." <> business_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(plan_limit_decoder())) {
        Ok(limits) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Retrieved "
              <> string.inspect(list.length(limits))
              <> " business plan limits",
          )
          Ok(limits)
        }
        Error(_) -> Error(ParseError("Invalid plan limits format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch business plan limits"))
  }
}

/// Get a specific plan limit by ID (with business ownership check)
pub fn get_plan_limit_by_id(
  business_id: String,
  limit_id: String,
) -> Result(customer_types.PlanLimit, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting plan limit: "
      <> limit_id
      <> " for business: "
      <> business_id,
  )

  let path =
    "/plan_limits?id=eq." <> limit_id <> "&business_id=eq." <> business_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(plan_limit_decoder())) {
        Ok([]) -> Error(NotFound("Plan limit not found"))
        Ok([limit, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Retrieved plan limit: " <> limit.id,
          )
          Ok(limit)
        }
        Error(_) -> Error(ParseError("Invalid plan limit format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch plan limit"))
  }
}

/// Update a business plan limit
pub fn update_business_plan_limit(
  business_id: String,
  limit_id: String,
  metric_name: String,
  limit_value: Float,
  limit_period: String,
  breach_operator: String,
  breach_action: String,
  webhook_urls: Option(String),
  customer_id: Option(String),
) -> Result(customer_types.PlanLimit, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Updating plan limit: " <> limit_id,
  )

  let base_fields = [
    #("metric_name", json.string(metric_name)),
    #("limit_value", json.float(limit_value)),
    #("limit_period", json.string(limit_period)),
    #("breach_operator", json.string(breach_operator)),
    #("breach_action", json.string(breach_action)),
    #("customer_id", case customer_id {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
  ]

  let all_fields = case webhook_urls {
    Some(urls) -> [#("webhook_urls", json.string(urls)), ..base_fields]
    None -> [#("webhook_urls", json.null()), ..base_fields]
  }

  let update_data = json.object(all_fields)

  let path =
    "/plan_limits?id=eq." <> limit_id <> "&business_id=eq." <> business_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(plan_limit_decoder())) {
        Ok([]) ->
          Error(NotFound("Plan limit not found or not owned by business"))
        Ok([updated_limit, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Updated plan limit: " <> updated_limit.id,
          )
          Ok(updated_limit)
        }
        Error(_) -> Error(ParseError("Invalid plan limit response format"))
      }
    }
    _ -> Error(DatabaseError("Failed to update plan limit"))
  }
}

/// Delete a business plan limit
pub fn delete_plan_limit(
  business_id: String,
  limit_id: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Deleting plan limit: "
      <> limit_id
      <> " for business: "
      <> business_id,
  )

  let path =
    "/plan_limits?id=eq." <> limit_id <> "&business_id=eq." <> business_id

  use response <- result.try(make_request(http.Delete, path, None))

  case response.status {
    200 | 204 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Deleted plan limit: " <> limit_id,
      )
      Ok(Nil)
    }
    404 -> Error(NotFound("Plan limit not found or not owned by business"))
    _ -> Error(DatabaseError("Failed to delete plan limit"))
  }
}

// ============================================================================
// STRIPE EVENT DEDUPLICATION
// ============================================================================

/// Record a Stripe event to prevent duplicate processing
pub fn insert_stripe_event(
  event_id: String,
  event_type: String,
  business_id: Option(String),
  customer_id: Option(String),
  raw_payload: String,
  source: String,
  source_business_id: Option(String),
) -> Result(Nil, SupabaseError) {
  let body =
    json.object([
      #("event_id", json.string(event_id)),
      #("event_type", json.string(event_type)),
      #("business_id", case business_id {
        Some(id) -> json.string(id)
        None -> json.null()
      }),
      #("customer_id", case customer_id {
        Some(id) -> json.string(id)
        None -> json.null()
      }),
      #("raw_payload", json.string(raw_payload)),
      #("source", json.string(source)),
      // ADD THIS
      #("source_business_id", case source_business_id {
        // ADD THIS
        Some(id) -> json.string(id)
        None -> json.null()
      }),
      #("status", json.string("pending")),
    ])
    |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/stripe_events",
    Some(body),
  ))

  case response.status {
    201 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to insert event"))
  }
}

/// Mark a Stripe event as completed
pub fn update_stripe_event_status(
  event_id: String,
  status: String,
  error_message: Option(String),
) -> Result(Nil, SupabaseError) {
  let base_fields = [
    #("status", json.string(status)),
    #("processed_at", json.string("now()")),
  ]

  let all_fields = case error_message {
    Some(msg) -> [#("error_message", json.string(msg)), ..base_fields]
    None -> base_fields
  }

  let update_data = json.object(all_fields)

  use response <- result.try(make_request(
    http.Patch,
    "/stripe_events?event_id=eq." <> event_id,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 | 204 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to update event status"))
  }
}

// ============================================================================
// PROVISIONING QUEUE
// ============================================================================

// Add missing functions
pub fn get_expired_machines() -> Result(
  List(customer_types.CustomerMachine),
  SupabaseError,
) {
  let path = "/customer_machines?status=eq.running&expires_at=lt.now()"

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_machine_decoder()),
        )
      {
        Ok(machines) -> Ok(machines)
        Error(_) -> Error(ParseError("Invalid machines format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch expired machines"))
  }
}

pub fn get_customer_machines(
  customer_id: String,
) -> Result(List(customer_types.CustomerMachine), SupabaseError) {
  let path =
    "/customer_machines?customer_id=eq." <> customer_id <> "&status=eq.running"

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_machine_decoder()),
        )
      {
        Ok(machines) -> Ok(machines)
        Error(_) -> Error(ParseError("Invalid machines format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch customer machines"))
  }
}

pub fn update_machine_status(
  machine_id: String,
  status: String,
) -> Result(Nil, SupabaseError) {
  let update_data =
    json.object([
      #("status", json.string(status)),
      #("updated_at", json.string("now()")),
    ])

  let path = "/customer_machines?id=eq." <> machine_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 | 204 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to update machine status"))
  }
}

pub fn insert_customer_machine(
  customer_id: String,
  business_id: String,
  machine_id: String,
  fly_app_name: String,
  ip_address: String,
  status: String,
  expires_at: Int,
  machine_size: String,
  region: String,
) -> Result(Nil, SupabaseError) {
  let expires_at_iso = utils.unix_to_iso8601(expires_at)

  let data =
    json.object([
      #("customer_id", json.string(customer_id)),
      #("business_id", json.string(business_id)),
      #("machine_id", json.string(machine_id)),
      #("app_name", json.string(fly_app_name)),
      #("machine_size", json.string(machine_size)),
      #("region", json.string(region)),
      #("ip_address", json.string(ip_address)),
      #("status", json.string(status)),
      #("expires_at", json.string(expires_at_iso)),
      #("provider", json.string("fly")),
    ])

  case
    make_request(http.Post, "/customer_machines", Some(json.to_string(data)))
  {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(DatabaseError("Failed to insert customer machine"))
  }
}

pub fn update_provisioning_task_status(
  task_id: String,
  status: String,
) -> Result(Nil, SupabaseError) {
  let update_data =
    json.object([
      #("status", json.string(status)),
      #("completed_at", json.string("now()")),
    ])

  let path = "/provisioning_queue?id=eq." <> task_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 | 204 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to update task status"))
  }
}

pub fn update_provisioning_task_dead_letter(
  task_id: String,
  error_message: String,
) -> Result(Nil, SupabaseError) {
  let update_data =
    json.object([
      #("status", json.string("dead_letter")),
      #("error_message", json.string(error_message)),
      #("dead_letter_at", json.string("now()")),
    ])

  let path = "/provisioning_queue?id=eq." <> task_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 | 204 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to move task to dead letter"))
  }
}

pub fn update_provisioning_task_retry(
  task_id: String,
  attempt_count: Int,
  next_retry_at: Int,
  error_message: String,
) -> Result(Nil, SupabaseError) {
  let update_data =
    json.object([
      #("attempt_count", json.int(attempt_count)),
      #("next_retry_at", json.int(next_retry_at)),
      #("last_attempt_at", json.string("now()")),
      #("error_message", json.string(error_message)),
    ])

  let path = "/provisioning_queue?id=eq." <> task_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 | 204 -> Ok(Nil)
    _ -> Error(DatabaseError("Failed to update retry info"))
  }
}

/// Add a machine provisioning task to the queue
pub fn insert_provisioning_queue(
  business_id: String,
  customer_id: String,
  action: String,
  provider: String,
  payload: Dict(String, String),
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Queuing " <> action <> " for customer: " <> customer_id,
  )

  // For test customers, always use unique idempotency key
  let idempotency_key = case string.starts_with(customer_id, "test_") {
    True ->
      action
      <> "_"
      <> customer_id
      <> "_"
      <> int.to_string(utils.current_timestamp())
      <> "_"
      <> utils.generate_random()
    // Add random component for tests
    False ->
      action
      <> "_"
      <> customer_id
      <> "_"
      <> int.to_string(utils.current_timestamp())
  }

  let payload_json =
    payload
    |> dict.to_list()
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
    |> json.object()

  let queue_data =
    json.object([
      #("business_id", json.string(business_id)),
      #("customer_id", json.string(customer_id)),
      #("action", json.string(action)),
      #("provider", json.string(provider)),
      #("status", json.string("pending")),
      #("payload", payload_json),
      #("idempotency_key", json.string(idempotency_key)),
      #("next_retry_at", json.null()),
      #("attempt_count", json.int(0)),
      #("max_attempts", json.int(3)),
    ])

  use response <- result.try(make_request(
    http.Post,
    "/provisioning_queue",
    Some(json.to_string(queue_data)),
  ))

  case response.status {
    201 | 200 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Queued " <> action <> " for: " <> customer_id,
      )
      Ok(Nil)
    }
    409 -> {
      // For test data, this is an error - we want unique entries
      case string.starts_with(customer_id, "test_") {
        True -> {
          logging.log(
            logging.Error,
            "[SupabaseClient] Test provisioning failed - duplicate: "
              <> idempotency_key,
          )
          Error(DatabaseError("Test provisioning duplicate - check cleanup"))
        }
        False -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] Action already queued (duplicate): "
              <> idempotency_key,
          )
          Ok(Nil)
          // Not an error for production - idempotent
        }
      }
    }
    _ -> {
      logging.log(
        logging.Error,
        "[SupabaseClient] Failed to queue provisioning: Status "
          <> int.to_string(response.status)
          <> " Body: "
          <> response.body,
      )
      Error(DatabaseError("Failed to queue provisioning action"))
    }
  }
}

pub fn soft_delete_customer(
  business_id: String,
  customer_id: String,
  deleted_by: String,
) -> Result(String, SupabaseError) {
  let body =
    json.object([
      #("deleted_at", json.string("NOW()")),
      #("deleted_by", json.string(deleted_by)),
    ])
    |> json.to_string()

  let path =
    "/customers?business_id=eq."
    <> business_id
    <> "&customer_id=eq."
    <> customer_id

  use response <- result.try(make_request(http.Patch, path, Some(body)))

  case response.status {
    200 | 204 -> Ok("Customer soft deleted")
    _ -> Error(DatabaseError("Failed to soft delete customer"))
  }
}

pub fn restore_deleted_customer(
  business_id: String,
  customer_id: String,
) -> Result(String, SupabaseError) {
  let body =
    json.object([
      #("deleted_at", json.null()),
      #("deleted_by", json.null()),
    ])
    |> json.to_string()

  let path =
    "/customers?business_id=eq."
    <> business_id
    <> "&customer_id=eq."
    <> customer_id

  use response <- result.try(make_request(http.Patch, path, Some(body)))

  case response.status {
    200 | 204 -> Ok("Customer restored")
    _ -> Error(DatabaseError("Failed to restore customer"))
  }
}

pub fn get_customer_full_context(
  business_id: String,
  customer_id: String,
) -> Result(customer_types.CustomerContext, SupabaseError) {
  let body =
    json.object([
      #("p_business_id", json.string(business_id)),
      #("p_customer_id", json.string(customer_id)),
    ])
    |> json.to_string()

  use response <- result.try(make_request(
    http.Post,
    "/rpc/get_customer_context",
    Some(body),
  ))

  case response.status {
    200 -> {
      case json.parse(response.body, customer_context_decoder()) {
        Ok(context) -> Ok(context)
        Error(_) -> Error(ParseError("Invalid context format"))
      }
    }
    404 -> Error(NotFound("Customer not found"))
    _ -> Error(DatabaseError("Failed to get customer context"))
  }
}

/// Get pending provisioning tasks
pub fn get_pending_provisioning_tasks(
  limit: Int,
) -> Result(List(ProvisioningTask), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting pending provisioning tasks",
  )

  let query =
    "/provisioning_queue?status=eq.pending&or=(next_retry_at.is.null,next_retry_at.lte.now())&order=created_at.asc&limit="
    <> int.to_string(limit)

  use response <- result.try(make_request(http.Get, query, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(provisioning_task_decoder())) {
        Ok(tasks) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] Found "
              <> int.to_string(list.length(tasks))
              <> " pending tasks",
          )
          Ok(tasks)
        }
        Error(_) -> Error(ParseError("Invalid provisioning tasks format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch provisioning tasks"))
  }
}

// ============================================================================
// CLIENT PLAN LIMITS MANAGEMENT  
// ============================================================================

/// Create a client-specific plan limit (override business limit)
pub fn create_customer_plan_limit(
  business_id: String,
  customer_id: String,
  metric_name: String,
  limit_value: Float,
  limit_period: String,
  breach_operator: String,
  breach_action: String,
  webhook_urls: Option(String),
) -> Result(customer_types.PlanLimit, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Creating client plan limit: "
      <> business_id
      <> "/"
      <> customer_id
      <> "/"
      <> metric_name
      <> " = "
      <> float.to_string(limit_value),
  )

  let base_fields = [
    #("business_id", json.null()),
    #("plan_id", json.null()),
    #("customer_id", json.string(customer_id)),
    #("metric_name", json.string(metric_name)),
    #("limit_value", json.float(limit_value)),
    #("limit_period", json.string(limit_period)),
    #("breach_operator", json.string(breach_operator)),
    #("breach_action", json.string(breach_action)),
  ]

  let all_fields = case webhook_urls {
    Some(urls) -> [#("webhook_urls", json.string(urls)), ..base_fields]
    None -> base_fields
  }

  let limit_data = json.object(all_fields)

  use response <- result.try(make_request(
    http.Post,
    "/plan_limits",
    Some(json.to_string(limit_data)),
  ))

  case response.status {
    201 -> {
      case json.parse(response.body, decode.list(plan_limit_decoder())) {
        Ok([new_limit, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Created client plan limit: " <> new_limit.id,
          )
          Ok(new_limit)
        }
        Ok([]) -> Error(ParseError("No plan limit returned from server"))
        Error(_) -> Error(ParseError("Invalid plan limit response format"))
      }
    }
    409 ->
      Error(DatabaseError("Plan limit already exists for this client metric"))
    _ -> Error(DatabaseError("Failed to create client plan limit"))
  }
}

/// Get all plan limits for a specific client
pub fn get_customer_plan_limits(
  business_id: String,
  customer_id: String,
) -> Result(List(customer_types.PlanLimit), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting client plan limits for: "
      <> business_id
      <> "/"
      <> customer_id,
  )

  let path = "/plan_limits?customer_id=eq." <> customer_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(plan_limit_decoder())) {
        Ok(limits) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Retrieved "
              <> string.inspect(list.length(limits))
              <> " client plan limits",
          )
          Ok(limits)
        }
        Error(_) -> Error(ParseError("Invalid plan limits format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch client plan limits"))
  }
}

/// Get effective plan limits for a client (client-specific + business fallbacks)
pub fn get_effective_customer_limits(
  business_id: String,
  customer_id: String,
) -> Result(List(customer_types.PlanLimit), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting effective limits for client: "
      <> business_id
      <> "/"
      <> customer_id,
  )

  // Get both business and client limits
  use business_limits <- result.try(get_business_plan_limits(business_id))
  use client_limits <- result.try(get_customer_plan_limits(
    business_id,
    customer_id,
  ))

  // Create a map of client limits by metric_name for fast lookup
  let client_limits_map =
    client_limits
    |> list.fold(dict.new(), fn(acc, limit) {
      dict.insert(acc, limit.metric_name, limit)
    })

  // For each business limit, use client override if it exists
  let effective_limits =
    business_limits
    |> list.map(fn(business_limit) {
      case dict.get(client_limits_map, business_limit.metric_name) {
        Ok(client_limit) -> client_limit
        // Use client override
        Error(_) -> business_limit
        // Use business default
      }
    })

  // Add any client-only limits that don't have business counterparts
  let client_only_limits =
    client_limits
    |> list.filter(fn(client_limit) {
      !list.any(business_limits, fn(business_limit) {
        business_limit.metric_name == client_limit.metric_name
      })
    })

  let all_effective_limits = list.append(effective_limits, client_only_limits)

  logging.log(
    logging.Info,
    "[SupabaseClient] ✅ Computed "
      <> string.inspect(list.length(all_effective_limits))
      <> " effective limits for client",
  )

  Ok(all_effective_limits)
}

// ============================================================================
// INTEGRATION KEY MANAGEMENT
// ============================================================================

/// Get integration keys for a business
pub fn get_integration_keys(
  business_id: String,
  key_type: Option(String),
) -> Result(List(IntegrationKey), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting integration keys for: " <> business_id,
  )

  let type_filter = case key_type {
    Some(kt) -> "&key_type=eq." <> kt
    None -> ""
  }

  let active_filter = "&is_active=eq.true"

  let path =
    "/integration_keys?business_id=eq."
    <> business_id
    <> type_filter
    <> active_filter
  // ✅ ADD THIS

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(integration_key_decoder())) {
        Ok(keys) -> Ok(keys)
        Error(_) -> Error(ParseError("Invalid integration keys format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch integration keys"))
  }
}

/// Get a specific integration key by composite key
pub fn get_integration_key_by_composite(
  composite_key: String,
) -> Result(IntegrationKey, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting integration key by composite: " <> composite_key,
  )

  // Split the composite key
  let parts = string.split(composite_key, "/")
  case parts {
    [business_id, key_type, key_name] -> {
      let path =
        "/integration_keys?business_id=eq."
        <> business_id
        <> "&key_type=eq."
        <> key_type
        <> "&key_name=eq."
        <> key_name

      use response <- result.try(make_request(http.Get, path, None))

      case response.status {
        200 -> {
          case
            json.parse(response.body, decode.list(integration_key_decoder()))
          {
            Ok([]) -> Error(NotFound("Integration key not found"))
            Ok([key, ..]) -> Ok(key)
            Error(_) -> Error(ParseError("Invalid integration key format"))
          }
        }
        _ -> Error(DatabaseError("Failed to fetch integration key"))
      }
    }
    _ -> Error(ParseError("Invalid composite key format"))
  }
}

pub fn update_integration_key(
  business_id: String,
  key_type: String,
  key_name: String,
  encrypted_key: String,
) -> Result(IntegrationKey, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Updating integration key: "
      <> business_id
      <> "/"
      <> key_type
      <> "/"
      <> key_name,
  )

  let update_data =
    json.object([
      #("encrypted_key", json.string(encrypted_key)),
    ])

  let path =
    "/integration_keys?business_id=eq."
    <> business_id
    <> "&key_type=eq."
    <> key_type
    <> "&key_name=eq."
    <> key_name

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(integration_key_decoder())) {
        Ok([updated_key, ..]) -> Ok(updated_key)
        Ok([]) -> Error(NotFound("Key not found"))
        Error(_) -> Error(ParseError("Invalid response format"))
      }
    }
    _ -> Error(DatabaseError("Failed to update key"))
  }
}

// New function to store with hash
pub fn store_integration_key_with_hash(
  business_id: String,
  key_type: String,
  key_name: String,
  encrypted_key: String,
  key_hash: String,
  metadata: Option(String),
) -> Result(IntegrationKey, SupabaseError) {
  let body =
    json.object([
      #("business_id", json.string(business_id)),
      #("key_type", json.string(key_type)),
      #("key_name", json.string(key_name)),
      #("encrypted_key", json.string(encrypted_key)),
      #("key_hash", json.string(key_hash)),
      // Add hash
      #("metadata", case metadata {
        Some(data) -> json.string(data)
        None -> json.null()
      }),
      #("is_active", json.bool(True)),
    ])
    |> json.to_string()

  logging.log(logging.Info, "[SupabaseClient] 🔍 INSERT BODY: " <> body)

  let path = "/integration_keys"
  use response <- result.try(make_request(http.Post, path, Some(body)))

  logging.log(
    logging.Info,
    "[SupabaseClient] 📥 RESPONSE STATUS: " <> int.to_string(response.status),
  )
  logging.log(
    logging.Info,
    "[SupabaseClient] 📥 RESPONSE BODY: " <> response.body,
  )

  case response.status {
    201 | 200 -> {
      case json.parse(response.body, decode.list(integration_key_decoder())) {
        Ok([key, ..]) -> Ok(key)
        Ok([]) -> Error(ParseError("No key returned"))
        Error(_) -> Error(ParseError("Failed to parse created key"))
      }
    }
    _ -> Error(DatabaseError("Failed to store key"))
  }
}

// ============================================================================
// METRICS STORAGE
// ============================================================================

/// Store metric data for persistence/billing
pub fn store_metric(
  business_id: String,
  customer_id: Option(String),
  metric_name: String,
  value: String,
  metric_type: String,
  scope: String,
  adapters: Option(Dict(String, json.Json)),
  threshold_value: Option(Float),
  threshold_operator: Option(String),
  threshold_action: Option(String),
  webhook_urls: Option(String),
) -> Result(MetricRecord, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Storing metric: " <> business_id <> "/" <> metric_name,
  )

  let base_fields = [
    #("business_id", json.string(business_id)),
    #("metric_name", json.string(metric_name)),
    #("value", json.string(value)),
    #("metric_type", json.string(metric_type)),
    #("scope", json.string(scope)),
  ]

  // Add threshold fields if provided
  let with_threshold = case threshold_value {
    Some(val) -> [
      #("threshold_value", json.float(val)),
      #(
        "threshold_operator",
        json.string(threshold_operator |> option.unwrap("gte")),
      ),
      #(
        "threshold_action",
        json.string(threshold_action |> option.unwrap("deny")),
      ),
      ..base_fields
    ]
    None -> base_fields
  }

  let with_webhook = case webhook_urls {
    Some(url) -> [#("webhook_urls", json.string(url)), ..with_threshold]
    None -> with_threshold
  }
  let with_client = case customer_id {
    Some(cid) -> [#("customer_id", json.string(cid)), ..with_webhook]
    None -> with_webhook
  }

  let all_fields = case adapters {
    Some(adp) -> [#("adapters", json.object(dict.to_list(adp))), ..with_client]
    None -> with_client
  }

  let metric_data = json.object(all_fields)

  use response <- result.try(make_request(
    http.Post,
    "/metrics",
    Some(json.to_string(metric_data)),
  ))

  case response.status {
    201 -> {
      // TODO: Implement metric record decoder and return proper result
      Ok(MetricRecord(
        id: "placeholder",
        business_id: business_id,
        customer_id: customer_id,
        metric_name: metric_name,
        value: value,
        metric_type: metric_type,
        scope: scope,
        adapters: adapters,
        flushed_at: "now",
      ))
    }
    _ -> Error(DatabaseError("Failed to store metric"))
  }
}

// Add to supabase_client.gleam
pub fn store_metrics_batch(
  metrics: List(MetricRecord),
) -> Result(List(MetricRecord), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Batch storing "
      <> string.inspect(list.length(metrics))
      <> " metrics",
  )

  // Convert list to JSON array
  let metrics_json =
    metrics
    |> list.map(metric_record_to_json)
    |> json.array(from: _, of: fn(item) { item })

  use response <- result.try(make_request(
    http.Post,
    "/metrics",
    Some(json.to_string(metrics_json)),
  ))

  case response.status {
    200 | 201 -> {
      logging.log(logging.Info, "[SupabaseClient] ✅ Batch insert successful")
      Ok(metrics)
      // Return the original metrics for now
    }
    _ -> Error(DatabaseError("Failed to batch store metrics"))
  }
}

// Helper to convert MetricRecord to JSON
// In metric_record_to_json function
fn metric_record_to_json(record: MetricRecord) -> json.Json {
  let float_value = case float.parse(record.value) {
    Ok(val) -> val
    Error(_) -> 0.0
  }

  let customer_id_json = case record.customer_id {
    Some(cid) -> json.string(cid)
    None -> json.null()
  }

  let result =
    json.object([
      #("business_id", json.string(record.business_id)),
      #("customer_id", customer_id_json),
      // Always include it!
      #("metric_name", json.string(record.metric_name)),
      #("value", json.float(float_value)),
      #("metric_type", json.string(record.metric_type)),
      #("scope", json.string(record.scope)),
    ])

  logging.log(
    logging.Info,
    "[SupabaseClient] 🔍 Sending JSON: " <> json.to_string(result),
  )
  result
}

// ============================================================================
// QUERY METRICS HISTORY
// ============================================================================

/// Get the latest metric value from Supabase for restoration on startup
pub fn get_latest_metric_value(
  account_id: String,
  metric_name: String,
) -> Result(Float, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting latest value for: "
      <> account_id
      <> "/"
      <> metric_name,
  )

  // Use the centralized parser!
  let #(business_id, customer_id_opt, _scope) =
    metric_types.parse_account_id(account_id)

  let base_params = [
    #("business_id", "eq." <> business_id),
    #("metric_name", "eq." <> metric_name),
    #("order", "flushed_at.desc"),
    #("limit", "1"),
  ]

  let query_params = case customer_id_opt {
    Some(customer_id) -> [#("customer_id", "eq." <> customer_id), ..base_params]
    None -> base_params
  }

  use response <- result.try(make_request_with_params(
    http.Get,
    "/metrics",
    None,
    query_params,
  ))
  case response.status {
    200 -> {
      // ✅ CORRECT: or: takes a LIST of decoders
      let value_decoder =
        decode.one_of(decode.field("value", decode.float, decode.success), or: [
          decode.field("value", decode.int, fn(i) {
            decode.success(int.to_float(i))
          }),
        ])

      let decoder = decode.list(value_decoder)

      case json.parse(response.body, decoder) {
        Ok([value]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Restored value: " <> float.to_string(value),
          )
          Ok(value)
        }
        Ok([]) -> {
          logging.log(logging.Info, "[SupabaseClient] No previous value found")
          Error(NotFound("No previous metric value"))
        }
        Ok(_) -> Error(DatabaseError("Unexpected response format"))
        Error(decode_errors) -> {
          logging.log(
            logging.Error,
            "[SupabaseClient] 🔍 Parse error: " <> string.inspect(decode_errors),
          )
          logging.log(
            logging.Error,
            "[SupabaseClient] 🔍 Response body: " <> response.body,
          )
          Error(DatabaseError("Failed to parse response"))
        }
      }
    }
    404 -> Error(NotFound("Metric not found"))
    _ -> Error(DatabaseError("Failed to fetch metric value"))
  }
}

// ============================================================================
// CLIENT MANAGEMENT CRUD
// ============================================================================

/// Link a user_id to a customer (for social auth)
pub fn link_user_to_customer(
  business_id: String,
  customer_id: String,
  user_id: String,
) -> Result(customer_types.Customer, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Linking user "
      <> user_id
      <> " to customer: "
      <> customer_id,
  )

  let update_data =
    json.object([
      #("user_id", json.string(user_id)),
      #("updated_at", json.string(int.to_string(utils.current_timestamp()))),
    ])

  let path =
    "/customers?customer_id=eq."
    <> customer_id
    <> "&business_id=eq."
    <> business_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Customer not found or not owned by business"))
        Ok([updated_customer, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Linked user to customer: "
              <> updated_customer.customer_id,
          )
          Ok(updated_customer)
        }
        Error(_) -> Error(ParseError("Invalid customer response format"))
      }
    }
    _ -> Error(DatabaseError("Failed to link user to customer"))
  }
}

/// Unlink a user_id from a customer
pub fn unlink_user_from_customer(
  business_id: String,
  customer_id: String,
) -> Result(customer_types.Customer, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Unlinking user from customer: " <> customer_id,
  )

  let update_data =
    json.object([
      #("user_id", json.null()),
      #("updated_at", json.string(int.to_string(utils.current_timestamp()))),
    ])

  let path =
    "/customers?customer_id=eq."
    <> customer_id
    <> "&business_id=eq."
    <> business_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Customer not found or not owned by business"))
        Ok([updated_customer, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Unlinked user from customer: "
              <> updated_customer.customer_id,
          )
          Ok(updated_customer)
        }
        Error(_) -> Error(ParseError("Invalid customer response format"))
      }
    }
    _ -> Error(DatabaseError("Failed to unlink user from customer"))
  }
}

/// Get all customers for a business
pub fn get_business_customers(
  business_id: String,
) -> Result(List(customer_types.Customer), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting customers for business: " <> business_id,
  )

  let path =
    "/customers?business_id=eq."
    <> business_id
    <> "&deleted_at=is.null"
    <> "&select=customer_id,customer_name,plan_id,stripe_price_id"

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok(customers) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Retrieved "
              <> string.inspect(list.length(customers))
              <> " customers",
          )
          Ok(customers)
        }
        Error(_) -> Error(ParseError("Invalid customers format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch customers"))
  }
}

/// Get a specific client by ID (with business ownership check)
pub fn get_customer_by_id(
  business_id: String,
  customer_id: String,
) -> Result(customer_types.Customer, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting customer: "
      <> customer_id
      <> " for business: "
      <> business_id,
  )

  let path =
    "/customers?business_id=eq."
    <> business_id
    <> "&customer_id=eq."
    <> customer_id
    <> "&deleted_at=is.null"

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Client not found"))
        Ok([customer, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Retrieved client: " <> customer.customer_id,
          )
          Ok(customer)
        }
        Error(_) -> Error(ParseError("Invalid client format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch client"))
  }
}

/// Update a client
pub fn update_customer(
  business_id: String,
  customer_id: String,
  customer_name: String,
  plan_id: String,
) -> Result(customer_types.Customer, SupabaseError) {
  logging.log(logging.Info, "[SupabaseClient] Updating client: " <> customer_id)

  let update_data =
    json.object([
      #("customer_name", json.string(customer_name)),
      #("plan_id", json.string(plan_id)),
    ])

  let path =
    "/customers?customer_id=eq."
    <> customer_id
    <> "&business_id=eq."
    <> business_id

  use response <- result.try(make_request(
    http.Patch,
    path,
    Some(json.to_string(update_data)),
  ))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Client not found or not owned by business"))
        Ok([updated_customer, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Updated customer: "
              <> updated_customer.customer_id,
          )
          Ok(updated_customer)
        }
        Error(_) -> Error(ParseError("Invalid client response format"))
      }
    }
    _ -> Error(DatabaseError("Failed to update client"))
  }
}

/// Delete a client
pub fn delete_customer(
  business_id: String,
  customer_id: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Deleting client: "
      <> customer_id
      <> " for business: "
      <> business_id,
  )

  let path =
    "/customers?customer_id=eq."
    <> customer_id
    <> "&business_id=eq."
    <> business_id

  use response <- result.try(make_request(http.Delete, path, None))

  case response.status {
    200 | 204 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Deleted customer: " <> customer_id,
      )
      Ok(Nil)
    }
    404 -> Error(NotFound("Client not found or not owned by business"))
    _ -> Error(DatabaseError("Failed to delete client"))
  }
}

// Add this function to supabase_client.gleam (around line 1500, near other customer functions)

/// Get customer by Stripe customer ID (for webhook processing)
pub fn get_customer_by_stripe_customer(
  stripe_customer_id: String,
) -> Result(customer_types.Customer, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting customer by Stripe ID: " <> stripe_customer_id,
  )

  let path = "/customers?stripe_customer_id=eq." <> stripe_customer_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case
        json.parse(
          response.body,
          decode.list(customer_types.customer_decoder()),
        )
      {
        Ok([]) -> Error(NotFound("Customer not found for Stripe ID"))
        Ok([customer, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] ✅ Found customer: " <> customer.customer_id,
          )
          Ok(customer)
        }
        Error(_) -> Error(ParseError("Invalid customer format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch customer by Stripe ID"))
  }
}

/// Reset all stripe_billing metrics for a specific customer
pub fn reset_customer_stripe_billing_metrics(
  business_id: String,
  customer_id: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Resetting StripeBilling metrics for customer: "
      <> business_id
      <> "/"
      <> customer_id,
  )

  // Reset in database
  let url =
    "/metrics?business_id=eq."
    <> business_id
    <> "&customer_id=eq."
    <> customer_id
    <> "&metric_type=eq.stripe_billing"

  let reset_json = json.object([#("value", json.float(0.0))])

  use response <- result.try(make_request(
    http.Patch,
    url,
    Some(json.to_string(reset_json)),
  ))

  case response.status {
    200 | 204 -> {
      // Also reset in-memory value
      let account_id = business_id <> ":" <> customer_id

      // Get all stripe_billing metrics for this customer
      // You'll need to find the metric names somehow
      // For now, just reset the known one:
      let _ = metric_store.reset_metric(account_id, "api_calls_billing", 0.0)

      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Reset metrics in DB and memory",
      )
      Ok(Nil)
    }
    404 -> {
      logging.log(logging.Warning, "[SupabaseClient] No metrics found to reset")
      Ok(Nil)
    }
    _ -> Error(DatabaseError("Failed to reset metrics"))
  }
}

pub fn reset_stripe_billing_metrics_for_business(
  business_id: String,
) -> Result(Nil, SupabaseError) {
  // Find all StripeBilling metrics for this business in the metrics table
  let query =
    "/metrics?business_id=eq."
    <> business_id
    <> "&metric_type=eq.stripe_billing"

  use _response <- result.try(make_request(http.Get, query, None))

  // For now, just update all stripe_billing metrics to 0
  let update_data =
    json.object([
      #("value", json.float(0.0)),
      #("flushed_at", json.string(int.to_string(utils.current_timestamp()))),
    ])

  let update_path =
    "/metrics?business_id=eq."
    <> business_id
    <> "&metric_type=eq.stripe_billing"
  use _response <- result.try(make_request(
    http.Patch,
    update_path,
    Some(json.to_string(update_data)),
  ))

  Ok(Nil)
}

/// Create a new client for a business
pub fn create_customer(
  business_id: String,
  customer_id: String,
  customer_name: String,
  plan_id: String,
  user_id: option.Option(String),
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Creating customer: "
      <> business_id
      <> "/"
      <> customer_id
      <> " on plan: "
      <> plan_id,
  )

  let base_fields = [
    #("business_id", json.string(business_id)),
    #("customer_id", json.string(customer_id)),
    #("customer_name", json.string(customer_name)),
  ]

  // Add plan_id if not empty
  let with_plan = case plan_id {
    "" -> base_fields
    _ -> [#("plan_id", json.string(plan_id)), ..base_fields]
  }

  // Add user_id if provided
  let final_fields = case user_id {
    option.Some(uid) -> [#("user_id", json.string(uid)), ..with_plan]
    option.None -> with_plan
  }

  let body = json.object(final_fields)

  use response <- result.try(make_request(
    http.Post,
    "/customers",
    Some(json.to_string(body)),
  ))

  case response.status {
    201 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Customer created: " <> customer_id,
      )
      Ok(Nil)
    }
    409 -> Error(DatabaseError("Client already exists"))
    _ ->
      Error(DatabaseError(
        "Failed to create customer: " <> int.to_string(response.status),
      ))
  }
}

/// Query metric history for analytics/dashboards
pub fn get_metric_history(
  business_id: String,
  metric_name: Option(String),
  start_time: Option(String),
  end_time: Option(String),
  limit: Int,
) -> Result(List(MetricRecord), SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Querying metric history for: " <> business_id,
  )

  let metric_filter = case metric_name {
    Some(name) -> "&metric_name=eq." <> name
    None -> ""
  }

  let time_filter = case start_time, end_time {
    Some(start), Some(end) ->
      "&flushed_at=gte." <> start <> "&flushed_at=lte." <> end
    Some(start), None -> "&flushed_at=gte." <> start
    None, Some(end) -> "&flushed_at=lte." <> end
    None, None -> ""
  }

  let path =
    "/metrics?business_id=eq."
    <> business_id
    <> metric_filter
    <> time_filter
    <> "&order=flushed_at.desc&limit="
    <> int.to_string(limit)

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      // TODO: Implement proper metric record decoder
      Ok([])
    }
    _ -> Error(DatabaseError("Failed to query metric history"))
  }
}
