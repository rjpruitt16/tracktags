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

pub type KeyRequest {
  KeyRequest(
    business_id: option.Option(String),
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
  case dict.get(credentials, "business_id") {
    Ok("biz_" <> _) -> Ok(Nil)
    Ok(_) -> Error("Business ID must start with biz_")
    Error(_) -> Error("Missing business_id for business key")
  }
  |> result.try(fn(_) {
    case dict.get(credentials, "api_key") {
      Ok("tk_live_" <> _) -> Ok(Nil)
      Ok("tk_test_" <> _) -> Ok(Nil)
      Ok(_) -> Error("API key must start with tk_live_ or tk_test_")
      Error(_) -> Error("Missing api_key for business key")
    }
  })
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

fn key_request_decoder() -> decode.Decoder(KeyRequest) {
  use business_id <- decode.optional_field(
    "business_id",
    None,
    decode.optional(decode.string),
  )
  use key_type <- decode.field("key_type", decode.string)
  use key_name <- decode.field("key_name", decode.string)
  use credentials <- decode.field(
    "credentials",
    decode.dict(decode.string, decode.string),
  )
  decode.success(KeyRequest(
    business_id: business_id,
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

fn process_create_key(business_id_param: String, req: KeyRequest) -> Response {
  let request_id = utils.generate_request_id()
  logging.log(
    logging.Info,
    "[KeyHandler] 🔍 CREATE key START - ID: " <> request_id,
  )

  // Determine the actual business_id to use
  let business_id = case business_id_param {
    "admin_override" -> {
      case req.business_id {
        option.Some(bid) -> bid
        option.None -> ""
      }
    }
    _ -> business_id_param
  }

  // Validate we have a business_id
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
      // Validate request matches
      case
        req.business_id == option.Some(business_id)
        && req.key_type == "business"
      {
        False -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Bad Request")),
                #("message", json.string("Invalid key creation request")),
              ]),
            ),
            400,
          )
        }
        True -> {
          logging.log(
            logging.Info,
            "[KeyHandler] Processing CREATE key: "
              <> business_id
              <> "/"
              <> req.key_type
              <> "/"
              <> req.key_name,
          )

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
              logging.log(
                logging.Error,
                "[KeyHandler] Encryption failed: " <> err,
              )
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
              // Store in database with the correct function name
              case
                supabase_client.store_integration_key_with_hash(
                  business_id,
                  req.key_type,
                  req.key_name,
                  encrypted,
                  api_key_hash,
                  // Store the hash of the actual API key
                  None,
                  // No metadata
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
      }
    }
  }
}

pub fn create_customer_key(req: Request, customer_id: String) -> Response {
  use <- wisp.require_method(req, http.Post)
  use business_id_from_auth <- with_auth(req)

  // For admin requests, get business_id from body
  case business_id_from_auth {
    "admin_override" -> {
      // Parse body to get business_id
      use json_data <- wisp.require_json(req)

      case
        decode.run(
          json_data,
          decode.field("business_id", decode.string, decode.success),
        )
      {
        Ok(bid) -> process_customer_key_creation(bid, customer_id)
        Error(_) -> {
          logging.log(
            logging.Error,
            "[KeyHandler] Admin request missing business_id in body",
          )
          let error_json =
            json.object([
              #("error", json.string("Bad Request")),
              #(
                "message",
                json.string("business_id required in body for admin requests"),
              ),
            ])
          wisp.json_response(json.to_string_tree(error_json), 400)
        }
      }
    }
    _ -> process_customer_key_creation(business_id_from_auth, customer_id)
  }
}

fn process_customer_key_creation(
  business_id: String,
  customer_id: String,
) -> Response {
  logging.log(
    logging.Info,
    "[KeyHandler] Creating customer API key for: "
      <> customer_id
      <> " in business: "
      <> business_id,
  )

  // Check if a key already exists for this customer
  case supabase_client.get_integration_keys(business_id, Some("customer_api")) {
    Ok(existing_keys) -> {
      let has_existing =
        list.any(existing_keys, fn(key) {
          key.key_name == customer_id && key.is_active
        })

      case has_existing {
        True -> {
          logging.log(
            logging.Warning,
            "[KeyHandler] Customer already has an active API key: "
              <> customer_id,
          )
          let error_json =
            json.object([
              #("error", json.string("Conflict")),
              #(
                "message",
                json.string("Customer already has an active API key"),
              ),
            ])
          wisp.json_response(json.to_string_tree(error_json), 409)
        }
        False -> generate_and_store_customer_key(business_id, customer_id)
      }
    }
    Error(_) -> generate_and_store_customer_key(business_id, customer_id)
  }
}

fn generate_and_store_customer_key(
  business_id: String,
  customer_id: String,
) -> Response {
  // Generate the new key
  let plain_customer_key = utils.create_customer_key(customer_id)

  // Hash the key for validation
  let key_hash = crypto.hash_api_key(plain_customer_key)

  logging.log(
    logging.Info,
    "[KeyHandler] Generated key for customer: "
      <> customer_id
      <> " (hash: "
      <> string.slice(key_hash, 0, 10)
      <> "...)",
  )

  // Encrypt the key for storage
  case crypto.encrypt_to_json(plain_customer_key) {
    Ok(encrypted_key) -> {
      // Store with both encrypted key and hash
      case
        supabase_client.store_integration_key_with_hash(
          business_id,
          "customer_api",
          customer_id,
          encrypted_key,
          key_hash,
          None,
        )
      {
        Ok(stored_key) -> {
          logging.log(
            logging.Info,
            "[KeyHandler] ✅ Customer key created with hash: " <> stored_key.id,
          )

          // Return the PLAIN key to the user (only time they'll see it)
          let success_json =
            json.object([
              #("status", json.string("created")),
              #("api_key", json.string(plain_customer_key)),
              #("customer_id", json.string(customer_id)),
              #("key_id", json.string(stored_key.id)),
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

pub fn list_customer_keys(req: Request, customer_id: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  let success_json =
    json.object([
      #("message", json.string("List customer keys - TODO")),
      #("business_id", json.string(business_id)),
      #("customer_id", json.string(customer_id)),
    ])
  wisp.json_response(json.to_string_tree(success_json), 200)
}
