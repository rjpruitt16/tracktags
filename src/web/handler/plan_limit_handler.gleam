// src/web/handler/limit_handler.gleam
import clients/supabase_client
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import utils/utils
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================

pub type PlanLimitRequest {
  PlanLimitRequest(
    metric_name: String,
    limit_value: Float,
    limit_period: String,
    breach_operator: String,
    breach_action: String,
    webhook_urls: option.Option(String),
    customer_id: option.Option(String),
  )
}

pub type PlanLimitResponse {
  PlanLimitResponse(
    id: String,
    metric_name: String,
    limit_value: Float,
    limit_period: String,
    breach_operator: String,
    breach_action: String,
    webhook_urls: option.Option(String),
    created_at: String,
  )
}

// ============================================================================
// CONSTANTS
// ============================================================================

const valid_periods = ["daily", "monthly", "yearly", "realtime"]

const valid_operators = ["gt", "gte", "lt", "lte", "eq"]

const valid_actions = ["deny", "allow_overage", "webhook", "scale"]

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

fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  case extract_api_key(req) {
    Error(error) -> {
      logging.log(logging.Warning, "[PlanLimitHandler] Auth failed: " <> error)
      let error_json =
        json.object([
          #("error", json.string("Unauthorized")),
          #("message", json.string(error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 401)
    }
    Ok(api_key) -> {
      case supabase_client.validate_api_key(api_key) {
        Ok(supabase_client.BusinessKey(business_id)) -> {
          logging.log(
            logging.Info,
            "[PlanLimitHandler] ✅ API key validated for business: "
              <> business_id,
          )
          handler(business_id)
        }
        Ok(supabase_client.CustomerKey(business_id, _)) -> {
          logging.log(
            logging.Warning,
            "[PlanLimitHandler] Customer key cannot manage plan limits for business: "
              <> business_id,
          )
          let error_json =
            json.object([
              #("error", json.string("Forbidden")),
              #(
                "message",
                json.string("Customer keys cannot manage plan limits"),
              ),
            ])
          wisp.json_response(json.to_string_tree(error_json), 403)
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

// ============================================================================
// JSON DECODERS
// ============================================================================

fn limit_request_decoder() -> decode.Decoder(PlanLimitRequest) {
  use metric_name <- decode.field("metric_name", decode.string)
  use limit_value <- decode.field("limit_value", decode.float)
  use limit_period <- decode.optional_field(
    "limit_period",
    "monthly",
    decode.string,
  )
  use breach_operator <- decode.optional_field(
    "breach_operator",
    "gte",
    decode.string,
  )
  use breach_action <- decode.optional_field(
    "breach_action",
    "deny",
    decode.string,
  )
  use webhook_urls <- decode.optional_field(
    "webhook_urls",
    None,
    decode.optional(decode.string),
  )

  use customer_id <- decode.optional_field(
    "customer_id",
    None,
    decode.optional(decode.string),
  )

  decode.success(PlanLimitRequest(
    metric_name: metric_name,
    limit_value: limit_value,
    limit_period: limit_period,
    breach_operator: breach_operator,
    breach_action: breach_action,
    webhook_urls: webhook_urls,
    customer_id: customer_id,
  ))
}

// ============================================================================
// VALIDATION
// ============================================================================

fn validate_limit_request(
  req: PlanLimitRequest,
) -> Result(PlanLimitRequest, List(decode.DecodeError)) {
  // Validate metric_name
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
    // Validate limit_value
    case req.limit_value >=. 0.0 {
      False ->
        Error([decode.DecodeError("Invalid", "limit_value must be >= 0", [])])
      True -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate limit_period
    case list.contains(valid_periods, req.limit_period) {
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "limit_period must be one of: " <> string.join(valid_periods, ", "),
            [],
          ),
        ])
      True -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate breach_operator
    case list.contains(valid_operators, req.breach_operator) {
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "breach_operator must be one of: "
              <> string.join(valid_operators, ", "),
            [],
          ),
        ])
      True -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate breach_action
    case list.contains(valid_actions, req.breach_action) {
      False ->
        Error([
          decode.DecodeError(
            "Invalid",
            "breach_action must be one of: " <> string.join(valid_actions, ", "),
            [],
          ),
        ])
      True -> Ok(req)
    }
  })
}

// ============================================================================
// CRUD ENDPOINTS
// ============================================================================

/// CREATE - POST /api/v1/plan_limits
pub fn create_plan_limit(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔍 CREATE PLAN LIMIT START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use limit_req <- result.try(decode.run(json_data, limit_request_decoder()))
    use validated_req <- result.try(validate_limit_request(limit_req))
    Ok(process_create_plan_limit(business_id, validated_req))
  }

  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔍 CREATE PLAN LIMIT END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[PlanLimitHandler] Bad request: " <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid plan limit data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

/// READ - GET /api/v1/plan_limits
pub fn list_plan_limits(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔍 LIST PLAN LIMITS START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  case supabase_client.get_business_plan_limits(business_id) {
    Ok(limits) -> {
      let response_data =
        limits
        |> list.map(limit_to_json)
        |> json.array(from: _, of: fn(item) { item })

      let success_json =
        json.object([
          #("plan_limits", response_data),
          #("count", json.int(list.length(limits))),
          #("business_id", json.string(business_id)),
        ])

      logging.log(
        logging.Info,
        "[PlanLimitHandler] ✅ Listed "
          <> string.inspect(list.length(limits))
          <> " plan limits",
      )

      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 LIST PLAN LIMITS END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch plan limits")),
        ])

      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 LIST PLAN LIMITS END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

/// READ - GET /api/v1/plan_limits/:id
pub fn get_plan_limit(req: Request, limit_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔍 GET PLAN LIMIT START - ID: "
      <> request_id
      <> " limit: "
      <> limit_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  case supabase_client.get_plan_limit_by_id(business_id, limit_id) {
    Ok(limit) -> {
      let success_json = limit_to_json(limit)
      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 GET PLAN LIMIT END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      let error_json =
        json.object([
          #("error", json.string("Not Found")),
          #("message", json.string("Plan limit not found")),
        ])
      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 GET PLAN LIMIT END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 404)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch plan limit")),
        ])
      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 GET PLAN LIMIT END - ID: " <> request_id,
      )
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

