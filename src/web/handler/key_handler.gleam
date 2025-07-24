// src/web/handler/key_handler.gleam
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import utils/crypto
import utils/utils

// NEW: Import crypto module
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================

pub type KeyType {
  Stripe
  Supabase
  Fly
}

pub type KeyRequest {
  KeyRequest(
    key_type: String,
    key_name: String,
    credentials: Dict(String, String),
    // Keep it simple for JSON parsing
  )
}

// ============================================================================
// CONSTANTS
// ============================================================================

const valid_key_types = ["stripe", "supabase", "fly"]

// ============================================================================
// VALIDATION & CONVERSION
// ============================================================================

fn validate_stripe_credentials(
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  case dict.get(credentials, "secret_key") {
    Ok("sk_live_" <> _) -> Ok(Nil)
    Ok("sk_test_" <> _) -> Ok(Nil)
    Ok(_) -> Error("Stripe secret key must start with sk_live_ or sk_test_")
    Error(_) -> Error("Missing secret_key for Stripe key")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "webhook_secret") {
      Ok("whsec_" <> _) -> Ok(Nil)
      Ok(_) -> Error("Webhook secret must start with whsec_")
      Error(_) -> Error("Missing webhook_secret for Stripe key")
    }
  })
}

fn validate_supabase_credentials(
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  case dict.get(credentials, "url") {
    Ok("https://" <> rest) ->
      case string.contains(rest, ".supabase.co") {
        True -> Ok(Nil)
        False -> Error("URL must be a valid Supabase URL")
      }
    Ok(_) -> Error("Supabase URL must be HTTPS")
    Error(_) -> Error("Missing url for Supabase key")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "service_role_key") {
      Ok("eyJ" <> _) -> Ok(Nil)
      // JWT format
      Ok(_) -> Error("Invalid Supabase service role key format")
      Error(_) -> Error("Missing service_role_key for Supabase key")
    }
  })
}

fn validate_fly_credentials(
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  case dict.get(credentials, "api_token") {
    Ok("fo1_" <> _) -> Ok(Nil)
    // Fly.io token format
    Ok(_) -> Error("Invalid Fly.io API token format")
    Error(_) -> Error("Missing api_token for Fly key")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "app_name") {
      Ok("") -> Error("App name cannot be empty")
      Ok(_) -> Ok(Nil)
      Error(_) -> Error("Missing app_name for Fly key")
    }
  })
  |> result.try(fn(_) {
    let valid_regions = ["iad", "lax", "fra", "nrt", "syd"]
    // Common Fly regions
    case dict.get(credentials, "region") {
      Ok(region) ->
        case list.contains(valid_regions, region) {
          True -> Ok(Nil)
          False ->
            Error(
              "Invalid Fly.io region. Must be one of: "
              <> string.join(valid_regions, ", "),
            )
        }
      Error(_) -> Error("Missing region for Fly key")
    }
  })
}

fn validate_credentials(
  key_type: String,
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  case key_type {
    "stripe" -> validate_stripe_credentials(credentials)
    "supabase" -> validate_supabase_credentials(credentials)
    "fly" -> validate_fly_credentials(credentials)
    _ -> Error("Unknown key type")
  }
}

// UPDATED: Now encrypts credentials instead of plain JSON
fn encrypt_credentials(
  credentials: Dict(String, String),
) -> Result(String, String) {
  // Convert credentials to JSON first
  let credentials_json =
    credentials
    |> dict.to_list()
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
    |> json.object()
    |> json.to_string()

  // Encrypt the JSON
  case crypto.encrypt_to_json(credentials_json) {
    Ok(encrypted_json) -> Ok(encrypted_json)
    Error(crypto.EncryptionFailed(msg)) -> Error("Encryption failed: " <> msg)
    Error(crypto.KeyDerivationFailed(msg)) ->
      Error("Key derivation failed: " <> msg)
    Error(_) -> Error("Encryption error")
  }
}

// ============================================================================
// AUTH & HELPERS
// ============================================================================

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

