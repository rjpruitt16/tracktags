// src/types/metric_types.gleam
// Shared types to avoid circular dependencies

import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import storage/metric_store

pub type Message {
  RecordMetric(metric: Metric)
  FlushTick(timestamp: String, tick_type: String)
  ForceFlush
  GetStatus(reply_with: process.Subject(Metric))
  Shutdown
  GetValue(reply_with: process.Subject(Float))
  UpdatePlanLimit(Float, String, String)
  GetLimitStatus(reply_with: process.Subject(LimitStatus))
  GetMetricType(reply_to: process.Subject(MetricType))
  ResetToInitialValue
  CheckAndAdd(delta: Float, reply_to: process.Subject(Bool))
}

// ============================================================================
// CORE METRIC TYPES
// ============================================================================

/// Defines the scope/hierarchy level where a metric exists
pub type MetricScope {
  /// Business-level metric (aggregated across all customers)
  Business(business_id: String)

  /// Client-level metric (specific to one client within a business)
  Customer(business_id: String, customer_id: String)
  // Future scope extensions:
  // Region(region_id: String, business_id: String)
  // RegionCustomer(region_id: String, business_id: String, customer_id: String)  
  // RegionClientMachine(region_id: String, business_id: String, customer_id: String, machine_id: String)
}

pub type MetricType {
  Reset
  Checkpoint
}

pub type Metric {
  Metric(
    account_id: String,
    metric_name: String,
    value: Float,
    tags: Dict(String, String),
    timestamp: Int,
  )
}

pub type MetricMode {
  Simple(operation: SimpleOperation)
  Precision(config: PrecisionConfig)
}

pub type SimpleOperation {
  Sum
  Min
  Max
  Average
  Count
}

pub type PrecisionConfig {
  // TODO: Implement for v2.0 - premium feature
  Percentiles(percentiles: List(Float))
  Histogram(buckets: List(Float))
  FullDistribution
}

pub type MetricBatch {
  MetricBatch(
    business_id: String,
    customer_id: Option(String),
    metric_name: String,
    aggregated_value: Float,
    operation_count: Int,
    metric_type: String,
    metric_mode: MetricMode,
    window_start: Int,
    window_end: Int,
    flush_interval: String,
    scope: String,
    adapters: Option(Dict(String, json.Json)),
  )
}

pub type LimitStatus {
  LimitStatus(
    current_value: Float,
    limit_value: Float,
    limit_operator: String,
    breach_action: String,
    is_breached: Bool,
  )
}

// ============================================================================
// METADATA TYPES
// ============================================================================

pub type MetricMetadata {
  MetricMetadata(
    integrations: Option(IntegrationConfig),
    billing: Option(BillingConfig),
    custom: Option(Dict(String, dynamic.Dynamic)),
  )
}

pub type IntegrationConfig {
  IntegrationConfig(
    supabase: Option(SupabaseConfig),
    stripe: Option(StripeConfig),
    fly: Option(FlyConfig),
  )
}

pub type SupabaseConfig {
  SupabaseConfig(
    enabled: Bool,
    table_name: Option(String),
    retention_days: Option(Int),
    batch_interval: Option(String),
    restore_on_startup: Option(Bool),
  )
}

pub type StripeConfig {
  StripeConfig(
    enabled: Bool,
    price_id: Option(String),
    key_name: Option(String),
    billing_threshold: Option(Float),
    overage_item_id: Option(String),
    overage_threshold: Option(Int),
  )
}

pub type FlyConfig {
  FlyConfig(
    enabled: Bool,
    scale_threshold: Option(Float),
    max_machines: Option(Int),
  )
}

