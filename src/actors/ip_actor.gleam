// src/actors/ip_actor.gleam
import actors/metric_actor
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/otp/actor
import gleam/string
import glixir
import glixir/supervisor
import logging
import types/ip_types
import types/metric_types
import utils/utils

/// IP Actor State
pub type State {
  State(
    ip_address: String,
    metrics_supervisor: glixir.DynamicSupervisor(
      #(
        String,
        String,
        String,
        Float,
        String,
        String,
        Int,
        String,
        String,
        Float,
        String,
        String,
      ),
      process.Subject(metric_types.Message),
    ),
    last_accessed: Int,
    cleanup_threshold: Int,
    config: ip_types.IpRateLimitConfig,
  )
}

/// Handle incoming messages
fn handle_message(
  state: State,
  message: ip_types.Message,
) -> actor.Next(State, ip_types.Message) {
  let updated_state = State(..state, last_accessed: utils.current_timestamp())

  case message {
    ip_types.RecordRequest(timestamp) -> {
      handle_record_request(updated_state, timestamp)
    }

    ip_types.CheckAndIncrement(reply) -> {
      handle_check_and_increment(updated_state, reply)
    }

    ip_types.GetRequestCount(reply) -> {
      handle_get_request_count(updated_state, reply)
    }

    ip_types.CleanupTick(timestamp, tick_type) -> {
      handle_cleanup_tick(updated_state, timestamp, tick_type)
    }

    ip_types.Shutdown -> {
      logging.log(
        logging.Info,
        "[IpActor] Shutting down: " <> updated_state.ip_address,
      )
      cleanup_and_stop(updated_state)
    }
  }
}

fn handle_record_request(
  state: State,
  _timestamp: Int,
) -> actor.Next(State, ip_types.Message) {
  logging.log(
    logging.Info,
    "[IpActor] 📥 Recording request for IP: " <> state.ip_address,
  )
  let metric_key = ip_types.sanitize_ip(state.ip_address)
  let metric_name = "request_count"

  case metric_actor.lookup_metric_subject(metric_key, metric_name) {
    Ok(metric_subject) -> {
      // Send increment to existing metric
      let metric =
        metric_types.Metric(
          account_id: metric_key,
          metric_name: metric_name,
          value: 1.0,
          tags: dict.new(),
          timestamp: utils.current_timestamp(),
        )
      process.send(metric_subject, metric_types.RecordMetric(metric))
      actor.continue(state)
    }
    Error(_) -> {
      // Spawn metric actor for this IP
      spawn_request_count_metric(state)
    }
  }
}

fn handle_check_and_increment(
  state: State,
  reply: process.Subject(ip_types.RateLimitResult),
) -> actor.Next(State, ip_types.Message) {
  let metric_key = ip_types.sanitize_ip(state.ip_address)
  let metric_name = "request_count"

  case metric_actor.lookup_metric_subject(metric_key, metric_name) {
    Ok(metric_subject) -> {
      // Use atomic CheckAndAdd
      let check_reply = process.new_subject()
      process.send(metric_subject, metric_types.CheckAndAdd(1.0, check_reply))

      case process.receive(check_reply, 1000) {
        Ok(True) -> {
          // Request allowed, get current count
          let value_reply = process.new_subject()
          process.send(metric_subject, metric_types.GetValue(value_reply))

          case process.receive(value_reply, 500) {
            Ok(current) -> {
              let remaining = float.max(state.config.max_requests -. current, 0.0)
              process.send(
                reply,
                ip_types.Allowed(current_count: current, remaining: remaining),
              )
            }
            Error(_) -> {
              process.send(
                reply,
                ip_types.Allowed(
                  current_count: 0.0,
                  remaining: state.config.max_requests,
                ),
              )
            }
          }
        }
        Ok(False) -> {
          // Rate limited
          process.send(
            reply,
            ip_types.RateLimited(
              current_count: state.config.max_requests,
              limit: state.config.max_requests,
              retry_after_seconds: state.config.window_seconds,
            ),
          )
        }
        Error(_) -> {
          // Timeout - allow but log
          logging.log(
            logging.Warning,
            "[IpActor] Timeout checking rate limit for: " <> state.ip_address,
          )
          process.send(
            reply,
            ip_types.Allowed(
              current_count: 0.0,
              remaining: state.config.max_requests,
            ),
          )
        }
      }
      actor.continue(state)
    }
    Error(_) -> {
      // No metric yet, spawn one and allow this request
      let _ = spawn_request_count_metric(state)
      process.send(
        reply,
        ip_types.Allowed(
          current_count: 1.0,
          remaining: state.config.max_requests -. 1.0,
        ),
      )
      actor.continue(state)
    }
  }
}

