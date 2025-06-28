defmodule ClockActor do
  use GenServer
  require Logger

  @default_url "http://localhost:4000/events"

  # Public API - Called from Gleam via FFI
  def start_link(opts \\ []) do
    url = Keyword.get(opts, :url, @default_url)
    GenServer.start_link(__MODULE__, %{url: url}, name: __MODULE__)
  end

  def subscribe(tick_name, gleam_subject) do
    GenServer.call(__MODULE__, {:subscribe, tick_name, gleam_subject})
  end

  def unsubscribe(tick_name, gleam_subject) do
    GenServer.call(__MODULE__, {:unsubscribe, tick_name, gleam_subject})
  end

  def get_status() do
    GenServer.call(__MODULE__, :get_status)
  end

  # GenServer callbacks
  def init(%{url: url}) do
    Logger.info("[ClockActor] Starting clock actor with SSE from: #{url}")

    # Trap exits for proper supervision
    Process.flag(:trap_exit, true)

    # Initialize ETS table for subscribers
    :ets.new(:tick_subscribers, [:set, :named_table, :public])

    state = %{
      url: url,
      sse_pid: nil,
      restart_count: 0,
      buffer: ""
    }

    # Start SSE connection
    {:ok, state, {:continue, :connect_sse}}
  end

  def handle_continue(:connect_sse, state) do
    Logger.info("[ClockActor] Connecting to SSE stream at: #{state.url}")

    # Start the SSE streaming process
    case start_sse_stream(state.url, self()) do
      {:ok, pid} ->
        Logger.info("[ClockActor] SSE stream started with PID: #{inspect(pid)}")
        {:noreply, %{state | sse_pid: pid}}

      {:error, reason} ->
        Logger.error("[ClockActor] Failed to start SSE stream: #{inspect(reason)}")
        # Retry after 5 seconds
        Process.send_after(self(), :retry_connect, 5000)
        {:noreply, state}
    end
  end

  def handle_call({:subscribe, tick_name, subscriber}, _from, state) do
    Logger.info("[ClockActor] Subscribing to #{tick_name}")

    existing =
      case :ets.lookup(:tick_subscribers, tick_name) do
        [{^tick_name, subs}] -> subs
        [] -> []
      end

    :ets.insert(:tick_subscribers, {tick_name, [subscriber | existing]})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, tick_name, gleam_subject}, _from, state) do
    Logger.info("[ClockActor] Unsubscribing from #{tick_name}")

    existing =
      case :ets.lookup(:tick_subscribers, tick_name) do
        [{^tick_name, subs}] -> subs
        [] -> []
      end

    updated_subscribers = List.delete(existing, gleam_subject)
    :ets.insert(:tick_subscribers, {tick_name, updated_subscribers})

    Logger.info("[ClockActor] Now #{length(updated_subscribers)} subscribers for #{tick_name}")
    {:reply, :ok, state}
  end

  def handle_call(:get_status, _from, state) do
    all_subscribers = :ets.tab2list(:tick_subscribers)

    status = %{
      status: "running",
      restart_count: state.restart_count,
      subscribers: all_subscribers,
      sse_status:
        if(state.sse_pid && Process.alive?(state.sse_pid), do: "connected", else: "disconnected"),
      url: state.url
    }

    {:reply, status, state}
  end

  # Handle SSE events
  def handle_info({:sse_event, event_data}, state) do
    Logger.debug("[ClockActor] Received SSE event: #{inspect(event_data)}")

    case parse_sse_event(event_data) do
      {:ok, tick_name, timestamp} ->
        broadcast_tick(tick_name, timestamp)

      {:error, reason} ->
        Logger.warn("[ClockActor] Failed to parse SSE event: #{reason}")
    end

    {:noreply, state}
  end

  # Handle SSE connection closed
  def handle_info({:sse_closed, reason}, state) do
    Logger.warn("[ClockActor] SSE connection closed: #{inspect(reason)}")
    Process.send_after(self(), :retry_connect, 5000)
    {:noreply, %{state | sse_pid: nil}}
  end

  # Retry connection
  def handle_info(:retry_connect, state) do
    Logger.info("[ClockActor] Retrying SSE connection...")
    {:noreply, state, {:continue, :connect_sse}}
  end

  # Handle process exits
  def handle_info({:EXIT, pid, reason}, state) when pid == state.sse_pid do
    Logger.warn("[ClockActor] SSE process died: #{inspect(reason)}")
    Process.send_after(self(), :retry_connect, 5000)
    {:noreply, %{state | sse_pid: nil, restart_count: state.restart_count + 1}}
  end

  def handle_info(msg, state) do
    Logger.debug("[ClockActor] Unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, state) do
    Logger.info("[ClockActor] Terminating: #{inspect(reason)}")

    # Kill SSE process if running
    if state.sse_pid && Process.alive?(state.sse_pid) do
      Process.exit(state.sse_pid, :shutdown)
    end

    # Clean up ETS table
    :ets.delete(:tick_subscribers)

    :ok
  end

  # Private functions
  defp start_sse_stream(url, parent_pid) do
    pid = spawn_link(fn -> sse_stream_loop(url, parent_pid) end)
    {:ok, pid}
  end

  defp sse_stream_loop(url, parent_pid) do
    Logger.info("[ClockActor SSE] Starting HTTPoison stream to: #{url}")

    options = [
      stream_to: self(),
      async: :once,
      recv_timeout: 60_000,
      timeout: 60_000
    ]

    headers = [
      {"Accept", "text/event-stream"},
      {"Connection", "keep-alive"},
      {"Cache-Control", "no-cache"}
    ]

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.AsyncResponse{id: ref}} ->
        Logger.info("[ClockActor SSE] Connected successfully")
        sse_receive_loop(ref, parent_pid, "")

      {:error, reason} ->
        Logger.error("[ClockActor SSE] Connection failed: #{inspect(reason)}")
        send(parent_pid, {:sse_closed, reason})
    end
  end

  defp sse_receive_loop(ref, parent_pid, buffer) do
    receive do
      %HTTPoison.AsyncStatus{id: ^ref, code: 200} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        sse_receive_loop(ref, parent_pid, buffer)

      %HTTPoison.AsyncStatus{id: ^ref, code: code} ->
        Logger.error("[ClockActor SSE] HTTP error: #{code}")
        send(parent_pid, {:sse_closed, {:http_error, code}})

      %HTTPoison.AsyncHeaders{id: ^ref, headers: _headers} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        sse_receive_loop(ref, parent_pid, buffer)

      %HTTPoison.AsyncChunk{id: ^ref, chunk: chunk} ->
        new_buffer = buffer <> chunk
        {events, remaining_buffer} = extract_complete_events(new_buffer)

        Enum.each(events, fn event ->
          send(parent_pid, {:sse_event, event})
        end)

        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        sse_receive_loop(ref, parent_pid, remaining_buffer)

      %HTTPoison.AsyncEnd{id: ^ref} ->
        Logger.info("[ClockActor SSE] Stream ended")
        send(parent_pid, {:sse_closed, :stream_ended})

      %HTTPoison.Error{id: ^ref, reason: reason} ->
        Logger.error("[ClockActor SSE] Stream error: #{inspect(reason)}")
        send(parent_pid, {:sse_closed, {:error, reason}})

      other ->
        Logger.warn("[ClockActor SSE] Unexpected message: #{inspect(other)}")
        sse_receive_loop(ref, parent_pid, buffer)
    after
      65_000 ->
        Logger.warn("[ClockActor SSE] Stream timeout")
        send(parent_pid, {:sse_closed, :timeout})
    end
  end

  defp extract_complete_events(buffer) do
    case String.split(buffer, "\n\n") do
      [incomplete] ->
        {[], incomplete}

      parts when length(parts) > 1 ->
        {complete_events, [remaining]} = Enum.split(parts, -1)
        complete_events = Enum.filter(complete_events, fn event -> String.trim(event) != "" end)
        {complete_events, remaining || ""}

      [] ->
        {[], ""}
    end
  end

  defp parse_sse_event(event_data) do
    lines = String.split(event_data, "\n")

    event_name =
      lines
      |> Enum.find_value(fn line ->
        case String.split(line, ": ", parts: 2) do
          ["event", name] -> String.trim(name)
          _ -> nil
        end
      end)

    data_json =
      lines
      |> Enum.find_value(fn line ->
        case String.split(line, ": ", parts: 2) do
          ["data", json] -> String.trim(json)
          _ -> nil
        end
      end)

    with true <- event_name != nil && data_json != nil,
         {:ok, %{"timestamp" => timestamp, "tick" => tick}} <- Jason.decode(data_json) do
      {:ok, tick, timestamp}
    else
      _ -> {:error, "Failed to parse SSE event"}
    end
  end

  defp broadcast_tick(tick_name, timestamp) do
    subscribers =
      case :ets.lookup(:tick_subscribers, tick_name) do
        [{^tick_name, subs}] -> subs
        [] -> []
      end

    # Also check for "all" subscribers
    all_subscribers =
      case :ets.lookup(:tick_subscribers, "all") do
        [{"all", subs}] -> subs
        [] -> []
      end

    all_to_notify = Enum.uniq(subscribers ++ all_subscribers)

    Logger.debug("[ClockActor] Broadcasting #{tick_name} to #{length(all_to_notify)} subscribers")

    Enum.each(all_to_notify, fn subscriber ->
      try do
        :actors@metric_actor.send_tick(subscriber, tick_name, timestamp)
      rescue
        e ->
          Logger.error("[ClockActor] Failed to send tick to subscriber: #{inspect(e)}")
      end
    end)
  end
end
