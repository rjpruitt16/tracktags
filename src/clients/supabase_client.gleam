// src/clients/supabase_client.gleam
import gleam/dict.{type Dict}
import gleam/dynamic/decode
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
import logging
import utils/utils

// ============================================================================
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

pub type Business {
  Business(
    business_id: String,
    stripe_customer_id: Option(String),
    business_name: String,
    email: String,
    plan_type: String,
  )
}

pub type IntegrationKey {
  IntegrationKey(
    id: String,
    business_id: String,
    key_type: String,
    key_name: String,
    encrypted_key: String,
    metadata: Option(Dict(String, json.Json)),
    is_active: Bool,
  )
}

pub type MetricRecord {
  MetricRecord(
    id: String,
    business_id: String,
    client_id: Option(String),
    metric_name: String,
    value: String,
    metric_type: String,
    scope: String,
    adapters: Option(Dict(String, json.Json)),
    flushed_at: String,
  )
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
    http.Get, None -> {
      req_with_headers
      |> request.set_method(http.Get)
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

fn business_decoder() -> decode.Decoder(Business) {
  use business_id <- decode.field("business_id", decode.string)
  use stripe_customer_id <- decode.field(
    "stripe_customer_id",
    decode.optional(decode.string),
  )
  use business_name <- decode.field("business_name", decode.string)
  use email <- decode.field("email", decode.string)
  use plan_type <- decode.field("plan_type", decode.string)
  decode.success(Business(
    business_id: business_id,
    stripe_customer_id: stripe_customer_id,
    business_name: business_name,
    email: email,
    plan_type: plan_type,
  ))
}

fn integration_key_decoder() -> decode.Decoder(IntegrationKey) {
  use id <- decode.field("id", decode.string)
  use business_id <- decode.field("business_id", decode.string)
  use key_type <- decode.field("key_type", decode.string)
  use key_name <- decode.field("key_name", decode.string)
  // Now expects a string, not optional
  use encrypted_key <- decode.field("encrypted_key", decode.string)
  use _metadata <- decode.field("metadata", decode.optional(decode.dynamic))
  use is_active <- decode.field("is_active", decode.bool)
  decode.success(IntegrationKey(
    id: id,
    business_id: business_id,
    key_type: key_type,
    key_name: key_name,
    encrypted_key: encrypted_key,
    metadata: None,
    // TODO: Convert Dynamic to Dict later if needed
    is_active: is_active,
  ))
}

// ============================================================================
// API KEY VALIDATION
// ============================================================================

/// Validate an API key and return the business_id
pub fn validate_api_key(api_key: String) -> Result(String, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Validating API key: "
      <> string.slice(api_key, 0, 10)
      <> "...",
  )

  let path =
    "/integration_keys?key_type=eq.api&encrypted_key=eq."
    <> api_key
    <> "&is_active=eq.true"

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(integration_key_decoder())) {
        Ok([]) -> {
          logging.log(logging.Warning, "[SupabaseClient] API key not found")
          Error(NotFound("API key not found"))
        }
        Ok([integration_key, ..]) -> {
          logging.log(
            logging.Info,
            "[SupabaseClient] API key validated for business: "
              <> integration_key.business_id,
          )
          Ok(integration_key.business_id)
        }
        Error(decode_errors) -> {
          logging.log(
            logging.Error,
            "[SupabaseClient] Failed to parse response: "
              <> string.inspect(decode_errors),
          )
          Error(ParseError("Invalid response format"))
        }
      }
    }
    401 -> Error(Unauthorized)
    _ ->
      Error(DatabaseError(
        "Unexpected response: " <> int.to_string(response.status),
      ))
  }
}

// ============================================================================
// BUSINESS MANAGEMENT
// ============================================================================

