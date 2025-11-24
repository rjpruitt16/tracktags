// src/utils/ip_ban.gleam
// Simple IP ban management using Cachex for fast lookups
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import logging
import utils/cachex

/// Cache name for banned IPs
const banned_ips_cache = "banned_ips_cache"

/// Default ban duration: 5 minutes (300,000 ms)
const default_ban_ttl_ms = 300_000

/// Initialize the banned IPs cache (call from tracktags.gleam startup)
pub fn init() -> Result(Nil, String) {
  case cachex.start_link(banned_ips_cache, []) {
    Ok(_) -> {
      logging.log(logging.Info, "[IpBan] Banned IPs cache initialized")
      Ok(Nil)
    }
    Error(e) -> {
      // Already started is OK
      case string.contains(e, "already_started") {
        True -> Ok(Nil)
        False -> Error("Failed to init IP ban cache: " <> e)
      }
    }
  }
}

/// Check if an IP is banned (fast O(1) lookup)
pub fn is_banned(ip: String) -> Bool {
  let key = sanitize_ip(ip)
  case cachex.exists(banned_ips_cache, key) {
    Ok(True) -> True
    Ok(False) -> False
    Error(_) -> False
    // Fail open on cache errors
  }
}

/// Ban an IP for the default duration (5 minutes)
pub fn ban_ip(ip: String) -> Result(Nil, String) {
  ban_ip_for(ip, default_ban_ttl_ms)
}

/// Ban an IP for a specific duration in milliseconds
pub fn ban_ip_for(ip: String, ttl_ms: Int) -> Result(Nil, String) {
  let key = sanitize_ip(ip)
  logging.log(
    logging.Warning,
    "[IpBan] Banning IP: " <> ip <> " for " <> int.to_string(ttl_ms) <> "ms",
  )
  case cachex.put_with_ttl(banned_ips_cache, key, True, ttl_ms) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("Failed to ban IP: " <> e)
  }
}

/// Unban an IP (remove from ban list)
pub fn unban_ip(ip: String) -> Result(Nil, String) {
  let key = sanitize_ip(ip)
  logging.log(logging.Info, "[IpBan] Unbanning IP: " <> ip)
  case cachex.delete(banned_ips_cache, key) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("Failed to unban IP: " <> e)
  }
}

/// Get ban info for an IP (returns Some(True) if banned)
pub fn get_ban_status(ip: String) -> Result(Bool, String) {
  let key = sanitize_ip(ip)
  case cachex.get(banned_ips_cache, key) {
    Ok(Some(_)) -> Ok(True)
    Ok(None) -> Ok(False)
    Error(e) -> Error(e)
  }
}

/// Sanitize IP for cache key (same as ip_types)
fn sanitize_ip(ip: String) -> String {
  ip
  |> string.replace(".", "_")
  |> string.replace(":", "_")
}

