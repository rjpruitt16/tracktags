defmodule SSESupervisor do
  use GenServer
  require Logger

  # Public API
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  # GenServer callbacks
  def init(state) do
    # Trap exits so we can handle child process crashes
    Process.flag(:trap_exit, true)

    # Start children immediately
    send(self(), :start_children)

    {:ok, Map.put(state, :restart_count, 0)}
  end

  def handle_call("status", _from, state) do
    status =
      if process_alive?(state.handler_pid) and process_alive?(state.streamer_pid) do
        "running"
      else
        "stopped"
      end

    response = %{
      status: status,
      restart_count: Map.get(state, :restart_count, 0),
      handler_alive: process_alive?(state.handler_pid),
      streamer_alive: process_alive?(state.streamer_pid)
    }

    {:reply, response, state}
  end

  def handle_cast("stop", state) do
    Logger.info("[SSE Supervisor] Stopping SSE client")
    stop_children(state)
    {:stop, :normal, state}
  end

  def handle_cast("restart", state) do
    Logger.info("[SSE Supervisor] Restarting SSE client")
    stop_children(state)
    send(self(), :start_children)

    new_restart_count = Map.get(state, :restart_count, 0) + 1
    {:noreply, Map.put(state, :restart_count, new_restart_count)}
  end

  def handle_info(:start_children, state) do
    Logger.info("[SSE Supervisor] Starting SSE client children")

    # Start event handler process
    handler_pid =
      spawn_link(fn ->
        :clients@clockwork_client.event_handler_loop(
          state.event_subject,
          state.on_event,
          state.state_agent
        )
      end)

    # Start HTTP streamer process  
    streamer_pid =
      spawn_link(fn ->
        :clients@clockwork_client.httpoison_streaming_loop(
          state.url,
          state.state_agent
        )
      end)

    Logger.info(
      "[SSE Supervisor] Started handler (#{inspect(handler_pid)}) and streamer (#{inspect(streamer_pid)})"
    )

    new_state =
      state
      |> Map.put(:handler_pid, handler_pid)
      |> Map.put(:streamer_pid, streamer_pid)

    {:noreply, new_state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    # Child process died - handle restart
    cond do
      pid == Map.get(state, :handler_pid) ->
        Logger.warn("[SSE Supervisor] Handler process died: #{inspect(reason)}")
        handle_child_death(state, :handler)

      pid == Map.get(state, :streamer_pid) ->
        Logger.warn("[SSE Supervisor] Streamer process died: #{inspect(reason)}")
        handle_child_death(state, :streamer)

      true ->
        Logger.debug(
          "[SSE Supervisor] Unknown process died: #{inspect(pid)} - #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[SSE Supervisor] Unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp handle_child_death(state, _child_type) do
    # Stop remaining children
    stop_children(state)

    # Exponential backoff for restart
    restart_count = Map.get(state, :restart_count, 0)
    delay = min(30_000, 1000 * round(:math.pow(2, restart_count)))

    Logger.info(
      "[SSE Supervisor] Restarting children in #{delay}ms (attempt #{restart_count + 1})"
    )

    Process.send_after(self(), :start_children, delay)

    new_state =
      state
      |> Map.put(:handler_pid, nil)
      |> Map.put(:streamer_pid, nil)
      |> Map.put(:restart_count, restart_count + 1)

    {:noreply, new_state}
  end

  defp stop_children(state) do
    if process_alive?(Map.get(state, :handler_pid)) do
      Process.exit(state.handler_pid, :kill)
    end

    if process_alive?(Map.get(state, :streamer_pid)) do
      Process.exit(state.streamer_pid, :kill)
    end
  end

  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(_), do: false
end
