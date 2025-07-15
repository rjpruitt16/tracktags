// src/web/handler/integration_handler.gleam
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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

pub type IntegrationType {
  Stripe
  Supabase
  Fly
}

pub type IntegrationRequest {
  IntegrationRequest(
    integration_type: String,
    key_name: String,
    credentials: Dict(String, String),
    // Keep it simple for JSON parsing
  )
}

// ============================================================================
// CONSTANTS
// ============================================================================

const valid_integration_types = ["stripe", "supabase", "fly"]

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
    Error(_) -> Error("Missing secret_key for Stripe integration")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "webhook_endpoint") {
      Ok("https://" <> _) -> Ok(Nil)
      Ok(_) -> Error("Webhook URL must be HTTPS")
      Error(_) -> Error("Missing webhook_endpoint for Stripe integration")
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
    Error(_) -> Error("Missing url for Supabase integration")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "service_role_key") {
      Ok("eyJ" <> _) -> Ok(Nil)
      // JWT format
      Ok(_) -> Error("Invalid Supabase service role key format")
      Error(_) -> Error("Missing service_role_key for Supabase integration")
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
    Error(_) -> Error("Missing api_token for Fly integration")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "app_name") {
      Ok("") -> Error("App name cannot be empty")
      Ok(_) -> Ok(Nil)
      Error(_) -> Error("Missing app_name for Fly integration")
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
      Error(_) -> Error("Missing region for Fly integration")
    }
  })
}

fn validate_credentials(
  integration_type: String,
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  case integration_type {
    "stripe" -> validate_stripe_credentials(credentials)
    "supabase" -> validate_supabase_credentials(credentials)
    "fly" -> validate_fly_credentials(credentials)
    _ -> Error("Unknown integration type")
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

// Auth wrapper for integration endpoints
fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  case extract_api_key(req) {
    Error(error) -> {
      logging.log(
        logging.Warning,
        "[IntegrationHandler] Auth failed: " <> error,
      )
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
            "[IntegrationHandler] Invalid API key: "
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

fn integration_request_decoder() -> decode.Decoder(IntegrationRequest) {
  use integration_type <- decode.field("integration_type", decode.string)
  use key_name <- decode.field("key_name", decode.string)
  use credentials <- decode.field(
    "credentials",
    decode.dict(decode.string, decode.string),
  )
  decode.success(IntegrationRequest(
    integration_type: integration_type,
    key_name: key_name,
    credentials: credentials,
  ))
}

// ============================================================================
// API ENDPOINTS
// ============================================================================

/// CREATE - POST /api/v1/integrations
pub fn create_integration(req: Request) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[IntegrationHandler] 🔍 CREATE INTEGRATION START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use integration_req <- result.try(decode.run(
      json_data,
      integration_request_decoder(),
    ))
    use _ <- result.try(validate_integration_request(integration_req))
    Ok(process_create_integration(business_id, integration_req))
  }

  logging.log(
    logging.Info,
    "[IntegrationHandler] 🔍 CREATE INTEGRATION END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[IntegrationHandler] Bad request: " <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid integration data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

/// READ - GET /api/v1/integrations
pub fn list_integrations(req: Request) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[IntegrationHandler] 🔍 LIST INTEGRATIONS START - ID: " <> request_id,
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
            #("integration_type", json.string(key.key_type)),
            #("key_name", json.string(key.key_name)),
            #("is_active", json.bool(key.is_active)),
            // Don't return encrypted credentials for security
          ])
        })
        |> json.array(from: _, of: fn(item) { item })

      let success_json =
        json.object([
          #("integrations", response_data),
          #("count", json.int(list.length(keys))),
        ])

      logging.log(
        logging.Info,
        "[IntegrationHandler] ✅ Listed "
          <> string.inspect(list.length(keys))
          <> " integrations",
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch integrations")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

/// READ - GET /api/v1/integrations/{integration_type}
pub fn get_integrations_by_type(
  req: Request,
  integration_type: String,
) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[IntegrationHandler] 🔍 GET INTEGRATIONS BY TYPE START - ID: "
      <> request_id
      <> " type: "
      <> integration_type,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  // Validate integration type
  case list.contains(valid_integration_types, integration_type) {
    False -> {
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #(
            "message",
            json.string(
              "Invalid integration type. Must be one of: "
              <> string.join(valid_integration_types, ", "),
            ),
          ),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
    True -> {
      case
        supabase_client.get_integration_keys(
          business_id,
          Some(integration_type),
        )
      {
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
              #("integration_type", json.string(integration_type)),
              #("integrations", response_data),
              #("count", json.int(list.length(keys))),
            ])

          wisp.json_response(json.to_string_tree(success_json), 200)
        }
        Error(_) -> {
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to fetch integrations")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
  }
}

