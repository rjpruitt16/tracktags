// src/web/handler/proxy_handler.gleam

import actors/metric_actor
import birl
import clients/supabase_client
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glixir
import logging
import types/application_types
import types/customer_types
import types/metric_types
import utils/auth
import utils/cachex
import utils/crypto
import utils/utils
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================
pub type ProxyRequest {
  ProxyRequest(
    scope: String,
    // "business" or "customer"
    customer_id: option.Option(String),
    // required if scope=client
    metric_name: String,
    // metric to check for breach
    target_url: String,
    // URL to forward to
    method: String,
    // HTTP method
    headers: dict.Dict(String, String),
    // headers to forward
    body: option.Option(String),
    // request body
  )
}

pub type BreachStatus {
  BreachStatus(
    is_breached: Bool,
    current_usage: Float,
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
    remaining: option.Option(Float),
  )
}

pub type ProxyResponse {
  Allowed(breach_status: BreachStatus, forwarded_response: ForwardedResponse)
  Denied(
    breach_status: BreachStatus,
    error: String,
    retry_after: option.Option(Int),
  )
}

pub type ForwardedResponse {
  ForwardedResponse(
    status_code: Int,
    headers: dict.Dict(String, String),
    body: String,
  )
}

type DomainConfig {
  DomainConfig(authorized_businesses: List(String))
}

// ============================================================================
// MAIN ENDPOINT
// ============================================================================

