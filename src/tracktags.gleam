import erlang_interop
import gleam/erlang/atom
import gleam/erlang/process
import gleam/io

// External functions to interact with ClockActor
// Now we pass raw PIDs instead of Subjects
@external(erlang, "Elixir.ClockActor", "subscribe")
fn subscribe_raw(tick_name: String, pid: process.Pid) -> atom.Atom

@external(erlang, "Elixir.ClockActor", "unsubscribe")
fn unsubscribe_raw(tick_name: String, pid: process.Pid) -> atom.Atom

@external(erlang, "Elixir.ClockApp", "start")
fn start_clock_app() -> Result(atom.Atom, String)

// Wrapper functions that use the current process PID
fn subscribe(tick_name: String) -> atom.Atom {
  subscribe_raw(tick_name, erlang_interop.self())
}

fn unsubscribe(tick_name: String) -> atom.Atom {
  unsubscribe_raw(tick_name, erlang_interop.self())
}

// Function that runs in the listener process
fn listener_process(parent: process.Subject(Nil)) {
  io.println("🎯 Subscribing to ticks...")

  let result1 = subscribe("tick_1s")
  io.println("tick_1s subscription: " <> atom.to_string(result1))

  let result2 = subscribe("tick_5s")
  io.println("tick_5s subscription: " <> atom.to_string(result2))

  io.println("👂 Listening for 30 seconds...")

  // Listen for 30 seconds
  listen_with_timeout(30_000)

  io.println("🛑 Unsubscribing...")
  let _ = unsubscribe("tick_1s")
  let _ = unsubscribe("tick_5s")

  // Notify parent we're done
  process.send(parent, Nil)
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom.Atom) -> Int

fn current_time_ms() -> Int {
  system_time(atom.create_from_string("millisecond"))
}

fn listen_with_timeout(timeout_ms: Int) {
  let start = current_time_ms()
  listen_until(start + timeout_ms)
}

fn listen_until(end_time: Int) {
  case current_time_ms() > end_time {
    True -> {
      io.println("⏱️ Timeout reached")
      Nil
    }
    False -> {
      case erlang_interop.receive_message(5000) {
        Ok(message) -> {
          case message {
            erlang_interop.TimestampMessage(name, timestamp) -> {
              case name {
                "tick_1s" -> io.println("🟢 1s tick: " <> timestamp)
                "tick_5s" -> io.println("🔵 5s tick: " <> timestamp)
                "tick_30s" -> io.println("🟣 30s tick: " <> timestamp)
                _ -> io.println("❓ Unknown: " <> name)
              }
            }
            _ -> io.println("📦 Other message received")
          }
          listen_until(end_time)
        }
        Error(_) -> {
          io.println("⏰ No message timeout")
          listen_until(end_time)
        }
      }
    }
  }
}

pub fn main() {
  io.println("🚀 Starting Clock Actor Test (MVP)")

  // Start ClockApp
  io.println("📡 Starting ClockApp...")
  case start_clock_app() {
    Ok(_) -> io.println("✅ ClockApp started")
    Error(e) -> {
      io.println("❌ Failed: " <> e)
      panic
    }
  }

  process.sleep(1000)

  // Create subject for completion notification
  let done = process.new_subject()

  // Start listener process
  process.start(fn() { listener_process(done) }, False)

  // Wait for completion
  case process.receive(done, 35_000) {
    Ok(_) -> io.println("✅ Test completed")
    Error(_) -> io.println("⚠️ Test timeout")
  }
}