/// READ - GET /api/v1/integrations/{integration_type}/{key_name}
pub fn get_integration(
  req: Request,
  integration_type: String,
  key_name: String,
) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  // TODO: Implement get specific integration
  let success_json =
    json.object([
      #("integration_type", json.string(integration_type)),
      #("key_name", json.string(key_name)),
      #("business_id", json.string(business_id)),
      #("message", json.string("Get specific integration - TODO")),
    ])
  wisp.json_response(json.to_string_tree(success_json), 200)
}

/// UPDATE - PUT /api/v1/integrations/{integration_type}/{key_name}
pub fn update_integration(
  req: Request,
  integration_type: String,
  key_name: String,
) -> Response {
  use <- wisp.require_method(req, http.Put)
  use business_id <- with_auth(req)

  // TODO: Implement update integration
  let success_json =
    json.object([
      #("message", json.string("Update integration - TODO")),
      #("integration_type", json.string(integration_type)),
      #("key_name", json.string(key_name)),
      #("business_id", json.string(business_id)),
    ])
  wisp.json_response(json.to_string_tree(success_json), 200)
}

/// DELETE - DELETE /api/v1/integrations/{integration_type}/{key_name}
pub fn delete_integration(
  req: Request,
  integration_type: String,
  key_name: String,
) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  // TODO: Implement delete integration
  let success_json =
    json.object([
      #("message", json.string("Delete integration - TODO")),
      #("integration_type", json.string(integration_type)),
      #("key_name", json.string(key_name)),
      #("business_id", json.string(business_id)),
    ])
  wisp.json_response(json.to_string_tree(success_json), 200)
}

// ============================================================================
// PROCESSING FUNCTIONS
// ============================================================================

fn validate_integration_request(
  req: IntegrationRequest,
) -> Result(IntegrationRequest, List(decode.DecodeError)) {
  // Validate integration type
  case list.contains(valid_integration_types, req.integration_type) {
    False ->
      Error([
        decode.DecodeError(
          "Invalid",
          "integration_type must be one of: "
            <> string.join(valid_integration_types, ", "),
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
    case validate_credentials(req.integration_type, req.credentials) {
      Ok(_) -> Ok(req)
      Error(msg) -> Error([decode.DecodeError("Invalid", msg, [])])
    }
  })
}

fn process_create_integration(
  business_id: String,
  req: IntegrationRequest,
) -> Response {
  logging.log(
    logging.Info,
    "[IntegrationHandler] Processing CREATE integration: "
      <> business_id
      <> "/"
      <> req.integration_type
      <> "/"
      <> req.key_name,
  )

  // UPDATED: Now uses encryption
  case encrypt_credentials(req.credentials) {
    Error(encryption_error) -> {
      logging.log(
        logging.Error,
        "[IntegrationHandler] ❌ Encryption failed: " <> encryption_error,
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
          req.integration_type,
          req.key_name,
          encrypted_credentials,
          None,
        )
      {
        Ok(integration_key) -> {
          let success_json =
            json.object([
              #("status", json.string("created")),
              #("integration_id", json.string(integration_key.id)),
              #("business_id", json.string(business_id)),
              #("integration_type", json.string(req.integration_type)),
              #("key_name", json.string(req.key_name)),
              #("is_active", json.bool(integration_key.is_active)),
              #("encrypted", json.bool(True)),
              // NEW: Indicate encryption is used
            ])

          logging.log(
            logging.Info,
            "[IntegrationHandler] ✅ Integration created with encryption: "
              <> integration_key.id,
          )
          wisp.json_response(json.to_string_tree(success_json), 201)
        }
        Error(supabase_client.DatabaseError(msg)) -> {
          logging.log(
            logging.Error,
            "[IntegrationHandler] ❌ Database error: " <> msg,
          )
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to store integration")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
        Error(_) -> {
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to create integration")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
  }
}