pub type BillingConfig {
  BillingConfig(
    enabled: Bool,
    currency: Option(String),
    rate_per_operation: Option(Float),
  )
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Convert a MetricScope to the lookup key used in the registry
/// This must match the key format used by existing actors
pub fn scope_to_lookup_key(scope: MetricScope) -> String {
  case scope {
    // Business metrics use just the business_id as the key
    Business(business_id) -> business_id

    // Client metrics use "business_id:customer_id" format
    Customer(business_id, customer_id) -> business_id <> ":" <> customer_id
  }
}

/// Convert a MetricScope to its string representation for API contracts
pub fn scope_to_string(scope: MetricScope) -> String {
  case scope {
    Business(_) -> "business"
    Customer(_, _) -> "customer"
  }
}

/// Parse a scope string and IDs back into a MetricScope
/// Useful for API request parsing
pub fn string_to_scope(
  scope_str: String,
  business_id: String,
  customer_id: Option(String),
) -> Result(MetricScope, String) {
  case scope_str {
    "business" -> Ok(Business(business_id))
    "customer" ->
      case customer_id {
        Some(id) -> Ok(Customer(business_id, id))
        None -> Error("client scope requires customer_id")
      }
    _ -> Error("Invalid scope: " <> scope_str)
  }
}

/// Generate a human-readable description of the scope
pub fn scope_description(scope: MetricScope) -> String {
  case scope {
    Business(business_id) -> "Business-level metric for " <> business_id

    Customer(business_id, customer_id) ->
      "Client-level metric for " <> business_id <> "/" <> customer_id
  }
}

/// Extract business_id from any scope (useful for permissions)
pub fn get_business_id(scope: MetricScope) -> String {
  case scope {
    Business(business_id) -> business_id
    Customer(business_id, _) -> business_id
  }
}

/// Check if a scope is at the business level
pub fn is_business_scope(scope: MetricScope) -> Bool {
  case scope {
    Business(_) -> True
    Customer(_, _) -> False
  }
}

/// Check if a scope is at the client level  
pub fn is_client_scope(scope: MetricScope) -> Bool {
  case scope {
    Business(_) -> False
    Customer(_, _) -> True
  }
}

pub fn metric_type_to_string(metric_type: MetricType) -> String {
  case metric_type {
    Reset -> "reset"
    Checkpoint -> "checkpoint"
  }
}

pub fn string_to_metric_type(metric_type: String) -> MetricType {
  case metric_type {
    "reset" -> Reset
    "checkpoint" -> Checkpoint
    _ -> Checkpoint
  }
}

pub fn get_supabase_batch_interval(metadata: Option(MetricMetadata)) -> String {
  case metadata {
    Some(meta) -> {
      case meta.integrations {
        Some(integrations) -> {
          case integrations.supabase {
            Some(supabase_config) -> {
              case supabase_config.batch_interval {
                Some(interval) ->
                  interval_to_tick_format(validate_batch_interval(interval))
                None -> "tick_15s"
                // ← Default in tick format
              }
            }
            None -> "tick_15s"
          }
        }
        None -> "tick_15s"
      }
    }
    None -> "tick_15s"
  }
}

// Add this helper function
fn interval_to_tick_format(interval: String) -> String {
  "tick_" <> interval
}

pub fn handle_metric_types_flush(
  metric_type metric_type: MetricType,
  account_id account_id: String,
  metric_name metric_name: String,
  initial_value initial_value: Float,
) {
  // Handle Reset vs Checkpoint vs StripeBilling logic
  case metric_type {
    Reset -> {
      logging.log(
        logging.Info,
        "[MetricActor] 🔄 Reset metric to initial value: "
          <> float.to_string(initial_value),
      )
      let _ = metric_store.reset_metric(account_id, metric_name, initial_value)
      Nil
    }
    Checkpoint -> {
      logging.log(
        logging.Info,
        "[MetricActor] ✅ Checkpoint metric (keeping current value)",
      )
      Nil
    }
  }
}

/// Default behavior when no metadata is provided
fn default_supabase_behavior(metric_type: MetricType) -> Bool {
  case metric_type {
    Checkpoint -> False
    Reset -> False
  }
}

/// Validate and constrain batch intervals
fn validate_batch_interval(interval: String) -> String {
  case interval {
    "1s" | "5s" | "15s" | "30s" | "1m" | "5m" | "15m" | "30m" | "1h" -> interval
    _ -> "15s"
    // Default for invalid values
  }
}

pub fn should_send_to_supabase(
  metric_type: MetricType,
  metadata: Option(MetricMetadata),
) -> Bool {
  // Try to get explicit config from metadata
  case metadata {
    Some(meta) -> {
      case meta.integrations {
        Some(integrations) -> {
          case integrations.supabase {
            Some(supabase_config) -> supabase_config.enabled
            None -> type_default(metric_type)
          }
        }
        None -> type_default(metric_type)
      }
    }
    None -> type_default(metric_type)
  }
}

fn type_default(metric_type: MetricType) -> Bool {
  case metric_type {
    Checkpoint -> True
    Reset -> False
  }
}

pub fn should_report_overage(
  metadata: Option(MetricMetadata),
  is_breached: Bool,
  breach_action: String,
) -> Option(#(Option(String), String, Int)) {
  // Returns (key_name, item_id, threshold)
  case is_breached, breach_action {
    True, "allow_overage" -> {
      case get_stripe_config(metadata) {
        Some(stripe_config) -> {
          case stripe_config.overage_item_id, stripe_config.overage_threshold {
            Some(item_id), Some(threshold) ->
              Some(#(stripe_config.key_name, item_id, threshold))
            _, _ -> None
          }
        }
        None -> None
      }
    }
    _, _ -> None
  }
}

// ============================================================================
// METADATA SERIALIZATION (FOR ELIXIR BRIDGE)
// ============================================================================

/// Encode metadata to JSON string for Elixir bridge
pub fn encode_metadata_to_string(metadata: Option(MetricMetadata)) -> String {
  case metadata {
    None -> "{}"
    Some(meta) -> json.to_string(metadata_to_json(meta))
  }
}

pub fn decode_metadata_from_string(
  metadata_json: String,
) -> Option(MetricMetadata) {
  let decoder = {
    use integrations <- decode.optional_field(
      "integrations",
      None,
      decode.optional(integrations_decoder()),
    )
    use billing <- decode.optional_field(
      "billing",
      None,
      decode.optional(billing_config_decoder()),
    )
    use custom <- decode.optional_field(
      "custom",
      None,
      decode.optional(decode.dict(decode.string, decode.dynamic)),
    )

    decode.success(MetricMetadata(
      integrations: integrations,
      billing: billing,
      custom: custom,
    ))
  }
  case json.parse(metadata_json, decoder) {
    Ok(metadata) -> Some(metadata)
    Error(_) -> None
  }
}

// ============================================================================
// JSON ENCODERS
// ============================================================================

fn metadata_to_json(metadata: MetricMetadata) -> json.Json {
  let integrations_json = case metadata.integrations {
    Some(integrations) -> integrations_to_json(integrations)
    None -> json.null()
  }

  let billing_json = case metadata.billing {
    Some(billing) -> billing_config_to_json(billing)
    None -> json.null()
  }

  let custom_json = case metadata.custom {
    Some(custom) ->
      json.object(
        dict.to_list(custom)
        |> list.map(fn(entry) {
          let #(key, _value) = entry
          #(key, json.string("dynamic_value"))
          // Simplified for now
        }),
      )
    None -> json.null()
  }

  json.object([
    #("integrations", integrations_json),
    #("billing", billing_json),
    #("custom", custom_json),
  ])
}

fn integrations_to_json(integrations: IntegrationConfig) -> json.Json {
  json.object([
    #("supabase", case integrations.supabase {
      Some(config) -> supabase_config_to_json(config)
      None -> json.null()
    }),
    #("stripe", case integrations.stripe {
      Some(config) -> stripe_config_to_json(config)
      None -> json.null()
    }),
    #("fly", case integrations.fly {
      Some(config) -> fly_config_to_json(config)
      None -> json.null()
    }),
  ])
}

