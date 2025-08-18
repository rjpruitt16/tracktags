// src/web/handler/customer_handler.gleam=
import clients/supabase_client
import gleam/dynamic/decode
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

pub type CustomerRequest {
  CustomerRequest(
    customer_id: String,
    name: String,
    description: String,
    plan_id: String,
  )
}

pub type CustomerKeyRequest {
  CustomerKeyRequest(
    external_key: String,
    name: String,
    description: String,
    permissions: List(String),
  )
}

// ============================================================================
// AUTHENTICATION (copied from metric_handler pattern)
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
      logging.log(logging.Warning, "[CustomerHandler] Auth failed: " <> error)
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
            "[CustomerHandler] ✅ API key validated for business: "
              <> business_id,
          )
          handler(business_id)
        }
        Ok(supabase_client.CustomerKey(business_id, _)) -> {
          logging.log(
            logging.Warning,
            "[CustomerHandler] Customer key cannot manage customers for business: "
              <> business_id,
          )
          let error_json =
            json.object([
              #("error", json.string("Forbidden")),
              #("message", json.string("Customer keys cannot manage customers")),
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

fn customer_request_decoder() -> decode.Decoder(CustomerRequest) {
  use customer_id <- decode.field("customer_id", decode.string)
  use plan_id <- decode.field("plan_id", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)

  decode.success(CustomerRequest(
    customer_id: customer_id,
    name: name,
    description: description,
    plan_id: plan_id,
  ))
}

// ============================================================================
// VALIDATION
// ============================================================================

fn validate_customer_request(
  req: CustomerRequest,
) -> Result(CustomerRequest, List(decode.DecodeError)) {
  // Validate customer_id
  case string.length(req.customer_id) {
    0 ->
      Error([decode.DecodeError("Invalid", "customer_id cannot be empty", [])])
    n if n > 100 ->
      Error([
        decode.DecodeError(
          "Invalid",
          "customer_id too long (max 100 chars)",
          [],
        ),
      ])
    _ -> Ok(Nil)
  }
  |> result.try(fn(_) {
    // Validate name length
    case string.length(req.name) > 200 {
      True ->
        Error([
          decode.DecodeError("Invalid", "name too long (max 200 chars)", []),
        ])
      False -> Ok(req)
    }
  })
}

// ============================================================================
// CRUD ENDPOINTS
// ============================================================================

pub fn create_customer(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 CREATE CUSTOMER REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use customer_req <- result.try(decode.run(
      json_data,
      customer_request_decoder(),
    ))
    use validated_req <- result.try(validate_customer_request(customer_req))
    Ok(process_create_customer(business_id, validated_req))
  }

  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 CREATE CUSTOMER REQUEST END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[CustomerHandler] Bad request: " <> string.inspect(decode_errors),
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

pub fn list_customers(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 LIST CUSTOMERS REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] 📋 Listing customers for business: " <> business_id,
  )

  case supabase_client.get_business_customers(business_id) {
    Ok(customers) -> {
      let response_data =
        customers
        |> list.map(fn(customer) {
          json.object([
            #("customer_id", json.string(customer.customer_id)),
            #("customer_name", json.string(customer.customer_name)),
            #("plan_id", case customer.plan_id {
              Some(pid) -> json.string(pid)
              None -> json.null()
            }),
          ])
        })
        |> json.array(from: _, of: fn(item) { item })

      let success_json =
        json.object([
          #("customers", response_data),
          #("count", json.int(list.length(customers))),
        ])

      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 LIST CUSTOMERS REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch customers")),
        ])
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 LIST CUSTOMERS REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

pub fn get_customer(req: Request, customer_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 GET CUSTOMER REQUEST START - ID: "
      <> request_id
      <> " customer: "
      <> customer_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 Getting customer: "
      <> business_id
      <> "/"
      <> customer_id,
  )

  case supabase_client.get_customer_by_id(business_id, customer_id) {
    Ok(customer) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 GET CUSTOMER REQUEST END - ID: " <> request_id,
      )

      let success_json =
        json.object([
          #("customer_id", json.string(customer.customer_id)),
          #("customer_name", json.string(customer.customer_name)),
          #("plan_id", case customer.plan_id {
            Some(pid) -> json.string(pid)
            None -> json.null()
          }),
        ])
      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 GET CUSTOMER REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Customer not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 GET CUSTOMER REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([#("error", json.string("Internal Server Error"))]),
        ),
        500,
      )
    }
  }
}

pub fn delete_customer(req: Request, customer_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 DELETE CUSTOMER REQUEST START - ID: "
      <> request_id
      <> " client: "
      <> customer_id,
  )

  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] 🗑️ Deleting customer: "
      <> business_id
      <> "/"
      <> customer_id,
  )

  let success_json =
    json.object([
      #("message", json.string("Delete customer - LOGGED")),
      #("business_id", json.string(business_id)),
      #("customer_id", json.string(customer_id)),
    ])

  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 DELETE CUSTOMER REQUEST END - ID: " <> request_id,
  )

  wisp.json_response(json.to_string_tree(success_json), 200)
}

// ============================================================================
// PROCESSING FUNCTIONS
// ============================================================================

fn process_create_customer(
  business_id: String,
  req: CustomerRequest,
) -> Response {
  logging.log(
    logging.Info,
    "[CustomerHandler] 🏗️ Processing CREATE customer: "
      <> business_id
      <> "/"
      <> req.customer_id
      <> " (name: "
      <> req.name
      <> ")",
  )

  // Actually create the client in the database
  case
    supabase_client.create_customer(
      business_id,
      req.customer_id,
      req.name,
      req.plan_id,
    )
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] ✅ Customer created successfully in database",
      )

      let success_json =
        json.object([
          #("status", json.string("created")),
          #("business_id", json.string(business_id)),
          #("customer_id", json.string(req.customer_id)),
          #("name", json.string(req.name)),
          #("description", json.string(req.description)),
          #("timestamp", json.int(utils.current_timestamp())),
        ])

      wisp.json_response(json.to_string_tree(success_json), 201)
    }
    Error(supabase_client.DatabaseError(msg)) -> {
      logging.log(
        logging.Error,
        "[CustomerHandler] ❌ Failed to create customer: " <> msg,
      )

      let error_json =
        json.object([
          #("error", json.string("Database Error")),
          #("message", json.string("Failed to create customer: " <> msg)),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[CustomerHandler] ❌ Failed to create customer: "
          <> string.inspect(error),
      )

      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to create client")),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

pub fn list_client_keys(req: Request, customer_id: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] Listing keys for customer: " <> customer_id,
  )

  let success_json =
    json.object([
      #("message", json.string("List customer keys - LOGGED")),
      #("business_id", json.string(business_id)),
      #("customer_id", json.string(customer_id)),
    ])

  wisp.json_response(json.to_string_tree(success_json), 200)
}

pub fn delete_client_key(
  req: Request,
  customer_id: String,
  key_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] Deleting key: "
      <> key_id
      <> " for customer: "
      <> customer_id,
  )

  let success_json =
    json.object([
      #("message", json.string("Delete customer key - LOGGED")),
      #("business_id", json.string(business_id)),
      #("customer_id", json.string(customer_id)),
      #("key_id", json.string(key_id)),
    ])

  wisp.json_response(json.to_string_tree(success_json), 200)
}
