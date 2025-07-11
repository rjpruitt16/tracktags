import actors/metric_actor
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string
import glixir
import glixir/supervisor
import logging

pub type Message {
  RecordMetric(
    metric_id: String,
    metric: metric_actor.Metric,
    initial_value: Float,
    tick_type: String,
  )
  GetMetricActor(
    metric_name: String,
    reply_with: process.Subject(Option(process.Subject(metric_actor.Message))),
  )
  Shutdown
}

pub type State {
  State(
    account_id: String,
    metrics_supervisor: glixir.DynamicSupervisor(
      #(String, String, String, Float, String),
      process.Subject(metric_actor.Message),
    ),
  )
}

// Helper functions for consistent naming
pub fn user_subject_name(account_id: String) -> String {
  "tracktags_user_" <> account_id
}

pub fn lookup_user_subject(
  account_id: String,
) -> Result(process.Subject(Message), String) {
  case
    glixir.lookup_subject(
      atom.create("tracktags_actors"),
      atom.create(account_id),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("User actor not found: " <> account_id)
  }
}

// Encoder function for metric actor arguments
fn encode_metric_args(
  args: #(String, String, String, Float, String),
) -> List(dynamic.Dynamic) {
  let #(account_id, metric_name, tick_type, initial_value, tags_json) = args
  [
    dynamic.string(account_id),
    dynamic.string(metric_name),
    dynamic.string(tick_type),
    dynamic.float(initial_value),
    dynamic.string(tags_json),
  ]
}

fn decode_metric_reply(
  _reply: dynamic.Dynamic,
) -> Result(process.Subject(metric_actor.Message), String) {
  // Instead of trying to decode the bridge reply, use the lookup pattern
  // The bridge successfully starts the process and registers it
  // We'll look it up after a brief delay to ensure registration is complete

  // Return success - we'll use lookup in the calling code
  // This is a placeholder that won't actually be used
  Ok(process.new_subject())
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  logging.log(
    logging.Debug,
    "[UserActor] Received message: " <> string.inspect(message),
  )
  case message {
    RecordMetric(metric_id, metric, initial_value, tick_type) -> {
      logging.log(
        logging.Info,
        "[UserActor] Processing metric: "
          <> state.account_id
          <> "/"
          <> metric_id,
      )

      // Check if metric actor already exists
      case metric_actor.lookup_metric_subject(state.account_id, metric_id) {
        Ok(metric_subject) -> {
          logging.log(
            logging.Debug,
            "[UserActor] ✅ Found existing metric actor: " <> metric_id,
          )
          // Send record message to existing metric actor
          process.send(metric_subject, metric_actor.RecordMetric(metric))
          actor.continue(state)
        }
        Error(_) -> {
          // Spawn new metric actor dynamically
          logging.log(
            logging.Info,
            "[UserActor] Spawning new metric actor: " <> metric_id,
          )
          let metric_spec =
            metric_actor.start(
              state.account_id,
              metric_id,
              tick_type,
              initial_value,
              "{}",
              // empty tags JSON
            )

          case
            glixir.start_dynamic_child(
              state.metrics_supervisor,
              metric_spec,
              encode_metric_args,
              decode_metric_reply,
            )
          {
            supervisor.ChildStarted(child_pid, _reply) -> {
              logging.log(
                logging.Info,
                "[UserActor] ✅ Spawned metric actor: "
                  <> metric_id
                  <> " PID: "
                  <> string.inspect(child_pid),
              )

              // After spawning, look up and send the metric
              case
                metric_actor.lookup_metric_subject(state.account_id, metric_id)
              {
                Ok(metric_subject) -> {
                  process.send(
                    metric_subject,
                    metric_actor.RecordMetric(metric),
                  )
                  logging.log(
                    logging.Debug,
                    "[UserActor] ✅ Sent initial metric to new actor",
                  )
                }
                Error(_) -> {
                  logging.log(
                    logging.Warning,
                    "[UserActor] ⚠️ Could not find newly spawned metric actor: "
                      <> metric_id,
                  )
                }
              }
              actor.continue(state)
            }
            supervisor.StartChildError(error) -> {
              logging.log(
                logging.Error,
                "[UserActor] ❌ Failed to spawn metric: " <> error,
              )
              actor.continue(state)
            }
          }
        }
      }
    }

    GetMetricActor(metric_name, reply_with) -> {
      // Use lookup instead of returning None
      let result = case
        metric_actor.lookup_metric_subject(state.account_id, metric_name)
      {
        Ok(subject) -> option.Some(subject)
        Error(_) -> option.None
      }
      process.send(reply_with, result)
      actor.continue(state)
    }

    Shutdown -> {
      logging.log(
        logging.Info,
        "[UserActor] Shutting down: " <> state.account_id,
      )
      actor.stop()
    }
  }
}

// Encoder function for user actor arguments
fn encode_user_args(account_id: String) -> List(dynamic.Dynamic) {
  [dynamic.string(account_id)]
}

// start_link function for bridge to call
pub fn start_link(
  account_id: String,
) -> Result(process.Subject(Message), actor.StartError) {
  logging.log(logging.Info, "[UserActor] Starting for account: " <> account_id)

  // Start metrics supervisor for this user
  case
    glixir.start_dynamic_supervisor_named(atom.create("metrics_" <> account_id))
  {
    Ok(metrics_supervisor) -> {
      logging.log(
        logging.Debug,
        "[UserActor] ✅ Metrics supervisor started for " <> account_id,
      )
      let state =
        State(account_id: account_id, metrics_supervisor: metrics_supervisor)

      case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
        Ok(started) -> {
          // Register in registry for lookup
          case
            glixir.register_subject(
              atom.create("tracktags_actors"),
              atom.create(account_id),
              started.data,
              glixir.atom_key_encoder,
            )
          {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[UserActor] ✅ Registered: " <> account_id,
              )
            Error(_) ->
              logging.log(
                logging.Error,
                "[UserActor] ❌ Failed to register: " <> account_id,
              )
          }
          Ok(started.data)
        }
        Error(error) -> Error(error)
      }
    }
    Error(error) -> {
      logging.log(
        logging.Error,
        "[UserActor] ❌ Failed to start metrics supervisor: "
          <> string.inspect(error),
      )
      Error(actor.InitFailed("Failed to start metrics supervisor"))
    }
  }
}

// Returns glixir.ChildSpec for dynamic spawning
pub fn start(
  account_id: String,
) -> glixir.ChildSpec(String, process.Subject(Message)) {
  glixir.child_spec(
    id: "user_" <> account_id,
    module: "Elixir.UserActorBridge",
    function: "start_link",
    args: account_id,
    restart: glixir.permanent,
    shutdown_timeout: 5000,
    child_type: glixir.worker,
    encode: encode_user_args,
  )
}
