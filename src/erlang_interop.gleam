import gleam/erlang/process
import gleam/io
import gleam/result

// Message types that can come from Erlang/Elixir
pub type ErlangMessage {
  TextMessage(content: String)
  TimestampMessage(name: String, time: String)
  Unknown
}

// FFI to our Erlang bridge
@external(erlang, "message_bridge", "receive_and_convert")
fn receive_message_ffi(timeout: Int) -> Result(ErlangMessage, Nil)

// Public function to receive messages
pub fn receive_message(timeout: Int) -> Result(ErlangMessage, Nil) {
  receive_message_ffi(timeout)
}

// Helper to create a receiver that subscribes to ClockActor
pub fn clock_receiver_loop() {
  case receive_message(5000) {
    Ok(message) -> {
      case message {
        TimestampMessage(name, timestamp) -> {
          case name {
            "tick_1s" -> io.println("🟢 Received 1s tick: " <> timestamp)
            "tick_5s" -> io.println("🔵 Received 5s tick: " <> timestamp)
            "tick_30s" -> io.println("🟣 Received 30s tick: " <> timestamp)
            _ -> io.println("❓ Unknown tick: " <> name <> " at " <> timestamp)
          }
        }
        TextMessage(content) -> {
          io.println("📝 Received text: " <> content)
        }
        Unknown -> {
          io.println("❔ Received unknown message type")
        }
      }
      clock_receiver_loop()
    }
    Error(Nil) -> {
      io.println("⏰ No message received in 5 seconds")
      clock_receiver_loop()
    }
  }
}

// Get current process PID for subscribing
@external(erlang, "erlang", "self")
pub fn self() -> process.Pid
