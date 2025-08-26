# src/actors/customer_actor_bridge.ex
defmodule CustomerActorBridge do
  @moduledoc """
  Elixir bridge for starting CustomerActor processes from dynamic supervisor.
  Converts simple Elixir arguments to Gleam state structures.
  """

  def start_link(business_id, customer_id)
      when is_binary(business_id) and is_binary(customer_id) do
    case :actors@customer_actor.start_link(business_id, customer_id) do
      {:ok, {:subject, pid, _ref}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_return, other}}
    end
  end
end
