// src/types/ip_types.gleam
import gleam/erlang/process.{type Subject}
import gleam/string
import glixir
import utils/utils

/// Messages that can be sent to an IP actor
pub type Message {
  /// Record a request from this IP
  RecordRequest(timestamp: Int)
  /// Check if IP should be rate limited and atomically increment
  CheckAndIncrement(reply: Subject(RateLimitResult))
  /// Get current request count
  GetRequestCount(reply: Subject(Float))
  /// Cleanup tick - check if actor should shut down
  CleanupTick(timestamp: String, tick_type: String)
  /// Shutdown the actor
  Shutdown
}

/// Result of a rate limit check
pub type RateLimitResult {
  /// Request is allowed
  Allowed(current_count: Float, remaining: Float)
  /// Request is rate limited
  RateLimited(current_count: Float, limit: Float, retry_after_seconds: Int)
}

/// IP rate limiting configuration
pub type IpRateLimitConfig {
  IpRateLimitConfig(
    /// Max requests per window (e.g., 6000 for 5 min window = ~20 rps sustained)
    max_requests: Float,
    /// Time window in seconds (e.g., 300 for 5 minutes)
    window_seconds: Int,
    /// Tick type for reset (e.g., "tick_5m" for 5 minute reset)
    tick_type: String,
  )
}

/// Default rate limit: 6000 requests per 5 minutes (sustained ~20 rps)
pub fn default_config() -> IpRateLimitConfig {
  IpRateLimitConfig(
    max_requests: 6000.0,
    window_seconds: 300,
    tick_type: "tick_5m",
  )
}

/// Lookup an IP actor in the registry
pub fn lookup_ip_subject(
  ip_address: String,
) -> Result(Subject(Message), String) {
  let key = "ip:" <> sanitize_ip(ip_address)
  case glixir.lookup_subject_string(utils.tracktags_registry(), key) {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("IP actor not found: " <> key)
  }
}

/// Sanitize IP address for use as registry key (replace dots/colons with underscores)
pub fn sanitize_ip(ip: String) -> String {
  ip
  |> string.replace(".", "_")
  |> string.replace(":", "_")
}
