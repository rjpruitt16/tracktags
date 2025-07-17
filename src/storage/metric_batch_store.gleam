// src/storage/metric_batch_store.gleam
// Batch store supporting Simple and Precision metric modes
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import storage/metric_store
import types/metric_types.{
  type MetricBatch, type MetricMode, type SimpleOperation,
}
import utils/utils

// ============================================================================
// TYPES
// ============================================================================

pub type BatchStoreError {
  StoreInitError(String)
  BatchNotFound(String)
  EtsError(String)
  NotImplemented(String)
  InvalidOperation(String)
}

// ============================================================================
// PUBLIC API
// ============================================================================

/// Initialize the batch store ETS table
pub fn init_batch_store() -> Result(Nil, BatchStoreError) {
  case metric_store.init_store("metric_batches") {
    Ok(_) -> {
      logging.log(logging.Info, "[MetricBatchStore] ✅ Batch store initialized")
      Ok(Nil)
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[MetricBatchStore] ❌ Failed to init: " <> string.inspect(e),
      )
      Error(StoreInitError("Failed to initialize ETS table"))
    }
  }
}

/// Add or merge a metric batch with mode-aware operations
pub fn add_batch(
  tick_type: String,
  metric_batch: MetricBatch,
) -> Result(Nil, BatchStoreError) {
  let metric_key = create_metric_key(metric_batch)
  let composite_key = tick_type <> "|" <> metric_key

  logging.log(
    logging.Info,
    "[MetricBatchStore] 🔍 BEFORE STORE: "
      <> composite_key
      <> " value: "
      <> float.to_string(metric_batch.aggregated_value),
  )

  // Handle based on metric mode
  let result = case metric_batch.metric_mode {
    metric_types.Simple(operation) -> {
      handle_simple_operation(
        composite_key,
        metric_batch.aggregated_value,
        operation,
      )
    }
    metric_types.Precision(_) -> {
      Error(NotImplemented(
        "Precision metrics available in Pro plan - contact sales for upgrade",
      ))
    }
  }

  // Verify storage worked
  case result {
    Ok(_) -> {
      case metric_store.get_value("metric_batches", composite_key) {
        Ok(stored_value) -> {
          logging.log(
            logging.Info,
            "[MetricBatchStore] ✅ VERIFIED STORED: "
              <> composite_key
              <> " = "
              <> float.to_string(stored_value),
          )
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "[MetricBatchStore] ❌ STORAGE FAILED: "
              <> composite_key
              <> " not found after store",
          )
        }
      }
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[MetricBatchStore] ❌ STORE ERROR: " <> string.inspect(e),
      )
    }
  }

  result
}

/// Flush all batches for a specific tick interval
pub fn flush_interval(tick_type: String) -> List(MetricBatch) {
  logging.log(
    logging.Info,
    "[MetricBatchStore] 🚀 Flushing all batches for: " <> tick_type,
  )

  // DEBUG: See what keys are actually in ETS
  let all_keys = scan_all_ets_keys()
  logging.log(
    logging.Info,
    "[MetricBatchStore] 🔍 ALL ETS KEYS: " <> string.inspect(all_keys),
  )

  // Scan ETS for all keys starting with tick_type
  let filtered_keys = scan_ets_for_tick_type(tick_type)
  logging.log(
    logging.Info,
    "[MetricBatchStore] 🔍 FILTERED KEYS for "
      <> tick_type
      <> ": "
      <> string.inspect(filtered_keys),
  )

  filtered_keys
  |> list.filter_map(fn(composite_key) {
    logging.log(
      logging.Info,
      "[MetricBatchStore] 🔍 Trying to get value for key: " <> composite_key,
    )
    case metric_store.get_value("metric_batches", composite_key) {
      Ok(aggregated_value) -> {
        logging.log(
          logging.Info,
          "[MetricBatchStore] ✅ Found value: "
            <> float.to_string(aggregated_value),
        )
        case parse_composite_key(composite_key, aggregated_value) {
          Ok(metric_batch) -> Ok(metric_batch)
          Error(e) -> {
            logging.log(
              logging.Error,
              "[MetricBatchStore] ❌ Parse error: " <> e,
            )
            Error(Nil)
          }
        }
      }
      Error(e) -> {
        logging.log(
          logging.Error,
          "[MetricBatchStore] ❌ Get value error: " <> string.inspect(e),
        )
        Error(Nil)
      }
    }
  })
}

/// Clear all batches for a specific tick interval (after successful Supabase flush)
pub fn clear_interval(tick_type: String) -> Result(Nil, BatchStoreError) {
  logging.log(
    logging.Info,
    "[MetricBatchStore] 🧹 Clearing all batches for: " <> tick_type,
  )

  // Get all keys for this tick type and delete them
  let keys_to_delete = scan_ets_for_tick_type(tick_type)
  let deletion_results =
    list.map(keys_to_delete, fn(composite_key) {
      metric_store.delete_metric("metric_batches", composite_key)
    })

  // Check if any deletions failed
  case list.any(deletion_results, result.is_error) {
    True -> Error(EtsError("Some deletions failed"))
    False -> {
      logging.log(
        logging.Info,
        "[MetricBatchStore] ✅ Cleared "
          <> int.to_string(list.length(keys_to_delete))
          <> " entries for "
          <> tick_type,
      )
      Ok(Nil)
    }
  }
}

