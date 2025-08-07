// src/storage/metric_store.gleam
// Clean Gleam wrapper around Elixir ETS operations

import gleam/erlang/atom
import gleam/float
import logging

/// Supported aggregation operations
pub type Operation {
  Sum
  Average
  Min
  Max
  Count
  Last
}

/// Storage errors
pub type StoreError {
  TableNotFound(String)
  EntryNotFound(String)
  EtsError(String)
}

// ---- RESULT TYPES FROM ELIXIR ----

pub type StoreInitResult {
  MetricStoreInitOk
  MetricStoreInitError(String)
}

pub type StoreAddResult {
  MetricStoreAddOk(Float)
  MetricStoreAddError(String)
}

pub type StoreGetResult {
  MetricStoreGetOk(Float)
  MetricStoreGetError(String)
}

pub type StoreResetResult {
  MetricStoreResetOk
  MetricStoreResetError(String)
}

pub type StoreCleanupResult {
  MetricStoreCleanupOk
  MetricStoreCleanupError(String)
}

pub type StoreCreateResult {
  MetricStoreCreateOk
  MetricStoreCreateError(String)
}

pub type StoreDeleteResult {
  MetricStoreDeleteOk
  MetricStoreDeleteError(String)
}

pub type StoreScanResult {
  MetricStoreScanOk(List(String))
  MetricStoreScanError(String)
}

// ---- FFI TO ELIXIR ----

@external(erlang, "Elixir.Storage.MetricStore", "scan_all_keys")
fn scan_all_keys_ffi(table_name: String) -> StoreScanResult

@external(erlang, "Elixir.Storage.MetricStore", "delete_metric")
fn delete_metric_ffi(
  account_id: String,
  metric_name: String,
) -> StoreDeleteResult

@external(erlang, "Elixir.Storage.MetricStore", "init_store")
fn init_store_ffi(account_id: String) -> StoreInitResult

@external(erlang, "Elixir.Storage.MetricStore", "create_metric")
fn create_metric_ffi(
  account_id: String,
  metric_name: String,
  operation: atom.Atom,
  initial_value: Float,
) -> StoreCreateResult

@external(erlang, "Elixir.Storage.MetricStore", "add_value")
fn add_value_ffi(
  account_id: String,
  metric_name: String,
  value: Float,
) -> StoreAddResult

@external(erlang, "Elixir.Storage.MetricStore", "get_value")
fn get_value_ffi(account_id: String, metric_name: String) -> StoreGetResult

@external(erlang, "Elixir.Storage.MetricStore", "reset_metric")
fn reset_metric_ffi(
  account_id: String,
  metric_name: String,
  reset_value: Float,
) -> StoreResetResult

@external(erlang, "Elixir.Storage.MetricStore", "cleanup_store")
fn cleanup_store_ffi(account_id: String) -> StoreCleanupResult

// ---- PUBLIC API ----

/// Scan all keys in an ETS table
pub fn scan_all_keys(table_name: String) -> List(String) {
  case scan_all_keys_ffi(table_name) {
    MetricStoreScanOk(keys) -> keys
    MetricStoreScanError(_) -> []
  }
}

/// Delete a metric completely
pub fn delete_metric(
  account_id: String,
  metric_name: String,
) -> Result(Nil, StoreError) {
  case delete_metric_ffi(account_id, metric_name) {
    MetricStoreDeleteOk -> {
      logging.log(
        logging.Debug,
        "[MetricStore] ✅ Deleted metric: " <> account_id <> "/" <> metric_name,
      )
      Ok(Nil)
    }
    MetricStoreDeleteError(reason) -> Error(EtsError(reason))
  }
}

/// Initialize metric storage for an account
pub fn init_store(account_id: String) -> Result(Nil, StoreError) {
  case init_store_ffi(account_id) {
    MetricStoreInitOk -> {
      logging.log(
        logging.Info,
        "[MetricStore] ✅ Initialized store for: " <> account_id,
      )
      Ok(Nil)
    }
    MetricStoreInitError(reason) -> {
      logging.log(
        logging.Error,
        "[MetricStore] ❌ Failed to init store: " <> reason,
      )
      Error(EtsError(reason))
    }
  }
}

/// Create a new metric
pub fn create_metric(
  account_id: String,
  metric_name: String,
  operation: Operation,
  initial_value: Float,
) -> Result(Nil, StoreError) {
  let operation_atom = operation_to_atom(operation)

  case
    create_metric_ffi(account_id, metric_name, operation_atom, initial_value)
  {
    MetricStoreCreateOk -> {
      logging.log(
        logging.Debug,
        "[MetricStore] ✅ Created metric: " <> account_id <> "/" <> metric_name,
      )
      Ok(Nil)
    }
    MetricStoreCreateError(reason) -> Error(EtsError(reason))
  }
}

/// Add a value to an existing metric
pub fn add_value(
  account_id: String,
  metric_name: String,
  value: Float,
) -> Result(Float, StoreError) {
  case add_value_ffi(account_id, metric_name, value) {
    MetricStoreAddOk(new_value) -> {
      logging.log(
        logging.Debug,
        "[MetricStore] ✅ Updated "
          <> metric_name
          <> " = "
          <> float.to_string(new_value),
      )
      Ok(new_value)
    }
    MetricStoreAddError(reason) -> Error(EtsError(reason))
  }
}

/// Get current metric value
pub fn get_value(
  account_id: String,
  metric_name: String,
) -> Result(Float, StoreError) {
  case get_value_ffi(account_id, metric_name) {
    MetricStoreGetOk(value) -> Ok(value)
    MetricStoreGetError(reason) -> Error(EtsError(reason))
  }
}

/// Reset metric to a value
pub fn reset_metric(
  account_id: String,
  metric_name: String,
  reset_value: Float,
) -> Result(Nil, StoreError) {
  case reset_metric_ffi(account_id, metric_name, reset_value) {
    MetricStoreResetOk -> {
      logging.log(
        logging.Info,
        "[MetricStore] ✅ Reset "
          <> metric_name
          <> " to "
          <> float.to_string(reset_value),
      )
      Ok(Nil)
    }
    MetricStoreResetError(reason) -> Error(EtsError(reason))
  }
}

/// Clean up storage for an account
pub fn cleanup_store(account_id: String) -> Result(Nil, StoreError) {
  case cleanup_store_ffi(account_id) {
    MetricStoreCleanupOk -> {
      logging.log(
        logging.Info,
        "[MetricStore] ✅ Cleaned up store for: " <> account_id,
      )
      Ok(Nil)
    }
    MetricStoreCleanupError(reason) -> Error(EtsError(reason))
  }
}

// ---- HELPER FUNCTIONS ----

fn operation_to_atom(operation: Operation) -> atom.Atom {
  case operation {
    Sum -> atom.create("sum")
    Average -> atom.create("average")
    Min -> atom.create("min")
    Max -> atom.create("max")
    Count -> atom.create("count")
    Last -> atom.create("last")
  }
}
