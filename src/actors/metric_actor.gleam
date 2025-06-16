import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

// Simplified message types
pub type Message {
  RecordMetric(metric: MetricEvent)
  TickReceived(tick_type: String, timestamp: String)
  // Direct from PubSub
  ForceFlush
  GetStatus(reply_with: process.Subject(MetricStatus))
  Shutdown
}

pub type MetricEvent {
  MetricEvent(
    account_id: String,
    metric_name: String,
    value: Float,
    tags: Dict(String, String),
    timestamp: Int,
  )
}

pub type MetricStatus {
  MetricStatus(buffered_count: Int, last_flush: Option(Int), total_flushed: Int)
}

type State {
  State(
    buffer: List(MetricEvent),
    flush_on_ticks: List(String),
    last_flush: Option(Int),
    total_flushed: Int,
  )
}

// FFI to subscribe via Elixir PubSub
@external(erlang, "Elixir.ClockPubSub", "subscribe")
fn subscribe_to_tick(tick_type: String) -> atom.Atom

// Receive raw Erlang messages
@external(erlang, "gleam_erlang_ffi", "receive")
fn receive_any(timeout: Int) -> Result(dynamic.Dynamic, Nil)

// Decode tick tuples using dynamic.list
fn decode_tick_tuple(dyn: dynamic.Dynamic) -> Result(#(String, String), Nil) {
  case dynamic.list(dynamic.dynamic)(dyn) {
    Ok([tick_atom_dyn, timestamp_dyn]) -> {
      case dynamic.atom(tick_atom_dyn), dynamic.string(timestamp_dyn) {
        Ok(tick_atom), Ok(timestamp) -> {
          Ok(#(atom.to_string(tick_atom), timestamp))
        }
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn handle_message(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    RecordMetric(metric) -> {
      io.println("[Metric] Recording: " <> metric.metric_name)
      actor.continue(State(..state, buffer: [metric, ..state.buffer]))
    }

    TickReceived(tick_type, timestamp) -> {
      case list.contains(state.flush_on_ticks, tick_type) {
        True -> {
          io.println(
            "[Metric] Flushing on " <> tick_type <> " at " <> timestamp,
          )
          flush_metrics(state)
        }
        False -> actor.continue(state)
      }
    }

    ForceFlush -> flush_metrics(state)

    GetStatus(reply_with) -> {
      let status =
        MetricStatus(
          buffered_count: list.length(state.buffer),
          last_flush: state.last_flush,
          total_flushed: state.total_flushed,
        )
      process.send(reply_with, status)
      actor.continue(state)
    }

    Shutdown -> actor.Stop(process.Normal)
  }
}

fn flush_metrics(state: State) -> actor.Next(Message, State) {
  case state.buffer {
    [] -> {
      io.println("[Metric] Nothing to flush")
      actor.continue(state)
    }
    metrics -> {
      let count = list.length(metrics)
      io.println("[Metric] Flushing " <> int.to_string(count) <> " metrics")
      // TODO: Actually send to adapter
      actor.continue(
        State(
          ..state,
          buffer: [],
          last_flush: Some(current_timestamp()),
          total_flushed: state.total_flushed + count,
        ),
      )
    }
  }
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}

// Start with PubSub integration
pub fn start(
  flush_on_ticks: List(String),
) -> Result(process.Subject(Message), actor.StartError) {
  actor.start_spec(actor.Spec(
    init: fn() {
      let self = process.new_subject()

      // Subscribe to ticks via Elixir PubSub
      list.each(flush_on_ticks, fn(tick) { subscribe_to_tick(tick) })

      // Start receiver process for PubSub messages
      process.start(fn() { pubsub_receiver_loop(self) }, False)

      let state =
        State(
          buffer: [],
          flush_on_ticks: flush_on_ticks,
          last_flush: None,
          total_flushed: 0,
        )

      actor.Ready(state, process.new_selector())
    },
    init_timeout: 5000,
    loop: handle_message,
  ))
}

// Receiver loop that forwards PubSub messages
fn pubsub_receiver_loop(forward_to: process.Subject(Message)) {
  case receive_any(60_000) {
    Ok(msg) -> {
      case decode_tick_tuple(msg) {
        Ok(#(tick_type, timestamp)) -> {
          process.send(forward_to, TickReceived(tick_type, timestamp))
        }
        Error(_) -> Nil
        // Ignore non-tick messages
      }
      pubsub_receiver_loop(forward_to)
    }
    Error(_) -> pubsub_receiver_loop(forward_to)
  }
}