fn handle_get_request_count(
  state: State,
  reply: process.Subject(Float),
) -> actor.Next(State, ip_types.Message) {
  let metric_key = ip_types.sanitize_ip(state.ip_address)
  let metric_name = "request_count"

  case metric_actor.lookup_metric_subject(metric_key, metric_name) {
    Ok(metric_subject) -> {
      let value_reply = process.new_subject()
      process.send(metric_subject, metric_types.GetValue(value_reply))

      case process.receive(value_reply, 500) {
        Ok(count) -> process.send(reply, count)
        Error(_) -> process.send(reply, 0.0)
      }
    }
    Error(_) -> process.send(reply, 0.0)
  }
  actor.continue(state)
}

fn handle_cleanup_tick(
  state: State,
  _timestamp: String,
  _tick_type: String,
) -> actor.Next(State, ip_types.Message) {
  let current_time = utils.current_timestamp()
  let inactive_duration = current_time - state.last_accessed

  case inactive_duration > state.cleanup_threshold {
    True -> {
      logging.log(
        logging.Info,
        "[IpActor] Cleanup triggered for: "
          <> state.ip_address
          <> " (inactive for "
          <> int.to_string(inactive_duration)
          <> "s)",
      )
      cleanup_and_stop(state)
    }
    False -> actor.continue(state)
  }
}

fn cleanup_and_stop(state: State) -> actor.Next(State, ip_types.Message) {
  let registry_key = "ip:" <> ip_types.sanitize_ip(state.ip_address)

  case glixir.unregister_subject_string(utils.tracktags_registry(), registry_key) {
    Ok(_) ->
      logging.log(
        logging.Info,
        "[IpActor] Unregistered: " <> registry_key,
      )
    Error(_) ->
      logging.log(
        logging.Warning,
        "[IpActor] Failed to unregister: " <> registry_key,
      )
  }

  actor.stop()
}

fn spawn_request_count_metric(
  state: State,
) -> actor.Next(State, ip_types.Message) {
  let metric_key = ip_types.sanitize_ip(state.ip_address)
  let metric_name = "request_count"

  logging.log(
    logging.Info,
    "[IpActor] Spawning request_count metric for: " <> state.ip_address,
  )

  let metric_spec =
    metric_actor.start(
      metric_key,
      metric_name,
      state.config.tick_type,
      1.0,
      // initial value (first request)
      "{}",
      // tags
      "SUM",
      // operation
      state.config.window_seconds * 2,
      // cleanup after 2 windows of inactivity
      "reset",
      // metric type - resets each window
      "{}",
      // metadata
      state.config.max_requests,
      // limit value
      "gte",
      // breach when >= limit
      "deny",
      // breach action
    )

  case
    glixir.start_dynamic_child(
      state.metrics_supervisor,
      metric_spec,
      metric_types.encode_metric_args,
      fn(_) { Ok(process.new_subject()) },
    )
  {
    supervisor.ChildStarted(child_pid, _) -> {
      logging.log(
        logging.Info,
        "[IpActor] Spawned metric actor for: "
          <> state.ip_address
          <> " PID: "
          <> string.inspect(child_pid),
      )
    }
    supervisor.StartChildError(error) -> {
      logging.log(
        logging.Error,
        "[IpActor] Failed to spawn metric: " <> error,
      )
    }
  }

  actor.continue(state)
}

// ============================================================================
// PUBLIC API
// ============================================================================

pub fn encode_ip_args(args: String) -> List(dynamic.Dynamic) {
  [dynamic.string(args)]
}

