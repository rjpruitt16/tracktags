// src/clients/clockwork_client.gleam
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process

// Result types from our Elixir wrapper
pub type SseStartResult {
  SseStarted(ref: Dynamic)
  SseError(reason: String)
}

pub type SseEventResult {
  TickEvent(tick_name: String, timestamp: String)
  ParseError(reason: String)
}

// FFI to our Elixir wrapper
@external(erlang, "Elixir.HttpoisonSse", "start_sse")
pub fn start_sse_ffi(
  url: String,
  pid: process.Pid,
  retry_count: Int,
) -> SseStartResult

@external(erlang, "Elixir.HttpoisonSse", "stream_next")
pub fn stream_next(ref: Dynamic) -> atom.Atom

@external(erlang, "Elixir.HttpoisonSse", "parse_sse_event")
pub fn parse_sse_event(event_data: String) -> SseEventResult

@external(erlang, "Elixir.HttpoisonSse", "extract_complete_events")
pub fn extract_complete_events(buffer: String) -> #(List(String), String)
