import actors/metric_actor
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/io
import gleam/option.{type Option}
import gleam/otp/actor

// Simple user actor to manage user-specific metric actors
pub type Message {
  RecordMetric(account_id: String, metric: metric_actor.MetricEvent)
  GetMetricActor(
    account_id: String,
    reply_with: process.Subject(Option(process.Subject(metric_actor.Message))),
  )
  Shutdown
}

type State {
  State(
    // Map of account_id -> metric actor
    metric_actors: Dict(String, process.Subject(metric_actor.Message)),
  )
}

fn handle_message(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    RecordMetric(account_id, metric) -> {
      case dict.get(state.metric_actors, account_id) {
        Ok(metric_actor) -> {
          process.send(metric_actor, metric_actor.RecordMetric(metric))
          actor.continue(state)
        }
        Error(_) -> {
          io.println("[User] No metric actor for account: " <> account_id)
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
      actor.Stop(process.Normal)
    }
  }
}

pub fn start() -> Result(process.Subject(Message), actor.StartError) {
  let initial_state = State(metric_actors: dict.new())

  actor.start(initial_state, handle_message)
}