/// POST /api/v1/proxy - Check limits and forward request
pub fn check_and_forward(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[ProxyHandler] 🔍 PROXY REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use proxy_req <- result.try(decode.run(json_data, proxy_request_decoder()))
    use validated_req <- result.try(validate_proxy_request(proxy_req))
    Ok(process_proxy_request(business_id, validated_req, request_id))
  }

  logging.log(
    logging.Info,
    "[ProxyHandler] 🔍 PROXY REQUEST END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[ProxyHandler] Bad request: " <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid proxy request data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

fn domain_config_decoder() -> decode.Decoder(DomainConfig) {
  use authorized <- decode.field(
    "authorized_businesses",
    decode.list(decode.string),
  )
  decode.success(DomainConfig(authorized_businesses: authorized))
}

fn extract_domain_from_url(url: String) -> String {
  case string.split(url, "://") {
    [_, rest] -> {
      case string.split(rest, "/") {
        [domain, ..] -> domain
        [] -> url
      }
    }
    _ -> url
  }
}

// ============================================================================
// REQUEST PROCESSING
// ============================================================================

fn process_proxy_request(
  business_id: String,
  req: ProxyRequest,
  request_id: String,
) -> Response {
  logging.log(
    logging.Info,
    "[ProxyHandler] 🎯 Processing proxy request: " <> req.target_url,
  )

  case metric_types.string_to_scope(req.scope, business_id, req.customer_id) {
    Error(scope_error) -> {
      let error_json =
        json.object([
          #("error", json.string("Invalid Scope")),
          #("message", json.string(scope_error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
    Ok(scope) -> {
      // Check for customer scope and handle expiry
      case scope {
        metric_types.Customer(bid, cid) -> {
          logging.log(
            logging.Info,
            "[ProxyHandler] 🔍 Customer scope - checking for expiry: "
              <> request_id,
          )

          // Get customer context to check expiry
          case supabase_client.get_customer_full_context(bid, cid) {
            Ok(context) -> {
              case check_and_handle_expiry(context) {
                Ok(updated_context) -> {
                  // Context may have free limits if expired
                  process_proxy_with_context(
                    business_id,
                    req,
                    scope,
                    Some(updated_context),
                    request_id,
                  )
                }
                Error(e) -> {
                  logging.log(
                    logging.Error,
                    "[ProxyHandler] ❌ Expiry check failed: " <> e,
                  )
                  let error_json =
                    json.object([
                      #("error", json.string("Internal Server Error")),
                      #(
                        "message",
                        json.string("Failed to check subscription status"),
                      ),
                    ])
                  wisp.json_response(json.to_string_tree(error_json), 500)
                }
              }
            }
            Error(_) -> {
              logging.log(
                logging.Error,
                "[ProxyHandler] ❌ Failed to get customer context",
              )
              let error_json =
                json.object([
                  #("error", json.string("Internal Server Error")),
                  #("message", json.string("Failed to get customer context")),
                ])
              wisp.json_response(json.to_string_tree(error_json), 500)
            }
          }
        }
        metric_types.Business(_) -> {
          // Business scope - no expiry check needed
          process_proxy_with_context(business_id, req, scope, None, request_id)
        }
      }
    }
  }
}

fn process_proxy_with_context(
  business_id: String,
  req: ProxyRequest,
  scope: metric_types.MetricScope,
  context: option.Option(customer_types.CustomerContext),
  request_id: String,
) -> Response {
  let lookup_key = metric_types.scope_to_lookup_key(scope)

  // Check if metric_name is empty
  case string.length(req.metric_name) {
    0 -> {
      // No specific metric - return ALL plan limit statuses
      logging.log(
        logging.Info,
        "[ProxyHandler] 🔍 No metric specified - checking all plan limits: "
          <> request_id,
      )
      check_all_plan_limits_and_forward(lookup_key, scope, business_id, req)
    }
    _ -> {
      // Original behavior - check specific metric
      logging.log(
        logging.Info,
        "[ProxyHandler] 🔍 Checking metric: "
          <> lookup_key
          <> "/"
          <> req.metric_name
          <> " - "
          <> request_id,
      )

      // If we have context with plan_limits, use those for the check
      let plan_limits = case context {
        Some(ctx) -> ctx.plan_limits
        None -> []
      }

      case
        check_metric_breach_status_with_limits(
          lookup_key,
          req.metric_name,
          scope,
          business_id,
          plan_limits,
        )
      {
        Ok(breach_status) -> {
          case should_deny_request(breach_status) {
            True -> {
              logging.log(
                logging.Warning,
                "[ProxyHandler] 🚨 Request DENIED - metric over limit: "
                  <> request_id,
              )
              create_denied_response(breach_status)
            }
            False -> {
              logging.log(
                logging.Info,
                "[ProxyHandler] ✅ Request ALLOWED - forwarding to target: "
                  <> request_id,
              )
              forward_request_to_target(req, breach_status, scope, context)
            }
          }
        }

        Error(error_msg) -> {
          logging.log(
            logging.Error,
            "[ProxyHandler] ❌ Failed to check metric status: "
              <> error_msg
              <> " - "
              <> request_id,
          )
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to check metric status")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
  }
}

fn check_metric_breach_status_with_limits(
  lookup_key: String,
  metric_name: String,
  scope: metric_types.MetricScope,
  business_id: String,
  plan_limits: List(customer_types.PlanLimit),
) -> Result(BreachStatus, String) {
  case metric_actor.lookup_metric_subject(lookup_key, metric_name) {
    Ok(metric_subject) -> {
      // Metric exists - get its current status
      logging.log(
        logging.Info,
        "[ProxyHandler] ✅ Found existing metric, checking status",
      )

      // If we have plan_limits from expiry check, find the matching limit
      case find_limit_for_metric(plan_limits, metric_name) {
        Some(limit) -> {
          logging.log(
            logging.Info,
            "[ProxyHandler] 📊 Using plan limit: "
              <> metric_name
              <> " = "
              <> float.to_string(limit.limit_value),
          )
          get_metric_status_with_override(metric_subject, limit)
        }
        None -> {
          // No override, use metric's own limit
          get_metric_status(metric_subject)
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[ProxyHandler] 📡 Metric not found, requiring manual creation",
      )
      lookup_existing_metric_actor(lookup_key, metric_name, scope, business_id)
      |> result.try(get_metric_status)
    }
  }
}

fn find_limit_for_metric(
  plan_limits: List(customer_types.PlanLimit),
  metric_name: String,
) -> Option(customer_types.PlanLimit) {
  list.find(plan_limits, fn(limit) { limit.metric_name == metric_name })
  |> option.from_result
}

fn get_metric_status_with_override(
  metric_subject: process.Subject(metric_types.Message),
  limit: customer_types.PlanLimit,
) -> Result(BreachStatus, String) {
  let reply_subject = process.new_subject()

  process.send(metric_subject, metric_types.GetLimitStatus(reply_subject))

  case process.receive(reply_subject, 1000) {
    Ok(status) -> {
      // Override with the new limit from plan
      let is_breached = case limit.breach_operator {
        "gte" -> status.current_value >=. limit.limit_value
        "gt" -> status.current_value >. limit.limit_value
        "lte" -> status.current_value <=. limit.limit_value
        "lt" -> status.current_value <. limit.limit_value
        _ -> False
      }

      let remaining = case limit.breach_operator {
        "gte" | "gt" -> {
          let remaining_value = limit.limit_value -. status.current_value
          case remaining_value >. 0.0 {
            True -> Some(remaining_value)
            False -> Some(0.0)
          }
        }
        _ -> None
      }

      Ok(BreachStatus(
        is_breached: is_breached,
        current_usage: status.current_value,
        limit_value: limit.limit_value,
        limit_operator: limit.breach_operator,
        breach_action: limit.breach_action,
        remaining: remaining,
      ))
    }
    Error(_) -> Error("Timeout waiting for limit status")
  }
}

fn verify_domain_authorization(
  domain: String,
  business_id: String,
) -> Result(Bool, String) {
  // ✅ Skip verification for webhook.site (testing/debugging only)
  case string.contains(domain, "webhook.site") {
    True -> {
      logging.log(
        logging.Info,
        "[ProxyHandler] ✅ Skipping domain verification for webhook.site (debug endpoint)",
      )
      Ok(True)
    }
    False -> {
      // Original verification logic
      case utils.get_env_or("FLY_APP_NAME", "") {
        "" -> {
          logging.log(
            logging.Info,
            "[ProxyHandler] Skipping domain verification (local dev)",
          )
          Ok(True)
        }
        _ -> {
          // Check cache first
          let cache_key = domain <> ":" <> business_id
          case cachex.get("domain_cache", cache_key) {
            Ok(Some(cached_result)) -> {
              logging.log(
                logging.Info,
                "[ProxyHandler] Cache hit for domain: " <> domain,
              )
              Ok(cached_result)
            }
            _ -> {
              // Cache miss - fetch from domain
              logging.log(
                logging.Info,
                "[ProxyHandler] Cache miss, fetching .tracktags.json for: "
                  <> domain,
              )
              fetch_and_verify_domain(domain, business_id, cache_key)
            }
          }
        }
      }
    }
  }
}

fn fetch_and_verify_domain(
  domain: String,
  business_id: String,
  cache_key: String,
) -> Result(Bool, String) {
  let url = "https://" <> domain <> "/.tracktags.json"

  // Build GET request
  case request.to(url) {
    Error(_) -> {
      logging.log(
        logging.Error,
        "[ProxyHandler] Invalid URL for .tracktags.json: " <> url,
      )
      Error("Invalid domain URL")
    }
    Ok(req) -> {
      // Send the request
      case httpc.send(req) {
        Ok(response) if response.status == 200 -> {
          case json.parse(response.body, domain_config_decoder()) {
            Ok(config) -> {
              let authorized =
                list.contains(config.authorized_businesses, business_id)
                || list.contains(config.authorized_businesses, "*")

              // Cache result for 1 hour
              let _ = cachex.put("domain_cache", cache_key, authorized)

              logging.log(
                logging.Info,
                "[ProxyHandler] Domain "
                  <> domain
                  <> " authorized: "
                  <> string.inspect(authorized),
              )
              Ok(authorized)
            }
            Error(_) -> {
              logging.log(
                logging.Warning,
                "[ProxyHandler] Invalid .tracktags.json format for: " <> domain,
              )
              // Cache denial for 1 hour
              let _ = cachex.put("domain_cache", cache_key, False)
              Ok(False)
            }
          }
        }
        Ok(response) if response.status == 404 -> {
          logging.log(
            logging.Warning,
            "[ProxyHandler] No .tracktags.json found for: " <> domain,
          )
          // Cache denial for 1 hour
          let _ = cachex.put("domain_cache", cache_key, False)
          Ok(False)
        }
        Ok(_response) -> {
          logging.log(
            logging.Error,
            "[ProxyHandler] Unexpected status fetching .tracktags.json for: "
              <> domain,
          )
          Error("Unexpected HTTP status")
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "[ProxyHandler] Failed to fetch .tracktags.json for: " <> domain,
          )
          Error("Could not fetch domain verification file")
        }
      }
    }
  }
}

// ============================================================================
// METRIC BREACH CHECKING
// ============================================================================

fn check_metric_breach_status(
  lookup_key: String,
  metric_name: String,
  scope: metric_types.MetricScope,
  business_id: String,
) -> Result(BreachStatus, String) {
  case metric_actor.lookup_metric_subject(lookup_key, metric_name) {
    Ok(metric_subject) -> {
      // Metric exists - get its current status
      logging.log(
        logging.Info,
        "[ProxyHandler] ✅ Found existing metric, checking status",
      )
      get_metric_status(metric_subject)
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[ProxyHandler] 📡 Metric not found, requiring manual creation",
      )
      lookup_existing_metric_actor(lookup_key, metric_name, scope, business_id)
      |> result.try(get_metric_status)
    }
  }
}

fn get_metric_status(
  metric_subject: process.Subject(metric_types.Message),
) -> Result(BreachStatus, String) {
  let reply_subject = process.new_subject()

  // Get real limit status from MetricActor
  process.send(metric_subject, metric_types.GetLimitStatus(reply_subject))

  case process.receive(reply_subject, 1000) {
    Ok(limit_status) -> {
      let remaining = case limit_status.limit_operator {
        "gte" | "gt" -> {
          let remaining_value =
            limit_status.limit_value -. limit_status.current_value
          case remaining_value >. 0.0 {
            True -> Some(remaining_value)
            False -> Some(0.0)
          }
        }
        _ -> None
      }

      Ok(BreachStatus(
        is_breached: limit_status.is_breached,
        current_usage: limit_status.current_value,
        limit_value: limit_status.limit_value,
        limit_operator: limit_status.limit_operator,
        breach_action: limit_status.breach_action,
        remaining: remaining,
      ))
    }
    Error(_) -> Error("Timeout waiting for limit status")
  }
}

// WARNING: DO NOT ATTEMPT TO CREATE METRICS DYNAMICALLY IN PROXY_HANDLER
// 
// We spent significant time trying to auto-create metrics when they don't exist,
// and every approach led to catastrophic race conditions in the Gleam/OTP system:
//
// FAILED ATTEMPT #1: Direct actor spawning with sleep delays
//   - Created metrics but actor wasn't registered in time
//   - Adding sleeps just moved the race condition
//   - HTTP request would timeout waiting for actor initialization
//
// FAILED ATTEMPT #2: Using metric_handler.create_client_metric_internal
//   - Circular dependency issues between handlers
//   - Plan loading from database was async and non-deterministic
//   - Metric would be "created" but actor initialization would race with proxy request
//
// FAILED ATTEMPT #3: Checking ClientActor plan loading state
//   - Plans can change during runtime
//   - Required complex state synchronization between actors
//   - Added fragile coupling between proxy_handler and internal actor states
//
// ROOT CAUSE: The proxy request path cannot wait for:
//   1. Database writes to complete
//   2. Actor spawn and registration  
//   3. Plan data to load from database
//   4. Metric actor to initialize with plan limits
//   All while maintaining reasonable HTTP timeout constraints.
//
// SOLUTION: Metrics MUST exist before proxy usage. This is actually better because:
//   - Clear separation of concerns
//   - Predictable behavior
//   - No race conditions
//   - SDK/client can handle metric creation separately
//   - Follows the pattern of "configure then use"
//
// DO NOT CHANGE THIS FUNCTION TO CREATE METRICS. It will break in production.
fn lookup_existing_metric_actor(
  lookup_key: String,
  metric_name: String,
  scope: metric_types.MetricScope,
  _business_id: String,
) -> Result(process.Subject(metric_types.Message), String) {
  // Actually look up the metric actor
  case metric_actor.lookup_metric_subject(lookup_key, metric_name) {
    Ok(subject) -> {
      logging.log(
        logging.Info,
        "[ProxyHandler] ✅ Found metric actor for "
          <> lookup_key
          <> "/"
          <> metric_name,
      )
      Ok(subject)
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[ProxyHandler] ❌ Metric actor not found for "
          <> lookup_key
          <> "/"
          <> metric_name,
      )
      Error(
        "Metric '"
        <> metric_name
        <> "' not found. Create it first using POST /api/v1/metrics with scope="
        <> metric_types.scope_to_string(scope)
        <> " before using the proxy.",
      )
    }
  }
}

// ============================================================================
// REQUEST FORWARDING
// ============================================================================

fn should_deny_request(breach_status: BreachStatus) -> Bool {
  breach_status.is_breached && breach_status.breach_action == "deny"
}

fn forward_request_to_target(
  req: ProxyRequest,
  breach_status: BreachStatus,
  scope: metric_types.MetricScope,
  context: option.Option(customer_types.CustomerContext),
) -> Response {
  logging.log(
    logging.Info,
    "[ProxyHandler] 🚀 Forwarding request to: " <> req.target_url,
  )

  // Extract business_id from scope
  let business_id = case scope {
    metric_types.Business(bid) -> bid
    metric_types.Customer(bid, _) -> bid
  }

  // Extract domain and verify authorization
  let domain = extract_domain_from_url(req.target_url)

  case verify_domain_authorization(domain, business_id) {
    Ok(False) -> {
      logging.log(
        logging.Warning,
        "[ProxyHandler] Domain not authorized: " <> domain,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Unauthorized Domain")),
            #(
              "message",
              json.string(
                "Domain "
                <> domain
                <> " has not authorized business_id: "
                <> business_id
                <> ". Add business_id to .tracktags.json at domain root.",
              ),
            ),
          ]),
        ),
        403,
      )
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[ProxyHandler] Domain verification failed: " <> e,
      )
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Domain Verification Failed")),
            #("message", json.string(e)),
          ]),
        ),
        502,
      )
    }
    Ok(True) -> {
      // Domain is authorized - proceed with existing forwarding logic

      // Get TrackTags URL from environment, default to localhost:8080
      let tracktags_url =
        utils.get_env_or("TRACKTAGS_URL", "http://localhost:8080")

      // Extract just the host:port from the URL for comparison
      let tracktags_host = case string.split(tracktags_url, "://") {
        [_, rest] ->
          string.split(rest, "/")
          |> list.first
          |> result.unwrap("localhost:8080")
        _ -> "localhost:8080"
      }

      // Check for loops - only if target contains our actual host
      case
        string.contains(req.target_url, tracktags_host)
        || string.contains(req.target_url, "/api/v1/proxy")
      {
        True -> {
          logging.log(
            logging.Warning,
            "[ProxyHandler] Loop detected in target URL: " <> req.target_url,
          )
          let error_json =
            json.object([
              #("error", json.string("Loop Detected")),
              #("message", json.string("Cannot proxy back to TrackTags")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 400)
        }
        False -> {
          // Check if request already has TrackTags headers (indicating it's been proxied)
          case dict.get(req.headers, "x-tracktags-customer-id") {
            Ok(_) -> {
              logging.log(
                logging.Warning,
                "[ProxyHandler] Request already proxied - TrackTags headers detected",
              )
              let error_json =
                json.object([
                  #("error", json.string("Double Proxy Detected")),
                  #(
                    "message",
                    json.string(
                      "Request has already been proxied through TrackTags",
                    ),
                  ),
                ])
              wisp.json_response(json.to_string_tree(error_json), 400)
            }
            Error(_) -> {
              // Safe to proceed with forwarding
              let http_method = case string.uppercase(req.method) {
                "GET" -> http.Get
                "POST" -> http.Post
                "PUT" -> http.Put
                "DELETE" -> http.Delete
                "PATCH" -> http.Patch
                _ -> http.Get
              }

              case request.to(req.target_url) {
                Error(_) -> {
                  logging.log(
                    logging.Error,
                    "[ProxyHandler] ❌ Invalid target URL: " <> req.target_url,
                  )
                  let error_json =
                    json.object([
                      #("error", json.string("Invalid URL")),
                      #("message", json.string("Target URL is malformed")),
                    ])
                  wisp.json_response(json.to_string_tree(error_json), 400)
                }
                Ok(base_req) -> {
                  // Add forwarded headers from original request
                  // SECURITY: Strip Authorization header to prevent user API key leakage
                  let req_with_headers =
                    dict.fold(req.headers, base_req, fn(acc_req, key, value) {
                      case string.lowercase(key) {
                        "authorization" -> acc_req
                        // Don't forward user's API key
                        _ -> request.set_header(acc_req, key, value)
                      }
                    })

                  // Add TrackTags metadata headers based on scope and context
                  let req_with_metadata = case scope, context {
                    metric_types.Customer(bid, cid), Some(ctx) -> {
                      let machine_ids =
                        list.map(ctx.machines, fn(m) { m.machine_id })
                      req_with_headers
                      |> request.set_header("X-TrackTags-Customer-Id", cid)
                      |> request.set_header("X-TrackTags-Business-Id", bid)
                      |> request.set_header(
                        "X-TrackTags-Owned-Machines",
                        string.join(machine_ids, ","),
                      )
                      |> request.set_header(
                        "X-TrackTags-Plan-Id",
                        option.unwrap(ctx.customer.plan_id, "free"),
                      )
                      |> request.set_header(
                        "X-TrackTags-Machine-Count",
                        int.to_string(list.length(ctx.machines)),
                      )
                      |> request.set_header("X-TrackTags-Proxied", "true")
                      |> add_webhook_secret_headers(business_id)
                    }
                    metric_types.Business(bid), _ -> {
                      req_with_headers
                      |> request.set_header("X-TrackTags-Business-Id", bid)
                      |> request.set_header("X-TrackTags-Scope", "business")
                      |> request.set_header("X-TrackTags-Proxied", "true")
                      |> add_webhook_secret_headers(business_id)
                    }
                    _, _ -> {
                      req_with_headers
                      |> request.set_header("X-TrackTags-Proxied", "true")
                    }
                  }

                  // Build final request with body
                  let final_req = case http_method, req.body {
                    http.Post, Some(body) -> {
                      req_with_metadata
                      |> request.set_method(http.Post)
                      |> request.set_header("Content-Type", "application/json")
                      |> request.set_body(body)
                    }
                    http.Put, Some(body) -> {
                      req_with_metadata
                      |> request.set_method(http.Put)
                      |> request.set_header("Content-Type", "application/json")
                      |> request.set_body(body)
                    }
                    http.Patch, Some(body) -> {
                      req_with_metadata
                      |> request.set_method(http.Patch)
                      |> request.set_header("Content-Type", "application/json")
                      |> request.set_body(body)
                    }
                    http.Get, _ -> {
                      req_with_metadata
                      |> request.set_method(http.Get)
                    }
                    http.Delete, _ -> {
                      req_with_metadata
                      |> request.set_method(http.Delete)
                    }
                    _, _ -> req_with_metadata |> request.set_method(http_method)
                  }

                  // Send the request
                  case httpc.send(final_req) {
                    Ok(response) -> {
                      logging.log(
                        logging.Info,
                        "[ProxyHandler] ✅ Target responded with status: "
                          <> int.to_string(response.status),
                      )

                      let forwarded_response =
                        ForwardedResponse(
                          status_code: response.status,
                          headers: dict.from_list(response.headers),
                          body: response.body,
                        )

                      let success_json =
                        allowed_response_to_json(
                          breach_status,
                          forwarded_response,
                        )
                      wisp.json_response(json.to_string_tree(success_json), 200)
                    }
                    Error(http_error) -> {
                      logging.log(
                        logging.Error,
                        "[ProxyHandler] ❌ HTTP error: "
                          <> string.inspect(http_error),
                      )
                      let error_json =
                        json.object([
                          #("error", json.string("Proxy Error")),
                          #(
                            "message",
                            json.string("Failed to forward request to target"),
                          ),
                        ])
                      wisp.json_response(json.to_string_tree(error_json), 502)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn create_denied_response(breach_status: BreachStatus) -> Response {
  let denied_json = denied_response_to_json(breach_status)
  wisp.json_response(json.to_string_tree(denied_json), 429)
  // Too Many Requests
}

// ============================================================================
// JSON CONVERSION
// ============================================================================

fn allowed_response_to_json(
  breach_status: BreachStatus,
  forwarded_response: ForwardedResponse,
) -> json.Json {
  json.object([
    #("status", json.string("allowed")),
    #("breach_status", breach_status_to_json(breach_status)),
    #(
      "forwarded_response",
      json.object([
        #("status_code", json.int(forwarded_response.status_code)),
        #(
          "headers",
          dict.fold(
            forwarded_response.headers,
            json.object([]),
            fn(_acc, key, value) {
              // Convert headers dict to JSON object
              json.object([#(key, json.string(value))])
            },
          ),
        ),
        #("body", json.string(forwarded_response.body)),
      ]),
    ),
  ])
}

fn denied_response_to_json(breach_status: BreachStatus) -> json.Json {
  let base_fields = [
    #("status", json.string("denied")),
    #("breach_status", breach_status_to_json(breach_status)),
    #("error", json.string("Plan limit exceeded")),
  ]

  // Add retry_after if available
  let all_fields = case breach_status.remaining {
    Some(_) -> [#("retry_after", json.int(3600)), ..base_fields]
    // 1 hour default
    None -> base_fields
  }

  json.object(all_fields)
}

fn breach_status_to_json(breach_status: BreachStatus) -> json.Json {
  let base_fields = [
    #("is_breached", json.bool(breach_status.is_breached)),
    #("current_usage", json.float(breach_status.current_usage)),
    #("limit_value", json.float(breach_status.limit_value)),
    #("limit_operator", json.string(breach_status.limit_operator)),
    #("breach_action", json.string(breach_status.breach_action)),
  ]

  let all_fields = case breach_status.remaining {
    Some(remaining) -> [#("remaining", json.float(remaining)), ..base_fields]
    None -> base_fields
  }

  json.object(all_fields)
}

// ============================================================================
// REQUEST PARSING & VALIDATION
// ============================================================================

fn proxy_request_decoder() -> decode.Decoder(ProxyRequest) {
  use scope <- decode.field("scope", decode.string)
  use customer_id <- decode.optional_field(
    "customer_id",
    None,
    decode.optional(decode.string),
  )
  use metric_name <- decode.field("metric_name", decode.string)
  use target_url <- decode.field("target_url", decode.string)
  use method <- decode.optional_field("method", "GET", decode.string)
  use headers <- decode.optional_field(
    "headers",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use body <- decode.optional_field(
    "body",
    None,
    decode.optional(decode.string),
  )

  decode.success(ProxyRequest(
    scope: scope,
    customer_id: customer_id,
    metric_name: metric_name,
    target_url: target_url,
    method: method,
    headers: headers,
    body: body,
  ))
}

fn validate_proxy_request(
  req: ProxyRequest,
) -> Result(ProxyRequest, List(decode.DecodeError)) {
  // Validate scope
  case req.scope {
    "business" | "customer" -> Ok(Nil)
    _ ->
      Error([
        decode.DecodeError(
          "Invalid",
          "scope must be 'business' or 'customer'",
          [],
        ),
      ])
  }
  |> result.try(fn(_) {
    // Validate customer_id for customer scope
    case req.scope, req.customer_id {
      "customer", None ->
        Error([
          decode.DecodeError(
            "Invalid",
            "customer_id required for customer scope",
            [],
          ),
        ])
      _, _ -> Ok(Nil)
    }
  })
  |> result.try(fn(_) { Ok(Nil) })
  |> result.try(fn(_) {
    case
      string.starts_with(req.target_url, "http://")
      || string.starts_with(req.target_url, "https://")
    {
      True -> Ok(req)
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "target_url must be a valid HTTP/HTTPS URL",
            [],
          ),
        ])
    }
  })
}

// ============================================================================
// AUTHENTICATION (Reused from other handlers)
// ============================================================================

fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  auth.with_auth(req, fn(auth_result, _api_key, _is_admin) {
    case auth_result {
      auth.ActorCached(auth.BusinessActor(business_id, _)) ->
        handler(business_id)

      auth.ActorCached(auth.CustomerActor(business_id, customer_id, _)) -> {
        case
          supabase_client.get_customer_full_context(business_id, customer_id)
        {
          Ok(context) -> {
            case check_and_handle_expiry(context) {
              Ok(updated_context) ->
                handle_customer_request_with_context(
                  req,
                  business_id,
                  customer_id,
                  updated_context,
                )
              Error(_) ->
                wisp.internal_server_error()
                |> wisp.string_body("Failed to process subscription expiry")
            }
          }
          Error(_) ->
            wisp.internal_server_error()
            |> wisp.string_body("Failed to get customer context")
        }
      }

      auth.DatabaseValid(supabase_client.BusinessKey(_)) -> {
        // Business keys can't use proxy
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Forbidden")),
              #(
                "message",
                json.string("Business key cannot use proxy endpoint"),
              ),
            ]),
          ),
          403,
        )
      }

      auth.DatabaseValid(supabase_client.CustomerKey(business_id, customer_id)) -> {
        case
          supabase_client.get_customer_full_context(business_id, customer_id)
        {
          Ok(context) -> {
            case check_and_handle_expiry(context) {
              Ok(updated_context) ->
                handle_customer_request_with_context(
                  req,
                  business_id,
                  customer_id,
                  updated_context,
                )
              Error(_) ->
                wisp.internal_server_error()
                |> wisp.string_body("Failed to process subscription expiry")
            }
          }
          Error(_) ->
            wisp.internal_server_error()
            |> wisp.string_body("Failed to get customer context")
        }
      }

      auth.InvalidKey(_) -> {
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Unauthorized")),
              #("message", json.string("Invalid API key")),
            ]),
          ),
          401,
        )
      }
    }
  })
}

