// src/types/application_types.gleam - NEW FILE
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/option.{type Option}
import types/business_types
import types/customer_types
import types/metric_types.{type MetricMetadata, type MetricType}

pub type ApplicationMessage {
  SendMetricToBusiness(
    business_id: String,
    metric_name: String,
    tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    initial_value: Float,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
  SendMetricToCustomer(
    business_id: String,
    customer_id: String,
    metric_name: String,
    tick_type: String,
    operation: String,
    cleanup_after_seconds: Int,
    metric_type: MetricType,
    initial_value: Float,
    tags: Dict(String, String),
    metadata: Option(MetricMetadata),
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
  )
  EnsureCustomerActor(
    business_id: String,
    customer_id: String,
    context: customer_types.CustomerContext,
    api_key: String,
    reply_to: process.Subject(
      Result(process.Subject(customer_types.Message), String),
    ),
  )
  EnsureBusinessActor(
    business_id: String,
    api_key: String,
    reply_to: process.Subject(
      Result(process.Subject(business_types.Message), String),
    ),
  )
  Shutdown
}
