// src/web/handler/metric_handler.gleam - COMPLETE VERSION
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
import types/application_types
import types/metric_types.{type MetricMetadata}
import utils/auth
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
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
}

pub type UpdateMetricRequest {
  UpdateMetricRequest(value: Float)
}

// Valid operations, intervals, and cleanup periods
const valid_operations = ["SUM", "AVG", "MAX", "MIN", "COUNT"]

const valid_intervals = [
  "5s", "15s", "30s", "1m", "15m", "30m", "1h", "6h", "1d",
]

const valid_cleanup_periods = [
  "5s", "1m", "1h", "6h", "1d", "7d", "30d", "never",
]

const valid_metric_types = ["reset", "checkpoint", "stripe_billing"]

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
    "5s" -> "tick_5s"
    "15s" -> "ticks_15s"
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

// In metric_handler.gleam
fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  auth.with_auth(req, fn(auth_result, api_key, is_admin) {
    case auth_result {
      auth.ActorCached(auth.BusinessActor(business_id, _)) ->
        handler(business_id)

      auth.ActorCached(auth.CustomerActor(business_id, _, _)) ->
        handler(business_id)

      auth.DatabaseValid(supabase_client.BusinessKey(business_id)) -> {
        case is_admin {
          True -> {
            // Admin shouldn't be creating metrics directly
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("error", json.string("Forbidden")),
                  #(
                    "message",
                    json.string("Admin key cannot create metrics directly"),
                  ),
                ]),
              ),
              403,
            )
          }
          False -> {
            // Ensure actor exists for future caching
            let _ = auth.ensure_actor_from_auth(auth_result, api_key)
            handler(business_id)
          }
        }
      }

      auth.DatabaseValid(supabase_client.CustomerKey(business_id, _)) ->
        handler(business_id)

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

fn with_auth_typed(
  req: Request,
  handler: fn(supabase_client.KeyValidation) -> Response,
) -> Response {
  case extract_api_key(req) {
    Error(error) -> {
      logging.log(logging.Warning, "[MetricHandler] Auth failed: " <> error)
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Unauthorized")),
            #("message", json.string(error)),
          ]),
        ),
        401,
      )
    }
    Ok(api_key) -> {
      case supabase_client.validate_api_key(api_key) {
        Ok(key_validation) -> handler(key_validation)
        Error(supabase_client.NotFound(_)) ->
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Unauthorized")),
                #("message", json.string("Invalid API key")),
              ]),
            ),
            401,
          )
        Error(err) -> {
          logging.log(
            logging.Error,
            "[MetricHandler] Auth error: " <> string.inspect(err),
          )
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Service error")),
                #("message", json.string("API key validation failed")),
              ]),
            ),
            500,
          )
        }
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

  use limit_value <- decode.optional_field("limit_value", 0.0, decode.float)
  use limit_operator <- decode.optional_field(
    "limit_operator",
    "gte",
    decode.string,
  )
  use breach_action <- decode.optional_field(
    "breach_action",
    "disabled",
    decode.string,
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
    limit_value: limit_value,
    limit_operator: limit_operator,
    breach_action: breach_action,
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
  use _ <- result.try(case string.length(req.metric_name) {
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
  })

  // Validate operation
  use _ <- result.try(case list.contains(valid_operations, req.operation) {
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
  })

  // Validate flush_interval
  use _ <- result.try(case list.contains(valid_intervals, req.flush_interval) {
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
  })

  // Validate cleanup_after
  use _ <- result.try(
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
    },
  )

  // Validate metric_type
  use _ <- result.try(case list.contains(valid_metric_types, req.metric_type) {
    False ->
      Error([
        decode.DecodeError(
          "Invalid",
          "Invalid metric_type. Must be one of: "
            <> string.join(valid_metric_types, ", "),
          [],
        ),
      ])
    True -> Ok(Nil)
  })

  // Apply stripe billing interval validation (this modifies the request if needed)
  validate_stripe_billing_interval(req)
}

fn validate_stripe_billing_interval(
  req: MetricRequest,
) -> Result(MetricRequest, List(decode.DecodeError)) {
  case req.metric_type {
    "stripe_billing" -> {
      // Enforce 1h minimum for StripeBilling metrics
      case req.flush_interval {
        "1s" | "5s" | "15s" | "30s" | "1m" | "5m" | "15m" | "30m" -> {
          logging.log(
            logging.Info,
            "[MetricHandler] ⚡ StripeBilling metric forced to 1h interval (was "
              <> req.flush_interval
              <> ") for performance",
          )
          Ok(MetricRequest(..req, flush_interval: "1h"))
        }
        "1h" | "6h" | "12h" | "1d" -> Ok(req)
        // These are fine
        _ -> {
          // Unknown interval, default to 1h
          logging.log(
            logging.Warning,
            "[MetricHandler] Unknown interval '"
              <> req.flush_interval
              <> "' for StripeBilling, defaulting to 1h",
          )
          Ok(MetricRequest(..req, flush_interval: "1h"))
        }
      }
    }
    _ -> Ok(req)
    // Non-billing metrics can use any interval
  }
}

