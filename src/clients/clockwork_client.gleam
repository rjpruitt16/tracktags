// import clockwork_types.{
//   type SSEEvent, ConnectionEstablished, ConnectionLost, TickEvent,
// }
// import gleam/dynamic
// import gleam/erlang/process
// import gleam/int
// import gleam/io
// import gleam/list
// import gleam/otp/actor
// import gleam/string
//
// pub type SSEClient {
//   SSEClient(subject: process.Subject(SSEMessage))
// }
//
// pub type SSEMessage {
//   SSEConnected
//   SSEDisconnected(reason: String)
//   SSEChunk(chunk: String)
//   HandleExternalMessage(dynamic.Dynamic)
// }
//
// /// Start SSE client that receives messages from Elixir GenServer
// pub fn start_sse(
//   url: String,
//   on_event: fn(SSEEvent) -> Nil,
// ) -> Result(SSEClient, String) {
//   io.println("[SSE Client] 🚀 Starting for: " <> url)
//
//   case
//     actor.start_spec(actor.Spec(
//       init: fn() {
//         let selector =
//           process.new_selector()
//           |> process.selecting_anything(HandleExternalMessage)
//         actor.Ready(SSEState(on_event: on_event), selector)
//       },
//       init_timeout: 5000,
//       loop: handle_sse_message,
//     ))
//   {
//     Ok(subject) -> {
//       let pid = process.subject_owner(subject)
//       io.println(
//         "[SSE Client] ✅ Actor started with PID: " <> string.inspect(pid),
//       )
//
//       // Start Elixir SSE GenServer and pass the subject directly
//       let _ = start_elixir_genserver(url, subject)
//
//       Ok(SSEClient(subject))
//     }
//     Error(error) -> Error("Failed to start actor: " <> string.inspect(error))
//   }
// }
//
// type SSEState {
//   SSEState(on_event: fn(SSEEvent) -> Nil)
// }
//
// fn handle_sse_message(
//   message: SSEMessage,
//   state: SSEState,
// ) -> actor.Next(SSEMessage, SSEState) {
//   case message {
//     HandleExternalMessage(dyn) -> {
//       io.println("[SSE] 📤 Got external message: " <> string.inspect(dyn))
//
//       // Try to decode the Elixir message
//       case decode_elixir_message(dyn) {
//         Ok(sse_msg) -> {
//           // Process the decoded message
//           handle_sse_message(sse_msg, state)
//         }
//         Error(_) -> {
//           io.println("[SSE] ❌ Failed to decode external message")
//           actor.continue(state)
//         }
//       }
//     }
//
//     SSEChunk(chunk) -> {
//       io.println("[SSE] 📤 Got chunk: " <> string.slice(chunk, 0, 50))
//
//       case parse_sse_events(chunk) {
//         events -> {
//           case events {
//             [] -> io.println("[SSE] ❌ No events parsed")
//             _ -> {
//               io.println(
//                 "[SSE] ✅ Parsed "
//                 <> int.to_string(list.length(events))
//                 <> " events",
//               )
//               send_events_to_handler(events, state.on_event)
//             }
//           }
//         }
//       }
//
//       actor.continue(state)
//     }
//
//     SSEConnected -> {
//       io.println("[SSE] ✅ Connected")
//       state.on_event(ConnectionEstablished)
//       actor.continue(state)
//     }
//
//     SSEDisconnected(reason) -> {
//       io.println("[SSE] ❌ Disconnected: " <> reason)
//       state.on_event(ConnectionLost(reason))
//       actor.continue(state)
//     }
//   }
// }
//
// fn decode_elixir_message(dyn: dynamic.Dynamic) -> Result(SSEMessage, Nil) {
//   // Try to decode {:sse_connected}
//   case dynamic.tuple2(dynamic.atom, dynamic.atom)(dyn) {
//     Ok(#("sse_connected", _)) -> Ok(SSEConnected)
//     Error(_) -> {
//       // Try to decode {:sse_chunk, string}
//       case dynamic.tuple2(dynamic.atom, dynamic.string)(dyn) {
//         Ok(#("sse_chunk", chunk)) -> Ok(SSEChunk(chunk))
//         Error(_) -> {
//           io.println("[SSE] ❌ Unknown message format: " <> string.inspect(dyn))
//           Error(Nil)
//         }
//       }
//     }
//   }
// }
//
// fn send_events_to_handler(
//   events: List(SSEEvent),
//   handler: fn(SSEEvent) -> Nil,
// ) -> Nil {
//   case events {
//     [] -> Nil
//     [event, ..rest] -> {
//       handler(event)
//       send_events_to_handler(rest, handler)
//     }
//   }
// }
//
// /// Tell Elixir GenServer to start and pass the subject directly
// @external(erlang, "sse_client", "start_link")
// fn start_elixir_genserver(
//   url: String,
//   gleam_subject: process.Subject(SSEMessage),
// ) -> Result(process.Pid, String)
//
// // SSE Parsing
// fn parse_sse_events(chunk: String) -> List(SSEEvent) {
//   // Split chunk into individual events (separated by double newlines)
//   let events = string.split(chunk, "\n\n")
//   parse_event_list(events, [])
// }
//
// fn parse_event_list(events: List(String), acc: List(SSEEvent)) -> List(SSEEvent) {
//   case events {
//     [] -> acc
//     [event_text, ..rest] -> {
//       case parse_single_event(event_text) {
//         Ok(event) -> parse_event_list(rest, [event, ..acc])
//         Error(_) -> parse_event_list(rest, acc)
//       }
//     }
//   }
// }
//
// fn parse_single_event(event_text: String) -> Result(SSEEvent, Nil) {
//   let lines = string.split(string.trim(event_text), "\n")
//   parse_lines(lines, "", "")
// }
//
// fn parse_lines(
//   lines: List(String),
//   event: String,
//   data: String,
// ) -> Result(SSEEvent, Nil) {
//   case lines {
//     [] ->
//       case event, data {
//         "", _ -> Error(Nil)
//         ev, dt -> create_event(ev, dt)
//       }
//
//     [line, ..rest] -> {
//       case string.split_once(line, ": ") {
//         Ok(#("event", value)) -> parse_lines(rest, string.trim(value), data)
//         Ok(#("data", value)) -> parse_lines(rest, event, string.trim(value))
//         _ -> parse_lines(rest, event, data)
//       }
//     }
//   }
// }
//
// fn create_event(event_type: String, data: String) -> Result(SSEEvent, Nil) {
//   case string.starts_with(event_type, "tick_") {
//     True -> {
//       case extract_timestamp(data) {
//         Ok(timestamp) -> Ok(TickEvent(event_type, timestamp))
//         Error(_) -> Error(Nil)
//       }
//     }
//     False -> Error(Nil)
//   }
// }
//
// fn extract_timestamp(json: String) -> Result(String, Nil) {
//   case string.split(json, "\"timestamp\":\"") {
//     [_, rest] -> {
//       case string.split(rest, "\"") {
//         [timestamp, ..] -> Ok(timestamp)
//         _ -> Error(Nil)
//       }
//     }
//     _ -> Error(Nil)
//   }
// }
