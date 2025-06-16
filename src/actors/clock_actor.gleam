import clockwork_types.{
  type ClockMessage, type ClockStatus, type ClockTick, type TickNotification,
  ClockDisconnected, ClockReconnected, ClockStatus, GetStatus, SSEConnected,
  SSEDisconnected, Shutdown, Subscribe, Tick, TickReceived, Unsubscribe,
}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervisor
import gleam/result
import gleam/string

// Internal state
type State {
  State(
    subscribers: Dict(String, List(process.Subject(TickNotification))),
    connected: Bool,
    total_ticks: Int,
    start_time: Int,
    clockwork_url: String,
  )
}

// Actor implementation
fn handle_message(
  message: ClockMessage,
  state: State,
) -> actor.Next(ClockMessage, State) {
  case message {
    Subscribe(tick, subscriber) -> {
      io.println("[Clock] New subscription for: " <> tick)

      let current = dict.get(state.subscribers, tick) |> result.unwrap([])
      let updated = case list.contains(current, subscriber) {
        True -> current
        False -> [subscriber, ..current]
      }

      let new_subscribers = dict.insert(state.subscribers, tick, updated)

      // Notify about connection status
      case state.connected {
        False -> process.send(subscriber, ClockDisconnected)
        True -> Nil
      }

      actor.continue(State(..state, subscribers: new_subscribers))
    }

    Unsubscribe(tick, subscriber) -> {
      let updated_subs = case dict.get(state.subscribers, tick) {
        Ok(subs) -> {
          let filtered = list.filter(subs, fn(s) { s != subscriber })
          case filtered {
            [] -> dict.delete(state.subscribers, tick)
            _ -> dict.insert(state.subscribers, tick, filtered)
          }
        }
        Error(_) -> state.subscribers
      }

      actor.continue(State(..state, subscribers: updated_subs))
    }

    TickReceived(event) -> {
      io.println("[Clock] 🎯 Received tick: " <> event.name)

      // Send to specific subscribers
      case dict.get(state.subscribers, event.name) {
        Ok(subs) -> {
          io.println(
            "[Clock] 📤 Sending to "
            <> int.to_string(list.length(subs))
            <> " specific subscribers",
          )
          list.each(subs, fn(sub) {
            process.send(sub, Tick(event.name, event.timestamp))
          })
        }
        Error(_) -> {
          io.println("[Clock] 🔍 No subscribers for " <> event.name)
        }
      }

      // Send to "all" subscribers
      case dict.get(state.subscribers, "all") {
        Ok(subs) -> {
          io.println(
            "[Clock] 📤 Sending to "
            <> int.to_string(list.length(subs))
            <> " 'all' subscribers",
          )
          list.each(subs, fn(sub) {
            process.send(sub, Tick(event.name, event.timestamp))
          })
        }
        Error(_) -> {
          io.println("[Clock] 🔍 No 'all' subscribers")
        }
      }

      actor.continue(State(..state, total_ticks: state.total_ticks + 1))
    }

    SSEConnected -> {
      io.println("[Clock] Connected to Clockwork")
      notify_all(state.subscribers, ClockReconnected)
      actor.continue(State(..state, connected: True))
    }

    SSEDisconnected(reason) -> {
      io.println("[Clock] Disconnected: " <> reason)
      notify_all(state.subscribers, ClockDisconnected)
      actor.continue(State(..state, connected: False))
    }

    GetStatus(reply_with) -> {
      let status =
        ClockStatus(
          connected: state.connected,
          subscribers: dict.map_values(state.subscribers, fn(_, subs) {
            list.length(subs)
          }),
          total_ticks_received: state.total_ticks,
          uptime_seconds: current_timestamp() - state.start_time,
        )
      process.send(reply_with, status)
      actor.continue(state)
    }

    Shutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

fn notify_all(
  subscribers: Dict(String, List(process.Subject(TickNotification))),
  msg: TickNotification,
) {
  dict.each(subscribers, fn(_, subs) {
    list.each(subs, fn(sub) { process.send(sub, msg) })
  })
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
  // Convert nanoseconds to seconds
}

// Initialize the actor
pub fn start(
  clockwork_url: String,
) -> Result(process.Subject(ClockMessage), actor.StartError) {
  let initial_state =
    State(
      subscribers: dict.new(),
      connected: False,
      total_ticks: 0,
      start_time: current_timestamp(),
      clockwork_url: clockwork_url,
    )

  actor.start(initial_state, handle_message)
}

// For supervised version, we'll need a different approach
// Since we can't easily get the child from supervisor
pub type ClockSystem {
  ClockSystem(
    supervisor: process.Subject(supervisor.Message),
    clock_actor: process.Subject(ClockMessage),
  )
}

// Start with supervision
pub fn start_supervised(
  clockwork_url: String,
) -> Result(ClockSystem, actor.StartError) {
  // First start the clock actor
  use clock_actor <- result.try(start(clockwork_url))

  // Then start the supervisor
  use supervisor <- result.try(
    supervisor.start(fn(children) {
      // For now, just return the children builder
      // In a real app, you'd add the SSE client here too
      children
    }),
  )

  Ok(ClockSystem(supervisor: supervisor, clock_actor: clock_actor))
}
