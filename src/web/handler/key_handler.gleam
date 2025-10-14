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
import utils/audit
import utils/auth
import utils/crypto
import utils/utils
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================

pub type KeyType {
  Stripe
  Supabase
  Fly
}

// Body-only request (no business_id in body)
pub type KeyRequestBody {
  KeyRequestBody(
    key_type: String,
    key_name: String,
    credentials: Dict(String, String),
  )
}

// Full request (with business_id from URL)
pub type KeyRequest {
  KeyRequest(
    key_type: String,
    key_name: String,
    credentials: Dict(String, String),
  )
}

// ============================================================================
// CONSTANTS
// ============================================================================

const valid_key_types = [
  "stripe",
  "supabase",
  "fly",
  "business",
  "customer_api",
  "stripe_frontend",
]

// ============================================================================
// VALIDATION & CONVERSION
// ============================================================================

// Add to the validation section (around line 100)
fn validate_fly_credentials(
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  case dict.get(credentials, "api_token") {
    Ok("fo1_" <> _) -> Ok(Nil)
    Ok("fo0_" <> _) -> Ok(Nil)
    // Some tokens start with fo0
    Ok(_) -> Error("Invalid Fly.io API token format")
    Error(_) -> Error("Missing api_token for Fly key")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "org_slug") {
      Ok("") -> Error("Organization slug cannot be empty")
      Ok(_) -> Ok(Nil)
      Error(_) -> Error("Missing org_slug for Fly key")
    }
  })
  |> result.try(fn(_) {
    // Default region is optional, will use business default if not provided
    case dict.get(credentials, "default_region") {
      Ok("") -> Error("Region cannot be empty if provided")
      Ok(_) -> Ok(Nil)
      Error(_) -> Ok(Nil)
      // Optional field
    }
  })
}

// Update validate_credentials function to include fly
fn validate_credentials(
  key_type: String,
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  case key_type {
    "stripe" -> validate_stripe_credentials(credentials)
    "supabase" -> validate_supabase_credentials(credentials)
    "fly" -> validate_fly_credentials(credentials)
    // Add this line
    "business" -> validate_business_credentials(credentials)
    "stripe_frontend" -> Ok(Nil)
    _ -> Error("Unknown key type")
  }
}

fn validate_business_credentials(
  credentials: Dict(String, String),
) -> Result(Nil, String) {
  // Just validate description or other fields if needed
  case dict.get(credentials, "description") {
    Ok(_) -> Ok(Nil)
    Error(_) -> Ok(Nil)
    // Description is optional
  }
}

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

// Auth wrapper for key endpoints
fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  auth.with_auth(req, fn(auth_result, api_key, is_admin) {
    case auth_result {
      auth.ActorCached(auth.BusinessActor(business_id, _)) ->
        handler(business_id)

      auth.DatabaseValid(supabase_client.BusinessKey(business_id)) -> {
        case is_admin {
          True -> handler("admin_override")
          // Admin creating keys
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
              #("message", json.string("Customer keys cannot manage keys")),
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
              #("message", json.string("Customer keys cannot manage keys")),
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

fn key_request_body_decoder() -> decode.Decoder(KeyRequestBody) {
  use key_type <- decode.field("key_type", decode.string)
  use key_name <- decode.field("key_name", decode.string)
  use credentials <- decode.field(
    "credentials",
    decode.dict(decode.string, decode.string),
  )

  decode.success(KeyRequestBody(
    key_type: key_type,
    key_name: key_name,
    credentials: credentials,
  ))
}

// ============================================================================
// API ENDPOINTS
// ============================================================================

// src/web/handler/key_handler.gleam

/// CREATE - POST /api/v1/businesses/{business_id}/keys
pub fn create_business_key(req: Request, business_id: String) -> Response {
  use <- wisp.require_method(req, http.Post)
  use _ <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use key_body <- result.try(decode.run(json_data, key_request_body_decoder()))

    // Build full KeyRequest with business_id from URL
    let key_req =
      KeyRequest(
        key_type: key_body.key_type,
        key_name: key_body.key_name,
        credentials: key_body.credentials,
      )

    use _ <- result.try(validate_key_request(key_req))
    Ok(process_create_business_key(business_id, key_req))
  }

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[KeyHandler] Bad request: " <> string.inspect(decode_errors),
      )
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string("Invalid key data")),
          ]),
        ),
        400,
      )
    }
  }
}

