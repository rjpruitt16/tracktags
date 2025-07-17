// src/types/metric_types.gleam
// Shared types to avoid circular dependencies

import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/float
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import logging
import storage/metric_store

// ============================================================================
// CORE METRIC TYPES
// ============================================================================

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
    client_id: Option(String),
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
    // NEW: "1s", "15s", "30s", "1m"
  )
}

pub type StripeConfig {
  StripeConfig(
    enabled: Bool,
    price_id: Option(String),
    billing_threshold: Option(Float),
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

/// Get Supabase batch interval from metadata (default: "15s")
pub fn get_supabase_batch_interval(metadata: Option(MetricMetadata)) -> String {
  case metadata {
    Some(meta) -> {
      case meta.integrations {
        Some(integrations) -> {
          case integrations.supabase {
            Some(supabase_config) -> {
              case supabase_config.batch_interval {
                Some(interval) -> validate_batch_interval(interval)
                None -> "15s"
                // Default
              }
            }
            None -> "15s"
          }
        }
        None -> "15s"
      }
    }
    None -> "15s"
  }
}

pub fn handle_metric_types_flush(
  metric_type metric_type: MetricType,
  account_id account_id: String,
  metric_name metric_name: String,
  initial_value initial_value: Float,
) {
  // Handle Reset vs Checkpoint logic
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

/// Validate and constrain batch intervals
fn validate_batch_interval(interval: String) -> String {
  case interval {
    "1s" | "15s" | "30s" | "1m" | "5m" | "15m" | "30m" | "1h" -> interval
    _ -> "15s"
    // Default for invalid values
  }
}

/// Check if Supabase integration is enabled in metadata
pub fn should_send_to_supabase(
  metric_type: MetricType,
  metadata: Option(MetricMetadata),
) -> Bool {
  case metadata {
    Some(meta) -> {
      case meta.integrations {
        Some(integrations) -> {
          case integrations.supabase {
            Some(supabase_config) -> supabase_config.enabled
            None -> default_supabase_behavior(metric_type)
          }
        }
        None -> default_supabase_behavior(metric_type)
      }
    }
    None -> default_supabase_behavior(metric_type)
  }
}

/// Default behavior when no metadata is provided
fn default_supabase_behavior(metric_type: MetricType) -> Bool {
  case metric_type {
    Checkpoint -> False
    Reset -> False
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
  ])
}

fn stripe_config_to_json(config: StripeConfig) -> json.Json {
  json.object([
    #("enabled", json.bool(config.enabled)),
    #("price_id", json.nullable(config.price_id, json.string)),
    #("billing_threshold", json.nullable(config.billing_threshold, json.float)),
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

  decode.success(SupabaseConfig(
    enabled: enabled,
    table_name: table_name,
    retention_days: retention_days,
    batch_interval: batch_interval,
  ))
}

fn stripe_config_decoder() -> decode.Decoder(StripeConfig) {
  use enabled <- decode.field("enabled", decode.bool)
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

  decode.success(StripeConfig(
    enabled: enabled,
    price_id: price_id,
    billing_threshold: billing_threshold,
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
