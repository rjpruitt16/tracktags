// src/utils/utils.gleam
import envoy
import gleam/option.{None, Some}
import logging

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

/// Get environment variable with default fallback
pub fn get_env_or(key: String, default: String) -> String {
  option.unwrap(
    case envoy.get(key) {
      Ok(val) -> Some(val)
      Error(_) -> None
    },
    default,
  )
}

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