/// LIST - GET /api/v1/businesses/{business_id}/keys
pub fn list_business_keys(req: Request, business_id: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use _ <- with_auth(req)

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
            #("created_at", json.string(key.created_at)),
          ])
        })
        |> json.array(from: _, of: fn(item) { item })

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("keys", response_data),
            #("count", json.int(list.length(keys))),
          ]),
        ),
        200,
      )
    }
    Error(_) -> wisp.internal_server_error()
  }
}

/// GET - GET /api/v1/businesses/{business_id}/keys/{key_type}/{key_name}
pub fn get_business_key(
  req: Request,
  business_id: String,
  key_type: String,
  key_name: String,
) -> Response {
  use <- wisp.require_method(req, http.Get)
  use _ <- with_auth(req)

  let composite_key = business_id <> "/" <> key_type <> "/" <> key_name

  case supabase_client.get_integration_key_by_composite(composite_key) {
    Ok(key) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("key_type", json.string(key.key_type)),
            #("key_name", json.string(key.key_name)),
            #("is_active", json.bool(key.is_active)),
            #("created_at", json.string(key.created_at)),
          ]),
        ),
        200,
      )
    }
    Error(supabase_client.NotFound(_)) -> wisp.not_found()
    Error(_) -> wisp.internal_server_error()
  }
}

/// UPDATE - PUT /api/v1/businesses/{business_id}/keys/{key_type}/{key_name}
pub fn update_business_key(
  req: Request,
  business_id: String,
  key_type: String,
  key_name: String,
) -> Response {
  use <- wisp.require_method(req, http.Put)
  use _ <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let decoder =
    decode.field(
      "credentials",
      decode.dict(decode.string, decode.string),
      decode.success,
    )

  case decode.run(json_data, decoder) {
    Ok(credentials) -> {
      case key_type {
        "stripe_frontend" -> {
          let frontend_json =
            json.object([
              #(
                "pricing_table_id",
                json.string(
                  dict.get(credentials, "pricing_table_id") |> result.unwrap(""),
                ),
              ),
              #(
                "publishable_key",
                json.string(
                  dict.get(credentials, "publishable_key") |> result.unwrap(""),
                ),
              ),
            ])

          case
            supabase_client.update_integration_key(
              business_id,
              key_type,
              key_name,
              json.to_string(frontend_json),
            )
          {
            Ok(_) -> {
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("status", json.string("updated")),
                    #("message", json.string("Configuration updated")),
                  ]),
                ),
                200,
              )
            }
            Error(_) -> wisp.internal_server_error()
          }
        }
        _ -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #(
                  "error",
                  json.string("Update not supported for this key type"),
                ),
              ]),
            ),
            400,
          )
        }
      }
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([#("error", json.string("Invalid request data"))]),
        ),
        400,
      )
    }
  }
}

/// DELETE - DELETE /api/v1/businesses/{business_id}/keys/{key_type}/{key_name}
pub fn delete_business_key(
  req: Request,
  business_id: String,
  key_type: String,
  key_name: String,
) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use _ <- with_auth(req)

  logging.log(
    logging.Info,
    "[KeyHandler] Deleting key: "
      <> business_id
      <> "/"
      <> key_type
      <> "/"
      <> key_name,
  )

  case
    supabase_client.deactivate_integration_key(business_id, key_type, key_name)
  {
    Ok(_) -> {
      let _ =
        audit.log_action(
          "delete_key",
          "integration_key",
          business_id <> "/" <> key_type <> "/" <> key_name,
          dict.from_list([
            #("key_type", json.string(key_type)),
            #("key_name", json.string(key_name)),
          ]),
        )
      wisp.ok() |> wisp.string_body("Key deleted")
    }
    Error(_) -> wisp.internal_server_error()
  }
}

