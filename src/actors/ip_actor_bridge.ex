# src/actors/ip_actor_bridge.ex
defmodule IpActorBridge do
  @moduledoc """
  Elixir bridge for starting IpActor processes from dynamic supervisor.
  """

  def start_link(ip_address) when is_binary(ip_address) do
    case :actors@ip_actor.start_link(ip_address) do
      {:ok, {:subject, pid, _ref}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_return, other}}
    end
  end
end
