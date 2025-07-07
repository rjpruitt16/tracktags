defmodule UserActorBridge do
  @moduledoc """
  Elixir bridge for starting UserActor processes from dynamic supervisor.
  Converts simple Elixir arguments to Gleam state structures.
  """

  def start_link(account_id) when is_binary(account_id) do
    # Call the Gleam start_link function with the account_id
    case :actors@user_actor.start_link(account_id) do
      {:ok, {:subject, pid, _ref}} ->
        # Elixir supervisor expects {:ok, pid}, not {:ok, subject}
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_return, other}}
    end
  end
end