pub fn create_customer_key(
  req: Request,
  business_id: String,
  customer_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Post)
  use _ <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use key_body <- result.try(decode.run(json_data, key_request_body_decoder()))

    // Validate key_name matches customer_id for customer keys
    case key_body.key_type {
      "customer_api" -> {
        case key_body.key_name == customer_id {
          True -> Ok(key_body)
          False ->
            Error([
              decode.DecodeError(
                "key_name must match customer_id for customer keys",
                "",
                [],
              ),
            ])
        }
      }
      _ -> Ok(key_body)
    }
  }

  case result {
    Ok(_key_body) -> {
      // Check if THIS CUSTOMER has reached key limit (2 active keys)
      case
        supabase_client.get_integration_keys(business_id, Some("customer_api"))
      {
        Ok(existing_keys) -> {
          // IMPORTANT: Filter by customer_id (key_name starts with customer_id)
          let customer_active_keys =
            list.filter(existing_keys, fn(key) {
              string.starts_with(key.key_name, customer_id) && key.is_active
            })

          let active_count = list.length(customer_active_keys)

          case active_count >= 2 {
            True -> {
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("error", json.string("Key Limit Reached")),
                    #(
                      "message",
                      json.string(
                        "Maximum 2 active keys per customer. Delete a key first.",
                      ),
                    ),
                  ]),
                ),
                409,
              )
            }
            False -> generate_and_store_customer_key(business_id, customer_id)
          }
        }
        Error(_) -> generate_and_store_customer_key(business_id, customer_id)
      }
    }
    // ADD THIS ERROR HANDLER:
    Error(decode_errors) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string(string.inspect(decode_errors))),
          ]),
        ),
        400,
      )
    }
  }
}

/// LIST - GET /api/v1/businesses/{business_id}/customers/{customer_id}/keys
pub fn list_customer_keys(
  req: Request,
  business_id: String,
  customer_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Get)
  use _ <- with_auth(req)

  case supabase_client.get_integration_keys(business_id, Some("customer_api")) {
    Ok(keys) -> {
      let customer_keys =
        list.filter(keys, fn(key) { key.key_name == customer_id })

      let response_data =
        customer_keys
        |> list.map(fn(key) {
          json.object([
            #("id", json.string(key.id)),
            #("key_name", json.string(key.key_name)),
            #("is_active", json.bool(key.is_active)),
            #("created_at", json.string(key.created_at)),
          ])
        })
        |> json.array(from: _, of: fn(item) { item })

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("keys", response_data),
            #("count", json.int(list.length(customer_keys))),
          ]),
        ),
        200,
      )
    }
    Error(_) -> wisp.internal_server_error()
  }
}

pub fn delete_customer_key(
  req: Request,
  business_id: String,
  customer_id: String,
  key_name: String,
) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use _ <- with_auth(req)

  // Validate that the key_name STARTS WITH the customer_id (security check)
  case string.starts_with(key_name, customer_id) {
    False -> {
      logging.log(
        logging.Warning,
        "[KeyHandler] Attempt to delete key for wrong customer: key="
          <> key_name
          <> " customer="
          <> customer_id,
      )
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Forbidden")),
            #("message", json.string("Key does not belong to this customer")),
          ]),
        ),
        403,
      )
    }
    True -> {
      case
        supabase_client.deactivate_integration_key(
          business_id,
          "customer_api",
          key_name,
          // Use the full key_name with timestamp
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[KeyHandler] ✅ Deleted customer key: " <> key_name,
          )
          wisp.ok() |> wisp.string_body("Key deleted")
        }
        Error(_) -> wisp.internal_server_error()
      }
    }
  }
}

// Helper remains the same
fn process_create_business_key(business_id: String, req: KeyRequest) -> Response {
  // Check key limit
  case supabase_client.get_integration_keys(business_id, Some(req.key_type)) {
    Ok(existing_keys) -> {
      let active_count = list.count(existing_keys, fn(k) { k.is_active })
      case active_count >= 2 {
        True -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Key Limit Reached")),
                #(
                  "message",
                  json.string(
                    "Maximum 2 active keys per type. Delete a key first.",
                  ),
                ),
              ]),
            ),
            409,
          )
        }
        False -> {
          let request_id = utils.generate_request_id()
          // Generate here
          create_and_store_key(business_id, req, request_id)
          // Pass it
        }
      }
    }
    Error(_) -> {
      let request_id = utils.generate_request_id()
      // Generate here
      create_and_store_key(business_id, req, request_id)
      // Pass it
    }
  }
}

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
    use key_body <- result.try(decode.run(json_data, key_request_body_decoder()))

    // Build KeyRequest from body
    let key_req =
      KeyRequest(
        key_type: key_body.key_type,
        key_name: key_body.key_name,
        credentials: key_body.credentials,
      )

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

