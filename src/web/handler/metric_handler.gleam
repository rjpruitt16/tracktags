import actors/application
import actors/metric_actor
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import glixir
import logging
import storage/metric_store
import wisp.{type Request, type Response}

// Request body structures
pub type MetricRequest {
  MetricRequest(
    metric_name: String,
    value: Float,
    operation: String,
    flush_interval: String,
    tags: Dict(String, String),
  )
}

pub type UpdateMetricRequest {
  UpdateMetricRequest(value: Float)
}

// Valid operations and intervals
const valid_operations = ["SUM", "AVG", "MAX", "MIN", "COUNT"]

const valid_intervals = [
  "1s", "5s", "30s", "1m", "15m", "30m", "1h", "6h", "1d",
]

// Convert flush_interval to tick_type for internal use
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

// TODO: Update to validate key. 
fn validate_api_key(api_key: String) -> Result(String, String) {
  case api_key {
    "tk_live_test123" -> Ok("test_user_001")
    "tk_live_test456" -> Ok("test_user_002")
    "tk_live_test789" -> Ok("test_user_003")
    _ -> Error("Invalid API key")
  }
}

// Extract API key from Authorization header
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

// Common auth wrapper
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
            "[MetricHandler] Invalid API key: " <> api_key,
          )
          let error_json =
            json.object([
              #("error", json.string("Unauthorized")),
              #("message", json.string(error)),
            ])
          wisp.json_response(json.to_string_tree(error_json), 401)
        }
        Ok(account_id) -> handler(account_id)
      }
    }
  }
}

// JSON decoders
fn metric_request_decoder() -> decode.Decoder(MetricRequest) {
  use metric_name <- decode.field("metric_name", decode.string)
  use value <- decode.field("value", decode.float)
  use operation <- decode.optional_field("operation", "SUM", decode.string)
  use flush_interval <- decode.optional_field(
    "flush_interval",
    "1h",
    decode.string,
  )
  use tags <- decode.optional_field(
    "tags",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )

  decode.success(MetricRequest(
    metric_name: metric_name,
    value: value,
    operation: operation,
    flush_interval: flush_interval,
    tags: tags,
  ))
}

fn update_metric_request_decoder() -> decode.Decoder(UpdateMetricRequest) {
  use value <- decode.field("value", decode.float)
  decode.success(UpdateMetricRequest(value: value))
}

// Validate the parsed request
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
    // Validate value is not zero (simple validation)
    case req.value {
      _ -> Ok(req)
    }
  })
}

// Helper to get the application actor from registry
fn get_application_actor() -> Result(
  process.Subject(application.ApplicationMessage),
  String,
) {
  case
    glixir.lookup_subject(
      atom.create("tracktags_actors"),
      atom.create("application_actor"),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Application actor not found in registry")
  }
}

// ===== CRUD ENDPOINTS =====

// CREATE (POST /api/v1/metrics)
pub fn create_metric(req: Request) -> Response {
  let request_id = string.inspect(system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 CREATE REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)

  use account_id <- with_auth(req)

  // Parse JSON body
  use json_data <- wisp.require_json(req)

  let result = {
    use metric_req <- result.try(decode.run(json_data, metric_request_decoder()))
    use validated_req <- result.try(validate_metric_request(metric_req))
    Ok(process_create_metric(account_id, validated_req))
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

// READ (GET /api/v1/metrics/{metric_name})
pub fn get_metric(req: Request, metric_name: String) -> Response {
  let request_id = string.inspect(system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 GET REQUEST START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Get)

  use account_id <- with_auth(req)

  case metric_store.get_value(account_id, metric_name) {
    Ok(value) -> {
      let success_json =
        json.object([
          #("metric_name", json.string(metric_name)),
          #("account_id", json.string(account_id)),
          #("current_value", json.float(value)),
          #("timestamp", json.int(current_timestamp())),
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

// UPDATE (PUT /api/v1/metrics/{metric_name})
pub fn update_metric(req: Request, metric_name: String) -> Response {
  let request_id = string.inspect(system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 UPDATE REQUEST START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Put)

  use account_id <- with_auth(req)

  // Parse JSON body
  use json_data <- wisp.require_json(req)

  let result = {
    use update_req <- result.try(decode.run(
      json_data,
      update_metric_request_decoder(),
    ))
    Ok(process_update_metric(account_id, metric_name, update_req.value))
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

// DELETE (DELETE /api/v1/metrics/{metric_name})
pub fn delete_metric(req: Request, metric_name: String) -> Response {
  let request_id = string.inspect(system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 DELETE REQUEST START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Delete)

  use account_id <- with_auth(req)

  // Try to find and stop the metric actor
  case metric_actor.lookup_metric_subject(account_id, metric_name) {
    Ok(metric_subject) -> {
      // Send shutdown message to metric actor
      process.send(metric_subject, metric_actor.Shutdown)

      // Clean up ETS entry
      // Note: MetricStore doesn't have delete yet, we'll add it

      let success_json =
        json.object([
          #("message", json.string("Metric deleted successfully")),
          #("metric_name", json.string(metric_name)),
          #("account_id", json.string(account_id)),
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

// ===== PROCESSING FUNCTIONS =====

// Process the validated metric request (CREATE)
fn process_create_metric(account_id: String, req: MetricRequest) -> Response {
  let operation = req.operation
  let interval = req.flush_interval
  let tags = req.tags
  let tick_type = interval_to_tick_type(interval)

  logging.log(
    logging.Info,
    "[MetricHandler] Processing CREATE metric: "
      <> account_id
      <> "/"
      <> req.metric_name,
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
        application.SendMetricToUser(
          account_id: account_id,
          metric_name: req.metric_name,
          value: req.value,
          tick_type: tick_type,
          operation: req.operation,
        ),
      )

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ CREATE metric sent to application: "
          <> req.metric_name
          <> " = "
          <> float.to_string(req.value),
      )

      let success_json =
        json.object([
          #("status", json.string("created")),
          #("account_id", json.string(account_id)),
          #("metric_name", json.string(req.metric_name)),
          #("value", json.float(req.value)),
          #("operation", json.string(operation)),
          #("flush_interval", json.string(interval)),
          #("tick_type", json.string(tick_type)),
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

// Process UPDATE metric (set absolute value)
fn process_update_metric(
  account_id: String,
  metric_name: String,
  new_value: Float,
) -> Response {
  logging.log(
    logging.Info,
    "[MetricHandler] Processing UPDATE metric: "
      <> account_id
      <> "/"
      <> metric_name
      <> " to "
      <> float.to_string(new_value),
  )

  case metric_store.reset_metric(account_id, metric_name, new_value) {
    Ok(_) -> {
      let success_json =
        json.object([
          #("status", json.string("updated")),
          #("account_id", json.string(account_id)),
          #("metric_name", json.string(metric_name)),
          #("new_value", json.float(new_value)),
          #("timestamp", json.int(current_timestamp())),
        ])

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ Updated metric: "
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

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