fn supabase_config_to_json(config: SupabaseConfig) -> json.Json {
  json.object([
    #("enabled", json.bool(config.enabled)),
    #("table_name", json.nullable(config.table_name, json.string)),
    #("retention_days", json.nullable(config.retention_days, json.int)),
    #("batch_interval", json.nullable(config.batch_interval, json.string)),
    #("restore_on_startup", json.nullable(config.restore_on_startup, json.bool)),
  ])
}

fn stripe_config_to_json(config: StripeConfig) -> json.Json {
  json.object([
    #("enabled", json.bool(config.enabled)),
    #("key_name", json.nullable(config.key_name, json.string)),
    #("price_id", json.nullable(config.price_id, json.string)),
    #("billing_threshold", json.nullable(config.billing_threshold, json.float)),
    #("overage_item_id", json.nullable(config.overage_item_id, json.string)),
    #("overage_threshold", json.nullable(config.overage_threshold, json.int)),
  ])
}

fn fly_config_to_json(config: FlyConfig) -> json.Json {
  json.object([
    #("enabled", json.bool(config.enabled)),
    #("scale_threshold", json.nullable(config.scale_threshold, json.float)),
    #("max_machines", json.nullable(config.max_machines, json.int)),
  ])
}

fn billing_config_to_json(config: BillingConfig) -> json.Json {
  json.object([
    #("enabled", json.bool(config.enabled)),
    #("currency", json.nullable(config.currency, json.string)),
    #(
      "rate_per_operation",
      json.nullable(config.rate_per_operation, json.float),
    ),
  ])
}

