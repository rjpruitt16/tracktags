// src/web/handler/metric_handler.gleam - COMPLETE VERSION
import actors/application
import actors/metric_actor
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glixir
import logging
import storage/metric_store
import types/metric_types.{type MetricMetadata}
import utils/utils
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================

pub type MetricRequest {
  MetricRequest(
    metric_name: String,
    operation: String,
    flush_interval: String,
    cleanup_after: String,
    metric_type: String,
    initial_value: Float,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
  )
}

pub type UpdateMetricRequest {
  UpdateMetricRequest(value: Float)
}

// Valid operations, intervals, and cleanup periods
const valid_operations = ["SUM", "AVG", "MAX", "MIN", "COUNT"]

const valid_intervals = [
  "1s", "5s", "30s", "1m", "15m", "30m", "1h", "6h", "1d",
]

const valid_cleanup_periods = [
  "5s", "1m", "1h", "6h", "1d", "7d", "30d", "never",
]

const valid_metric_types = ["reset", "checkpoint"]

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

fn cleanup_to_seconds(cleanup_period: String) -> Int {
  case cleanup_period {
    "5s" -> 5
    "1m" -> 60
    "1h" -> 3600
    "6h" -> 21_600
    "1d" -> 86_400
    "7d" -> 604_800
    "30d" -> 2_592_000
    "never" -> -1
    _ -> 86_400
  }
}

fn interval_to_tick_type(interval: String) -> String {
  case interval {
    "1s" -> "tick_1s"
    "5s" -> "tick_5s"
    "30s" -> "tick_30s"
    "1m" -> "tick_1m"
    "15m" -> "tick_15m"
    "30m" -> "tick_30m"
    "1h" -> "tick_1h"
    "6h" -> "tick_6h"
    "1d" -> "tick_1d"
    _ -> "tick_1s"
  }
}

// ============================================================================
// AUTHENTICATION
// ============================================================================

fn validate_api_key(api_key: String) -> Result(String, String) {
  logging.log(
    logging.Info,
    "[MetricHandler] Validating API key via Supabase: "
      <> string.slice(api_key, 0, 10)
      <> "...",
  )

  case supabase_client.validate_api_key(api_key) {
    Ok(business_id) -> {
      logging.log(
        logging.Info,
        "[MetricHandler] ✅ API key validated for business: " <> business_id,
      )
      Ok(business_id)
    }
    Error(supabase_client.NotFound(_)) -> {
      logging.log(
        logging.Warning,
        "[MetricHandler] ❌ API key not found in database",
      )
      Error("Invalid API key")
    }
    Error(supabase_client.Unauthorized) -> {
      logging.log(
        logging.Warning,
        "[MetricHandler] ❌ Unauthorized access to Supabase",
      )
      Error("Database access denied")
    }
    Error(supabase_client.HttpError(_)) -> {
      logging.log(
        logging.Error,
        "[MetricHandler] ❌ Network error connecting to Supabase",
      )
      Error("Service temporarily unavailable")
    }
    Error(supabase_client.DatabaseError(msg)) -> {
      logging.log(logging.Error, "[MetricHandler] ❌ Database error: " <> msg)
      Error("Database error")
    }
    Error(supabase_client.ParseError(msg)) -> {
      logging.log(logging.Error, "[MetricHandler] ❌ Parse error: " <> msg)
      Error("Invalid response format")
    }
    Error(supabase_client.NetworkError(msg)) -> {
      logging.log(logging.Error, "[MetricHandler] ❌ Network error: " <> msg)
      Error("Network error")
    }
  }
}

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
      logging.log(logging.Warning, "[MetricHandler] Auth failed: " <> error)
      let error_json =
        json.object([
          #("error", json.string("Unauthorized")),
          #("message", json.string(error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 401)
    }
    Ok(api_key) -> {
      case validate_api_key(api_key) {
        Error(error) -> {
          logging.log(
            logging.Warning,
            "[MetricHandler] Invalid API key: "
              <> string.slice(api_key, 0, 10)
              <> "...",
          )
          let error_json =
            json.object([
              #("error", json.string("Unauthorized")),
              #("message", json.string(error)),
            ])
          wisp.json_response(json.to_string_tree(error_json), 401)
        }
        Ok(business_id) -> handler(business_id)
      }
    }
  }
}

// ============================================================================
// JSON DECODERS
// ============================================================================

