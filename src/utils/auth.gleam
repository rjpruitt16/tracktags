// src/utils/auth.gleam - FIXED VERSION
import clients/supabase_client
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import glixir
import logging
import types/application_types
import types/business_types
import types/customer_types
import utils/crypto
import utils/utils
import wisp.{type Request, type Response}

pub type ActorAuth {
  BusinessActor(
    business_id: String,
    subject: process.Subject(business_types.Message),
  )
  CustomerActor(
    business_id: String,
    customer_id: String,
    subject: process.Subject(customer_types.Message),
  )
}

// src/utils/auth.gleam
pub type AuthResult {
  ActorCached(actor: ActorAuth)
  DatabaseValid(validation: supabase_client.KeyValidation)
  InvalidKey(reason: String)
}

/// Initialize the API key registries
pub fn init_auth_registries() -> Result(Nil, String) {
  // Business API keys registry
  use _ <- result.try(
    glixir.start_registry(business_api_keys_registry())
    |> result.map_error(fn(e) {
      "Failed to start business keys registry: " <> string.inspect(e)
    }),
  )
  logging.log(logging.Info, "[Auth] Business API keys registry started")

  // Customer API keys registry  
  use _ <- result.try(
    glixir.start_registry(customer_api_keys_registry())
    |> result.map_error(fn(e) {
      "Failed to start customer keys registry: " <> string.inspect(e)
    }),
  )
  logging.log(logging.Info, "[Auth] Customer API keys registry started")

  Ok(Nil)
}

fn business_api_keys_registry() -> atom.Atom {
  atom.create("business_api_keys")
}

fn customer_api_keys_registry() -> atom.Atom {
  atom.create("customer_api_keys")
}

/// Business actors call this when they start up
pub fn register_business_api_key(
  api_key_hash: String,
  subject: process.Subject(business_types.Message),
) -> Result(Nil, String) {
  let key = "apikey:" <> api_key_hash

  case
    glixir.register_subject_string(business_api_keys_registry(), key, subject)
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[Auth] Registered business actor for key hash: "
          <> string.slice(api_key_hash, 0, 10)
          <> "...",
      )
      Ok(Nil)
    }
    Error(e) -> Error("Failed to register business key: " <> string.inspect(e))
  }
}

/// Customer actors call this when they start up
pub fn register_customer_api_key(
  api_key_hash: String,
  subject: process.Subject(customer_types.Message),
) -> Result(Nil, String) {
  let key = "apikey:" <> api_key_hash

  case
    glixir.register_subject_string(customer_api_keys_registry(), key, subject)
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[Auth] Registered customer actor for key hash: "
          <> string.slice(api_key_hash, 0, 10)
          <> "...",
      )
      Ok(Nil)
    }
    Error(e) -> Error("Failed to register customer key: " <> string.inspect(e))
  }
}

/// Validates API key - checks both registries, then database
pub fn validate_api_key_with_cache(api_key: String) -> AuthResult {
  let key_hash = crypto.hash_api_key(api_key)
  let lookup_key = "apikey:" <> key_hash

  // Check business registry first
  case glixir.lookup_subject_string(business_api_keys_registry(), lookup_key) {
    Ok(business_subject) -> {
      // Need to get business_id - validate against DB to get the ID
      case supabase_client.validate_api_key(api_key) {
        Ok(supabase_client.BusinessKey(business_id)) -> {
          logging.log(logging.Debug, "[Auth] Found cached business actor")
          ActorCached(BusinessActor(business_id, business_subject))
        }
        _ -> {
          // Registry out of sync? Fall through to DB validation
          validate_from_database(api_key)
        }
      }
    }
    Error(_) -> {
      // Not in business registry, check customer registry
      case
        glixir.lookup_subject_string(customer_api_keys_registry(), lookup_key)
      {
        Ok(customer_subject) -> {
          // Get IDs from DB validation
          case supabase_client.validate_api_key(api_key) {
            Ok(supabase_client.CustomerKey(business_id, customer_id)) -> {
              logging.log(logging.Debug, "[Auth] Found cached customer actor")
              ActorCached(CustomerActor(
                business_id,
                customer_id,
                customer_subject,
              ))
            }
            _ -> {
              // Registry out of sync? Fall through to DB validation
              validate_from_database(api_key)
            }
          }
        }
        Error(_) -> {
          // Not in either registry, validate against database
          validate_from_database(api_key)
        }
      }
    }
  }
}

fn validate_from_database(api_key: String) -> AuthResult {
  case supabase_client.validate_api_key(api_key) {
    Ok(validation) -> {
      logging.log(logging.Debug, "[Auth] Key validated from database")
      DatabaseValid(validation)
    }
    Error(e) -> InvalidKey(string.inspect(e))
  }
}

