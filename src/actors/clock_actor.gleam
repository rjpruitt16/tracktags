// Pure Gleam ClockActor - SSE client for tick events using PubSub
import actors/metric_actor
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/string
import glixir
import logging

// Messages that the ClockActor can receive
pub type Message {
  Subscribe(
    tick_name: String,
    subscriber: process.Subject(metric_actor.Message),
  )
  Unsubscribe(
    tick_name: String,
    subscriber: process.Subject(metric_actor.Message),
  )
  GetStatus
  SseEvent(event_data: String)
  SseConnected
  SseClosed(reason: String)
  RetryConnect
  Shutdown
}

// ClockActor state
pub type State {
  State(
    url: String,
    pubsub_name: String,
    sse_pid: process.Pid,
    restart_count: Int,
    status: String,
  )
}

// Topic naming convention
fn topic_for_tick(tick_name: String) -> String {
  "tick:" <> tick_name
}

// Start SSE connection using HTTPoison (placeholder for now)
fn start_sse_connection(
  url: String,
  self_subject: process.Subject(Message),
) -> Nil {
  logging.log(logging.Info, "[ClockActor] Starting SSE connection to: " <> url)

  // For now, just simulate connection - we'll implement actual SSE later
  process.send(self_subject, SseConnected)

  // TODO: Implement actual HTTPoison streaming
  Nil
}

// Parse SSE event data (simplified for now)
fn parse_sse_event(event_data: String) -> Result(#(String, String), String) {
  // Simple parsing - look for tick_1s events
  case string.contains(event_data, "tick_1s") {
    True -> Ok(#("tick_1s", "mock_timestamp"))
    False -> Error("Unknown event type")
  }
}

// Update the broadcast_tick function
fn broadcast_tick(
  pubsub_name: String,
  tick_name: String,
  timestamp: String,
) -> Nil {
  let topic = topic_for_tick(tick_name)

  // Create a list of properties for the tick data
  let tick_properties = [
    #(dynamic.string("tick_name"), dynamic.string(tick_name)),
    #(dynamic.string("timestamp"), dynamic.string(timestamp)),
  ]

  let dynamic_message = dynamic.properties(tick_properties)

  logging.log(
    logging.Info,
    "[ClockActor] Broadcasting " <> tick_name <> " on topic: " <> topic,
  )

  case glixir.pubsub_broadcast(pubsub_name, topic, dynamic_message) {
    Ok(_) -> {
      logging.log(logging.Debug, "[ClockActor] ✅ Tick broadcast successfully")

      // Also broadcast to "all" topic for subscribers listening to everything
      case
        glixir.pubsub_broadcast(
          pubsub_name,
          topic_for_tick("all"),
          dynamic_message,
        )
      {
        Ok(_) -> Nil
        Error(e) -> {
          logging.log(
            logging.Warning,
            "[ClockActor] Failed to broadcast to 'all' topic: "
              <> string.inspect(e),
          )
          Nil
        }
      }
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[ClockActor] Failed to broadcast tick: " <> string.inspect(e),
      )
      Nil
    }
  }
}

// Handle ClockActor messages
fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Subscribe(tick_name, subscriber) -> {
      logging.log(logging.Info, "[ClockActor] Subscribing to " <> tick_name)

      // In PubSub pattern, the subscriber manages their own subscription
      // We just need to tell them which topic to subscribe to
      let topic = topic_for_tick(tick_name)

      // The subscriber should call glixir.pubsub_subscribe(pubsub_name, topic)
      // in their own process
      logging.log(
        logging.Info,
        "[ClockActor] Subscriber should listen to topic: " <> topic,
      )

      actor.continue(state)
    }

    Unsubscribe(tick_name, _subscriber) -> {
      logging.log(logging.Info, "[ClockActor] Unsubscribing from " <> tick_name)
      // With PubSub, subscribers manage their own unsubscription
      actor.continue(state)
    }

    GetStatus -> {
      logging.log(logging.Info, "[ClockActor] Status: " <> state.status)
      actor.continue(state)
    }

    SseEvent(event_data) -> {
      logging.log(logging.Debug, "[ClockActor] SSE event: " <> event_data)
      case parse_sse_event(event_data) {
        Ok(#(tick_name, timestamp)) -> {
          broadcast_tick(state.pubsub_name, tick_name, timestamp)
        }
        Error(_) -> Nil
      }
      actor.continue(state)
    }

    SseConnected -> {
      logging.log(logging.Info, "[ClockActor] ✅ SSE Connected")
      actor.continue(State(..state, status: "connected"))
    }

    SseClosed(reason) -> {
      logging.log(
        logging.Warning,
        "[ClockActor] SSE connection closed: " <> reason,
      )
      actor.continue(State(..state, status: "disconnected"))
    }

    RetryConnect -> {
      logging.log(logging.Info, "[ClockActor] Retrying SSE connection...")
      actor.continue(State(..state, restart_count: state.restart_count + 1))
    }

    Shutdown -> {
      logging.log(logging.Info, "[ClockActor] Shutting down")
      actor.stop()
    }
  }
}

// Start the ClockActor
pub fn start(url: String) -> Result(process.Subject(Message), actor.StartError) {
  logging.log(logging.Info, "[ClockActor] Starting with URL: " <> url)

  // Start PubSub for clock events
  let pubsub_name = "clock_events"
  case glixir.start_pubsub(pubsub_name) {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[ClockActor] ✅ PubSub started: " <> pubsub_name,
      )

      let initial_state =
        State(
          url: url,
          pubsub_name: pubsub_name,
          sse_pid: process.self(),
          // placeholder
          restart_count: 0,
          status: "starting",
        )

      case
        actor.new(initial_state)
        |> actor.on_message(handle_message)
        |> actor.start()
      {
        Ok(started) -> {
          let subject = started.data

          // Start SSE connection
          start_sse_connection(url, subject)

          Ok(subject)
        }
        Error(e) -> Error(e)
      }
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Failed to start PubSub: " <> string.inspect(e),
      )
      Error(actor.InitFailed("Failed to start PubSub"))
    }
  }
}

// Helper to get the PubSub name (for subscribers)
pub fn get_pubsub_name() -> String {
  "clock_events"
}

// Helper to get topic name for a tick type
pub fn get_tick_topic(tick_name: String) -> String {
  topic_for_tick(tick_name)
}

// Test function with real subscriber
pub fn test_with_subscriber() -> Nil {
  logging.log(
    logging.Info,
    "[ClockActor] Testing with PubSub subscriber pattern...",
  )

  case start("http://localhost:4000/events") {
    Ok(clock_subject) -> {
      logging.log(logging.Info, "[ClockActor] ✅ ClockActor started")

      // In the real implementation, MetricActor would:
      // 1. Call glixir.pubsub_subscribe(get_pubsub_name(), get_tick_topic("tick_1s"))
      // 2. Listen for metric_actor.Tick messages in its own actor loop

      // For testing, let's create a simple subscriber
      let test_subscriber = process.new_subject()

      // Subscribe to tick_1s events
      case
        glixir.pubsub_subscribe(get_pubsub_name(), get_tick_topic("tick_1s"))
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[ClockActor] ✅ Subscribed to tick_1s topic",
          )

          // Send a test tick manually to verify the connection
          process.send(clock_subject, SseEvent("test tick_1s event"))
          logging.log(logging.Info, "[ClockActor] ✅ Sent test tick event")
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[ClockActor] ❌ Failed to subscribe: " <> string.inspect(e),
          )
        }
      }
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[ClockActor] ❌ Failed to start ClockActor: " <> string.inspect(e),
      )
    }
  }
}