fn metric_request_decoder() -> decode.Decoder(MetricRequest) {
  use metric_name <- decode.field("metric_name", decode.string)
  use operation <- decode.optional_field("operation", "SUM", decode.string)
  use flush_interval <- decode.optional_field(
    "flush_interval",
    "1h",
    decode.string,
  )
  use cleanup_after <- decode.optional_field(
    "cleanup_after",
    "1d",
    decode.string,
  )
  use tags <- decode.optional_field(
    "tags",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use initial_value <- decode.optional_field("initial_value", 0.0, decode.float)
  use metric_type <- decode.optional_field(
    "metric_type",
    "checkpoint",
    decode.string,
  )

  use metadata <- decode.optional_field(
    "metadata",
    None,
    decode.optional(metric_types.metadata_decoder()),
  )

  decode.success(MetricRequest(
    metric_name: metric_name,
    operation: operation,
    flush_interval: flush_interval,
    cleanup_after: cleanup_after,
    metric_type: metric_type,
    initial_value: initial_value,
    tags: tags,
    metadata: metadata,
  ))
}

fn update_metric_request_decoder() -> decode.Decoder(UpdateMetricRequest) {
  use value <- decode.field("value", decode.float)
  decode.success(UpdateMetricRequest(value: value))
}

// ============================================================================
// VALIDATION
// ============================================================================

fn validate_metric_request(
  req: MetricRequest,
) -> Result(MetricRequest, List(decode.DecodeError)) {
  // Validate metric name
  case string.length(req.metric_name) {
    0 ->
      Error([decode.DecodeError("Invalid", "metric_name cannot be empty", [])])
    n if n > 100 ->
      Error([
        decode.DecodeError(
          "Invalid",
          "metric_name too long (max 100 chars)",
          [],
        ),
      ])
    _ -> Ok(Nil)
  }
  |> result.try(fn(_) {
    // Validate operation
    case list.contains(valid_operations, req.operation) {
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "Invalid operation. Must be one of: "
              <> string.join(valid_operations, ", "),
            [],
          ),
        ])
      True -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate flush_interval
    case list.contains(valid_intervals, req.flush_interval) {
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "Invalid flush_interval. Must be one of: "
              <> string.join(valid_intervals, ", "),
            [],
          ),
        ])
      True -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate cleanup_after
    case list.contains(valid_cleanup_periods, req.cleanup_after) {
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "Invalid cleanup_after. Must be one of: "
              <> string.join(valid_cleanup_periods, ", "),
            [],
          ),
        ])
      True -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate metric_type
    case list.contains(valid_metric_types, req.metric_type) {
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "Invalid metric_type. Must be one of: "
              <> string.join(valid_metric_types, ", "),
            [],
          ),
        ])
      True -> Ok(req)
    }
  })
}

// ============================================================================
// REGISTRY HELPERS
// ============================================================================

fn get_application_actor() -> Result(
  process.Subject(application.ApplicationMessage),
  String,
) {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      atom.create("application_actor"),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Application actor not found in registry")
  }
}

// ============================================================================
// CRUD ENDPOINTS
// ============================================================================

pub fn create_metric(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 CREATE REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  // ✅ Parse query parameters
  let scope = case wisp.get_query(req) |> list.key_find("scope") {
    Ok(s) -> s
    Error(_) -> "business"
    // default
  }

  let client_id = case wisp.get_query(req) |> list.key_find("client_id") {
    Ok(cid) -> Some(cid)
    Error(_) -> None
  }

  let result = {
    use metric_req <- result.try(decode.run(json_data, metric_request_decoder()))
    use validated_req <- result.try(validate_metric_request(metric_req))

    // ✅ Route based on scope
    case scope {
      "client" -> {
        case client_id {
          Some(cid) ->
            Ok(process_create_client_metric(business_id, cid, validated_req))
          None ->
            Error([
              decode.DecodeError(
                "Missing",
                "client_id required for client scope",
                [],
              ),
            ])
        }
      }
      "business" | _ -> Ok(process_create_metric(business_id, validated_req))
    }
  }
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 CREATE REQUEST END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[MetricHandler] Bad request: " <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid request data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

pub fn get_metric(req: Request, metric_name: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 GET REQUEST START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)
  // Parse query parameters  
  let scope = case wisp.get_query(req) |> list.key_find("scope") {
    Ok(s) -> s
    Error(_) -> "business"
  }

  let lookup_key = case scope {
    "client" -> {
      case wisp.get_query(req) |> list.key_find("client_id") {
        Ok(cid) -> business_id <> ":" <> cid
        Error(_) -> business_id
      }
    }
    _ -> business_id
  }

  case metric_store.get_value(lookup_key, metric_name) {
    Ok(value) -> {
      let success_json =
        json.object([
          #("metric_name", json.string(metric_name)),
          #("business_id", json.string(business_id)),
          #("current_value", json.float(value)),
          #("timestamp", json.int(utils.current_timestamp())),
        ])

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ Retrieved metric: "
          <> metric_name
          <> " = "
          <> float.to_string(value),
      )
      logging.log(
        logging.Info,
        "[MetricHandler] 🔍 GET REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Not Found")),
          #("message", json.string("Metric not found: " <> metric_name)),
        ])

      logging.log(
        logging.Warning,
        "[MetricHandler] Metric not found: " <> metric_name,
      )
      logging.log(
        logging.Info,
        "[MetricHandler] 🔍 GET REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 404)
    }
  }
}

