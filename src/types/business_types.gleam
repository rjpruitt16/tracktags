// src/types/business_types.gleam
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/option.{type Option}
import glixir
import types/customer_types
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

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
  RecordClientMetric(
    customer_id: String,
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
  RefreshPlanLimit(
    metric_name: String,
    new_limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
  EnsureCustomerExists(
    customer_id: String,
    context: customer_types.CustomerContext,
    reply: process.Subject(process.Subject(customer_types.Message)),
  )
}

pub fn lookup_business_subject(
  business_id: String,
) -> Result(process.Subject(Message), String) {
  case glixir.lookup_subject_string(utils.tracktags_registry(), business_id) {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Business actor not found: " <> business_id)
  }
}

pub type Business {
  Business(
    business_id: String,
    stripe_customer_id: Option(String),
    stripe_subscription_id: Option(String),
    business_name: String,
    email: String,
    plan_type: String,
    subscription_status: String,
    current_plan_id: Option(String),
  )
}

pub type Plan {
  Plan(
    id: String,
    business_id: String,
    plan_name: String,
    stripe_price_id: Option(String),
    plan_status: String,
  )
}

pub type PlanLimit {
  PlanLimit(
    id: String,
    plan_id: String,
    metric_name: String,
    limit_value: Float,
    limit_period: String,
    breach_operator: String,
    breach_action: String,
    webhook_urls: Option(String),
  )
}
