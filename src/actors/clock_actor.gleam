// src/actors/clock_actor.gleam - Enhanced with debug logging and shutdown
import clients/clockwork_client
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import glixir
import logging
import utils/utils

// ───────────── Messages ─────────────
pub type Message {
  TickEvent(tick_name: String, timestamp: String)
  SseClosed(reason: String)
  RetryConnect(retry_count: Int)
  StoreSubject(subject: process.Subject(Message))
  Shutdown
}

// ───────────── State ─────────────
pub type State {
  State(
    url: String,
    pubsub_name: atom.Atom,
    restart_count: Int,
    self_subject: Option(process.Subject(Message)),
  )
}

// ───────────────────────────────────────────────────────────────────────────────
//  PUBLIC FFI  –  called from Elixir
// ───────────────────────────────────────────────────────────────────────────────

pub fn reconnect(retry_count: Int) {
  logging.log(
    logging.Info,
    "[ClockActor] 🎯 Reconnect attempt " <> int.to_string(retry_count + 1),
  )
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.clock_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subj) -> {
      process.send(subj, RetryConnect(retry_count))
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Registry lookup failed: " <> string.inspect(err),
      )
    }
  }
}

/// Elixir passes every parsed tick here.
pub fn process_tick_event(tick: String, ts: String) -> Nil {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.clock_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subj) -> {
      logging.log(
        logging.Info,
        "[ClockActor] ✅ Found clock_actor subject, sending TickEvent",
      )
      process.send(subj, TickEvent(tick, ts))
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Registry lookup failed: " <> string.inspect(err),
      )
      logging.log(
        logging.Error,
        "[ClockActor] ❌ clock_actor not found in registry",
      )
    }
  }
}

/// Elixir calls this once the SSE loop ends/crashes.
pub fn sse_closed(reason: String) -> Nil {
  logging.log(logging.Info, "[ClockActor] 🔥 SSE CLOSED FFI CALL: " <> reason)

  case
    glixir.lookup_subject(
      atom.create("tracktags_actors"),
      atom.create("clock_actor"),
      glixir.atom_key_encoder,
    )
  {
    Ok(subj) -> {
      logging.log(
        logging.Info,
        "[ClockActor] ✅ Found clock_actor subject, sending SseClosed",
      )
      process.send(subj, SseClosed(reason))
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Registry lookup failed for SseClosed: "
          <> string.inspect(err),
      )
    }
  }
}

// ───────────── Helpers ─────────────
fn topic_for_tick(t: String) -> String {
  "tick:" <> t
}

fn encode_tick_message(tick_data: #(String, String)) -> String {
  let #(tick_name, timestamp) = tick_data
  let json_result =
    json.object([
      #("tick_name", json.string(tick_name)),
      #("timestamp", json.string(timestamp)),
    ])
    |> json.to_string

  // 🔍 DEBUG: Let's see what we're actually creating
  logging.log(
    logging.Info,
    "[ClockActor] 🔍 Encoded JSON: " <> string.inspect(json_result),
  )

  json_result
}

fn broadcast_tick(bus: atom.Atom, tick: String, ts: String) -> Nil {
  logging.log(
    logging.Info,
    "[ClockActor] 📡 BROADCASTING TICK: "
      <> tick
      <> " on bus: "
      <> atom.to_string(bus),
  )

  let tick_data = #(tick, ts)
  let topic = topic_for_tick(tick)
  let all_topic = topic_for_tick("all")

  logging.log(logging.Info, "[ClockActor] 📡 Broadcasting to topic: " <> topic)

  case glixir.pubsub_broadcast(bus, topic, tick_data, encode_tick_message) {
    Ok(_) ->
      logging.log(
        logging.Info,
        "[ClockActor] ✅ Broadcast successful: " <> topic,
      )
    Error(e) ->
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Broadcast failed: "
          <> topic
          <> " - "
          <> string.inspect(e),
      )
  }

  logging.log(
    logging.Info,
    "[ClockActor] 📡 Broadcasting to all topic: " <> all_topic,
  )
  case glixir.pubsub_broadcast(bus, all_topic, tick_data, encode_tick_message) {
    Ok(_) ->
      logging.log(
        logging.Info,
        "[ClockActor] ✅ Broadcast successful: " <> all_topic,
      )
    Error(e) ->
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Broadcast failed: "
          <> all_topic
          <> " - "
          <> string.inspect(e),
      )
  }
}

