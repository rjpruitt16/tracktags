// src/web/handler/plan_limit_handler.gleam
import clients/supabase_client
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import types/customer_types
import utils/auth
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================

pub type CreatePlanRequest {
  CreatePlanRequest(plan_name: String, stripe_price_id: option.Option(String))
}

pub type PlanLimitRequest {
  PlanLimitRequest(
    metric_name: String,
    limit_value: Float,
    limit_period: String,
    breach_operator: String,
    breach_action: String,
    webhook_urls: option.Option(String),
    customer_id: option.Option(String),
    plan_id: option.Option(String),
    metric_type: String,
  )
}

// ============================================================================
// CONSTANTS
// ============================================================================

const valid_periods = ["daily", "monthly", "yearly", "realtime"]

const valid_operators = ["gt", "gte", "lt", "lte", "eq"]

const valid_actions = ["deny", "allow_overage", "webhook", "scale", "allow"]

// ============================================================================
// AUTHENTICATION
// ============================================================================

fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  auth.with_auth(req, fn(auth_result, api_key, is_admin) {
    case auth_result {
      auth.ActorCached(auth.BusinessActor(business_id, _)) ->
        handler(business_id)

      auth.DatabaseValid(supabase_client.BusinessKey(business_id)) -> {
        case is_admin {
          True -> {
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("error", json.string("Forbidden")),
                  #("message", json.string("Admin key cannot manage plans")),
                ]),
              ),
              403,
            )
          }
          False -> {
            let _ = auth.ensure_actor_from_auth(auth_result, api_key)
            handler(business_id)
          }
        }
      }

      auth.ActorCached(auth.CustomerActor(_, _, _)) -> {
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Forbidden")),
              #("message", json.string("Customer keys cannot access plans")),
            ]),
          ),
          403,
        )
      }

      auth.DatabaseValid(supabase_client.CustomerKey(_, _)) -> {
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Forbidden")),
              #("message", json.string("Customer keys cannot access plans")),
            ]),
          ),
          403,
        )
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

// ============================================================================
// JSON DECODERS
// ============================================================================

fn plan_request_decoder() -> decode.Decoder(CreatePlanRequest) {
  use plan_name <- decode.field("plan_name", decode.string)
  use stripe_price_id <- decode.optional_field(
    "stripe_price_id",
    None,
    decode.optional(decode.string),
  )

  decode.success(CreatePlanRequest(
    plan_name: plan_name,
    stripe_price_id: stripe_price_id,
  ))
}

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
  use plan_id <- decode.optional_field(
    "plan_id",
    None,
    decode.optional(decode.string),
  )
  // ← ADD
  use metric_type <- decode.optional_field(
    "metric_type",
    "reset",
    decode.string,
  )
  // ← ADD

  decode.success(PlanLimitRequest(
    metric_name: metric_name,
    limit_value: limit_value,
    limit_period: limit_period,
    breach_operator: breach_operator,
    breach_action: breach_action,
    webhook_urls: webhook_urls,
    customer_id: customer_id,
    plan_id: plan_id,
    // ← ADD
    metric_type: metric_type,
    // ← ADD
  ))
}

// ============================================================================
// VALIDATION
// ============================================================================

fn validate_limit_request(
  req: PlanLimitRequest,
) -> Result(PlanLimitRequest, List(decode.DecodeError)) {
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
    case req.limit_value >=. 0.0 {
      False ->
        Error([decode.DecodeError("Invalid", "limit_value must be >= 0", [])])
      True -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
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
// PLAN CRUD ENDPOINTS
// ============================================================================

/// CREATE - POST /api/v1/plans
pub fn create_plan(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  case decode.run(json_data, plan_request_decoder()) {
    Ok(plan_req) -> {
      case
        supabase_client.create_plan(
          business_id,
          plan_req.plan_name,
          plan_req.stripe_price_id,
        )
      {
        Ok(plan) -> {
          let success_json =
            json.object([
              #("status", json.string("created")),
              #("id", json.string(plan.id)),
              #("plan_name", json.string(plan.plan_name)),
              #("stripe_price_id", case plan.stripe_price_id {
                Some(id) -> json.string(id)
                None -> json.null()
              }),
            ])
          wisp.json_response(json.to_string_tree(success_json), 201)
        }
        Error(_) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Internal Server Error")),
                #("message", json.string("Failed to create plan")),
              ]),
            ),
            500,
          )
        }
      }
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string("Invalid plan data")),
          ]),
        ),
        400,
      )
    }
  }
}