// ============================================================================
// JSON DECODERS
// ============================================================================
fn billing_config_decoder() -> decode.Decoder(BillingConfig) {
  use enabled <- decode.field("enabled", decode.bool)
  use currency <- decode.optional_field(
    "currency",
    None,
    decode.optional(decode.string),
  )
  use rate_per_operation <- decode.optional_field(
    "rate_per_operation",
    None,
    decode.optional(decode.float),
  )

  decode.success(BillingConfig(
    enabled: enabled,
    currency: currency,
    rate_per_operation: rate_per_operation,
  ))
}

fn integrations_decoder() -> decode.Decoder(IntegrationConfig) {
  use supabase <- decode.optional_field(
    "supabase",
    None,
    decode.optional(supabase_config_decoder()),
  )
  use stripe <- decode.optional_field(
    "stripe",
    None,
    decode.optional(stripe_config_decoder()),
  )
  use fly <- decode.optional_field(
    "fly",
    None,
    decode.optional(fly_config_decoder()),
  )

  decode.success(IntegrationConfig(supabase: supabase, stripe: stripe, fly: fly))
}

fn supabase_config_decoder() -> decode.Decoder(SupabaseConfig) {
  use enabled <- decode.field("enabled", decode.bool)
  use table_name <- decode.optional_field(
    "table_name",
    None,
    decode.optional(decode.string),
  )
  use retention_days <- decode.optional_field(
    "retention_days",
    None,
    decode.optional(decode.int),
  )
  use batch_interval <- decode.optional_field(
    "batch_interval",
    None,
    decode.optional(decode.string),
  )
  use restore_on_startup <- decode.optional_field(
    "restore_on_startup",
    None,
    decode.optional(decode.bool),
  )

  decode.success(SupabaseConfig(
    enabled: enabled,
    table_name: table_name,
    retention_days: retention_days,
    batch_interval: batch_interval,
    restore_on_startup: restore_on_startup,
  ))
}

/// Check if metric should restore from DB on startup
pub fn should_restore_on_startup(metric_type: MetricType) -> Bool {
  case metric_type {
    // Checkpoint ALWAYS restores (that's its purpose)
    Checkpoint -> True

    // Reset NEVER restores (always starts fresh)
    Reset -> False
    // StripeBilling lets user decide (default: false for safety)
  }
}

fn stripe_config_decoder() -> decode.Decoder(StripeConfig) {
  use enabled <- decode.field("enabled", decode.bool)
  use key_name <- decode.optional_field(
    // ADD THIS
    "key_name",
    None,
    decode.optional(decode.string),
  )
  use price_id <- decode.optional_field(
    "price_id",
    None,
    decode.optional(decode.string),
  )
  use billing_threshold <- decode.optional_field(
    "billing_threshold",
    None,
    decode.optional(decode.float),
  )
  use overage_item_id <- decode.optional_field(
    "overage_item_id",
    None,
    decode.optional(decode.string),
  )
  use overage_threshold <- decode.optional_field(
    "overage_threshold",
    None,
    decode.optional(decode.int),
  )

  decode.success(StripeConfig(
    enabled: enabled,
    key_name: key_name,
    // ADD THIS
    price_id: price_id,
    billing_threshold: billing_threshold,
    overage_item_id: overage_item_id,
    overage_threshold: overage_threshold,
  ))
}