/// Start an IP actor (called by supervisor)
pub fn start_link(
  ip_address ip_address: String,
) -> Result(process.Subject(ip_types.Message), actor.StartError) {
  logging.log(logging.Info, "[IpActor] Starting for: " <> ip_address)

  case
    glixir.start_dynamic_supervisor_named_safe(
      "ip_metrics_" <> ip_types.sanitize_ip(ip_address),
    )
  {
    Ok(metrics_supervisor) -> {
      let current_time = utils.current_timestamp()
      let config = ip_types.default_config()

      let state =
        State(
          ip_address: ip_address,
          metrics_supervisor: metrics_supervisor,
          last_accessed: current_time,
          cleanup_threshold: 3600,
          // 1 hour of inactivity
          config: config,
        )

      case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
        Ok(started) -> {
          let registry_key = "ip:" <> ip_types.sanitize_ip(ip_address)

          case
            glixir.register_subject_string(
              utils.tracktags_registry(),
              registry_key,
              started.data,
            )
          {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[IpActor] Registered: " <> registry_key,
              )
            Error(_) ->
              logging.log(
                logging.Error,
                "[IpActor] Failed to register: " <> registry_key,
              )
          }

          // Subscribe to cleanup ticks
          case
            glixir.pubsub_subscribe_with_registry_key(
              utils.clock_events_bus(),
              "tick:tick_5m",
              "actors@ip_actor",
              "handle_ip_cleanup_tick",
              registry_key,
            )
          {
            Ok(_) ->
              logging.log(
                logging.Info,
                "[IpActor] Subscribed to cleanup ticks: " <> registry_key,
              )
            Error(e) ->
              logging.log(
                logging.Error,
                "[IpActor] Failed cleanup subscription: " <> string.inspect(e),
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
        "[IpActor] Failed to start metrics supervisor: " <> string.inspect(error),
      )
      Error(actor.InitFailed("Failed to start metrics supervisor"))
    }
  }
}

/// ChildSpec for spawning via supervisor
pub fn start(
  ip_address: String,
) -> glixir.ChildSpec(String, process.Subject(ip_types.Message)) {
  glixir.child_spec(
    id: "ip_" <> ip_types.sanitize_ip(ip_address),
    module: "Elixir.IpActorBridge",
    function: "start_link",
    args: ip_address,
    restart: glixir.permanent,
    shutdown_timeout: 5000,
    child_type: glixir.worker,
  )
}

/// Handle cleanup tick (called by pubsub)
pub fn handle_ip_cleanup_tick(registry_key: String, json_message: String) -> Nil {
  case glixir.lookup_subject_string(utils.tracktags_registry(), registry_key) {
    Ok(ip_subject) -> {
      let tick_decoder = {
        use tick_name <- decode.field("tick_name", decode.string)
        use timestamp <- decode.field("timestamp", decode.string)
        decode.success(#(tick_name, timestamp))
      }

      case json.parse(json_message, tick_decoder) {
        Ok(#(tick_name, timestamp)) -> {
          process.send(ip_subject, ip_types.CleanupTick(timestamp, tick_name))
        }
        Error(_) -> Nil
      }
    }
    Error(_) -> Nil
  }
}

/// Get or spawn an IP actor
pub fn get_or_spawn_ip_actor(
  ip_supervisor: glixir.DynamicSupervisor(
    String,
    process.Subject(ip_types.Message),
  ),
  ip_address: String,
) -> Result(process.Subject(ip_types.Message), String) {
  case ip_types.lookup_ip_subject(ip_address) {
    Ok(subject) -> Ok(subject)
    Error(_) -> {
      // Spawn new IP actor
      let ip_spec = start(ip_address)

      case
        glixir.start_dynamic_child(
          ip_supervisor,
          ip_spec,
          encode_ip_args,
          fn(_) { Ok(process.new_subject()) },
        )
      {
        supervisor.ChildStarted(_, _) -> {
          // Give it a moment to register
          process.sleep(50)
          ip_types.lookup_ip_subject(ip_address)
        }
        supervisor.StartChildError(error) -> Error(error)
      }
    }
  }
}