/// Extract API key from request headers
pub fn extract_api_key(req: Request) -> Result(String, String) {
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

///  Check for admin key in X-Admin-Key header
fn check_admin_key(req: Request) -> Bool {
  case list.key_find(req.headers, "x-admin-key") {
    Ok(admin_key) -> {
      let expected = utils.require_env("ADMIN_SECRET_KEY")
      logging.log(
        logging.Info,
        "[Auth] Comparing admin keys - received length: "
          <> int.to_string(string.length(admin_key))
          <> ", expected length: "
          <> int.to_string(string.length(expected)),
      )
      // Log first few characters for debugging
      logging.log(
        logging.Info,
        "[Auth] Received starts with: "
          <> string.slice(admin_key, 0, 5)
          <> ", Expected starts with: "
          <> string.slice(expected, 0, 5),
      )
      admin_key == expected
    }
    Error(_) -> {
      logging.log(logging.Info, "[Auth] No X-Admin-Key header found")
      False
    }
  }
}

/// Updated with_auth that checks admin header first
pub fn with_auth(
  req: Request,
  handler: fn(AuthResult, String, Bool) -> Response,
) -> Response {
  // Check for admin access first (separate header)
  case check_admin_key(req) {
    True -> {
      // Admin authenticated via X-Admin-Key header
      handler(
        DatabaseValid(supabase_client.BusinessKey("admin")),
        "admin",
        True,
      )
    }
    False -> {
      // Check regular Authorization header
      case extract_api_key(req) {
        Error(error) -> handler(InvalidKey(error), "", False)
        Ok(api_key) -> {
          // Regular key validation (no longer checking for admin in Authorization)
          let auth_result = validate_api_key_with_cache(api_key)
          handler(auth_result, api_key, False)
        }
      }
    }
  }
}

fn get_application_actor() -> Result(
  process.Subject(application_types.ApplicationMessage),
  String,
) {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.application_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Application actor not found")
  }
}

pub fn ensure_actor_from_auth(
  auth_result: AuthResult,
  api_key: String,
) -> Result(ActorAuth, String) {
  case auth_result {
    ActorCached(actor) -> Ok(actor)

    DatabaseValid(validation) -> {
      case validation {
        supabase_client.BusinessKey(business_id) -> {
          ensure_business_actor(business_id, api_key)
        }
        supabase_client.CustomerKey(business_id, customer_id) -> {
          case
            supabase_client.get_customer_full_context(business_id, customer_id)
          {
            Ok(context) ->
              ensure_customer_actor(business_id, customer_id, api_key, context)
            Error(e) ->
              Error("Failed to get customer context: " <> string.inspect(e))
          }
        }
      }
    }

    InvalidKey(reason) -> Error(reason)
  }
}

fn ensure_business_actor(
  business_id: String,
  api_key: String,
) -> Result(ActorAuth, String) {
  case get_application_actor() {
    Ok(app_actor) -> {
      let reply = process.new_subject()

      process.send(
        app_actor,
        application_types.EnsureBusinessActor(business_id, api_key, reply),
      )

      case process.receive(reply, 1000) {
        Ok(Ok(business_subject)) -> {
          // Register the API key for this actor
          let key_hash = crypto.hash_api_key(api_key)
          let _ = register_business_api_key(key_hash, business_subject)

          Ok(BusinessActor(business_id, business_subject))
        }
        Ok(Error(e)) -> Error(e)
        Error(_) -> Error("Timeout ensuring business actor")
      }
    }
    Error(e) -> Error(e)
  }
}

fn ensure_customer_actor(
  business_id: String,
  customer_id: String,
  api_key: String,
  context: customer_types.CustomerContext,
) -> Result(ActorAuth, String) {
  case get_application_actor() {
    Ok(app_actor) -> {
      let reply = process.new_subject()

      process.send(
        app_actor,
        application_types.EnsureCustomerActor(
          business_id,
          customer_id,
          context,
          api_key,
          reply,
        ),
      )

      case process.receive(reply, 1000) {
        Ok(Ok(customer_subject)) -> {
          // Register the API key for this actor
          let key_hash = crypto.hash_api_key(api_key)
          let _ = register_customer_api_key(key_hash, customer_subject)

          Ok(CustomerActor(business_id, customer_id, customer_subject))
        }
        Ok(Error(e)) -> Error(e)
        Error(_) -> Error("Timeout ensuring customer actor")
      }
    }
    Error(e) -> Error(e)
  }
}