/// Remove all batches for a specific metric (called on metric shutdown)
pub fn remove_metric(
  account_id: String,
  metric_name: String,
) -> Result(Nil, BatchStoreError) {
  logging.log(
    logging.Info,
    "[MetricBatchStore] 🧹 Removing all batches for: "
      <> account_id
      <> "/"
      <> metric_name,
  )

  // Scan all ETS keys and find ones containing this metric
  let all_keys = scan_all_ets_keys()
  let metric_keys =
    list.filter(all_keys, fn(composite_key) {
      string.contains(composite_key, account_id <> "|")
      && string.contains(composite_key, "|" <> metric_name <> "|")
    })

  // Delete all matching keys
  let deletion_results =
    list.map(metric_keys, fn(composite_key) {
      metric_store.delete_metric("metric_batches", composite_key)
    })

  case list.any(deletion_results, result.is_error) {
    True -> Error(EtsError("Some metric deletions failed"))
    False -> Ok(Nil)
  }
}

// ============================================================================
// ETS SCANNING HELPERS
// ============================================================================

/// Scan ETS for all keys starting with a specific tick type
fn scan_ets_for_tick_type(tick_type: String) -> List(String) {
  // Get all keys from ETS and filter by prefix
  scan_all_ets_keys()
  |> list.filter(fn(key) { string.starts_with(key, tick_type <> "|") })
}

/// Scan all keys in the metric_batches ETS table
fn scan_all_ets_keys() -> List(String) {
  metric_store.scan_all_keys("metric_batches")
}

/// Parse a composite key back into a MetricBatch
fn parse_composite_key(
  composite_key: String,
  aggregated_value: Float,
) -> Result(MetricBatch, String) {
  // Parse: "tick_15s|business_id|client_id|metric_name|metric_type"
  case string.split(composite_key, "|") {
    [tick_type, business_id, client_id_part, metric_name, metric_type] -> {
      let client_id = case client_id_part {
        "business_level" -> None
        actual_client_id -> Some(actual_client_id)
      }

      Ok(metric_types.MetricBatch(
        business_id: business_id,
        client_id: client_id,
        metric_name: metric_name,
        aggregated_value: aggregated_value,
        operation_count: 1,
        // We don't track this separately for now
        metric_type: metric_type,
        metric_mode: metric_types.Simple(metric_types.Sum),
        // Default mode
        window_start: utils.current_timestamp(),
        window_end: utils.current_timestamp(),
        flush_interval: tick_type,
        scope: "business",
        adapters: None,
      ))
    }
    _ -> Error("Invalid composite key format: " <> composite_key)
  }
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

/// Handle simple operations using ETS aggregation
fn handle_simple_operation(
  composite_key: String,
  value: Float,
  operation: SimpleOperation,
) -> Result(Nil, BatchStoreError) {
  // Convert SimpleOperation to metric_store operation
  let store_operation = case operation {
    metric_types.Sum -> metric_store.Sum
    metric_types.Min -> metric_store.Min
    metric_types.Max -> metric_store.Max
    metric_types.Count -> metric_store.Count
    metric_types.Average -> {
      // For average, we'll store sum and count separately
      // TODO: Implement proper average calculation with separate sum/count tracking
      metric_store.Sum
      // Fallback to sum for now
    }
  }

  // Try to add to existing metric, create if doesn't exist
  case metric_store.get_value("metric_batches", composite_key) {
    Ok(_) -> {
      // Entry exists, add to it
      case metric_store.add_value("metric_batches", composite_key, value) {
        Ok(_) -> {
          logging.log(
            logging.Debug,
            "[MetricBatchStore] ✅ Added value to existing: " <> composite_key,
          )
          Ok(Nil)
        }
        Error(e) -> Error(EtsError("Failed to add: " <> string.inspect(e)))
      }
    }
    Error(_) -> {
      // Create new entry
      case
        metric_store.create_metric(
          "metric_batches",
          composite_key,
          store_operation,
          value,
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Debug,
            "[MetricBatchStore] ✅ Created new metric: " <> composite_key,
          )
          Ok(Nil)
        }
        Error(e) -> Error(EtsError("Failed to create: " <> string.inspect(e)))
      }
    }
  }
}

/// Create a unique key for a metric batch (without tick_type prefix)
fn create_metric_key(batch: MetricBatch) -> String {
  batch.business_id
  <> "|"
  <> case batch.client_id {
    Some(cid) -> cid
    None -> "business_level"
  }
  <> "|"
  <> batch.metric_name
  <> "|"
  <> batch.metric_type
}
