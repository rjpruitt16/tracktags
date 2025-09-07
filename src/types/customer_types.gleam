// src/types/customer_types.gleam
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import glixir
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

pub type Customer {
  Customer(
    customer_id: String,
    business_id: String,
    customer_name: String,
    plan_id: Option(String),
    stripe_customer_id: Option(String),
    stripe_subscription_id: Option(String),
    stripe_price_id: Option(String),
    created_at: String,
  )
}

pub type CustomerMachine {
  CustomerMachine(
    id: String,
    customer_id: String,
    business_id: String,
    machine_id: String,
    fly_app_name: Option(String),
    machine_url: Option(String),
    ip_address: Option(String),
    status: String,
    expires_at: Int,
    docker_image: Option(String),
    fly_state: Option(String),
  )
}

pub type CustomerContext {
  CustomerContext(
    customer: Customer,
    machines: List(CustomerMachine),
    plan_limits: List(PlanLimit),
  )
}

// Keep PlanLimit here too to avoid circular deps
pub type PlanLimit {
  PlanLimit(
    id: String,
    business_id: Option(String),
    plan_id: Option(String),
    customer_id: Option(String),
    metric_name: String,
    limit_value: Float,
    limit_period: String,
    breach_operator: String,
    breach_action: String,
    webhook_urls: Option(String),
    created_at: String,
    metric_type: String,
  )
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
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
  CleanupTick(timestamp: String, tick_type: String)
  GetMetricActor(
    metric_name: String,
    reply_with: process.Subject(Option(process.Subject(metric_types.Message))),
  )
  Shutdown
  PlanLimitChanged(
    business_id: String,
    customer_id: String,
    metric_name: String,
    new_limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
  ResetStripeMetrics
  UpdateMachines(machine_ids: List(String), expires_at: Int)
  UpdatePlan(plan_id: Option(String), stripe_price_id: Option(String))
  GetMachines(reply: Subject(List(String)))
  GetPlan(reply: Subject(#(Option(String), Option(String))))

  UpdateContext(context: CustomerContext)
}

pub fn lookup_client_subject(
  business_id: String,
  customer_id: String,
) -> Result(process.Subject(Message), String) {
  let key = "client:" <> business_id <> ":" <> customer_id
  case glixir.lookup_subject_string(utils.tracktags_registry(), key) {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Client actor not found: " <> key)
  }
}