// ============================================================================
// REGISTRY HELPERS
// ============================================================================

fn get_application_actor() -> Result(
  process.Subject(application_types.ApplicationMessage),
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

// In metric_handler.gleam  
pub fn create_metric(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  // Parse scope from query parameters
  let scope_str = case wisp.get_query(req) |> list.key_find("scope") {
    Ok(s) -> s
    Error(_) -> "business"
  }

  let customer_id = case wisp.get_query(req) |> list.key_find("customer_id") {
    Ok(cid) -> Some(cid)
    Error(_) -> None
  }

  let result = {
    use metric_req <- result.try(decode.run(json_data, metric_request_decoder()))
    use validated_req <- result.try(validate_metric_request(metric_req))

    // Route based on scope using your existing infrastructure
    case metric_types.string_to_scope(scope_str, business_id, customer_id) {
      Ok(metric_types.Business(_)) ->
        Ok(process_create_metric(business_id, validated_req))
      Ok(metric_types.Customer(_, cid)) ->
        Ok(process_create_client_metric(business_id, cid, validated_req))
      Error(error) -> Error([decode.DecodeError("Invalid", error, [])])
    }
  }
  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[MetricHandler] Validation failed: " <> string.inspect(decode_errors),
      )

      // NEW: Format detailed error message
      let #(error_message, error_details) = format_decode_errors(decode_errors)
      let error_json =
        json.object([
          #("error", json.string("Validation Failed")),
          #("message", json.string(error_message)),
          #("details", json.object(error_details)),
          #("received_data", json.string(string.inspect(json_data))),
          // Show what was received
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

// NEW: Helper function to format decode errors
fn format_decode_errors(
  decode_errors: List(decode.DecodeError),
) -> #(String, List(#(String, json.Json))) {
  case decode_errors {
    [decode.DecodeError(expected, reason, path)] -> {
      let field_path = case path {
        [] -> "root"
        path -> string.join(path, ".")
      }

      case expected, reason {
        "String", "field not found" -> #(
          "Missing required field: " <> field_path,
          [
            #("field", json.string(field_path)),
            #("error_type", json.string("missing_field")),
          ],
        )

        "String", reason -> #(
          "Invalid value for field '" <> field_path <> "': " <> reason,
          [
            #("field", json.string(field_path)),
            #("error_type", json.string("invalid_value")),
            #("reason", json.string(reason)),
          ],
        )

        expected, "variant not found" -> #(
          "Invalid enum value for '"
            <> field_path
            <> "'. Expected: "
            <> expected,
          [
            #("field", json.string(field_path)),
            #("error_type", json.string("invalid_enum")),
            #("expected_type", json.string(expected)),
            #("valid_options", get_valid_options_for_field(field_path)),
          ],
        )

        _, _ -> #(
          "Validation error in field '"
            <> field_path
            <> "': expected "
            <> expected
            <> ", "
            <> reason,
          [
            #("field", json.string(field_path)),
            #("error_type", json.string("validation_error")),
            #("expected", json.string(expected)),
            #("reason", json.string(reason)),
          ],
        )
      }
    }
    [] -> #("Unknown validation error", [
      #("error_type", json.string("unknown")),
    ])

    multiple_errors -> {
      let error_count = list.length(multiple_errors)
      #(
        "Multiple validation errors ("
          <> int.to_string(error_count)
          <> " total)",
        [
          #("error_count", json.int(error_count)),
          #(
            "errors",
            json.array(
              from: list.map(multiple_errors, fn(err) {
                json.string(string.inspect(err))
              }),
              of: fn(x) { x },
            ),
          ),
        ],
      )
    }
  }
}

// NEW: Helper to provide valid options for enum fields
fn get_valid_options_for_field(field_path: String) -> json.Json {
  case field_path {
    "metric_type" ->
      json.array(
        from: ["reset", "checkpoint", "stripe_billing"],
        of: json.string,
      )
    "operation" ->
      json.array(from: ["SUM", "COUNT", "MAX", "MIN", "AVG"], of: json.string)
    _ -> json.null()
  }
}

