// src/utils/utils.gleam
import birl
import envoy
import gleam/erlang/atom
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gluid
import logging

// ============================================================================
// COMMON ATOMS - Centralized to avoid typos and easy updates
// ============================================================================

/// Main registry for all TrackTags actors
pub fn tracktags_registry() -> atom.Atom {
  atom.create("tracktags_actors")
}

/// PubSub bus for clock events
pub fn clock_events_bus() -> atom.Atom {
  atom.create("clock_events")
}

/// Supabase actor registry key
pub fn supabase_actor_key() -> atom.Atom {
  atom.create("supabase_actor")
}

/// Clock actor registry key  
pub fn clock_actor_key() -> atom.Atom {
  atom.create("clock_actor")
}

pub fn application_actor_key() -> atom.Atom {
  atom.create("application_actor")
}

pub fn machine_actor_key() -> atom.Atom {
  atom.create("machine_actor")
}

pub fn realtime_actor_key() -> atom.Atom {
  atom.create("realtime_actor")
}

pub fn realtime_events_bus() -> atom.Atom {
  atom.create("realtime_events")
}

// ============================================================================
// ENVIRONMENT HELPERS
// ============================================================================

/// Require an environment variable or crash
pub fn require_env(key: String) -> String {
  case envoy.get(key) {
    Ok(val) -> val
    Error(_) -> {
      logging.log(
        logging.Error,
        "[Utils] Required environment variable '" <> key <> "' was not present",
      )
      panic as "Required environment variable missing"
    }
  }
}

// Get environment variable with default fallback
pub fn get_env_or(key: String, default: String) -> String {
  option.unwrap(
    case envoy.get(key) {
      Ok(val) -> Some(val)
      Error(_) -> None
    },
    default,
  )
}

/// Get current ISO 8601 timestamp string
pub fn current_iso_timestamp() -> String {
  birl.now()
  |> birl.to_iso8601()
}

// ============================================================================
// TIME HELPERS
// ============================================================================

/// Get current system time in nanoseconds
@external(erlang, "os", "system_time")
pub fn system_time() -> Int

/// Get current timestamp in seconds
pub fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}

/// Create a request ID for logging
pub fn generate_request_id() -> String {
  system_time()
  |> to_string()
}

@external(erlang, "erlang", "integer_to_binary")
fn to_string(int: Int) -> String

pub fn generate_random() -> String {
  string.slice(int.to_string(system_time()), -8, 8)
}

pub fn create_business_key() -> String {
  "tk_live_" <> generate_random()
}

pub fn create_customer_key(customer_id: String) -> String {
  "ck_live_" <> customer_id <> "_" <> generate_random()
}

// In utils.gleam, add this function:
pub fn unix_to_iso8601(unix_timestamp: Int) -> String {
  // Convert Unix timestamp to ISO 8601 format
  // This is a simplified version - you might need to use birl properly
  let dt = birl.from_unix(unix_timestamp)
  birl.to_iso8601(dt)
}

pub fn generate_uuid() -> String {
  gluid.guidv4()
}
