// src/tick_decoder.gleam
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/result

/// Decode Erlang tuple messages like {:tick_1s, "2024-01-15T21:08:54Z"}
/// into Gleam-friendly format
pub fn decode_tick_tuple(
  dyn: dynamic.Dynamic,
) -> Result(#(String, String), List(dynamic.DecodeError)) {
  // Decode as list (Erlang tuples become lists via dynamic)
  case dynamic.list(dynamic.dynamic)(dyn) {
    Ok([tick_atom_dyn, timestamp_dyn]) -> {
      // Decode each element
      case dynamic.atom(tick_atom_dyn), dynamic.string(timestamp_dyn) {
        Ok(tick_atom), Ok(timestamp) -> {
          Ok(#(atom.to_string(tick_atom), timestamp))
        }
        _, _ ->
          Error([dynamic.DecodeError("Expected (atom, string) tuple", "?", [])])
      }
    }
    Ok(_) -> Error([dynamic.DecodeError("Expected 2-element tuple", "?", [])])
    Error(e) -> Error(e)
  }
}

/// Receive any Erlang message
@external(erlang, "gleam_erlang_ffi", "receive")
pub fn receive_any(timeout: Int) -> Result(dynamic.Dynamic, Nil)

/// Receive and decode a tick message
pub fn receive_tick(
  timeout: Int,
) -> Result(#(String, String), List(dynamic.DecodeError)) {
  case receive_any(timeout) {
    Ok(msg) -> decode_tick_tuple(msg)
    Error(_) ->
      Error([dynamic.DecodeError("Timeout receiving message", "?", [])])
  }
}