fn start_sse(url: String, parent_pid: process.Pid, retry_count: Int) -> Nil {
  logging.log(
    logging.Info,
    "[ClockActor] 🚀 Starting SSE connection to: " <> url,
  )

  // call the raw FFI; parent receives {:tick_event,…} via other FFI calls
  case clockwork_client.start_sse_ffi(url, parent_pid, retry_count) {
    clockwork_client.SseStarted(_) -> {
      logging.log(
        logging.Info,
        "[ClockActor] ✅ SSE worker started successfully",
      )
    }
    clockwork_client.SseError(r) -> {
      logging.log(logging.Error, "[ClockActor] ❌ SSE start error: " <> r)
    }
  }
}

// ───────────── Handler ─────────────
fn handle_message(st: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    TickEvent(t, ts) -> {
      case t {
        "tick_1s" -> Nil
        // Silent
        _ ->
          logging.log(
            logging.Info,
            "[ClockActor] 🎯 PROCESSING TickEvent: " <> t <> " at " <> ts,
          )
      }
      broadcast_tick(st.pubsub_name, t, ts)
      actor.continue(State(..st, restart_count: 0))
    }
    SseClosed(reason) -> {
      logging.log(logging.Warning, "[ClockActor] ⚠️ SSE closed: " <> reason)
      case
        glixir.lookup_subject(
          utils.tracktags_registry(),
          utils.clock_actor_key(),
          glixir.atom_key_encoder,
        )
      {
        Ok(subj) -> {
          logging.log(
            logging.Info,
            "[ClockActor] ✅ Found clock_actor subject, sending TickEvent",
          )
          process.send(subj, RetryConnect(st.restart_count))
        }
        Error(err) -> {
          logging.log(
            logging.Error,
            "[ClockActor] ❌ Registry lookup failed: " <> string.inspect(err),
          )
          logging.log(
            logging.Error,
            "[ClockActor] ❌ clock_actor not found in registry",
          )
        }
      }

      // Start with retry 0
      actor.continue(st)
    }

    RetryConnect(retry_count) -> {
      let backoff_ms = case retry_count {
        0 -> 1000
        1 -> 2000
        2 -> 4000
        3 -> 8000
        4 -> 16_000
        _ -> 30_000
      }
      logging.log(
        logging.Info,
        "[ClockActor] 🔄 Retrying in " <> int.to_string(backoff_ms) <> "ms...",
      )

      process.sleep(backoff_ms)
      start_sse(st.url, process.self(), retry_count)
      actor.continue(State(..st, restart_count: retry_count))
    }
    StoreSubject(subject) -> {
      logging.log(logging.Info, "[ClockActor] 📝 Storing self subject reference")
      actor.continue(State(..st, self_subject: Some(subject)))
    }

    Shutdown -> {
      logging.log(logging.Info, "[ClockActor] 🛑 Graceful shutdown requested")
      // TODO: Stop SSE connection if needed
      actor.stop()
    }
  }
}

// ───────────── Bootstrap ─────────────
pub fn start(url: String) -> Result(process.Subject(Message), actor.StartError) {
  logging.log(
    logging.Info,
    "[ClockActor] 🚀 Starting ClockActor with URL: " <> url,
  )

  let bus = atom.create("clock_events")
  logging.log(
    logging.Info,
    "[ClockActor] 🚀 Starting PubSub bus: " <> atom.to_string(bus),
  )

  let assert Ok(_) = glixir.pubsub_start(bus)
  logging.log(
    logging.Info,
    "[ClockActor] ✅ PubSub bus started: " <> atom.to_string(bus),
  )

  let init_state =
    State(url: url, pubsub_name: bus, restart_count: 0, self_subject: None)

  case
    actor.new(init_state) |> actor.on_message(handle_message) |> actor.start()
  {
    Error(e) -> {
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Failed to start actor: " <> string.inspect(e),
      )
      Error(e)
    }

    Ok(started) -> {
      let subj = started.data
      logging.log(logging.Info, "[ClockActor] ✅ Actor started successfully")

      // register so Elixir can FFI-call us
      logging.log(
        logging.Info,
        "[ClockActor] 📝 Registering in registry as 'clock_actor'",
      )
      case
        glixir.register_subject(
          atom.create("tracktags_actors"),
          atom.create("clock_actor"),
          subj,
          glixir.atom_key_encoder,
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[ClockActor] ✅ Successfully registered in registry",
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[ClockActor] ❌ Failed to register in registry: "
              <> string.inspect(e),
          )
        }
      }

      // spin up SSE worker (linked)
      logging.log(logging.Info, "[ClockActor] 🚀 Starting SSE worker")
      start_sse(url, process.self(), 0)

      logging.log(logging.Info, "[ClockActor] 🎉 ClockActor fully initialized")
      Ok(subj)
    }
  }
}

// Optional helpers for other modules
pub fn get_pubsub_name() -> atom.Atom {
  atom.create("clock_events")
}

pub fn get_tick_topic(tick: String) -> String {
  topic_for_tick(tick)
}
