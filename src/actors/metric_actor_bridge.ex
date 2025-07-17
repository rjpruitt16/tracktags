defmodule MetricActorBridge do
  @moduledoc """
  Bridge between Elixir supervisor and Gleam MetricActor.
  Converts simple Elixir arguments to complex Gleam state structures.
  Now supports cleanup_after_seconds parameter.
  """

  def start_link(account_id, metric_name, tick_type, supabase_tick_type, initial_value, tags_json, operation, cleanup_after_seconds, metric_type, metadata)
      when is_binary(account_id) and is_binary(metric_name) and is_binary(tick_type) and
             is_number(initial_value) and is_binary(tags_json) and is_binary(operation) and
             is_integer(cleanup_after_seconds) do
    # Call the Gleam start_link function with all the arguments including cleanup
    case :actors@metric_actor.start_link(
           account_id,
           metric_name,
           tick_type,
           supabase_tick_type,
           initial_value,
           tags_json,
           operation,
           cleanup_after_seconds,
           metric_type,
           metadata
         ) do
      {:ok, {:subject, pid, _ref}} ->
        # Register the process with a predictable name for registry pattern
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