fn handle_customer_request_with_context(
  req: Request,
  business_id: String,
  customer_id: String,
  context: customer_types.CustomerContext,
) -> Response {
  use json_data <- wisp.require_json(req)

  case decode.run(json_data, proxy_request_decoder()) {
    Ok(proxy_req) -> {
      // Ensure customer actor exists with context
      case ensure_and_update_customer_actor(business_id, customer_id, context) {
        Ok(_) -> {
          // Override scope to customer
          let customer_proxy_req =
            ProxyRequest(
              ..proxy_req,
              scope: "customer",
              customer_id: Some(customer_id),
            )

          // Process normally - just checks metrics, doesn't route to machines
          process_proxy_request(
            business_id,
            customer_proxy_req,
            utils.generate_request_id(),
          )
        }
        Error(e) -> {
          wisp.internal_server_error()
          |> wisp.string_body("Failed to initialize customer: " <> e)
        }
      }
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid proxy request")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

fn ensure_and_update_customer_actor(
  business_id: String,
  customer_id: String,
  context: customer_types.CustomerContext,
) -> Result(Nil, String) {
  // Get application actor
  case get_application_actor() {
    Ok(app_actor) -> {
      let reply = process.new_subject()

      // Send with api_key empty string since we don't have it here
      process.send(
        app_actor,
        application_types.EnsureCustomerActor(
          business_id,
          customer_id,
          context,
          "",
          // Empty API key since we're already authenticated
          reply,
        ),
      )

      case process.receive(reply, 1000) {
        Ok(Ok(_customer_actor)) -> Ok(Nil)
        Ok(Error(e)) -> Error(e)
        Error(_) -> Error("Timeout ensuring customer actor")
      }
    }
    Error(_) -> Error("Application actor not found")
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

fn forward_with_limit_metadata(
  req: ProxyRequest,
  limit_statuses: List(#(String, BreachStatus)),
  scope: metric_types.MetricScope,
  context: option.Option(customer_types.CustomerContext),
) -> Response {
  // Build JSON of all limits
  let limits_json =
    json.object(
      list.map(limit_statuses, fn(pair) {
        let #(metric_name, status) = pair
        #(
          metric_name,
          json.object([
            #("current_usage", json.float(status.current_usage)),
            #("limit_value", json.float(status.limit_value)),
            #("limit_operator", json.string(status.limit_operator)),
            #("is_breached", json.bool(status.is_breached)),
            #("remaining", case status.remaining {
              Some(r) -> json.float(r)
              None -> json.null()
            }),
          ]),
        )
      }),
    )

  logging.log(
    logging.Info,
    "[ProxyHandler] 🚀 Forwarding request to: " <> req.target_url,
  )

  let business_id = case scope {
    metric_types.Business(bid) -> bid
    metric_types.Customer(bid, _) -> bid
  }

  let domain = extract_domain_from_url(req.target_url)

  case verify_domain_authorization(domain, business_id) {
    Ok(False) -> {
      logging.log(
        logging.Warning,
        "[ProxyHandler] Domain not authorized: " <> domain,
      )
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Unauthorized Domain")),
            #(
              "message",
              json.string(
                "Domain "
                <> domain
                <> " has not authorized business_id: "
                <> business_id,
              ),
            ),
          ]),
        ),
        403,
      )
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[ProxyHandler] Domain verification failed: " <> e,
      )
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Domain Verification Failed")),
            #("message", json.string(e)),
          ]),
        ),
        502,
      )
    }
    Ok(True) -> {
      let tracktags_url =
        utils.get_env_or("TRACKTAGS_URL", "http://localhost:8080")

      let tracktags_host = case string.split(tracktags_url, "://") {
        [_, rest] ->
          string.split(rest, "/")
          |> list.first
          |> result.unwrap("localhost:8080")
        _ -> "localhost:8080"
      }

      case
        string.contains(req.target_url, tracktags_host)
        || string.contains(req.target_url, "/api/v1/proxy")
      {
        True -> {
          logging.log(
            logging.Warning,
            "[ProxyHandler] Loop detected in target URL: " <> req.target_url,
          )
          let error_json =
            json.object([
              #("error", json.string("Loop Detected")),
              #("message", json.string("Cannot proxy back to TrackTags")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 400)
        }
        False -> {
          case dict.get(req.headers, "x-tracktags-customer-id") {
            Ok(_) -> {
              logging.log(
                logging.Warning,
                "[ProxyHandler] Request already proxied - TrackTags headers detected",
              )
              let error_json =
                json.object([
                  #("error", json.string("Double Proxy Detected")),
                  #(
                    "message",
                    json.string(
                      "Request has already been proxied through TrackTags",
                    ),
                  ),
                ])
              wisp.json_response(json.to_string_tree(error_json), 400)
            }
            Error(_) -> {
              let http_method = case string.uppercase(req.method) {
                "GET" -> http.Get
                "POST" -> http.Post
                "PUT" -> http.Put
                "DELETE" -> http.Delete
                "PATCH" -> http.Patch
                _ -> http.Get
              }

              case request.to(req.target_url) {
                Error(_) -> {
                  logging.log(
                    logging.Error,
                    "[ProxyHandler] ❌ Invalid target URL: " <> req.target_url,
                  )
                  let error_json =
                    json.object([
                      #("error", json.string("Invalid URL")),
                      #("message", json.string("Target URL is malformed")),
                    ])
                  wisp.json_response(json.to_string_tree(error_json), 400)
                }
                Ok(base_req) -> {
                  // SECURITY: Strip Authorization header to prevent user API key leakage
                  let req_with_headers =
                    dict.fold(req.headers, base_req, fn(acc_req, key, value) {
                      case string.lowercase(key) {
                        "authorization" -> acc_req
                        // Don't forward user's API key
                        _ -> request.set_header(acc_req, key, value)
                      }
                    })

                  // NEW: Add X-TrackTags-Limits header with all limit statuses
                  let req_with_limits =
                    req_with_headers
                    |> request.set_header(
                      "X-TrackTags-Limits",
                      json.to_string(limits_json),
                    )

                  let req_with_metadata = case scope, context {
                    metric_types.Customer(bid, cid), Some(ctx) -> {
                      let machine_ids =
                        list.map(ctx.machines, fn(m) { m.machine_id })
                      req_with_limits
                      |> request.set_header("X-TrackTags-Customer-Id", cid)
                      |> request.set_header("X-TrackTags-Business-Id", bid)
                      |> request.set_header(
                        "X-TrackTags-Owned-Machines",
                        string.join(machine_ids, ","),
                      )
                      |> request.set_header(
                        "X-TrackTags-Plan-Id",
                        option.unwrap(ctx.customer.plan_id, "free"),
                      )
                      |> request.set_header(
                        "X-TrackTags-Machine-Count",
                        int.to_string(list.length(ctx.machines)),
                      )
                      |> request.set_header("X-TrackTags-Proxied", "true")
                    }
                    metric_types.Business(bid), _ -> {
                      req_with_limits
                      |> request.set_header("X-TrackTags-Business-Id", bid)
                      |> request.set_header("X-TrackTags-Scope", "business")
                      |> request.set_header("X-TrackTags-Proxied", "true")
                    }
                    _, _ -> {
                      req_with_limits
                      |> request.set_header("X-TrackTags-Proxied", "true")
                    }
                  }

                  let final_req = case http_method, req.body {
                    http.Post, Some(body) -> {
                      req_with_metadata
                      |> request.set_method(http.Post)
                      |> request.set_header("Content-Type", "application/json")
                      |> request.set_body(body)
                    }
                    http.Put, Some(body) -> {
                      req_with_metadata
                      |> request.set_method(http.Put)
                      |> request.set_header("Content-Type", "application/json")
                      |> request.set_body(body)
                    }
                    http.Patch, Some(body) -> {
                      req_with_metadata
                      |> request.set_method(http.Patch)
                      |> request.set_header("Content-Type", "application/json")
                      |> request.set_body(body)
                    }
                    http.Get, _ -> {
                      req_with_metadata
                      |> request.set_method(http.Get)
                    }
                    http.Delete, _ -> {
                      req_with_metadata
                      |> request.set_method(http.Delete)
                    }
                    _, _ -> req_with_metadata |> request.set_method(http_method)
                  }

                  case httpc.send(final_req) {
                    Ok(response) -> {
                      logging.log(
                        logging.Info,
                        "[ProxyHandler] ✅ Target responded with status: "
                          <> int.to_string(response.status),
                      )

                      let forwarded_response =
                        ForwardedResponse(
                          status_code: response.status,
                          headers: dict.from_list(response.headers),
                          body: response.body,
                        )

                      // Create a dummy breach status since we're not breached
                      let success_status =
                        BreachStatus(
                          is_breached: False,
                          current_usage: 0.0,
                          limit_value: 0.0,
                          limit_operator: "gte",
                          breach_action: "allow",
                          remaining: None,
                        )

                      let success_json =
                        allowed_response_to_json(
                          success_status,
                          forwarded_response,
                        )
                      wisp.json_response(json.to_string_tree(success_json), 200)
                    }
                    Error(http_error) -> {
                      logging.log(
                        logging.Error,
                        "[ProxyHandler] ❌ HTTP error: "
                          <> string.inspect(http_error),
                      )
                      let error_json =
                        json.object([
                          #("error", json.string("Proxy Error")),
                          #(
                            "message",
                            json.string("Failed to forward request to target"),
                          ),
                        ])
                      wisp.json_response(json.to_string_tree(error_json), 502)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn check_all_plan_limits_and_forward(
  lookup_key: String,
  scope: metric_types.MetricScope,
  business_id: String,
  req: ProxyRequest,
) -> Response {
  case scope {
    metric_types.Customer(bid, cid) -> {
      case supabase_client.get_customer_full_context(bid, cid) {
        Ok(context) -> {
          // Check status of ALL plan limit metrics
          let limit_statuses =
            list.filter_map(context.plan_limits, fn(limit) {
              case
                check_metric_breach_status(
                  lookup_key,
                  limit.metric_name,
                  scope,
                  business_id,
                )
              {
                Ok(status) -> Ok(#(limit.metric_name, status))
                Error(_) -> Error(Nil)
                // Metric doesn't exist yet - skip it
              }
            })

          logging.log(
            logging.Info,
            "[ProxyHandler] 📊 Checked "
              <> int.to_string(list.length(limit_statuses))
              <> " plan limit metrics",
          )

          // Check if ANY would deny
          let any_denials =
            list.any(limit_statuses, fn(pair) {
              let #(_, status) = pair
              should_deny_request(status)
            })

          case any_denials {
            True -> {
              // Find first denial
              case
                list.find(limit_statuses, fn(pair) {
                  let #(_, s) = pair
                  should_deny_request(s)
                })
              {
                Ok(#(metric_name, breach_status)) -> {
                  logging.log(
                    logging.Warning,
                    "[ProxyHandler] 🚨 DENIED - " <> metric_name <> " over limit",
                  )
                  create_denied_response(breach_status)
                }
                Error(_) -> wisp.internal_server_error()
              }
            }
            False -> {
              // Forward with ALL statuses in custom header
              logging.log(
                logging.Info,
                "[ProxyHandler] ✅ All limits OK - forwarding with metadata",
              )
              forward_with_limit_metadata(
                req,
                limit_statuses,
                scope,
                Some(context),
              )
            }
          }
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "[ProxyHandler] ❌ Failed to get customer context",
          )
          wisp.internal_server_error()
        }
      }
    }
    metric_types.Business(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Invalid Request")),
            #("message", json.string("metric_name required for business scope")),
          ]),
        ),
        400,
      )
    }
  }
}

// Add to proxy_handler.gleam
fn check_and_handle_expiry(
  context: customer_types.CustomerContext,
) -> Result(customer_types.CustomerContext, String) {
  case is_subscription_expired(context.customer.subscription_ends_at) {
    True -> {
      logging.log(
        logging.Warning,
        "[ProxyHandler] ⏰ Subscription expired, loading free tier limits",
      )

      // Get free plan for this business
      case
        supabase_client.get_free_plan_for_business(context.customer.business_id)
      {
        Ok(free_plan) -> {
          // Get free plan limits
          case supabase_client.get_plan_limits_by_plan_id(free_plan.id) {
            Ok(free_limits) -> {
              // Return context with FREE LIMITS swapped in
              Ok(
                customer_types.CustomerContext(
                  ..context,
                  plan_limits: free_limits,
                  // ← Just swap!
                ),
              )
            }
            Error(_) -> Error("Failed to load free limits")
          }
        }
        Error(_) -> Error("No free plan found")
      }
    }
    False -> Ok(context)
  }
}

fn is_subscription_expired(ends_at: Option(String)) -> Bool {
  case ends_at {
    Some(expires_str) -> {
      case birl.parse(expires_str) {
        Ok(expires_time) ->
          birl.to_unix(expires_time) < utils.current_timestamp()
        Error(_) -> False
      }
    }
    None -> False
  }
}

// Fetch business webhook secrets from Supabase
fn get_business_secrets(
  business_id: String,
) -> Result(#(String, Option(String)), String) {
  logging.log(
    logging.Info,
    "[ProxyHandler] 🔍 Fetching webhook secrets for business",
  )

  case
    supabase_client.get_integration_keys(business_id, Some("webhook_secret"))
  {
    Ok(keys) -> {
      // Filter active webhook_secret keys
      let active_secrets =
        list.filter(keys, fn(k) {
          k.is_active && k.key_type == "webhook_secret"
        })

      case active_secrets {
        [] -> {
          logging.log(
            logging.Info,
            "[ProxyHandler] 📭 No webhook secrets configured",
          )
          Error("No webhook secrets configured")
        }
        [key] -> {
          // Only one key exists
          case decrypt_secret_key(key.encrypted_key) {
            Ok(secret) -> {
              logging.log(
                logging.Info,
                "[ProxyHandler] ✅ Found one webhook secret",
              )
              Ok(#(secret, None))
            }
            Error(e) -> Error(e)
          }
        }
        [key1, key2, ..] -> {
          // Both keys exist
          let secret1_result = decrypt_secret_key(key1.encrypted_key)
          let secret2_result = decrypt_secret_key(key2.encrypted_key)

          case secret1_result, secret2_result {
            Ok(secret1), Ok(secret2) -> {
              logging.log(
                logging.Info,
                "[ProxyHandler] ✅ Found two webhook secrets",
              )
              // Determine which is primary/secondary by key_name
              case key1.key_name, key2.key_name {
                "primary", _ -> Ok(#(secret1, Some(secret2)))
                _, "primary" -> Ok(#(secret2, Some(secret1)))
                _, _ -> Ok(#(secret1, Some(secret2)))
                // Default: first is primary
              }
            }
            Ok(secret1), Error(_) -> {
              logging.log(
                logging.Warning,
                "[ProxyHandler] ⚠️ Secondary secret failed to decrypt",
              )
              Ok(#(secret1, None))
            }
            Error(e), _ -> Error(e)
          }
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Warning,
        "[ProxyHandler] ❌ Failed to fetch integration keys",
      )
      Error("Failed to fetch webhook secrets")
    }
  }
}

// Decrypt a single secret key from encrypted JSON
fn decrypt_secret_key(encrypted_json: String) -> Result(String, String) {
  // Use the crypto module's decrypt_from_json function
  use credentials_json <- result.try(
    crypto.decrypt_from_json(encrypted_json)
    |> result.map_error(fn(_e) { "Failed to decrypt secret" }),
    // ← Convert CryptoError to String
  )

  // Extract the "secret" field using manual parsing
  use #(_, rest) <- result.try(
    string.split_once(credentials_json, "\"secret\":\"")
    |> result.replace_error("Secret field not found in credentials"),
  )

  use #(secret, _) <- result.try(
    string.split_once(rest, "\"")
    |> result.replace_error("Failed to parse secret from credentials JSON"),
  )

  logging.log(logging.Info, "[ProxyHandler] ✅ Successfully decrypted secret")
  Ok(secret)
}

// Helper to add webhook secrets to request builder
fn add_webhook_secret_headers(
  req: request.Request(String),
  business_id: String,
) -> request.Request(String) {
  case get_business_secrets_cached(business_id) {
    Ok(#(primary, secondary)) -> {
      logging.log(
        logging.Info,
        "[ProxyHandler] 🔐 Adding webhook secrets to request",
      )

      let req_with_primary =
        request.set_header(req, "x-webhook-secret-primary", primary)

      case secondary {
        Some(sec) ->
          request.set_header(
            req_with_primary,
            "x-webhook-secret-secondary",
            sec,
          )
        None -> req_with_primary
      }
    }
    Error(e) -> {
      logging.log(logging.Info, "[ProxyHandler] 📭 No secrets: " <> e)
      req
      // No secrets, return unchanged
    }
  }
}

// Cache secrets tuple for 5 minutes
fn get_business_secrets_cached(
  business_id: String,
) -> Result(#(String, Option(String)), String) {
  let cache_key = "webhook_secrets:" <> business_id

  // Try cache first
  case cachex.get("secrets_cache", cache_key) {
    Ok(Some(cached)) -> {
      logging.log(logging.Info, "[ProxyHandler] 💾 Cache hit for secrets")
      Ok(cached)
    }
    _ -> {
      // Cache miss, fetch from DB
      case get_business_secrets(business_id) {
        Ok(secrets) -> {
          // Cache for 5 minutes (300 seconds)
          let _ = cachex.put("secrets_cache", cache_key, secrets)
          Ok(secrets)
        }
        Error(e) -> Error(e)
      }
    }
  }
}
