defmodule :sse_client do
  use GenServer
  require Logger

  def start_link(url, gleam_subject) do
    GenServer.start_link(__MODULE__, {url, gleam_subject}, name: __MODULE__)
  end

  def init({url, gleam_subject}) do
    Logger.info("[SSE Elixir] Starting for #{url}")

    # Extract the PID from the Gleam subject tuple
    {:subject, pid, _ref} = gleam_subject

    send(self(), {:connect, pid})
    {:ok, %{url: url, gleam_pid: pid}}
  end

  def handle_info({:connect, pid}, state) do
    Logger.info("[SSE Elixir] Connecting to #{state.url}")

    # Send to the PID, not the subject
    send(pid, {:sse_connected})

    # Send a test tick
    :timer.sleep(1000)
    send(pid, {:sse_chunk, "event: tick_1s\ndata: {\"timestamp\":\"2025-06-15T10:30:00Z\"}\n\n"})

    {:noreply, state}
  end
end