/// UPDATE - PUT /api/v1/plan_limits/:id
pub fn update_plan_limit(req: Request, limit_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔍 UPDATE PLAN LIMIT START - ID: "
      <> request_id
      <> " limit: "
      <> limit_id,
  )

  use <- wisp.require_method(req, http.Put)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use limit_req <- result.try(decode.run(json_data, limit_request_decoder()))
    use validated_req <- result.try(validate_limit_request(limit_req))
    Ok(process_update_plan_limit(business_id, limit_id, validated_req))
  }

  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔍 UPDATE PLAN LIMIT END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[PlanLimitHandler] Bad update request: "
          <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid plan limit data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

/// DELETE - DELETE /api/v1/plan_limits/:id
pub fn delete_plan_limit(req: Request, limit_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔍 DELETE PLAN LIMIT START - ID: "
      <> request_id
      <> " limit: "
      <> limit_id,
  )

  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  case supabase_client.delete_plan_limit(business_id, limit_id) {
    Ok(_) -> {
      let success_json =
        json.object([
          #("message", json.string("Plan limit deleted successfully")),
          #("limit_id", json.string(limit_id)),
          #("business_id", json.string(business_id)),
        ])

      logging.log(
        logging.Info,
        "[PlanLimitHandler] ✅ Deleted plan limit: " <> limit_id,
      )

      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 DELETE PLAN LIMIT END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      let error_json =
        json.object([
          #("error", json.string("Not Found")),
          #("message", json.string("Plan limit not found")),
        ])

      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 DELETE PLAN LIMIT END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 404)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to delete plan limit")),
        ])
      logging.log(
        logging.Info,
        "[PlanLimitHandler] 🔍 DELETE PLAN LIMIT END - ID: " <> request_id,
      )
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

// ============================================================================
// PROCESSING FUNCTIONS
// ============================================================================

fn process_create_plan_limit(
  business_id: String,
  req: PlanLimitRequest,
) -> Response {
  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🏗️ Processing CREATE plan limit: "
      <> business_id
      <> "/"
      <> req.metric_name
      <> " = "
      <> float.to_string(req.limit_value),
  )

  case
    supabase_client.create_business_plan_limit(
      business_id,
      req.metric_name,
      req.limit_value,
      req.limit_period,
      req.breach_operator,
      req.breach_action,
      req.webhook_urls,
    )
  {
    Ok(limit) -> {
      logging.log(
        logging.Info,
        "[PlanLimitHandler] ✅ Plan limit created successfully",
      )

      let success_json =
        json.object([
          #("status", json.string("created")),
          #("id", json.string(limit.id)),
          #("business_id", json.string(business_id)),
          #("metric_name", json.string(req.metric_name)),
          #("limit_value", json.float(req.limit_value)),
          #("limit_period", json.string(req.limit_period)),
          #("breach_operator", json.string(req.breach_operator)),
          #("breach_action", json.string(req.breach_action)),
          #("webhook_urls", case req.webhook_urls {
            Some(urls) -> json.string(urls)
            None -> json.null()
          }),
          #("timestamp", json.int(utils.current_timestamp())),
        ])

      wisp.json_response(json.to_string_tree(success_json), 201)
    }
    Error(supabase_client.DatabaseError(msg)) -> {
      logging.log(
        logging.Error,
        "[PlanLimitHandler] ❌ Failed to create plan limit: " <> msg,
      )

      let error_json =
        json.object([
          #("error", json.string("Database Error")),
          #("message", json.string("Failed to create plan limit: " <> msg)),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[PlanLimitHandler] ❌ Failed to create plan limit: "
          <> string.inspect(error),
      )

      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to create plan limit")),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

fn process_update_plan_limit(
  business_id: String,
  limit_id: String,
  req: PlanLimitRequest,
) -> Response {
  logging.log(
    logging.Info,
    "[PlanLimitHandler] 🔄 Processing UPDATE plan limit: " <> limit_id,
  )

  case
    supabase_client.update_business_plan_limit(
      business_id,
      limit_id,
      req.metric_name,
      req.limit_value,
      req.limit_period,
      req.breach_operator,
      req.breach_action,
      req.webhook_urls,
      req.customer_id,
    )
  {
    Ok(limit) -> {
      logging.log(
        logging.Info,
        "[PlanLimitHandler] ✅ Plan limit updated successfully",
      )

      let success_json = limit_to_json(limit)
      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      let error_json =
        json.object([
          #("error", json.string("Not Found")),
          #("message", json.string("Plan limit not found")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 404)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[PlanLimitHandler] ❌ Failed to update plan limit: "
          <> string.inspect(error),
      )

      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to update plan limit")),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

fn limit_to_json(limit: supabase_client.PlanLimit) -> json.Json {
  json.object([
    #("id", json.string(limit.id)),
    #("metric_name", json.string(limit.metric_name)),
    #("limit_value", json.float(limit.limit_value)),
    #("limit_period", json.string(limit.limit_period)),
    #("breach_operator", json.string(limit.breach_operator)),
    #("breach_action", json.string(limit.breach_action)),
    #("webhook_urls", case limit.webhook_urls {
      Some(urls) -> json.string(urls)
      None -> json.null()
    }),
    #("created_at", json.string(limit.created_at)),
  ])
}