/// READ - GET /api/v1/keys/{key_type}/{key_name}
pub fn get_key(req: Request, key_type: String, key_name: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  let composite_key = business_id <> "/" <> key_type <> "/" <> key_name

  case supabase_client.get_integration_key_by_composite(composite_key) {
    Ok(key) -> {
      let value = case key_type {
        "stripe_frontend" -> key.encrypted_key
        _ -> "{\"encrypted\": true}"
      }

      let success_json =
        json.object([
          #("key_type", json.string(key_type)),
          #("key_name", json.string(key_name)),
          #("value", json.string(value)),
          #("is_active", json.bool(key.is_active)),
        ])
      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      let error_json = json.object([#("error", json.string("Key not found"))])
      wisp.json_response(json.to_string_tree(error_json), 404)
      // Fixed: to_string_tree
    }
    Error(_) -> {
      let error_json =
        json.object([#("error", json.string("Internal server error"))])
      wisp.json_response(json.to_string_tree(error_json), 500)
      // Fixed: to_string_tree
    }
  }
}

/// UPDATE - PUT /api/v1/keys/{key_type}/{key_name}  
pub fn update_key(req: Request, key_type: String, key_name: String) -> Response {
  use <- wisp.require_method(req, http.Put)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  // Parse the update data
  let decoder =
    decode.field(
      "credentials",
      decode.dict(decode.string, decode.string),
      decode.success,
      // Fixed: Added third argument
    )

  case decode.run(json_data, decoder) {
    Ok(credentials) -> {
      case key_type {
        "stripe_frontend" -> {
          let frontend_json =
            json.object([
              #(
                "pricing_table_id",
                json.string(
                  dict.get(credentials, "pricing_table_id") |> result.unwrap(""),
                ),
              ),
              #(
                "publishable_key",
                json.string(
                  dict.get(credentials, "publishable_key") |> result.unwrap(""),
                ),
              ),
            ])

          case
            supabase_client.update_integration_key(
              business_id,
              key_type,
              key_name,
              json.to_string(frontend_json),
            )
          {
            Ok(_) -> {
              let success_json =
                json.object([
                  #("status", json.string("updated")),
                  #(
                    "message",
                    json.string("Configuration updated successfully"),
                  ),
                ])
              wisp.json_response(json.to_string_tree(success_json), 200)
            }
            Error(_) -> {
              let error_json =
                json.object([#("error", json.string("Failed to update key"))])
              wisp.json_response(json.to_string_tree(error_json), 500)
              // Fixed
            }
          }
        }
        _ -> {
          let error_json =
            json.object([
              #("error", json.string("Update not supported for this key type")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 400)
        }
      }
    }
    Error(_) -> {
      let error_json =
        json.object([#("error", json.string("Invalid request data"))])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

/// DELETE - DELETE /api/v1/keys/{key_type}/{key_name}
pub fn delete_key(req: Request, key_type: String, key_name: String) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  // Admin can't delete without knowing which business
  case business_id {
    "admin" -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string("Admin must specify business_id in path")),
          ]),
        ),
        400,
      )
    }
    _ -> {
      logging.log(
        logging.Info,
        "[KeyHandler] Deleting key: "
          <> business_id
          <> "/"
          <> key_type
          <> "/"
          <> key_name,
      )

      case
        supabase_client.deactivate_integration_key(
          business_id,
          key_type,
          key_name,
        )
      {
        Ok(_) -> {
          let _ =
            audit.log_action(
              "delete_key",
              "integration_key",
              business_id <> "/" <> key_type <> "/" <> key_name,
              dict.from_list([
                #("key_type", json.string(key_type)),
                #("key_name", json.string(key_name)),
              ]),
            )
          wisp.ok() |> wisp.string_body("Key deleted")
        }
        Error(_) -> wisp.internal_server_error()
      }
    }
  }
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

fn process_create_key(business_id_param: String, req: KeyRequest) -> Response {
  let request_id = utils.generate_request_id()

  // For business keys, business_id comes from auth
  let business_id = case business_id_param {
    "admin_override" -> {
      // Admin needs business_id somewhere - maybe query param?
      business_id_param
    }
    _ -> business_id_param
  }

  case business_id {
    "" -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string("business_id required")),
          ]),
        ),
        400,
      )
    }
    _ -> {
      // Check key limit
      case
        supabase_client.get_integration_keys(business_id, Some(req.key_type))
      {
        Ok(existing_keys) -> {
          let active_count = list.count(existing_keys, fn(k) { k.is_active })
          case active_count >= 2 {
            True -> {
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("error", json.string("Key Limit Reached")),
                    #(
                      "message",
                      json.string(
                        "Maximum 2 active keys per type. Delete a key first.",
                      ),
                    ),
                  ]),
                ),
                409,
              )
            }
            False -> create_and_store_key(business_id, req, request_id)
          }
        }
        Error(_) -> create_and_store_key(business_id, req, request_id)
      }
    }
  }
}