pub fn update_metric(req: Request, metric_name: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 UPDATE REQUEST START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Put)
  use business_id <- with_auth(req)

  // Parse query parameters  
  let scope = case wisp.get_query(req) |> list.key_find("scope") {
    Ok(s) -> s
    Error(_) -> "business"
  }

  let lookup_key = case scope {
    "client" -> {
      case wisp.get_query(req) |> list.key_find("client_id") {
        Ok(cid) -> business_id <> ":" <> cid
        // "biz_001:mobile_app"
        Error(_) -> business_id
        // fallback to business
      }
    }
    _ -> business_id
    // business scope
  }

  use json_data <- wisp.require_json(req)

  let result = {
    use update_req <- result.try(decode.run(
      json_data,
      update_metric_request_decoder(),
    ))
    // ✅ FIXED: Pass lookup_key to process_update_metric
    Ok(process_update_metric(
      lookup_key,
      business_id,
      metric_name,
      update_req.value,
    ))
  }

  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 UPDATE REQUEST END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[MetricHandler] Bad update request: " <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid update data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

pub fn delete_metric(req: Request, metric_name: String) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 DELETE REQUEST START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  case metric_actor.lookup_metric_subject(business_id, metric_name) {
    Ok(metric_subject) -> {
      process.send(metric_subject, metric_actor.Shutdown)

      let success_json =
        json.object([
          #("message", json.string("Metric deleted successfully")),
          #("metric_name", json.string(metric_name)),
          #("business_id", json.string(business_id)),
        ])

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ Deleted metric: " <> metric_name,
      )
      logging.log(
        logging.Info,
        "[MetricHandler] 🔍 DELETE REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Not Found")),
          #("message", json.string("Metric not found: " <> metric_name)),
        ])

      logging.log(
        logging.Warning,
        "[MetricHandler] Delete failed - metric not found: " <> metric_name,
      )
      logging.log(
        logging.Info,
        "[MetricHandler] 🔍 DELETE REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 404)
    }
  }
}

pub fn list_metrics(req: Request) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  let todo_json =
    json.object([
      #("message", json.string("List metrics - TODO")),
      #("business_id", json.string(business_id)),
    ])
  wisp.json_response(json.to_string_tree(todo_json), 200)
}

pub fn get_metric_history(req: Request, metric_name: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  let todo_json =
    json.object([
      #("message", json.string("Get metric history - TODO")),
      #("metric_name", json.string(metric_name)),
      #("business_id", json.string(business_id)),
    ])
  wisp.json_response(json.to_string_tree(todo_json), 200)
}

// ============================================================================
// PROCESSING FUNCTIONS
// ============================================================================

