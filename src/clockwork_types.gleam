// Shared types for the Clockwork client system
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/option.{type Option}

// Core tick event for the clock actor (rich data structure)
pub type ClockTick {
  ClockTick(name: String, timestamp: Int, sequence: Int, region: Option(String))
}

// Messages that the clock actor can receive
pub type ClockMessage {
  Subscribe(tick: String, subscriber: process.Subject(TickNotification))
  Unsubscribe(tick: String, subscriber: process.Subject(TickNotification))
  SSEConnected
  SSEDisconnected(reason: String)
  TickReceived(event: ClockTick)
  GetStatus(reply_with: process.Subject(ClockStatus))
  Shutdown
}

// Notifications sent to subscribers
pub type TickNotification {
  Tick(name: String, timestamp: Int)
  ClockDisconnected
  ClockReconnected
}

// Status information about the clock
pub type ClockStatus {
  ClockStatus(
    connected: Bool,
    subscribers: Dict(String, Int),
    total_ticks_received: Int,
    uptime_seconds: Int,
  )
}

// SSE Client events (simpler, string-based)
pub type SSEEvent {
  TickEvent(name: String, timestamp: String)
  ConnectionEstablished
  ConnectionLost(reason: String)
}
