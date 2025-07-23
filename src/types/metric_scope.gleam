// src/types/metric_scope.gleam
// Defines the scope hierarchy for metrics and provides consistent lookup key generation

import gleam/option.{type Option, None, Some}

/// Defines the scope/hierarchy level where a metric exists
pub type MetricScope {
  /// Business-level metric (aggregated across all clients)
  Business(business_id: String)

  /// Client-level metric (specific to one client within a business)
  Client(business_id: String, client_id: String)
  // Future scope extensions:
  // Region(region_id: String, business_id: String)
  // RegionClient(region_id: String, business_id: String, client_id: String)  
  // RegionClientMachine(region_id: String, business_id: String, client_id: String, machine_id: String)
}

/// Convert a MetricScope to the lookup key used in the registry
/// This must match the key format used by existing actors
pub fn scope_to_lookup_key(scope: MetricScope) -> String {
  case scope {
    // Business metrics use just the business_id as the key
    Business(business_id) -> business_id

    // Client metrics use "business_id:client_id" format
    Client(business_id, client_id) -> business_id <> ":" <> client_id
  }
}

/// Convert a MetricScope to its string representation for API contracts
pub fn scope_to_string(scope: MetricScope) -> String {
  case scope {
    Business(_) -> "business"
    Client(_, _) -> "client"
  }
}

/// Parse a scope string and IDs back into a MetricScope
/// Useful for API request parsing
pub fn string_to_scope(
  scope_str: String,
  business_id: String,
  client_id: Option(String),
) -> Result(MetricScope, String) {
  case scope_str {
    "business" -> Ok(Business(business_id))
    "client" ->
      case client_id {
        Some(id) -> Ok(Client(business_id, id))
        None -> Error("client scope requires client_id")
      }
    _ -> Error("Invalid scope: " <> scope_str)
  }
}

/// Generate a human-readable description of the scope
pub fn scope_description(scope: MetricScope) -> String {
  case scope {
    Business(business_id) -> "Business-level metric for " <> business_id

    Client(business_id, client_id) ->
      "Client-level metric for " <> business_id <> "/" <> client_id
  }
}

/// Extract business_id from any scope (useful for permissions)
pub fn get_business_id(scope: MetricScope) -> String {
  case scope {
    Business(business_id) -> business_id
    Client(business_id, _) -> business_id
  }
}

/// Check if a scope is at the business level
pub fn is_business_scope(scope: MetricScope) -> Bool {
  case scope {
    Business(_) -> True
    Client(_, _) -> False
  }
}

/// Check if a scope is at the client level  
pub fn is_client_scope(scope: MetricScope) -> Bool {
  case scope {
    Business(_) -> False
    Client(_, _) -> True
  }
}
