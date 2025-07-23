// src/types/client_types.gleam
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/option.{type Option}
import glixir
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

pub type Client {
  Client(client_id: String, business_id: String, client_name: String)
}

pub type CustomerApiKey {
  CustomerApiKey(
    customer_uid: String,
    business_id: String,
    api_key: String,
    current_plan_id: String,
  )
}

pub type Message {
  RecordMetric(
    metric_name: String,
    initial_value: Float,
    tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
    plan_limit_value: Float,
    plan_limit_operator: String,
    plan_breach_action: String,
  )
  CleanupTick(timestamp: String, tick_type: String)
  GetMetricActor(
    metric_name: String,
    reply_with: process.Subject(Option(process.Subject(metric_types.Message))),
  )
  Shutdown
  PlanLimitChanged(
    business_id: String,
    client_id: String,
    metric_name: String,
    new_limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
}

pub fn lookup_client_subject(
  business_id: String,
  client_id: String,
) -> Result(process.Subject(Message), String) {
  let key = "client:" <> business_id <> ":" <> client_id
  case glixir.lookup_subject_string(utils.tracktags_registry(), key) {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Client actor not found: " <> key)
  }
}
