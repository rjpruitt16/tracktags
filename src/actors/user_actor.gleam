import actors/metric_actor.{type Metric, State}
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string

// TODO: - Gleam OTP library does not have dynamic supervisor
// so convert when available
pub type Message {
  RecordMetric(metric_id: String, metric: metric_actor.Metric)
  GetMetricActor(
    account_id: String,
    reply_with: process.Subject(Option(process.Subject(metric_actor.Message))),
  )
  Shutdown
}

pub type State {
  State(
    // Map of account_id -> metric actor
    metric_actors: Dict(String, process.Subject(metric_actor.Message)),
    account_id: String,
  )
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  io.println("[UserActor] Received message: " <> string.inspect(message))
  // Add this
  case message {
    RecordMetric(metric_id, metric) -> {
      case dict.get(state.metric_actors, metric_id) {
        Ok(metric_actor) -> {
          process.send(metric_actor, metric_actor.RecordMetric(metric))
          actor.continue(state)
        }
        Error(_) -> {
          io.println("[User] No metric actor for metric_id: " <> metric_id)
          // TODO: Create metric actor on demand
          actor.continue(state)
        }
      }
    }

    GetMetricActor(account_id, reply_with) -> {
      let result =
        dict.get(state.metric_actors, account_id)
        |> option.from_result
      process.send(reply_with, result)
      actor.continue(state)
    }
    Shutdown -> {
      actor.stop()
    }
  }
}

pub fn start(
  state: State,
  metric_states: List(metric_actor.State),
) -> supervision.ChildSpecification(process.Subject(Message)) {
  supervision.worker(fn() {
    io.println("[UserActor] started")
    echo metric_states
    let possible =
      actor.new(state) |> actor.on_message(handle_message) |> actor.start

    let supervisor = static_supervisor.new(static_supervisor.OneForOne)
    let _ =
      list.fold(metric_states, supervisor, fn(build, state) {
        static_supervisor.add(build, metric_actor.start(state))
      })
      |> static_supervisor.start

    possible
  })
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