// Auth wrapper for key endpoints
fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  case extract_api_key(req) {
    Error(error) -> {
      logging.log(logging.Warning, "[KeyHandler] Auth failed: " <> error)
      let error_json =
        json.object([
          #("error", json.string("Unauthorized")),
          #("message", json.string(error)),
        ])
      wisp.json_response(json.to_string_tree(error_json), 401)
    }
    Ok(api_key) -> {
      case supabase_client.validate_api_key(api_key) {
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[KeyHandler] Invalid API key: "
              <> string.slice(api_key, 0, 10)
              <> "...",
          )
          let error_json =
            json.object([
              #("error", json.string("Unauthorized")),
              #("message", json.string("Invalid API key")),
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

fn key_request_decoder() -> decode.Decoder(KeyRequest) {
  use key_type <- decode.field("integration_type", decode.string)
  use key_name <- decode.field("key_name", decode.string)
  use credentials <- decode.field(
    "credentials",
    decode.dict(decode.string, decode.string),
  )
  decode.success(KeyRequest(
    key_type: key_type,
    key_name: key_name,
    credentials: credentials,
  ))
}

// ============================================================================
// API ENDPOINTS
// ============================================================================

/// CREATE - POST /api/v1/key
pub fn create_key(req: Request) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[KeyHandler] 🔍 CREATE key START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use key_req <- result.try(decode.run(json_data, key_request_decoder()))
    use _ <- result.try(validate_key_request(key_req))
    Ok(process_create_key(business_id, key_req))
  }

  logging.log(
    logging.Info,
    "[KeyHandler] 🔍 CREATE key END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[KeyHandler] Bad request: " <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid key data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

/// READ - GET /api/v1/key
pub fn list_key(req: Request) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[KeyHandler] 🔍 LIST key START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  case supabase_client.get_integration_keys(business_id, None) {
    Ok(keys) -> {
      let response_data =
        keys
        |> list.map(fn(key) {
          json.object([
            #("id", json.string(key.id)),
            #("key_type", json.string(key.key_type)),
            #("key_name", json.string(key.key_name)),
            #("is_active", json.bool(key.is_active)),
            // Don't return encrypted credentials for security
          ])
        })
        |> json.array(from: _, of: fn(item) { item })

      let success_json =
        json.object([
          #("key", response_data),
          #("count", json.int(list.length(keys))),
        ])

      logging.log(
        logging.Info,
        "[KeyHandler] ✅ Listed " <> string.inspect(list.length(keys)) <> " key",
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch key")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

/// READ - GET /api/v1/key/{key_type}
pub fn get_key_by_type(req: Request, key_type: String) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[KeyHandler] 🔍 GET key BY TYPE START - ID: "
      <> request_id
      <> " type: "
      <> key_type,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  // Validate key type
  case list.contains(valid_key_types, key_type) {
    False -> {
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #(
            "message",
            json.string(
              "Invalid key type. Must be one of: "
              <> string.join(valid_key_types, ", "),
            ),
          ),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
    True -> {
      case supabase_client.get_integration_keys(business_id, Some(key_type)) {
        Ok(keys) -> {
          let response_data =
            keys
            |> list.map(fn(key) {
              json.object([
                #("id", json.string(key.id)),
                #("key_name", json.string(key.key_name)),
                #("is_active", json.bool(key.is_active)),
              ])
            })
            |> json.array(from: _, of: fn(item) { item })

          let success_json =
            json.object([
              #("key_type", json.string(key_type)),
              #("key", response_data),
              #("count", json.int(list.length(keys))),
            ])

          wisp.json_response(json.to_string_tree(success_json), 200)
        }
        Error(_) -> {
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to fetch key")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
  }
}

/// READ - GET /api/v1/key/{key_type}/{key_name}
pub fn get_key(req: Request, key_type: String, key_name: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  // TODO: Implement get specific key
  let success_json =
    json.object([
      #("key_type", json.string(key_type)),
      #("key_name", json.string(key_name)),
      #("business_id", json.string(business_id)),
      #("message", json.string("Get specific key - TODO")),
    ])
  wisp.json_response(json.to_string_tree(success_json), 200)
}

/// UPDATE - PUT /api/v1/key/{key_type}/{key_name}
pub fn update_key(req: Request, key_type: String, key_name: String) -> Response {
  use <- wisp.require_method(req, http.Put)
  use business_id <- with_auth(req)

  // TODO: Implement update key
  let success_json =
    json.object([
      #("message", json.string("Update key - TODO")),
      #("key_type", json.string(key_type)),
      #("key_name", json.string(key_name)),
      #("business_id", json.string(business_id)),
    ])
  wisp.json_response(json.to_string_tree(success_json), 200)
}

/// DELETE - DELETE /api/v1/key/{key_type}/{key_name}
pub fn delete_key(req: Request, key_type: String, key_name: String) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  // TODO: Implement delete key
  let success_json =
    json.object([
      #("message", json.string("Delete key - TODO")),
      #("key_type", json.string(key_type)),
      #("key_name", json.string(key_name)),
      #("business_id", json.string(business_id)),
    ])
  wisp.json_response(json.to_string_tree(success_json), 200)
}

// ============================================================================
// PROCESSING FUNCTIONS
// ============================================================================

fn validate_key_request(
  req: KeyRequest,
) -> Result(KeyRequest, List(decode.DecodeError)) {
  // Validate key type
  case list.contains(valid_key_types, req.key_type) {
    False ->
      Error([
        decode.DecodeError(
          "Invalid",
          "key_type must be one of: " <> string.join(valid_key_types, ", "),
          [],
        ),
      ])
    True -> Ok(Nil)
  }
  |> result.try(fn(_) {
    // Validate key name
    case string.length(req.key_name) {
      0 ->
        Error([decode.DecodeError("Invalid", "key_name cannot be empty", [])])
      n if n > 50 ->
        Error([
          decode.DecodeError("Invalid", "key_name too long (max 50 chars)", []),
        ])
      _ -> Ok(Nil)
    }
  })
  |> result.try(fn(_) {
    // Validate credentials
    case validate_credentials(req.key_type, req.credentials) {
      Ok(_) -> Ok(req)
      Error(msg) -> Error([decode.DecodeError("Invalid", msg, [])])
    }
  })
}

fn process_create_key(business_id: String, req: KeyRequest) -> Response {
  logging.log(
    logging.Info,
    "[KeyHandler] Processing CREATE key: "
      <> business_id
      <> "/"
      <> req.key_type
      <> "/"
      <> req.key_name,
  )

  // UPDATED: Now uses encryption
  case encrypt_credentials(req.credentials) {
    Error(encryption_error) -> {
      logging.log(
        logging.Error,
        "[KeyHandler] ❌ Encryption failed: " <> encryption_error,
      )
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to encrypt credentials")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
    Ok(encrypted_credentials) -> {
      case
        supabase_client.store_integration_key(
          business_id,
          req.key_type,
          req.key_name,
          encrypted_credentials,
          None,
        )
      {
        Ok(key_key) -> {
          let success_json =
            json.object([
              #("status", json.string("created")),
              #("key_id", json.string(key_key.id)),
              #("business_id", json.string(business_id)),
              #("key_type", json.string(req.key_type)),
              #("key_name", json.string(req.key_name)),
              #("is_active", json.bool(key_key.is_active)),
              #("encrypted", json.bool(True)),
              // NEW: Indicate encryption is used
            ])

          logging.log(
            logging.Info,
            "[KeyHandler] ✅ Key created with encryption: " <> key_key.id,
          )
          wisp.json_response(json.to_string_tree(success_json), 201)
        }
        Error(supabase_client.DatabaseError(msg)) -> {
          logging.log(logging.Error, "[KeyHandler] ❌ Database error: " <> msg)
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to store key")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
        Error(_) -> {
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to create key")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
  }
}
