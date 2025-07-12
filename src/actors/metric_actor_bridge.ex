defmodule MetricActorBridge do
  @moduledoc """
  Elixir bridge for starting MetricActor processes from dynamic supervisor.
  Converts simple Elixir arguments to complex Gleam state structures.
  """

  def start_link(account_id, metric_name, tick_type, initial_value, tags_json, operation)
      when is_binary(account_id) and is_binary(metric_name) and is_binary(tick_type) and
             is_number(initial_value) and is_binary(tags_json) do
    # Call the Gleam start_link function with all the arguments
    case :actors@metric_actor.start_link(
           account_id,
           metric_name,
           tick_type,
           initial_value,
           tags_json,
           operation
         ) do
      {:ok, {:subject, pid, _ref}} ->
        # Register the process with a predictable name for registry pattern
        registry_name = String.to_atom("metric_#{account_id}_#{metric_name}")
        Process.register(pid, registry_name)

        # Elixir supervisor expects {:ok, pid}, not {:ok, subject}
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_return, other}}
    end
  end
end
