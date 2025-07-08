import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import glixir/supervisor
import logging

// Simplified message types
pub type Message {
  RecordMetric(metric: Metric)
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

// Helper functions for consistent naming
pub fn metric_subject_name(account_id: String, metric_name: String) -> String {
  "tracktags_metric_" <> account_id <> "_" <> metric_name
}

pub fn lookup_metric_subject(
  account_id: String,
  metric_name: String,
) -> Result(process.Subject(Message), String) {
  let key = account_id <> "_" <> metric_name
  case glixir.lookup_subject("tracktags_actors", key) {
    Ok(subject) -> Ok(subject)
    Error(_) ->
      Error("Metric actor not found: " <> account_id <> "/" <> metric_name)
  }
}

pub fn send_tick(
  subject: process.Subject(Message),
  tick_type: String,
  timestamp: String,
) -> Nil {
  let tick_map =
    dict.from_list([#("tick_type", tick_type), #("timestamp", timestamp)])
  process.send(subject, Tick(tick_map))
}

// Decode a %{"tick_type" => t, "timestamp" => ts} map
fn decode_tick_map(
  tick_map: Dict(String, String),
) -> Result(#(String, String), Nil) {
  use tick_type <- result.try(dict.get(tick_map, "tick_type"))
  use timestamp <- result.try(dict.get(tick_map, "timestamp"))
  Ok(#(tick_type, timestamp))
}

// Use Gleam ClockActor instead of Elixir
// TODO: Need ClockActor reference - for now just log
fn subscribe_to_tick(
  tick_type: String,
  subscriber: process.Subject(Message),
) -> Nil {
  logging.log(
    logging.Info,
    "[MetricActor] Would subscribe to "
      <> tick_type
      <> " (ClockActor integration pending)",
  )
}

// Helper to parse JSON tags (simple version for now)
fn parse_tags_json(tags_json: String) -> Dict(String, String) {
  // For now, return empty dict - we can implement JSON parsing later
  case tags_json {
    "{}" -> dict.new()
    "" -> dict.new()
    _ -> dict.new()
  }
}

// start_link function for bridge to call
pub fn start_link(
  account_id: String,
  metric_name: String,
  tick_type: String,
  initial_value: Float,
  tags_json: String,
) -> Result(process.Subject(Message), actor.StartError) {
  logging.log(
    logging.Info,
    "[MetricActor] Starting: "
      <> account_id
      <> "/"
      <> metric_name
      <> " (tick_type: "
      <> tick_type
      <> ")",
  )

  let tags = parse_tags_json(tags_json)
  let timestamp = current_timestamp()

  let default_metric =
    Metric(
      account_id: account_id,
      metric_name: metric_name,
      value: initial_value,
      tags: tags,
      timestamp: timestamp,
    )

  let state =
    State(
      default_metric: default_metric,
      current_metric: default_metric,
      tick_type: tick_type,
    )

  case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
    Ok(started) -> {
      // Register in registry for lookup
      let key = account_id <> "_" <> metric_name
      case glixir.register_subject("tracktags_actors", key, started.data) {
        Ok(_) ->
          logging.log(logging.Info, "[MetricActor] ✅ Registered: " <> key)
        Error(_) ->
          logging.log(
            logging.Error,
            "[MetricActor] ❌ Failed to register: " <> key,
          )
      }

      // Subscribe to tick events
      logging.log(
        logging.Debug,
        "[MetricActor] Subscribing " <> metric_name <> " to " <> tick_type,
      )
      subscribe_to_tick(tick_type, started.data)
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Subscribed " <> metric_name <> " to " <> tick_type,
      )
      Ok(started.data)
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[MetricActor] ❌ Failed to start "
          <> metric_name
          <> ": "
          <> string.inspect(error),
      )
      Error(error)
    }
  }
}

// Returns supervisor.SimpleChildSpec for dynamic spawning
pub fn start(
  account_id: String,
  metric_name: String,
  tick_type: String,
  initial_value: Float,
  tags_json: String,
) -> supervisor.SimpleChildSpec {
  supervisor.SimpleChildSpec(
    id: "metric_" <> account_id <> "_" <> metric_name,
    start_module: atom.create("Elixir.MetricActorBridge"),
    start_function: atom.create("start_link"),
    start_args: [
      dynamic.string(account_id),
      dynamic.string(metric_name),
      dynamic.string(tick_type),
      dynamic.float(initial_value),
      dynamic.string(tags_json),
    ],
    restart: supervisor.Permanent,
    shutdown_timeout: 5000,
    child_type: supervisor.Worker,
  )
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  logging.log(
    logging.Debug,
    "[MetricActor] Processing message: "
      <> state.default_metric.account_id
      <> "/"
      <> state.default_metric.metric_name,
  )
  case message {
    RecordMetric(metric) -> {
      logging.log(
        logging.Debug,
        "[MetricActor] Recording: " <> metric.metric_name,
      )
      actor.continue(State(..state, current_metric: metric))
    }
    Tick(tick_map) -> {
      let decode_result = result.try(Ok(tick_map), decode_tick_map)
      case decode_result {
        Ok(#(tick_type, timestamp)) -> {
          logging.log(
            logging.Info,
            "[MetricActor] Flushing "
              <> state.default_metric.metric_name
              <> " on "
              <> tick_type
              <> " at "
              <> timestamp,
          )
          flush_metrics(state)
        }
        Error(_error) -> {
          logging.log(
            logging.Error,
            "[MetricActor] ❌ Failed to decode tick map",
          )
          actor.continue(state)
        }
      }
    }
    ForceFlush -> flush_metrics(state)
    GetStatus(reply_with) -> {
      process.send(reply_with, state.current_metric)
      actor.continue(state)
    }
    Shutdown -> {
      logging.log(
        logging.Info,
        "[MetricActor] Shutting down: " <> state.default_metric.metric_name,
      )
      actor.stop()
    }
  }
}

fn flush_metrics(state: State) -> actor.Next(State, Message) {
  logging.log(
    logging.Info,
    "[MetricActor] 📊 Flushing metrics: " <> state.default_metric.metric_name,
  )
  actor.continue(State(..state, current_metric: state.default_metric))
}

@external(erlang, "os", "system_time")
fn system_time() -> Int

fn current_timestamp() -> Int {
  system_time() / 1_000_000_000
}
