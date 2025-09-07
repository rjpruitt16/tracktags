// src/actors/clock_actor.gleam - Internal tick generation (no SSE)
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/string
import glixir
import logging
import utils/utils

// ───────────── Messages ─────────────
pub type Message {
  CheckTicks
  InitializeSelf(process.Subject(Message))
  Shutdown
}

// ───────────── State ─────────────
pub type State {
  State(
    pubsub_name: atom.Atom,
    tick_intervals: Dict(String, TickInterval),
    self_subject: process.Subject(Message),
  )
}

pub type TickInterval {
  TickInterval(name: String, interval_seconds: Int, next_tick_time: Int)
}

// ───────────── Tick Management ─────────────

/// All tick intervals in seconds (copied from Clockwork)
fn get_tick_intervals() -> Dict(String, Int) {
  dict.from_list([
    #("tick_5s", 5),
    #("tick_15s", 15),
    #("tick_30s", 30),
    #("tick_1m", 60),
    #("tick_15m", 900),
    #("tick_30m", 1800),
    #("tick_1h", 3600),
    #("tick_6h", 21_600),
    #("tick_1d", 86_400),
    #("tick_1w", 604_800),
    #("tick_1mo", 2_592_000),
  ])
}

/// Calculate next tick time aligned to interval boundary
fn calculate_next_tick(now: Int, interval: Int) -> Int {
  now + { interval - { now % interval } }
}

/// Maximum allowed drift before realigning (10 seconds)
const max_drift = 10

/// Initialize tick intervals with their next fire times
fn initialize_tick_intervals(now: Int) -> Dict(String, TickInterval) {
  get_tick_intervals()
  |> dict.map_values(fn(name, interval_seconds) {
    let next_tick_time = calculate_next_tick(now, interval_seconds)
    TickInterval(name, interval_seconds, next_tick_time)
  })
}

/// Check which ticks should fire and update their next fire times
fn check_and_fire_ticks(
  state: State,
) -> #(Dict(String, TickInterval), List(String)) {
  let now = utils.current_timestamp()

  let #(fired_ticks, updated_intervals) =
    dict.fold(state.tick_intervals, #([], dict.new()), fn(acc, name, interval) {
      let #(fired_list, updated_dict) = acc

      case now >= interval.next_tick_time {
        True -> {
          // This tick should fire
          let drift = now - interval.next_tick_time

          let new_next_time = case drift > max_drift {
            True -> {
              // Too much drift, realign to next boundary
              logging.log(
                logging.Warning,
                "[ClockActor] Tick "
                  <> name
                  <> " drifted by "
                  <> int.to_string(drift)
                  <> "s, realigning",
              )
              calculate_next_tick(now, interval.interval_seconds)
            }
            False -> {
              // Normal operation: advance by interval
              advance_to_next_tick(
                interval.next_tick_time,
                now,
                interval.interval_seconds,
              )
            }
          }

          let updated_interval =
            TickInterval(
              name: interval.name,
              interval_seconds: interval.interval_seconds,
              next_tick_time: new_next_time,
            )

          #(
            [name, ..fired_list],
            dict.insert(updated_dict, name, updated_interval),
          )
        }
        False -> {
          // This tick doesn't fire yet
          #(fired_list, dict.insert(updated_dict, name, interval))
        }
      }
    })

  #(updated_intervals, fired_ticks)
}

/// Advance to the next tick time that's after 'now' (handles catch-up)
fn advance_to_next_tick(next_time: Int, now: Int, interval: Int) -> Int {
  case next_time > now {
    True -> next_time
    False -> advance_to_next_tick(next_time + interval, now, interval)
  }
}

// ───────────── PubSub Helpers ─────────────

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

// ───────────── Message Handler ─────────────
fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    InitializeSelf(self_subject) -> {
      // Update state with proper self-reference and start tick loop
      let new_state =
        State(
          pubsub_name: state.pubsub_name,
          tick_intervals: state.tick_intervals,
          self_subject: self_subject,
        )

      // Start the tick checking loop
      process.send_after(self_subject, 500, CheckTicks)

      actor.continue(new_state)
    }

    CheckTicks -> {
      let #(updated_intervals, fired_ticks) = check_and_fire_ticks(state)
      let now_string = int.to_string(utils.current_timestamp())

      // Broadcast each fired tick
      list.each(fired_ticks, fn(tick_name) {
        // Skip logging for tick_1s to reduce noise (if we add it later)
        logging.log(
          logging.Info,
          "[ClockActor] 🎯 FIRING TICK: " <> tick_name <> " at " <> now_string,
        )
        broadcast_tick(state.pubsub_name, tick_name, now_string)
      })

      // Schedule next check in 500ms using stored self-reference
      process.send_after(state.self_subject, 500, CheckTicks)

      // Continue with updated state
      let new_state =
        State(
          pubsub_name: state.pubsub_name,
          tick_intervals: updated_intervals,
          self_subject: state.self_subject,
        )

      actor.continue(new_state)
    }

    Shutdown -> {
      logging.log(logging.Info, "[ClockActor] 🛑 Graceful shutdown requested")
      actor.stop()
    }
  }
}

// ───────────── Bootstrap ─────────────
pub fn start() -> Result(process.Subject(Message), actor.StartError) {
  logging.log(
    logging.Info,
    "[ClockActor] 🚀 Starting ClockActor with internal tick generation",
  )

  let bus = utils.clock_events_bus()
  logging.log(
    logging.Info,
    "[ClockActor] 🚀 Starting PubSub bus: " <> atom.to_string(bus),
  )

  let assert Ok(_) = glixir.pubsub_start(bus)
  logging.log(
    logging.Info,
    "[ClockActor] ✅ PubSub bus started: " <> atom.to_string(bus),
  )

  let now = utils.current_timestamp()
  let tick_intervals = initialize_tick_intervals(now)

  logging.log(
    logging.Info,
    "[ClockActor] 📅 Initialized "
      <> int.to_string(dict.size(tick_intervals))
      <> " tick intervals",
  )

  // We need a placeholder subject initially - will be updated below
  let placeholder_subject = process.new_subject()

  let init_state =
    State(
      pubsub_name: bus,
      tick_intervals: tick_intervals,
      self_subject: placeholder_subject,
    )

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

      // Register in the registry for other actors to find
      logging.log(
        logging.Info,
        "[ClockActor] 📝 Registering in registry as 'clock_actor'",
      )
      case
        glixir.register_subject(
          utils.tracktags_registry(),
          utils.clock_actor_key(),
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

      // Initialize the actor with proper self-reference
      logging.log(logging.Info, "[ClockActor] ⏰ Initializing tick generation")

      // Send initialization message to set up self-reference and start ticking
      process.send(subj, InitializeSelf(subj))

      logging.log(logging.Info, "[ClockActor] 🎉 ClockActor fully initialized")
      Ok(subj)
    }
  }
}

// ───────────── Public Helpers ─────────────
/// Get the PubSub bus name for external subscribers
pub fn get_pubsub_name() -> atom.Atom {
  utils.clock_events_bus()
}

/// Get the topic name for a specific tick
pub fn get_tick_topic(tick: String) -> String {
  topic_for_tick(tick)
}
