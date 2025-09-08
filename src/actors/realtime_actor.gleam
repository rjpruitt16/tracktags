// src/actors/realtime_actor.gleam - FIXED JSON PARSING
import clients/supabase_realtime_client
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import logging
import utils/utils

pub type Message {
  Connect
  Reconnect(retry_count: Int)
  PublishTableChange(
    table: String,
    event_type: String,
    record_json: String,
    old_record_json: String,
  )
  Shutdown
}

pub type State {
  State(retry_count: Int)
}

pub fn start() -> Result(process.Subject(Message), actor.StartError) {
  let initial_state = State(retry_count: 0)

  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) {
    // Register in registry
    let _ =
      glixir.register_subject(
        utils.tracktags_registry(),
        utils.realtime_actor_key(),
        started.data,
        glixir.atom_key_encoder,
      )
    started.data
  })
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Connect -> {
      logging.log(logging.Info, "[RealtimeActor] Starting realtime connection")
      case
        supabase_realtime_client.start_realtime_connection(state.retry_count)
      {
        supabase_realtime_client.RealtimeStarted(ref) -> {
          logging.log(
            logging.Info,
            "[RealtimeActor] Realtime connection started: "
              <> string.inspect(ref),
          )
        }
        supabase_realtime_client.RealtimeError(reason) -> {
          logging.log(
            logging.Error,
            "[RealtimeActor] Failed to start: " <> reason,
          )
          // Elixir will handle reconnect
        }
      }
      actor.continue(state)
    }

    Reconnect(count) -> {
      logging.log(
        logging.Info,
        "[RealtimeActor] Reconnecting, attempt: " <> string.inspect(count),
      )

      case supabase_realtime_client.start_realtime_connection(count) {
        supabase_realtime_client.RealtimeStarted(_) -> {
          logging.log(logging.Info, "[RealtimeActor] Reconnected")
          actor.continue(State(retry_count: 0))
        }
        supabase_realtime_client.RealtimeError(reason) -> {
          logging.log(
            logging.Error,
            "[RealtimeActor] Reconnect failed: " <> reason,
          )
          actor.continue(State(retry_count: count))
        }
      }
    }

    PublishTableChange(table, event_type, record_json, old_record_json) -> {
      // Route to appropriate channel with raw JSON strings
      let channel = case table {
        "businesses" -> {
          // Try to extract just the ID for routing
          case extract_id(record_json, "business_id") {
            Ok(id) -> "businesses:update:" <> id
            Error(_) -> "businesses:" <> event_type
          }
        }
        "customers" -> {
          case extract_id(record_json, "customer_id") {
            Ok(id) -> "customers:update:" <> id
            Error(_) -> "customers:" <> event_type
          }
        }
        _ -> table <> ":" <> event_type
      }

      // Broadcast the raw JSON strings - actors will decode
      let message =
        json.object([
          #("table", json.string(table)),
          #("event", json.string(event_type)),
          #("record_json", json.string(record_json)),
          #("old_record_json", json.string(old_record_json)),
          #("timestamp", json.int(utils.current_timestamp())),
        ])

      let _ =
        glixir.pubsub_broadcast(
          utils.realtime_events_bus(),
          channel,
          json.to_string(message),
          fn(x) { x },
        )

      actor.continue(state)
    }
    Shutdown -> {
      logging.log(logging.Info, "[RealtimeActor] Shutting down")
      actor.stop()
    }
  }
}

pub fn publish_table_change(
  table: String,
  event_type: String,
  record_json: String,
  old_record_json: String,
) -> Nil {
  case lookup_realtime_actor() {
    Ok(actor) -> {
      // Don't decode here - just pass the raw strings
      // Let each actor decode with their own types
      process.send(
        actor,
        PublishTableChange(
          table,
          event_type,
          record_json,
          // Keep as string
          old_record_json,
          // Keep as string
        ),
      )
    }
    Error(_) -> Nil
  }
}

fn lookup_realtime_actor() -> Result(process.Subject(Message), String) {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.realtime_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Realtime actor not found")
  }
}

// Called by Elixir to trigger reconnect
pub fn handle_reconnect(retry_count: Int) -> Nil {
  case lookup_realtime_actor() {
    Ok(actor) -> process.send(actor, Reconnect(retry_count))
    Error(_) -> Nil
  }
}

// Simple ID extractor just for routing
fn extract_id(json_str: String, field: String) -> Result(String, Nil) {
  let decoder = decode.field(field, decode.string, decode.success)
  // Use decode.field
  case json.parse(json_str, decoder) {
    Ok(id) -> Ok(id)
    Error(_) -> Error(Nil)
  }
}