fn fly_config_decoder() -> decode.Decoder(FlyConfig) {
  use enabled <- decode.field("enabled", decode.bool)
  use scale_threshold <- decode.optional_field(
    "scale_threshold",
    None,
    decode.optional(decode.float),
  )
  use max_machines <- decode.optional_field(
    "max_machines",
    None,
    decode.optional(decode.int),
  )

  decode.success(FlyConfig(
    enabled: enabled,
    scale_threshold: scale_threshold,
    max_machines: max_machines,
  ))
}

pub fn metadata_decoder() -> decode.Decoder(MetricMetadata) {
  use integrations <- decode.optional_field(
    "integrations",
    None,
    decode.optional(integrations_decoder()),
  )
  use billing <- decode.optional_field(
    "billing",
    None,
    decode.optional(billing_config_decoder()),
  )
  use custom <- decode.optional_field(
    "custom",
    None,
    decode.optional(decode.dict(decode.string, decode.dynamic)),
  )

  decode.success(MetricMetadata(
    integrations: integrations,
    billing: billing,
    custom: custom,
  ))
}

/// Parse account_id into components for MetricBatch creation
pub fn parse_account_id(account_id: String) -> #(String, Option(String), String) {
  case string.split_once(account_id, ":") {
    Ok(#(business_id, customer_id)) -> #(
      business_id,
      // Return the actual business_id
      Some(customer_id),
      // Return the actual customer_id  
      "customer",
    )
    Error(_) -> #(account_id, None, "business")
  }
}

/// Convert metadata to adapters field (comma-separated integrations)
pub fn metadata_to_adapters(
  metadata: Option(MetricMetadata),
) -> Option(Dict(String, json.Json)) {
  case metadata {
    Some(meta) -> {
      case meta.integrations {
        Some(integrations) -> {
          let enabled_integrations = []

          let with_supabase = case integrations.supabase {
            Some(config) if config.enabled -> [
              "supabase",
              ..enabled_integrations
            ]
            _ -> enabled_integrations
          }

          let with_stripe = case integrations.stripe {
            Some(config) if config.enabled -> ["stripe", ..with_supabase]
            _ -> with_supabase
          }

          let with_fly = case integrations.fly {
            Some(config) if config.enabled -> ["fly", ..with_stripe]
            _ -> with_stripe
          }

          case with_fly {
            [] -> None
            integrations_list -> {
              let adapters_dict =
                dict.new()
                |> dict.insert(
                  "enabled_integrations",
                  json.string(string.join(integrations_list, ",")),
                )
              Some(adapters_dict)
            }
          }
        }
        None -> None
      }
    }
    None -> None
  }
}

// Helper to extract Stripe config from metadata
pub fn get_stripe_config(
  metadata: Option(MetricMetadata),
) -> Option(StripeConfig) {
  case metadata {
    Some(meta) -> {
      case meta.integrations {
        Some(integrations) -> integrations.stripe
        None -> None
      }
    }
    None -> None
  }
}

// Check if we should report overage and get the config
pub fn get_overage_config(
  metadata: Option(MetricMetadata),
  is_breached: Bool,
  breach_action: String,
) -> Option(StripeConfig) {
  case is_breached, breach_action {
    True, "allow_overage" -> get_stripe_config(metadata)
    _, _ -> None
  }
}

pub fn encode_metric_args(
  args: #(
    String,
    String,
    String,
    Float,
    String,
    String,
    Int,
    String,
    String,
    Float,
    String,
    String,
  ),
) -> List(dynamic.Dynamic) {
  let #(
    account_id,
    metric_name,
    tick_type,
    initial_value,
    tags_json,
    operation,
    cleanup_after_seconds,
    metric_type,
    metadata,
    limit_value,
    limit_operator,
    breach_action,
  ) = args
  [
    dynamic.string(account_id),
    dynamic.string(metric_name),
    dynamic.string(tick_type),
    dynamic.float(initial_value),
    dynamic.string(tags_json),
    dynamic.string(operation),
    dynamic.int(cleanup_after_seconds),
    dynamic.string(metric_type),
    dynamic.string(metadata),
    dynamic.float(limit_value),
    dynamic.string(limit_operator),
    dynamic.string(breach_action),
  ]
}