/// Get business details by business_id
pub fn get_business(business_id: String) -> Result(Business, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting business: " <> business_id,
  )

  let path = "/businesses?business_id=eq." <> business_id

  use response <- result.try(make_request(http.Get, path, None))

  case response.status {
    200 -> {
      case json.parse(response.body, decode.list(business_decoder())) {
        Ok([]) -> Error(NotFound("Business not found"))
        Ok([business, ..]) -> Ok(business)
        Error(_) -> Error(ParseError("Invalid business format"))
      }
    }
    _ -> Error(DatabaseError("Failed to fetch business"))
  }
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
  let path = "/integration_keys?business_id=eq." <> business_id <> type_filter

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

/// Store a new integration key
pub fn store_integration_key(
  business_id: String,
  key_type: String,
  key_name: String,
  // Changed from Option(String) to String  
  encrypted_key: String,
  metadata: Option(Dict(String, json.Json)),
) -> Result(IntegrationKey, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Storing " <> key_type <> " key for: " <> business_id,
  )

  let base_fields = [
    #("business_id", json.string(business_id)),
    #("key_type", json.string(key_type)),
    #("key_name", json.string(key_name)),
    // Always include key_name
    #("encrypted_key", json.string(encrypted_key)),
    #("is_active", json.bool(True)),
  ]

  let all_fields = case metadata {
    Some(meta) -> [
      #("metadata", json.object(dict.to_list(meta))),
      ..base_fields
    ]
    None -> base_fields
  }

  let key_data = json.object(all_fields)

  use response <- result.try(make_request(
    http.Post,
    "/integration_keys",
    Some(json.to_string(key_data)),
  ))

  case response.status {
    201 -> {
      case json.parse(response.body, decode.list(integration_key_decoder())) {
        Ok([new_key, ..]) -> Ok(new_key)
        Ok([]) -> Error(ParseError("No key returned from server"))
        Error(_) -> Error(ParseError("Invalid response format"))
      }
    }
    _ -> Error(DatabaseError("Failed to store integration key"))
  }
}

// ============================================================================
// METRICS STORAGE
// ============================================================================

/// Store metric data for persistence/billing
pub fn store_metric(
  business_id: String,
  client_id: Option(String),
  metric_name: String,
  value: String,
  metric_type: String,
  scope: String,
  adapters: Option(Dict(String, json.Json)),
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

  let with_client = case client_id {
    Some(cid) -> [#("client_id", json.string(cid)), ..base_fields]
    None -> base_fields
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
        client_id: client_id,
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

  let base_fields = [
    #("business_id", json.string(record.business_id)),
    #("metric_name", json.string(record.metric_name)),
    #("value", json.float(float_value)),
    #("metric_type", json.string(record.metric_type)),
    #("scope", json.string(record.scope)),
  ]

  let all_fields = case record.client_id {
    Some(cid) -> [#("client_id", json.string(cid)), ..base_fields]
    None -> base_fields
  }

  let result = json.object(all_fields)

  // ✅ DEBUG: Log what we're sending to Supabase
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
  business_id: String,
  metric_name: String,
) -> Result(Float, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Getting latest value for: "
      <> business_id
      <> "/"
      <> metric_name,
  )

  let query_params = [
    #("business_id", "eq." <> business_id),
    #("metric_name", "eq." <> metric_name),
    #("order", "flushed_at.desc"),
    #("limit", "1"),
  ]

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

/// Create a new client for a business
pub fn create_client(
  business_id: String,
  client_id: String,
  client_name: String,
) -> Result(Nil, SupabaseError) {
  logging.log(
    logging.Info,
    "[SupabaseClient] Creating client: " <> business_id <> "/" <> client_id,
  )

  let client_data =
    json.object([
      #("client_id", json.string(client_id)),
      #("business_id", json.string(business_id)),
      #("client_name", json.string(client_name)),
    ])

  use response <- result.try(make_request(
    http.Post,
    "/clients",
    Some(json.to_string(client_data)),
  ))

  case response.status {
    201 -> {
      logging.log(
        logging.Info,
        "[SupabaseClient] ✅ Client created successfully",
      )
      Ok(Nil)
    }
    409 -> Error(DatabaseError("Client already exists"))
    _ -> Error(DatabaseError("Failed to create client"))
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
