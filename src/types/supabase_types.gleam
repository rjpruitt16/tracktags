// src/types/supabase_types.gleam
// Shared types to avoid circular dependencies between actors

pub type PlanLimitChangeEvent {
  PlanLimitChangeEvent(business_id: String, client_id: String)
}
