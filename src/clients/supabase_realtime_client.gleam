// src/customers/supabase_realtime_customer.gleam
import gleam/dynamic.{type Dynamic}
import gleam/string
import utils/utils

// Result types from our Elixir wrapper
pub type RealtimeStartResult {
  RealtimeStarted(ref: Dynamic)
  RealtimeError(reason: String)
}

pub type RealtimeEventResult {
  PlanLimitUpdate(business_id: String, customer_id: String)
  ParseError(reason: String)
  Ignore
}

// FFI to our Elixir wrapper
@external(erlang, "Elixir.SupabaseRealtime", "start_realtime_connection")
fn start_realtime_connection_ffi(
  realtime_url: String,
  anon_key: String,
  retry_count: Int,
) -> RealtimeStartResult

@external(erlang, "Elixir.SupabaseRealtime", "parse_realtime_event")
pub fn parse_realtime_event(event_data: String) -> RealtimeEventResult

pub fn start_realtime_connection(retry_count: Int) -> RealtimeStartResult {
  let url = get_supabase_realtime_url()
  let key = utils.require_env("SUPABASE_ANON_KEY")
  start_realtime_connection_ffi(url, key, retry_count)
}

pub fn get_supabase_realtime_url() -> String {
  let base_url = utils.require_env("SUPABASE_URL")
  // Convert https://your-project.supabase.co to wss://your-project.supabase.co/realtime/v1/websocket
  string.replace(base_url, "https://", "wss://") <> "/realtime/v1/websocket"
}

pub fn get_supabase_anon_key() -> String {
  utils.require_env("SUPABASE_KEY")
  // Reuse existing key
}
