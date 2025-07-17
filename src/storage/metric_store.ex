defmodule Storage.MetricStore do
  @moduledoc """
  High-performance ETS-based metric storage with Gleam interop.
  Handles all the complex ETS operations and returns simple atoms for Gleam.
  """
  
  # ---- STORE MANAGEMENT ----
  
  def init_store(account_id) when is_binary(account_id) do
    table_name = String.to_atom("metrics_#{account_id}")
    
    try do
      # Create ETS table with proper options
      :ets.new(table_name, [:set, :public, :named_table])
      :metric_store_init_ok
    rescue
      error ->
        {:metric_store_init_error, inspect(error)}
    end
  end
  
  def cleanup_store(account_id) when is_binary(account_id) do
    table_name = String.to_atom("metrics_#{account_id}")
    
    try do
      :ets.delete(table_name)
      :metric_store_cleanup_ok
    rescue
      error ->
        {:metric_store_cleanup_error, inspect(error)}
    end
  end
  
  # ---- METRIC OPERATIONS ----
  
  def create_metric(account_id, metric_name, operation_atom, initial_value)
      when is_binary(account_id) and is_binary(metric_name) and 
           is_atom(operation_atom) and is_number(initial_value) do
    
    table_name = String.to_atom("metrics_#{account_id}")
    timestamp = System.system_time(:millisecond)  # More precision for metrics
    
    entry = %{
      operation: operation_atom,
      current_value: initial_value * 1.0,  # Ensure float
      sample_count: 0,
      last_updated: timestamp
    }
    
    try do
      :ets.insert(table_name, {metric_name, entry})
      :metric_store_create_ok
    rescue
      error ->
        {:metric_store_create_error, inspect(error)}
    end
  end
  
  def add_value(account_id, metric_name, value)
      when is_binary(account_id) and is_binary(metric_name) and is_number(value) do
    
    table_name = String.to_atom("metrics_#{account_id}")
    
    try do
      case :ets.lookup(table_name, metric_name) do
        [{^metric_name, entry}] ->
          new_entry = apply_operation(entry, value * 1.0)
          :ets.insert(table_name, {metric_name, new_entry})
          {:metric_store_add_ok, new_entry.current_value}
        
        [] ->
          {:metric_store_add_error, "metric_not_found"}
      end
    rescue
      error ->
        {:metric_store_add_error, inspect(error)}
    end
  end
  
  def get_value(account_id, metric_name)
      when is_binary(account_id) and is_binary(metric_name) do
    
    table_name = String.to_atom("metrics_#{account_id}")
    
    try do
      case :ets.lookup(table_name, metric_name) do
        [{^metric_name, entry}] ->
          {:metric_store_get_ok, entry.current_value}
        
        [] ->
          {:metric_store_get_error, "metric_not_found"}
      end
    rescue
      error ->
        {:metric_store_get_error, inspect(error)}
    end
  end
  
  def reset_metric(account_id, metric_name, reset_value)
      when is_binary(account_id) and is_binary(metric_name) and is_number(reset_value) do
    
    table_name = String.to_atom("metrics_#{account_id}")
    timestamp = System.system_time(:second)
    
    try do
      case :ets.lookup(table_name, metric_name) do
        [{^metric_name, entry}] ->
          reset_entry = %{
            operation: entry.operation,
            current_value: reset_value * 1.0,
            sample_count: 1,
            last_updated: System.system_time(:millisecond)
          }
          :ets.insert(table_name, {metric_name, reset_entry})
          :metric_store_reset_ok
        
        [] ->
          {:metric_store_reset_error, "metric_not_found"}
      end
    rescue
      error ->
        {:metric_store_reset_error, inspect(error)}
    end
  end
  
  # ---- HELPER FUNCTIONS ----
  
  defp apply_operation(entry, new_value) do
    new_count = entry.sample_count + 1
    
    new_current_value = case entry.operation do
      :sum ->
        entry.current_value + new_value
      
      :average ->
        # Incremental average
        diff = new_value - entry.current_value
        entry.current_value + (diff / new_count)
      
      :min ->
        min(entry.current_value, new_value)
      
      :max ->
        max(entry.current_value, new_value)
      
      :count ->
        new_count * 1.0  # Convert to float
      
      :last ->
        new_value
    end
    
    %{
      operation: entry.operation,
      current_value: new_current_value,
      sample_count: new_count,
      last_updated: System.system_time(:millisecond)
    }
  end

  def delete_metric(account_id, metric_name) do
    table_name = String.to_atom("metrics_#{account_id}")
    try do
      :ets.delete(table_name, metric_name)
      :metric_store_delete_ok
    rescue
      error -> {:metric_store_delete_error, inspect(error)}
    end
  end
  
  def scan_all_keys(account_id) when is_binary(account_id) do
    table_name = String.to_atom("metrics_#{account_id}")
    
    try do
      keys = :ets.tab2list(table_name) |> Enum.map(fn {key, _value} -> key end)
      {:metric_store_scan_ok, keys}
    rescue
      error ->
        {:metric_store_scan_error, inspect(error)}
    end
  end
end
