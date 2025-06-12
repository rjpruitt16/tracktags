import gleam/erlang/process

// Type for SSE events
pub type SSEEvent {
  SSEEvent(data: String)
}

// External wrapper for the Elixir SSE client
@external(erlang, "sse_client", "start_link")
pub fn start_link(url: String, handler_pid: process.Pid) -> process.Pid
