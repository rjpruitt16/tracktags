import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/otp/actor
import gleam/string
import glixir
import glixir/supervisor
import logging

// Clean message types - removed PubSubTick and InitializeSubscription
pub type Message {
  RecordMetric(metric: Metric)
  Tick(timestamp: String, tick_type: String)
  // Simplified - no more Dict
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

// Tick data type for JSON decoding
pub type TickData {
  TickData(tick_name: String, timestamp: String)
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
  case
    glixir.lookup_subject(
      atom.create("tracktags_actors"),
      atom.create(key),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) ->
      Error("Metric actor not found: " <> account_id <> "/" <> metric_name)
  }
}

// FFI to start PubSub bridge
@external(erlang, "Elixir.MetricPubSubBridge", "start_link")
fn start_pubsub_bridge(
  account_id: String,
  metric_name: String,
  tick_type: String,
) -> Result(process.Pid, dynamic.Dynamic)

// New handler for bridge to call - this replaces handle_tick_json
pub fn handle_tick_generic(
  account_id: String,
  metric_name: String,
  json_message: String,
) -> Nil {
  logging.log(
    logging.Info,
    "[MetricActor] 🎯 Bridge received tick for: "
      <> account_id
      <> "/"
      <> metric_name,
  )

  // JSON decoder for tick data
  let tick_decoder = {
    use tick_name <- decode.field("tick_name", decode.string)
    use timestamp <- decode.field("timestamp", decode.string)
    decode.success(TickData(tick_name: tick_name, timestamp: timestamp))
  }

  case json.parse(json_message, tick_decoder) {
    Ok(tick_data) -> {
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Decoded tick: "
          <> tick_data.tick_name
          <> " at "
          <> tick_data.timestamp,
      )

      // Send to specific MetricActor
      case lookup_metric_subject(account_id, metric_name) {
        Ok(subject) -> {
          process.send(subject, Tick(tick_data.timestamp, tick_data.tick_name))
          logging.log(
            logging.Info,
            "[MetricActor] ✅ Sent tick to: " <> account_id <> "/" <> metric_name,
          )
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "[MetricActor] ❌ Actor not found: "
              <> account_id
              <> "/"
              <> metric_name,
          )
        }
      }
    }
    Error(decode_error) -> {
      logging.log(
        logging.Warning,
        "[MetricActor] ❌ Invalid tick JSON: "
          <> json_message
          <> " Error: "
          <> string.inspect(decode_error),
      )
    }
  }
}

// Helper to parse JSON tags (simple version for now)
fn parse_tags_json(tags_json: String) -> Dict(String, String) {
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

  let temp_state =
    State(
      default_metric: default_metric,
      current_metric: default_metric,
      tick_type: tick_type,
    )

  case
    actor.new(temp_state) |> actor.on_message(handle_message) |> actor.start
  {
    Ok(started) -> {
      let subject = started.data

      // Register in registry for lookup
      let key = account_id <> "_" <> metric_name
      case
        glixir.register_subject(
          atom.create("tracktags_actors"),
          atom.create(key),
          started.data,
          glixir.atom_key_encoder,
        )
      {
        Ok(_) ->
          logging.log(logging.Info, "[MetricActor] ✅ Registered: " <> key)
        Error(_) ->
          logging.log(
            logging.Error,
            "[MetricActor] ❌ Failed to register: " <> key,
          )
      }

      // Start PubSub bridge (automatically links via start_link)
      case start_pubsub_bridge(account_id, metric_name, tick_type) {
        Ok(_bridge_pid) -> {
          logging.log(
            logging.Info,
            "[MetricActor] ✅ PubSub bridge started and linked",
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[MetricActor] ❌ Failed to start bridge: " <> string.inspect(e),
          )
        }
      }

      logging.log(
        logging.Info,
        "[MetricActor] ✅ MetricActor started: " <> metric_name,
      )
      Ok(subject)
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

// Returns supervisor.ChildSpec for dynamic spawning
pub fn start(
  account_id: String,
  metric_name: String,
  tick_type: String,
  initial_value: Float,
  tags_json: String,
) -> supervisor.ChildSpec(
  #(String, String, String, Float, String),
  process.Subject(Message),
) {
  supervisor.ChildSpec(
    id: "metric_" <> account_id <> "_" <> metric_name,
    start_module: atom.create("Elixir.MetricActorBridge"),
    start_function: atom.create("start_link"),
    start_args: #(account_id, metric_name, tick_type, initial_value, tags_json),
    restart: supervisor.Permanent,
    shutdown_timeout: 5000,
    child_type: supervisor.Worker,
  )
}

// Clean message handler - removed PubSubTick and InitializeSubscription cases
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

    Tick(timestamp, tick_type) -> {
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
