defmodule TrackTagsApplication do
  use Application
  require Logger

  def start(url) do
    Logger.info("[TrackTagsApplication] Starting application with SSE URL: #{url}")

    children = [
      # Start the Clock Actor with SSE URL configuration
      {ClockActor, [url: url]}
    ]

    # One-for-one strategy - if ClockActor crashes, only restart that process
    # The ClockActor itself handles SSE reconnection internally
    opts = [strategy: :one_for_one, name: TrackTagsApplication.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("[TrackTagsApplication] Supervisor started with PID: #{inspect(pid)}")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("[TrackTagsApplication] Failed to start supervisor: #{inspect(reason)}")
        error
    end
  end
end
