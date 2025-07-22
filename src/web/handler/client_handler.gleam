// src/web/handler/client_handler.gleam
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

pub type ClientRequest {
  ClientRequest(
    client_id: String,
    name: String,
    description: String,
    plan_id: String,
  )
}

pub type ClientKeyRequest {
  ClientKeyRequest(
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
      logging.log(logging.Warning, "[ClientHandler] Auth failed: " <> error)
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
            "[ClientHandler] ✅ API key validated for business: " <> business_id,
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

// ============================================================================
// JSON DECODERS
// ============================================================================

fn client_request_decoder() -> decode.Decoder(ClientRequest) {
  use client_id <- decode.field("client_id", decode.string)
  use plan_id <- decode.field("plan_id", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)

  decode.success(ClientRequest(
    client_id: client_id,
    name: name,
    description: description,
    plan_id: plan_id,
  ))
}

fn client_key_request_decoder() -> decode.Decoder(ClientKeyRequest) {
  use external_key <- decode.field("external_key", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use permissions <- decode.optional_field(
    "permissions",
    ["metrics.read", "metrics.write"],
    decode.list(decode.string),
  )

  decode.success(ClientKeyRequest(
    external_key: external_key,
    name: name,
    description: description,
    permissions: permissions,
  ))
}

// ============================================================================
// VALIDATION
// ============================================================================

fn validate_client_request(
  req: ClientRequest,
) -> Result(ClientRequest, List(decode.DecodeError)) {
  // Validate client_id
  case string.length(req.client_id) {
    0 -> Error([decode.DecodeError("Invalid", "client_id cannot be empty", [])])
    n if n > 100 ->
      Error([
        decode.DecodeError("Invalid", "client_id too long (max 100 chars)", []),
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

pub fn create_client(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[ClientHandler] 🔍 CREATE CLIENT REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use client_req <- result.try(decode.run(json_data, client_request_decoder()))
    use validated_req <- result.try(validate_client_request(client_req))
    Ok(process_create_client(business_id, validated_req))
  }

  logging.log(
    logging.Info,
    "[ClientHandler] 🔍 CREATE CLIENT REQUEST END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[ClientHandler] Bad request: " <> string.inspect(decode_errors),
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

pub fn list_clients(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[ClientHandler] 🔍 LIST CLIENTS REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[ClientHandler] 📋 Listing clients for business: " <> business_id,
  )

  case supabase_client.get_business_clients(business_id) {
    Ok(clients) -> {
      let response_data =
        clients
        |> list.map(fn(client) {
          json.object([
            #("client_id", json.string(client.client_id)),
            #("client_name", json.string(client.client_name)),
            #("plan_id", case client.plan_id {
              Some(pid) -> json.string(pid)
              None -> json.null()
            }),
          ])
        })
        |> json.array(from: _, of: fn(item) { item })

      let success_json =
        json.object([
          #("clients", response_data),
          #("count", json.int(list.length(clients))),
          #("business_id", json.string(business_id)),
        ])

      logging.log(
        logging.Info,
        "[ClientHandler] 🔍 LIST CLIENTS REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch clients")),
        ])
      logging.log(
        logging.Info,
        "[ClientHandler] 🔍 LIST CLIENTS REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

pub fn get_client(req: Request, client_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[ClientHandler] 🔍 GET CLIENT REQUEST START - ID: "
      <> request_id
      <> " client: "
      <> client_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[ClientHandler] 🔍 Getting client: " <> business_id <> "/" <> client_id,
  )

  case supabase_client.get_client_by_id(business_id, client_id) {
    Ok(client) -> {
      logging.log(
        logging.Info,
        "[ClientHandler] 🔍 GET CLIENT REQUEST END - ID: " <> request_id,
      )

      let success_json =
        json.object([
          #("client_id", json.string(client.client_id)),
          #("client_name", json.string(client.client_name)),
          #("plan_id", case client.plan_id {
            Some(pid) -> json.string(pid)
            None -> json.null()
          }),
        ])
      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      logging.log(
        logging.Info,
        "[ClientHandler] 🔍 GET CLIENT REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Client not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[ClientHandler] 🔍 GET CLIENT REQUEST END - ID: " <> request_id,
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

pub fn delete_client(req: Request, client_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[ClientHandler] 🔍 DELETE CLIENT REQUEST START - ID: "
      <> request_id
      <> " client: "
      <> client_id,
  )

  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[ClientHandler] 🗑️ Deleting client: " <> business_id <> "/" <> client_id,
  )

  let success_json =
    json.object([
      #("message", json.string("Delete client - LOGGED")),
      #("business_id", json.string(business_id)),
      #("client_id", json.string(client_id)),
    ])

  logging.log(
    logging.Info,
    "[ClientHandler] 🔍 DELETE CLIENT REQUEST END - ID: " <> request_id,
  )

  wisp.json_response(json.to_string_tree(success_json), 200)
}

// ============================================================================
// PROCESSING FUNCTIONS
// ============================================================================

fn process_create_client(business_id: String, req: ClientRequest) -> Response {
  logging.log(
    logging.Info,
    "[ClientHandler] 🏗️ Processing CREATE client: "
      <> business_id
      <> "/"
      <> req.client_id
      <> " (name: "
      <> req.name
      <> ")",
  )

  // Actually create the client in the database
  case
    supabase_client.create_client(
      business_id,
      req.client_id,
      req.name,
      req.plan_id,
    )
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[ClientHandler] ✅ Client created successfully in database",
      )

      let success_json =
        json.object([
          #("status", json.string("created")),
          #("business_id", json.string(business_id)),
          #("client_id", json.string(req.client_id)),
          #("name", json.string(req.name)),
          #("description", json.string(req.description)),
          #("timestamp", json.int(utils.current_timestamp())),
        ])

      wisp.json_response(json.to_string_tree(success_json), 201)
    }
    Error(supabase_client.DatabaseError(msg)) -> {
      logging.log(
        logging.Error,
        "[ClientHandler] ❌ Failed to create client: " <> msg,
      )

      let error_json =
        json.object([
          #("error", json.string("Database Error")),
          #("message", json.string("Failed to create client: " <> msg)),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[ClientHandler] ❌ Failed to create client: " <> string.inspect(error),
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

pub fn create_client_key(req: Request, client_id: String) -> Response {
  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[ClientHandler] Creating key for client: " <> client_id,
  )

  let success_json =
    json.object([
      #("message", json.string("Create client key - LOGGED")),
      #("business_id", json.string(business_id)),
      #("client_id", json.string(client_id)),
    ])

  wisp.json_response(json.to_string_tree(success_json), 201)
}

pub fn list_client_keys(req: Request, client_id: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[ClientHandler] Listing keys for client: " <> client_id,
  )

  let success_json =
    json.object([
      #("message", json.string("List client keys - LOGGED")),
      #("business_id", json.string(business_id)),
      #("client_id", json.string(client_id)),
    ])

  wisp.json_response(json.to_string_tree(success_json), 200)
}

pub fn delete_client_key(
  req: Request,
  client_id: String,
  key_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[ClientHandler] Deleting key: " <> key_id <> " for client: " <> client_id,
  )

  let success_json =
    json.object([
      #("message", json.string("Delete client key - LOGGED")),
      #("business_id", json.string(business_id)),
      #("client_id", json.string(client_id)),
      #("key_id", json.string(key_id)),
    ])

  wisp.json_response(json.to_string_tree(success_json), 200)
}
