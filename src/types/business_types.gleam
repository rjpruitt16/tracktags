// src/types/business_types.gleam
import gleam/option.{type Option}

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
