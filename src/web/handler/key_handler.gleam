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
      // Check if it's the admin key first
      let admin_key = utils.require_env("ADMIN_API_KEY")
      case api_key == admin_key {
        True -> {
          logging.log(logging.Info, "[KeyHandler] Admin auth successful")
          // For admin requests, check for X-Business-ID header
          case
            list.find(req.headers, fn(header) { header.0 == "x-business-id" })
          {
            Ok(#(_, business_id)) -> {
              logging.log(
                logging.Info,
                "[KeyHandler] Admin request for business: " <> business_id,
              )
              handler(business_id)
            }
            Error(_) -> {
              // No X-Business-ID header - this is okay for some operations
              // but not for GET requests
              case req.method {
                http.Get | http.Put | http.Delete -> {
                  let error_json =
                    json.object([
                      #("error", json.string("Bad Request")),
                      #(
                        "message",
                        json.string(
                          "X-Business-ID header required for admin requests",
                        ),
                      ),
                    ])
                  wisp.json_response(json.to_string_tree(error_json), 400)
                }
                _ -> {
                  // For POST, we'll get business_id from body
                  handler("admin_override")
                }
              }
            }
          }
        }
        False -> {
          // Regular API key validation (unchanged)
          case supabase_client.validate_api_key(api_key) {
            Ok(supabase_client.BusinessKey(business_id)) -> {
              logging.log(
                logging.Info,
                "[KeyHandler] ✅ Business key validated for: " <> business_id,
              )
              handler(business_id)
            }
            Ok(supabase_client.CustomerKey(business_id, _)) -> {
              logging.log(
                logging.Warning,
                "[KeyHandler] Customer key cannot manage keys for business: "
                  <> business_id,
              )
              let error_json =
                json.object([
                  #("error", json.string("Forbidden")),
                  #(
                    "message",
                    json.string("Customer keys cannot manage other keys"),
                  ),
                ])
              wisp.json_response(json.to_string_tree(error_json), 403)
            }
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
          }
        }
      }
    }
  }
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
  use key_type <- decode.field("integration_type", decode.string)
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
  // Determine the actual business_id to use
  let business_id = case business_id_param {
    "admin_override" -> {
      // Use the business_id from the request for admin
      case req.business_id {
        option.Some(bid) -> bid
        option.None -> ""
        // Empty string will trigger error below
      }
    }
    _ -> business_id_param
  }

  // Check if we have a valid business_id
  case business_id {
    "" -> {
      logging.log(
        logging.Error,
        "[KeyHandler] Admin request missing business_id",
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("business_id required for admin requests")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
    _ -> {
      logging.log(
        logging.Info,
        "[KeyHandler] Processing CREATE key: "
          <> business_id
          <> "/"
          <> req.key_type
          <> "/"
          <> req.key_name,
      )

      // Process based on key type
      case req.key_type {
        "stripe_frontend" -> {
          // Don't encrypt public keys
          let frontend_json =
            json.object([
              #(
                "pricing_table_id",
                json.string(
                  dict.get(req.credentials, "pricing_table_id")
                  |> result.unwrap(""),
                ),
              ),
              #(
                "publishable_key",
                json.string(
                  dict.get(req.credentials, "publishable_key")
                  |> result.unwrap(""),
                ),
              ),
            ])

          case
            supabase_client.store_integration_key_with_hash(
              business_id,
              "stripe_frontend",
              "pricing_config",
              json.to_string(frontend_json),
              "",
              // No hash for public keys
              None,
            )
          {
            Ok(stored_key) -> {
              let success_json =
                json.object([
                  #("status", json.string("created")),
                  #("key_id", json.string(stored_key.id)),
                  #("message", json.string("Stripe frontend config saved")),
                ])
              wisp.json_response(json.to_string_tree(success_json), 201)
            }
            Error(_) -> {
              let error_json =
                json.object([#("error", json.string("Failed to save config"))])
              wisp.json_response(json.to_string_tree(error_json), 500)
            }
          }
        }

        "business" | "api" -> {
          // Business keys should be hashed
          case dict.get(req.credentials, "api_key") {
            Ok(api_key) -> {
              // Hash the API key
              let key_hash = crypto.hash_api_key(api_key)

              // Encrypt the credentials
              case encrypt_credentials(req.credentials) {
                Ok(encrypted_credentials) -> {
                  case
                    supabase_client.store_integration_key_with_hash(
                      business_id,
                      req.key_type,
                      req.key_name,
                      encrypted_credentials,
                      key_hash,
                      None,
                    )
                  {
                    Ok(stored_key) -> {
                      let success_json =
                        json.object([
                          #("status", json.string("created")),
                          #("key_id", json.string(stored_key.id)),
                          #("business_id", json.string(business_id)),
                          #("key_type", json.string(req.key_type)),
                          #("key_name", json.string(req.key_name)),
                          #("api_key", json.string(api_key)),
                          // Return plain key ONCE
                          #("is_active", json.bool(stored_key.is_active)),
                          #(
                            "warning",
                            json.string(
                              "Save this key securely. It will not be shown again.",
                            ),
                          ),
                        ])

                      logging.log(
                        logging.Info,
                        "[KeyHandler] ✅ Business key created with hash: "
                          <> stored_key.id,
                      )
                      wisp.json_response(json.to_string_tree(success_json), 201)
                    }
                    Error(err) -> {
                      logging.log(
                        logging.Error,
                        "[KeyHandler] ❌ Database error: " <> string.inspect(err),
                      )
                      let error_json =
                        json.object([
                          #("error", json.string("Internal Server Error")),
                          #("message", json.string("Failed to store key")),
                        ])
                      wisp.json_response(json.to_string_tree(error_json), 500)
                    }
                  }
                }
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
              }
            }
            Error(_) -> {
              let error_json =
                json.object([
                  #("error", json.string("Bad Request")),
                  #("message", json.string("Missing api_key in credentials")),
                ])
              wisp.json_response(json.to_string_tree(error_json), 400)
            }
          }
        }

        _ -> {
          // Other key types - not supported yet
          let error_json =
            json.object([
              #("error", json.string("Bad Request")),
              #(
                "message",
                json.string("Unsupported key type: " <> req.key_type),
              ),
            ])
          wisp.json_response(json.to_string_tree(error_json), 400)
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
