// src/types/integration_types.gleam
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/option.{type Option, None, Some}

// ============================================================================
// INTEGRATION CONFIGS
// ============================================================================

pub type SupabaseConfig {
  SupabaseConfig(
    enabled: Bool,
    table_name: Option(String),
    retention_days: Option(Int),
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

pub type IntegrationConfig {
  IntegrationConfig(
    supabase: Option(SupabaseConfig),
    stripe: Option(StripeConfig),
    fly: Option(FlyConfig),
  )
}

// ============================================================================
// METADATA STRUCTURE
// ============================================================================

pub type MetricMetadata {
  MetricMetadata(
    integrations: Option(IntegrationConfig),
    billing: Option(BillingConfig),
    custom: Option(Dict(String, dynamic.Dynamic)),
  )
}

// ============================================================================
// ENCODING/DECODING HELPERS
// ============================================================================

pub fn encode_metadata_to_string(metadata: Option(MetricMetadata)) -> String {
  case metadata {
    Some(_) -> "metadata_present"
    // Placeholder for now
    None -> "no_metadata"
  }
}
