defmodule MetricPubSubBridge do
  @moduledoc """
  Simple bridge that subscribes to Phoenix PubSub and forwards tick events
  to a Gleam MetricActor process. Automatically links to the calling process.
  """
  use GenServer

  def start_link(account_id, metric_name, tick_type) when is_binary(account_id) and is_binary(metric_name) and is_binary(tick_type) do
    # This automatically links to the calling process (MetricActor)
    GenServer.start_link(__MODULE__, {account_id, metric_name, tick_type})
  end

  def init({account_id, metric_name, tick_type}) do
    # Subscribe to the specific tick topic
    case Phoenix.PubSub.subscribe(:clock_events, "tick:#{tick_type}") do
      :ok ->
        {:ok, {account_id, metric_name, tick_type}}
      {:error, reason} ->
        {:stop, {:subscribe_failed, reason}}
    end
  end

  # Handle PubSub messages and forward to Gleam actor
  def handle_info(tick_json_string, {account_id, metric_name, tick_type} = state) when is_binary(tick_json_string) do
    # Call the Gleam handler function with specific actor info
    :actors@metric_actor.handle_tick_generic(account_id, metric_name, tick_json_string)
    
    {:noreply, state}
  end

  # Handle any other messages (ignore)
  def handle_info(_other_msg, state) do
    {:noreply, state}
  end
end
