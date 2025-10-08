// src/types/business_types.gleam
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
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
  RegisterApiKey(api_key: String)
  RealtimeBusinessUpdate(business: Business)
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
    business_name: String,
    email: String,
    plan_type: String,
    subscription_status: String,
    stripe_customer_id: Option(String),
    stripe_subscription_id: Option(String),
    stripe_price_id: Option(String),
    current_plan_id: Option(String),
    default_docker_image: Option(String),
    default_machine_size: Option(String),
    default_region: Option(String),
    created_at: String,
    subscription_ends_at: Option(String),
    deleted_at: Option(String),
    // ← ADD THIS
  )
}

pub fn business_decoder() -> decode.Decoder(Business) {
  use business_id <- decode.field("business_id", decode.string)
  use business_name <- decode.field("business_name", decode.string)
  use email <- decode.field("email", decode.string)
  use plan_type <- decode.field("plan_type", decode.string)
  use subscription_status <- decode.field("subscription_status", decode.string)
  use stripe_customer_id <- decode.field(
    "stripe_customer_id",
    decode.optional(decode.string),
  )
  use stripe_subscription_id <- decode.field(
    "stripe_subscription_id",
    decode.optional(decode.string),
  )
  use stripe_price_id <- decode.field(
    "stripe_price_id",
    decode.optional(decode.string),
  )
  use current_plan_id <- decode.optional_field(
    "current_plan_id",
    None,
    decode.optional(decode.string),
  )
  use default_docker_image <- decode.optional_field(
    "default_docker_image",
    None,
    decode.optional(decode.string),
  )
  use default_machine_size <- decode.optional_field(
    "default_machine_size",
    Some("shared-cpu-1x"),
    decode.optional(decode.string),
  )
  use default_region <- decode.optional_field(
    "default_region",
    Some("iad"),
    decode.optional(decode.string),
  )
  use created_at <- decode.field("created_at", decode.string)
  use subscription_ends_at <- decode.field(
    "subscription_ends_at",
    decode.optional(decode.string),
  )
  use deleted_at <- decode.field(
    // ← ADD THIS
    "deleted_at",
    decode.optional(decode.string),
  )

  decode.success(Business(
    business_id: business_id,
    business_name: business_name,
    email: email,
    plan_type: plan_type,
    subscription_status: subscription_status,
    stripe_customer_id: stripe_customer_id,
    stripe_subscription_id: stripe_subscription_id,
    stripe_price_id: stripe_price_id,
    current_plan_id: current_plan_id,
    default_docker_image: default_docker_image,
    default_machine_size: default_machine_size,
    default_region: default_region,
    created_at: created_at,
    subscription_ends_at: subscription_ends_at,
    deleted_at: deleted_at,
    // ← ADD THIS
  ))
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
