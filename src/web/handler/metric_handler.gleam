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
import wisp.{type Request, type Response}

// Request body structure
pub type MetricRequest {
  MetricRequest(
    metric_name: String,
    value: Float,
    operation: String,
    flush_interval: String,
    tags: Dict(String, String),
  )
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
    // Default fallback
  }
}

// Mock API key validation - replace with Supabase later
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

// JSON decoder for metric request using modern decode API
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
      // Accept all float values for now
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

// Main handler function
pub fn create_metric(req: Request) -> Response {
  logging.log(logging.Info, "[MetricHandler] POST /api/v1/metrics")

  use <- wisp.require_method(req, http.Post)

  // Extract and validate API key
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
        Ok(account_id) -> {
          // Parse JSON body using modern wisp
          use json_data <- wisp.require_json(req)

          let result = {
            // Decode the JSON into our MetricRequest type
            use metric_req <- result.try(decode.run(
              json_data,
              metric_request_decoder(),
            ))
            use validated_req <- result.try(validate_metric_request(metric_req))

            // Process the metric
            Ok(process_metric(account_id, validated_req))
          }

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
      }
    }
  }
}

// Process the validated metric request
fn process_metric(account_id: String, req: MetricRequest) -> Response {
  let operation = req.operation
  let interval = req.flush_interval
  let tags = req.tags
  let tick_type = interval_to_tick_type(interval)

  logging.log(
    logging.Info,
    "[MetricHandler] Processing metric: "
      <> account_id
      <> "/"
      <> req.metric_name,
  )

  // 🔥 NEW: Send the metric to the application actor to spawn MetricActor!
  case get_application_actor() {
    Ok(app_actor) -> {
      logging.log(
        logging.Info,
        "[MetricHandler] 🚀 Sending to application actor: "
          <> req.metric_name
          <> " with tick_type: "
          <> tick_type,
      )

      // Send SendMetricToUser message to application actor
      process.send(
        app_actor,
        application.SendMetricToUser(
          account_id: account_id,
          metric_name: req.metric_name,
          value: req.value,
          tick_type: tick_type,
        ),
      )

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ Metric sent to application: "
          <> req.metric_name
          <> " = "
          <> float.to_string(req.value),
      )

      // Return success response
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

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
