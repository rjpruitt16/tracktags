// src/web/handler/proxy_handler.gleam

import actors/metric_actor
import clients/supabase_client
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import types/metric_scope
import types/metric_types
import utils/utils
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================

pub type ProxyRequest {
  ProxyRequest(
    scope: String,
    // "business" or "client"
    client_id: option.Option(String),
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

// ============================================================================
// REQUEST PROCESSING
// ============================================================================

fn process_proxy_request(
  business_id: String,
  req: ProxyRequest,
  _request_id: String,
) -> Response {
  logging.log(
    logging.Info,
    "[ProxyHandler] 🎯 Processing proxy request: " <> req.target_url,
  )

  // Step 1: Parse scope using our new MetricScope system
  case metric_scope.string_to_scope(req.scope, business_id, req.client_id) {
    Error(scope_error) -> {
      let error_json =
        json.object([
          #("error", json.string("Invalid Scope")),
          #("message", json.string(scope_error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
    Ok(scope) -> {
      // Step 2: Generate lookup key and check metric status
      let lookup_key = metric_scope.scope_to_lookup_key(scope)

      logging.log(
        logging.Info,
        "[ProxyHandler] 🔍 Checking metric: "
          <> lookup_key
          <> "/"
          <> req.metric_name,
      )

      case
        check_metric_breach_status(
          lookup_key,
          req.metric_name,
          scope,
          business_id,
        )
      {
        Ok(breach_status) -> {
          case should_deny_request(breach_status) {
            True -> {
              logging.log(
                logging.Warning,
                "[ProxyHandler] 🚨 Request DENIED - metric over limit",
              )
              create_denied_response(breach_status)
            }
            False -> {
              logging.log(
                logging.Info,
                "[ProxyHandler] ✅ Request ALLOWED - forwarding to target",
              )
              forward_request_to_target(req, breach_status)
            }
          }
        }
        Error(error_msg) -> {
          logging.log(
            logging.Error,
            "[ProxyHandler] ❌ Failed to check metric status: " <> error_msg,
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

// ============================================================================
// METRIC BREACH CHECKING
// ============================================================================

fn check_metric_breach_status(
  lookup_key: String,
  metric_name: String,
  scope: metric_scope.MetricScope,
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
      spawn_metric_for_checking(lookup_key, metric_name, scope, business_id)
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

fn spawn_metric_for_checking(
  _lookup_key: String,
  metric_name: String,
  scope: metric_scope.MetricScope,
  _business_id: String,
) -> Result(process.Subject(metric_types.Message), String) {
  // NOTE: We tried several approaches to auto-spawn metrics:
  // 1. Direct actor messaging with sleeps - caused race conditions
  // 2. Using metric_handler.create_client_metric_internal - still had timing issues with plan loading
  // 3. Checking ClientActor plan loading state - complex and plans can change
  // 
  // DECISION: Require metrics to exist before using proxy. This is cleaner and avoids
  // all race conditions. Future SDK can handle auto-creation.

  Error(
    "Metric '"
    <> metric_name
    <> "' not found. Create it first using POST /api/v1/metrics with scope="
    <> metric_scope.scope_to_string(scope)
    <> " before using the proxy.",
  )
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
) -> Response {
  logging.log(
    logging.Info,
    "[ProxyHandler] 🚀 Forwarding request to: " <> req.target_url,
  )

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
      let req_with_headers =
        dict.fold(req.headers, base_req, fn(acc_req, key, value) {
          request.set_header(acc_req, key, value)
        })

      let final_req = case http_method, req.body {
        http.Post, Some(json_body) -> {
          req_with_headers
          |> request.set_method(http.Post)
          |> request.set_body(json_body)
        }
        http.Put, Some(json_body) -> {
          req_with_headers
          |> request.set_method(http.Put)
          |> request.set_body(json_body)
        }
        http.Patch, Some(json_body) -> {
          req_with_headers
          |> request.set_method(http.Patch)
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
        _, _ -> req_with_headers |> request.set_method(http_method)
      }

      case httpc.send(final_req) {
        Ok(response) -> {
          logging.log(
            logging.Info,
            "[ProxyHandler] ✅ Target responded with status: "
              <> string.inspect(response.status),
          )

          let forwarded_response =
            ForwardedResponse(
              status_code: response.status,
              headers: dict.from_list(response.headers),
              body: response.body,
            )

          let success_json =
            allowed_response_to_json(breach_status, forwarded_response)
          wisp.json_response(json.to_string_tree(success_json), 200)
        }
        Error(http_error) -> {
          logging.log(
            logging.Error,
            "[ProxyHandler] ❌ HTTP error: " <> string.inspect(http_error),
          )
          let error_json =
            json.object([
              #("error", json.string("Proxy Error")),
              #("message", json.string("Failed to forward request to target")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 502)
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
  use client_id <- decode.optional_field(
    "client_id",
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
    client_id: client_id,
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
    "business" | "client" -> Ok(Nil)
    _ ->
      Error([
        decode.DecodeError(
          "Invalid",
          "scope must be 'business' or 'client'",
          [],
        ),
      ])
  }
  |> result.try(fn(_) {
    // Validate client_id for client scope
    case req.scope, req.client_id {
      "client", None ->
        Error([
          decode.DecodeError(
            "Invalid",
            "client_id required for client scope",
            [],
          ),
        ])
      _, _ -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate metric_name
    case string.length(req.metric_name) {
      0 ->
        Error([decode.DecodeError("Invalid", "metric_name cannot be empty", [])])
      _ -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate target_url
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

fn extract_api_key(req: Request) -> Result(String, String) {
  case list.key_find(req.headers, "authorization") {
    Ok(auth_header) -> {
      case string.split_once(auth_header, " ") {
        Ok(#("Bearer", api_key)) -> Ok(string.trim(api_key))
        _ -> Error("Invalid Authorization header format")
      }
    }
    Error(_) -> Error("Missing Authorization header")
  }
}

fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  case extract_api_key(req) {
    Error(error) -> {
      logging.log(logging.Warning, "[ProxyHandler] Auth failed: " <> error)
      let error_json =
        json.object([
          #("error", json.string("Unauthorized")),
          #("message", json.string(error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 401)
    }
    Ok(api_key) -> {
      case supabase_client.validate_api_key(api_key) {
        Ok(business_id) -> {
          logging.log(
            logging.Info,
            "[ProxyHandler] ✅ API key validated for business: " <> business_id,
          )
          handler(business_id)
        }
        Error(supabase_client.Unauthorized) -> {
          let error_json =
            json.object([
              #("error", json.string("Unauthorized")),
              #("message", json.string("Invalid API key")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 401)
        }
        Error(_) -> {
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("API key validation failed")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
  }
}
