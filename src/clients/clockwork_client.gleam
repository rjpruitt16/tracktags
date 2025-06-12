import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}

pub type SSEEvent {
  SSEEvent(
    event: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

@external(erlang, "sse_client", "start_link")
pub fn start_link(url: String, handler: process.Pid) -> process.Pid

pub fn start_sse(url: String, on_event: fn(SSEEvent) -> Nil) -> Nil {
  // Create a new subject for message passing
  let handler_subject = process.new_subject()
  // Start a process to handle SSE events
  let handler_pid =
    process.start(fn() { sse_handler_loop(handler_subject, on_event) }, True)
  let _pid = start_link(url, handler_pid)
  io.println("[SSE] Started Elixir SSE client and handler")
  Nil
}

// Loop: receive SSE events from Elixir, call the callback
fn sse_handler_loop(
  subject: process.Subject(#(String, String)),
  on_event: fn(SSEEvent) -> Nil,
) -> Nil {
  // Block until a message arrives, with a timeout (e.g., 1000ms)
  let msg = process.receive(subject, 1000)
  case msg {
    Ok(#("sse_event", data)) -> {
      on_event(SSEEvent(Some("raw"), data, None, None))
      sse_handler_loop(subject, on_event)
    }
    _ -> {
      sse_handler_loop(subject, on_event)
    }
  }
}
