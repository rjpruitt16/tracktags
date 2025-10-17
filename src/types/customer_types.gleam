// src/types/customer_types.gleam
import birl
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None}
import glixir
import types/metric_types.{type MetricMetadata, type MetricType}
import utils/utils

// In types/customer_types.gleam
pub type Customer {
  Customer(
    customer_id: String,
    business_id: String,
    customer_name: String,
    plan_id: Option(String),
    stripe_customer_id: Option(String),
    stripe_subscription_id: Option(String),
    stripe_price_id: Option(String),
    subscription_ends_at: Option(String),
    created_at: String,
  )
}

pub fn customer_decoder() -> decode.Decoder(Customer) {
  use customer_id <- decode.field("customer_id", decode.string)
  use business_id <- decode.field("business_id", decode.string)
  use plan_id <- decode.field("plan_id", decode.optional(decode.string))
  use customer_name <- decode.field("customer_name", decode.string)
  use stripe_customer_id <- decode.optional_field(
    "stripe_customer_id",
    None,
    decode.optional(decode.string),
  )
  use stripe_subscription_id <- decode.optional_field(
    "stripe_subscription_id",
    None,
    decode.optional(decode.string),
  )
  use stripe_price_id <- decode.optional_field(
    "stripe_price_id",
    None,
    decode.optional(decode.string),
  )
  use subscription_ends_at <- decode.optional_field(
    "subscription_ends_at",
    None,
    decode.optional(decode.string),
  )
  use created_at <- decode.field("created_at", decode.string)

  decode.success(Customer(
    customer_id: customer_id,
    business_id: business_id,
    plan_id: plan_id,
    customer_name: customer_name,
    stripe_customer_id: stripe_customer_id,
    stripe_subscription_id: stripe_subscription_id,
    stripe_price_id: stripe_price_id,
    subscription_ends_at: subscription_ends_at,
    created_at: created_at,
  ))
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
    metric_name: String,
    limit_value: Float,
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
  ResetPlanMetrics
  SetMachinesList(machine_ids: List(String), expires_at: Int)
  SetPlan(plan_id: Option(String), stripe_price_id: Option(String))
  GetMachines(reply: Subject(List(String)))
  GetPlan(reply: Subject(#(Option(String), Option(String))))
  // Instead of RefreshFromDatabase, use specific updates:
  RealtimeMachineChange(machine: CustomerMachine, event_type: String)
  RealtimePlanChange(plan_id: Option(String), price_id: Option(String))
  SetContextFromDatabase(context: CustomerContext)

  RegisterApiKey(api_key: String)
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

pub fn customer_machine_decoder() -> decode.Decoder(CustomerMachine) {
  use id <- decode.field("id", decode.string)
  use customer_id <- decode.field("customer_id", decode.string)
  use business_id <- decode.field("business_id", decode.string)
  use machine_id <- decode.field("machine_id", decode.string)
  use fly_app_name <- decode.optional_field(
    "fly_app_name",
    None,
    decode.optional(decode.string),
  )
  use machine_url <- decode.optional_field(
    "machine_url",
    None,
    decode.optional(decode.string),
  )
  use ip_address <- decode.optional_field(
    "ip_address",
    None,
    decode.optional(decode.string),
  )
  use status <- decode.field("status", decode.string)
  use expires_at_str <- decode.field("expires_at", decode.string)
  use docker_image <- decode.optional_field(
    "docker_image",
    None,
    decode.optional(decode.string),
  )
  use fly_state <- decode.optional_field(
    "fly_state",
    None,
    decode.optional(decode.string),
  )

  // Parse the timestamp string to int
  let expires_at = case birl.parse(expires_at_str) {
    Ok(time) -> birl.to_unix(time)
    Error(_) -> 0
    // Default fallback
  }

  decode.success(CustomerMachine(
    id: id,
    customer_id: customer_id,
    business_id: business_id,
    machine_id: machine_id,
    fly_app_name: fly_app_name,
    machine_url: machine_url,
    ip_address: ip_address,
    status: status,
    expires_at: expires_at,
    docker_image: docker_image,
    fly_state: fly_state,
  ))
}