pub fn get_metric(req: Request, metric_name: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 GET START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Get)
  use key_validation <- with_auth_typed(req)

  let scope_str = case wisp.get_query(req) |> list.key_find("scope") {
    Ok(s) -> s
    Error(_) -> "business"
  }

  let customer_id_opt = case
    wisp.get_query(req) |> list.key_find("customer_id")
  {
    Ok(cid) -> Some(cid)
    Error(_) -> None
  }

  case key_validation {
    supabase_client.CustomerKey(business_id, customer_id) -> {
      // Customers can only read their own customer-scoped metrics
      case scope_str, customer_id_opt {
        "customer", Some(cid) if cid == customer_id -> {
          let lookup_key = business_id <> ":" <> customer_id
          case metric_store.get_value(lookup_key, metric_name) {
            Ok(value) ->
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("metric_name", json.string(metric_name)),
                    #("business_id", json.string(business_id)),
                    #("customer_id", json.string(customer_id)),
                    #("current_value", json.float(value)),
                    #("timestamp", json.int(utils.current_timestamp())),
                  ]),
                ),
                200,
              )
            Error(_) ->
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("error", json.string("Not Found")),
                    #(
                      "message",
                      json.string("Metric not found: " <> metric_name),
                    ),
                  ]),
                ),
                404,
              )
          }
        }
        _, _ -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Forbidden")),
                #(
                  "message",
                  json.string("Customers can only read their own metrics"),
                ),
              ]),
            ),
            403,
          )
        }
      }
    }

    supabase_client.BusinessKey(business_id) -> {
      // Businesses can read any metric in their scope
      case
        metric_types.string_to_scope(scope_str, business_id, customer_id_opt)
      {
        Ok(scope) -> {
          let lookup_key = metric_types.scope_to_lookup_key(scope)
          case metric_store.get_value(lookup_key, metric_name) {
            Ok(value) ->
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("metric_name", json.string(metric_name)),
                    #("business_id", json.string(business_id)),
                    #("current_value", json.float(value)),
                    #("timestamp", json.int(utils.current_timestamp())),
                  ]),
                ),
                200,
              )
            Error(_) ->
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("error", json.string("Not Found")),
                    #(
                      "message",
                      json.string("Metric not found: " <> metric_name),
                    ),
                  ]),
                ),
                404,
              )
          }
        }
        Error(error) ->
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Invalid Scope")),
                #("message", json.string(error)),
              ]),
            ),
            400,
          )
      }
    }
  }
}

pub fn update_metric(req: Request, metric_name: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔄 UPDATE START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use <- wisp.require_method(req, http.Put)
  use key_validation <- with_auth_typed(req)

  case key_validation {
    supabase_client.CustomerKey(_, _) -> {
      logging.log(
        logging.Warning,
        "[MetricHandler] Customer attempted direct metric update - denied",
      )
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Forbidden")),
            #(
              "message",
              json.string(
                "Customers cannot update metrics directly. Use the proxy endpoint.",
              ),
            ),
          ]),
        ),
        403,
      )
    }

    supabase_client.BusinessKey(business_id) -> {
      let scope_str = case wisp.get_query(req) |> list.key_find("scope") {
        Ok(s) -> s
        Error(_) -> "business"
      }

      let customer_id_opt = case
        wisp.get_query(req) |> list.key_find("customer_id")
      {
        Ok(cid) -> Some(cid)
        Error(_) -> None
      }

      let lookup_key = case
        metric_types.string_to_scope(scope_str, business_id, customer_id_opt)
      {
        Ok(scope) -> metric_types.scope_to_lookup_key(scope)
        Error(_) -> business_id
      }

      use json_data <- wisp.require_json(req)

      let result = {
        use update_req <- result.try(decode.run(
          json_data,
          update_metric_request_decoder(),
        ))
        Ok(process_update_metric(
          lookup_key,
          business_id,
          metric_name,
          update_req.value,
        ))
      }

      logging.log(
        logging.Info,
        "[MetricHandler] 🔄 UPDATE END - ID: " <> request_id,
      )

      case result {
        Ok(response) -> response
        Error(_) ->
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Bad Request")),
                #("message", json.string("Invalid update data")),
              ]),
            ),
            400,
          )
      }
    }
  }
}