fn process_create_metric(business_id: String, req: MetricRequest) -> Response {
  let operation = req.operation
  let interval = req.flush_interval
  let cleanup_after = req.cleanup_after
  let metric_type = metric_types.string_to_metric_type(req.metric_type)
  let initial_value = req.initial_value
  let tick_type = interval_to_tick_type(interval)
  let cleanup_seconds = cleanup_to_seconds(cleanup_after)

  logging.log(
    logging.Info,
    "[MetricHandler] Processing CREATE metric: "
      <> business_id
      <> "/"
      <> req.metric_name
      <> " (cleanup_after: "
      <> cleanup_after
      <> " = "
      <> int.to_string(cleanup_seconds)
      <> "s)",
  )

  case get_application_actor() {
    Ok(app_actor) -> {
      logging.log(
        logging.Info,
        "[MetricHandler] 🚀 Sending CREATE to application actor: "
          <> req.metric_name,
      )

      process.send(
        app_actor,
        application.SendMetricToBusiness(
          business_id: business_id,
          metric_name: req.metric_name,
          tick_type: tick_type,
          operation: req.operation,
          cleanup_after_seconds: cleanup_seconds,
          metric_type: metric_type,
          initial_value: initial_value,
          tags: req.tags,
          metadata: req.metadata,
        ),
      )

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ CREATE metric sent to application: "
          <> req.metric_name
          <> " = "
          <> float.to_string(req.initial_value),
      )

      let success_json =
        json.object([
          #("status", json.string("created")),
          #("business_id", json.string(business_id)),
          #("metric_name", json.string(req.metric_name)),
          #("operation", json.string(operation)),
          #("flush_interval", json.string(interval)),
          #("cleanup_after", json.string(cleanup_after)),
          #("tick_type", json.string(tick_type)),
          #("metric_type", json.string(req.metric_type)),
          #("initial_value", json.float(initial_value)),
        ])

      wisp.json_response(json.to_string_tree(success_json), 201)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[MetricHandler] ❌ Failed to get application actor: " <> error,
      )
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to process metric")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

fn process_update_metric(
  lookup_key: String,
  // ✅ NEW: Accept lookup_key parameter
  business_id: String,
  // Keep for response JSON
  metric_name: String,
  new_value: Float,
) -> Response {
  logging.log(
    logging.Info,
    "[MetricHandler] Processing UPDATE metric: "
      <> lookup_key
      // ✅ FIXED: Log the actual lookup key
      <> "/"
      <> metric_name
      <> " to "
      <> float.to_string(new_value),
  )

  // ✅ FIXED: Use lookup_key instead of business_id
  case metric_actor.lookup_metric_subject(lookup_key, metric_name) {
    Ok(metric_subject) -> {
      let metric =
        metric_actor.Metric(
          account_id: lookup_key,
          // ✅ FIXED: Use lookup_key for account_id
          metric_name: metric_name,
          value: new_value,
          tags: dict.new(),
          timestamp: utils.current_timestamp(),
        )

      process.send(metric_subject, metric_actor.RecordMetric(metric))

      let success_json =
        json.object([
          #("status", json.string("updated")),
          #("business_id", json.string(business_id)),
          #("metric_name", json.string(metric_name)),
          #("new_value", json.float(new_value)),
          #("timestamp", json.int(utils.current_timestamp())),
        ])

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ Updated metric via MetricActor: "
          <> metric_name
          <> " = "
          <> float.to_string(new_value),
      )
      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Not Found")),
          #("message", json.string("Metric not found: " <> metric_name)),
        ])

      logging.log(
        logging.Warning,
        "[MetricHandler] Update failed - metric not found: " <> metric_name,
      )
      wisp.json_response(json.to_string_tree(error_json), 404)
    }
  }
}

fn process_create_client_metric(
  business_id: String,
  client_id: String,
  req: MetricRequest,
) -> Response {
  let operation = req.operation
  let interval = req.flush_interval
  let cleanup_after = req.cleanup_after
  let metric_type = metric_types.string_to_metric_type(req.metric_type)
  let initial_value = req.initial_value
  let tick_type = interval_to_tick_type(interval)
  let cleanup_seconds = cleanup_to_seconds(cleanup_after)

  logging.log(
    logging.Info,
    "[MetricHandler] Processing CREATE metric: "
      <> business_id
      <> "/"
      <> req.metric_name
      <> " (cleanup_after: "
      <> cleanup_after
      <> " = "
      <> int.to_string(cleanup_seconds)
      <> "s)",
  )

  case get_application_actor() {
    Ok(app_actor) -> {
      logging.log(
        logging.Info,
        "[MetricHandler] 🚀 Sending CREATE to application actor: "
          <> req.metric_name,
      )

      process.send(
        app_actor,
        application.SendMetricToClient(
          business_id: business_id,
          client_id: client_id,
          metric_name: req.metric_name,
          tick_type: tick_type,
          operation: req.operation,
          cleanup_after_seconds: cleanup_seconds,
          metric_type: metric_type,
          initial_value: initial_value,
          tags: req.tags,
          metadata: req.metadata,
        ),
      )

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ CREATE metric sent to application: "
          <> req.metric_name
          <> " = "
          <> float.to_string(req.initial_value),
      )

      let success_json =
        json.object([
          #("status", json.string("created")),
          #("business_id", json.string(business_id)),
          #("metric_name", json.string(req.metric_name)),
          #("operation", json.string(operation)),
          #("flush_interval", json.string(interval)),
          #("cleanup_after", json.string(cleanup_after)),
          #("tick_type", json.string(tick_type)),
          #("metric_type", json.string(req.metric_type)),
          #("initial_value", json.float(initial_value)),
        ])

      wisp.json_response(json.to_string_tree(success_json), 201)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[MetricHandler] ❌ Failed to get application actor: " <> error,
      )
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to process metric")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}