// Extract the key creation logic into a helper
fn create_and_store_key(
  business_id: String,
  req: KeyRequest,
  request_id: String,
) -> Response {
  // Extract or generate the API key
  let api_key = case dict.get(req.credentials, "api_key") {
    Ok(key_value) -> key_value
    Error(_) -> "tk_" <> business_id <> "_" <> utils.generate_random()
  }

  // Hash the ACTUAL API KEY (not a UUID!)
  let api_key_hash = crypto.hash_api_key(api_key)

  // Encrypt credentials
  case encrypt_credentials(req.credentials) {
    Error(err) -> {
      logging.log(logging.Error, "[KeyHandler] Encryption failed: " <> err)
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Internal Server Error")),
            #("message", json.string("Failed to encrypt credentials")),
          ]),
        ),
        500,
      )
    }
    Ok(encrypted) -> {
      // Store in database
      case
        supabase_client.store_integration_key_with_hash(
          business_id,
          req.key_type,
          req.key_name,
          encrypted,
          api_key_hash,
          None,
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[KeyHandler] ✅ Business key created with hash: "
              <> string.slice(api_key_hash, 0, 10)
              <> "...",
          )

          logging.log(
            logging.Info,
            "[KeyHandler] 🔍 CREATE key END - ID: " <> request_id,
          )

          // Return the plain text API key to the user (only time they see it)
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("api_key", json.string(api_key)),
                #("key_name", json.string(req.key_name)),
                #("key_type", json.string(req.key_type)),
                #("business_id", json.string(business_id)),
              ]),
            ),
            201,
          )
        }
        Error(err) -> {
          logging.log(
            logging.Error,
            "[KeyHandler] Database error: " <> string.inspect(err),
          )
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Internal Server Error")),
                #("message", json.string("Failed to create key")),
              ]),
            ),
            500,
          )
        }
      }
    }
  }
}

fn generate_and_store_customer_key(
  business_id: String,
  customer_id: String,
) -> Response {
  // Generate unique key_name by adding timestamp
  let timestamp = utils.generate_random()
  let key_name = customer_id <> "_" <> timestamp

  // Generate the new key
  let plain_customer_key = utils.create_customer_key(customer_id)

  // Hash the key for validation
  let key_hash = crypto.hash_api_key(plain_customer_key)

  logging.log(
    logging.Info,
    "[KeyHandler] Generated key for customer: "
      <> customer_id
      <> " (key_name: "
      <> key_name
      <> ", hash: "
      <> string.slice(key_hash, 0, 10)
      <> "...)",
  )

  // Encrypt the key for storage
  case crypto.encrypt_to_json(plain_customer_key) {
    Ok(encrypted_key) -> {
      // Store with unique key_name
      case
        supabase_client.store_integration_key_with_hash(
          business_id,
          "customer_api",
          key_name,
          // Changed: now includes timestamp
          encrypted_key,
          key_hash,
          None,
        )
      {
        Ok(stored_key) -> {
          logging.log(
            logging.Info,
            "[KeyHandler] ✅ Customer key created: " <> stored_key.id,
          )

          let success_json =
            json.object([
              #("status", json.string("created")),
              #("api_key", json.string(plain_customer_key)),
              #("customer_id", json.string(customer_id)),
              #("key_id", json.string(stored_key.id)),
              #("key_name", json.string(key_name)),
              #(
                "warning",
                json.string(
                  "Save this key securely. It will not be shown again.",
                ),
              ),
            ])
          wisp.json_response(json.to_string_tree(success_json), 201)
        }
        Error(err) -> {
          logging.log(
            logging.Error,
            "[KeyHandler] Failed to store key: " <> string.inspect(err),
          )
          let error_json =
            json.object([
              #("error", json.string("Internal Server Error")),
              #("message", json.string("Failed to store API key")),
            ])
          wisp.json_response(json.to_string_tree(error_json), 500)
        }
      }
    }
    Error(crypto_err) -> {
      logging.log(
        logging.Error,
        "[KeyHandler] Failed to encrypt key: " <> string.inspect(crypto_err),
      )
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to encrypt API key")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}