/// READ - GET /api/v1/plans
pub fn list_plans(req: Request) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  case supabase_client.get_plans_for_business(business_id) {
    Ok(plans) -> {
      let plans_json =
        plans
        |> list.map(fn(plan) {
          json.object([
            #("id", json.string(plan.id)),
            #("plan_name", json.string(plan.plan_name)),
            #("stripe_price_id", case plan.stripe_price_id {
              Some(id) -> json.string(id)
              None -> json.null()
            }),
            #("created_at", json.string(plan.created_at)),
          ])
        })
        |> json.array(from: _, of: fn(x) { x })

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("plans", plans_json),
            #("count", json.int(list.length(plans))),
          ]),
        ),
        200,
      )
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Internal Server Error")),
            #("message", json.string("Failed to fetch plans")),
          ]),
        ),
        500,
      )
    }
  }
}

/// DELETE - DELETE /api/v1/plans/:id
pub fn delete_plan(req: Request, plan_id: String) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  case supabase_client.delete_plan(business_id, plan_id) {
    Ok(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("status", json.string("deleted")),
            #("plan_id", json.string(plan_id)),
          ]),
        ),
        200,
      )
    }
    Error(supabase_client.NotFound(_)) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Plan not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Internal Server Error")),
            #("message", json.string("Failed to delete plan")),
          ]),
        ),
        500,
      )
    }
  }
}

// ============================================================================
// PLAN LIMIT CRUD ENDPOINTS
// ============================================================================

/// CREATE - POST /api/v1/plan_limits
pub fn create_plan_limit(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use limit_req <- result.try(
      decode.run(json_data, limit_request_decoder())
      |> result.map_error(fn(errors) {
        let error_messages =
          list.map(errors, fn(err) {
            "Field: "
            <> string.join(err.path, ".")
            <> " - "
            <> err.expected
            <> " (got: "
            <> err.found
            <> ")"
          })
          |> string.join(", ")

        logging.log(
          logging.Error,
          "[PlanLimitHandler] Decode error: " <> error_messages,
        )
        error_messages
      }),
    )

    use validated_req <- result.try(
      validate_limit_request(limit_req)
      |> result.map_error(fn(errors) {
        let error_messages =
          list.map(errors, fn(err) { err.expected })
          |> string.join(", ")

        logging.log(
          logging.Error,
          "[PlanLimitHandler] Validation error: " <> error_messages,
        )
        error_messages
      }),
    )

    Ok(process_create_plan_limit(business_id, validated_req))
  }

  case result {
    Ok(response) -> response
    Error(error_msg) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string("Invalid plan limit data")),
            #("details", json.string(error_msg)),
          ]),
        ),
        400,
      )
    }
  }
}

/// READ - GET /api/v1/plan_limits
pub fn list_plan_limits(req: Request) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  case supabase_client.get_business_plan_limits(business_id) {
    Ok(limits) -> {
      let response_data =
        limits
        |> list.map(limit_to_json)
        |> json.array(from: _, of: fn(item) { item })

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("plan_limits", response_data),
            #("count", json.int(list.length(limits))),
          ]),
        ),
        200,
      )
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Internal Server Error")),
            #("message", json.string("Failed to fetch plan limits")),
          ]),
        ),
        500,
      )
    }
  }
}

