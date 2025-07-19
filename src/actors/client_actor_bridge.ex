# src/actors/client_actor_bridge.ex
defmodule ClientActorBridge do
  @moduledoc """
  Elixir bridge for starting ClientActor processes from dynamic supervisor.
  Converts simple Elixir arguments to Gleam state structures.
  """
  
def start_link(business_id, client_id) when is_binary(business_id) and is_binary(client_id) do
  case :actors@client_actor.start_link(business_id, client_id) do      
      {:ok, {:subject, pid, _ref}} ->
        {:ok, pid}
      {:error, reason} ->
        {:error, reason}
      other ->
        {:error, {:unexpected_return, other}}
    end
  end
end
