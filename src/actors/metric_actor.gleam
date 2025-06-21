import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode.{type DecodeError, DecodeError}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Started}
import gleam/otp/supervision
import gleam/result

// Simplified message types

pub type Message {
  RecordMetric(metric: Metric)
  // Tick(tick_map: dynamic.Dynamic)
  Tick(tick_map: Dict(String, String))
  ForceFlush
  GetStatus(reply_with: process.Subject(Metric))
  Shutdown
}

pub type Metric {
  Metric(
    account_id: String,
    metric_name: String,
    value: Float,
    tags: Dict(String, String),
    timestamp: Int,
  )
}

pub type State {
  State(default_metric: Metric, current_metric: Metric, tick_type: String)
}

// Decode a %{"tick_type" => t, "timestamp" => ts} map
fn decode_tick_map(
  tick_map: Dict(String, String),
) -> Result(#(String, String), Nil) {
  // let decoder = {
  //   use tick_type <- decode.field("tick_type", decode.string)
  //   use timestamp <- decode.field("timestamp", decode.string)
  //   decode.success(#(tick_type, timestamp))
  // }
  // decode.run(tick_map, decoder)
  use tick_type <- result.try(dict.get(tick_map, "tick_type"))
  use timestamp <- result.try(dict.get(tick_map, "timestamp"))
  Ok(#(tick_type, timestamp))
}

// FFI to your ClockActor.subscribe/2
@external(erlang, "Elixir.ClockActor", "subscribe")
fn subscribe_to_tick(
  tick_type: String,
  subscriber: process.Subject(Message),
) -> Nil

pub fn start(
  state: State,
) -> supervision.ChildSpecification(process.Subject(Message)) {
  io.print("[MetricActor] called")
  supervision.worker(fn() {
    let start =
      actor.new(state) |> actor.on_message(handle_message) |> actor.start

    case start {
      Ok(metric_actor) -> subscribe_to_tick(state.tick_type, metric_actor.data)
      Error(error) -> {
        io.debug("failure to start metric ")
        Nil
      }
    }
    start
  })
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  io.println(
    "[MetricActor] Starting metric actor for: "
    <> state.default_metric.account_id,
  )
  case message {
    RecordMetric(metric) -> {
      io.println("[Metric] Recording: " <> metric.metric_name)
      actor.continue(State(..state, tick_type: state.tick_type))
    }

    Tick(tick_map) -> {
      let decode_result = result.try(Ok(tick_map), decode_tick_map)
      case decode_result {
        Ok(#(tick_type, timestamp)) -> {
          io.println(
            "[Metric] Flushing on " <> tick_type <> " at " <> timestamp,
          )
          flush_metrics(state)
          actor.continue(state)
        }
        Error(error) -> {
          io.println("failure to decode tick map ")
          echo error
          actor.continue(state)
        }
      }
    }

    ForceFlush -> flush_metrics(state)

    GetStatus(reply_with) -> {
      process.send(reply_with, state.current_metric)
      actor.continue(state)
    }

    Shutdown -> actor.stop()
  }
}

fn flush_metrics(state: State) -> actor.Next(State, Message) {
  actor.continue(State(..state, current_metric: state.default_metric))
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