/// READ - GET /api/v1/plan_limits/:id
pub fn get_plan_limit(req: Request, limit_id: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  case supabase_client.get_plan_limit_by_id(business_id, limit_id) {
    Ok(limit) -> {
      wisp.json_response(json.to_string_tree(limit_to_json(limit)), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Plan limit not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Internal Server Error")),
            #("message", json.string("Failed to fetch plan limit")),
          ]),
        ),
        500,
      )
    }
  }
}

/// UPDATE - PUT /api/v1/plan_limits/:id
pub fn update_plan_limit(req: Request, limit_id: String) -> Response {
  use <- wisp.require_method(req, http.Put)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use limit_req <- result.try(decode.run(json_data, limit_request_decoder()))
    use validated_req <- result.try(validate_limit_request(limit_req))
    Ok(process_update_plan_limit(business_id, limit_id, validated_req))
  }

  case result {
    Ok(response) -> response
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string("Invalid plan limit data")),
          ]),
        ),
        400,
      )
    }
  }
}

/// DELETE - DELETE /api/v1/plan_limits/:id
pub fn delete_plan_limit(req: Request, limit_id: String) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  case supabase_client.delete_plan_limit(business_id, limit_id) {
    Ok(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("message", json.string("Plan limit deleted successfully")),
            #("limit_id", json.string(limit_id)),
          ]),
        ),
        200,
      )
    }
    Error(supabase_client.NotFound(_)) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Plan limit not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Internal Server Error")),
            #("message", json.string("Failed to delete plan limit")),
          ]),
        ),
        500,
      )
    }
  }
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

// In plan_handler.gleam - update process_create_plan_limit
fn process_create_plan_limit(
  business_id: String,
  req: PlanLimitRequest,
) -> Response {
  // Check if this is a plan-level or business-level limit
  case req.plan_id {
    Some(plan_id) -> {
      // Plan-level limit
      case
        supabase_client.create_plan_limit(
          business_id,
          plan_id,
          req.metric_name,
          req.limit_value,
          req.breach_operator,
          req.breach_action,
          req.webhook_urls,
          req.metric_type,
        )
      {
        Ok(limit) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("status", json.string("created")),
                #("id", json.string(limit.id)),
                #("metric_name", json.string(req.metric_name)),
                #("limit_value", json.float(req.limit_value)),
              ]),
            ),
            201,
          )
        }
        Error(_) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Internal Server Error")),
                #("message", json.string("Failed to create plan limit")),
              ]),
            ),
            500,
          )
        }
      }
    }
    None -> {
      // Business-level limit
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
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("status", json.string("created")),
                #("id", json.string(limit.id)),
                #("metric_name", json.string(req.metric_name)),
                #("limit_value", json.float(req.limit_value)),
              ]),
            ),
            201,
          )
        }
        Error(_) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Internal Server Error")),
                #("message", json.string("Failed to create plan limit")),
              ]),
            ),
            500,
          )
        }
      }
    }
  }
}

fn process_update_plan_limit(
  business_id: String,
  limit_id: String,
  req: PlanLimitRequest,
) -> Response {
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
      wisp.json_response(json.to_string_tree(limit_to_json(limit)), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Plan limit not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Internal Server Error")),
            #("message", json.string("Failed to update plan limit")),
          ]),
        ),
        500,
      )
    }
  }
}

fn limit_to_json(limit: customer_types.PlanLimit) -> json.Json {
  json.object([
    #("id", json.string(limit.id)),
    #("metric_name", json.string(limit.metric_name)),
    #("limit_value", json.float(limit.limit_value)),
    #("breach_operator", json.string(limit.breach_operator)),
    #("breach_action", json.string(limit.breach_action)),
    #("webhook_urls", case limit.webhook_urls {
      Some(urls) -> json.string(urls)
      None -> json.null()
    }),
    #("created_at", json.string(limit.created_at)),
  ])
}
