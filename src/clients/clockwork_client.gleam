// src/clients/clockwork_client.gleam
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/string
import glixir
import logging

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
pub fn start_sse_ffi(url: String, pid: process.Pid) -> SseStartResult

@external(erlang, "Elixir.HttpoisonSse", "stream_next")
pub fn stream_next(ref: Dynamic) -> atom.Atom

@external(erlang, "Elixir.HttpoisonSse", "parse_sse_event")
pub fn parse_sse_event(event_data: String) -> SseEventResult

@external(erlang, "Elixir.HttpoisonSse", "extract_complete_events")
pub fn extract_complete_events(buffer: String) -> #(List(String), String)

// Start SSE connection
pub fn start_sse_connection(url: String) -> Result(Dynamic, String) {
  logging.log(logging.Info, "[SSE Client] Connecting to: " <> url)

  case start_sse_ffi(url, process.self()) {
    SseStarted(ref) -> {
      logging.log(logging.Info, "[SSE Client] Connection established")
      Ok(ref)
    }
    SseError(reason) -> {
      logging.log(logging.Error, "[SSE Client] Connection failed: " <> reason)
      Error(reason)
    }
  }
}