pub fn delete_metric(req: Request, metric_name: String) -> Response {
  use <- wisp.require_method(req, http.Delete)

  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 DELETE REQUEST START - ID: "
      <> request_id
      <> " metric: "
      <> metric_name,
  )

  use business_id <- with_auth(req)

  // Parse query params for scope
  let query = wisp.get_query(req)
  let scope = case list.key_find(query, "scope") {
    Ok(s) -> s
    Error(_) -> "business"
  }
  let customer_id = case list.key_find(query, "customer_id") {
    Ok(cid) -> Some(cid)
    Error(_) -> None
  }

  // Construct proper registry key based on scope
  let registry_key = case scope, customer_id {
    "customer", Some(cid) -> business_id <> ":" <> cid <> "_" <> metric_name
    _, _ -> business_id <> "_" <> metric_name
  }

  logging.log(
    logging.Info,
    "[MetricHandler] 🔍 Deleting metric with registry key: " <> registry_key,
  )

  case glixir.lookup_subject_string(utils.tracktags_registry(), registry_key) {
    Ok(metric_subject) -> {
      process.send(metric_subject, metric_types.Shutdown)

      // Give it a moment to shut down
      process.sleep(100)

      logging.log(
        logging.Info,
        "[MetricHandler] ✅ Deleted metric: " <> metric_name,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("status", json.string("deleted")),
            #("metric_name", json.string(metric_name)),
            #("business_id", json.string(business_id)),
          ]),
        ),
        200,
      )
    }
    Error(_) -> {
      logging.log(
        logging.Warning,
        "[MetricHandler] Delete failed - metric not found: " <> metric_name,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Metric not found: " <> metric_name)),
          ]),
        ),
        404,
      )
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
  let limit_value = req.limit_value
  let limit_operator = req.limit_operator
  let breach_action = req.breach_action

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
        application_types.SendMetricToBusiness(
          business_id: business_id,
          metric_name: req.metric_name,
          tick_type: tick_type,
          operation: req.operation,
          cleanup_after_seconds: cleanup_seconds,
          metric_type: metric_type,
          initial_value: initial_value,
          tags: req.tags,
          metadata: req.metadata,
          limit_value: limit_value,
          limit_operator: limit_operator,
          breach_action: breach_action,
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
        metric_types.Metric(
          account_id: lookup_key,
          // ✅ FIXED: Use lookup_key for account_id
          metric_name: metric_name,
          value: new_value,
          tags: dict.new(),
          timestamp: utils.current_timestamp(),
        )

      process.send(metric_subject, metric_types.RecordMetric(metric))

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
  customer_id: String,
  req: MetricRequest,
) -> Response {
  case
    create_client_metric_internal(
      business_id,
      customer_id,
      req.metric_name,
      req.operation,
      req.flush_interval,
      req.cleanup_after,
      req.metric_type,
      req.initial_value,
      req.tags,
      req.metadata,
      req.limit_value,
      req.limit_operator,
      req.breach_action,
    )
  {
    Ok(_) -> {
      let success_json =
        json.object([
          #("status", json.string("created")),
          #("business_id", json.string(business_id)),
          #("customer_id", json.string(customer_id)),
          #("metric_name", json.string(req.metric_name)),
          #("operation", json.string(req.operation)),
          #("flush_interval", json.string(req.flush_interval)),
          #("cleanup_after", json.string(req.cleanup_after)),
          #("metric_type", json.string(req.metric_type)),
          #("initial_value", json.float(req.initial_value)),
        ])
      wisp.json_response(json.to_string_tree(success_json), 201)
    }
    Error(error) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string(error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

// NEW: Internal function for proxy_handler to use
pub fn create_client_metric_internal(
  business_id: String,
  customer_id: String,
  metric_name: String,
  operation: String,
  flush_interval: String,
  cleanup_after: String,
  metric_type: String,
  initial_value: Float,
  tags: Dict(String, String),
  metadata: Option(MetricMetadata),
  limit_value: Float,
  limit_operator: String,
  breach_action: String,
) -> Result(Nil, String) {
  let metric_type_parsed = metric_types.string_to_metric_type(metric_type)
  let tick_type = interval_to_tick_type(flush_interval)
  let cleanup_seconds = cleanup_to_seconds(cleanup_after)

  case get_application_actor() {
    Ok(app_actor) -> {
      process.send(
        app_actor,
        application_types.SendMetricToCustomer(
          business_id: business_id,
          customer_id: customer_id,
          metric_name: metric_name,
          tick_type: tick_type,
          operation: operation,
          cleanup_after_seconds: cleanup_seconds,
          metric_type: metric_type_parsed,
          initial_value: initial_value,
          tags: tags,
          metadata: metadata,
          limit_value: limit_value,
          limit_operator: limit_operator,
          breach_action: breach_action,
        ),
      )
      Ok(Nil)
    }
    Error(error) -> Error("Failed to get application actor: " <> error)
  }
}
