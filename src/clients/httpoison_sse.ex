defmodule HttpoisonSse do
  @moduledoc """
  HTTPoison SSE streaming wrapper for Gleam interop.
  """
  require Logger

  def start_sse(url, _parent_pid) when is_binary(url) do
    Logger.debug("[HttpoisonSse] Starting SSE connection to: #{url}")

    pid = spawn_link(fn -> sse_stream_loop(url) end)

    {:sse_started, pid}
  end

  defp sse_stream_loop(url) do
    Logger.info("[HttpoisonSse] Starting HTTPoison stream to: #{url}")

    headers = [
      {"Accept", "text/event-stream"},
      {"Connection", "keep-alive"},
      {"Cache-Control", "no-cache"}
    ]

    options = [
      stream_to: self(),
      async: :once,
      recv_timeout: 60_000,
      timeout: 60_000
    ]

    Logger.info("[HttpoisonSse] Making request with headers: #{inspect(headers)}")

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.AsyncResponse{id: ref}} ->
        Logger.info("[HttpoisonSse] Got AsyncResponse with ref: #{inspect(ref)}")
        sse_receive_loop(ref, "")

      {:error, reason} ->
        Logger.error("[HttpoisonSse] Connection failed: #{inspect(reason)}")
    end
  end

  defp sse_receive_loop(ref, buffer) do
    Logger.debug("[HttpoisonSse] Waiting for messages... Buffer size: #{byte_size(buffer)}")

    receive do
      %HTTPoison.AsyncStatus{id: ^ref, code: code} ->
        Logger.info("[HttpoisonSse] Received AsyncStatus: #{code}")
        if code == 200 do
          HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
          sse_receive_loop(ref, buffer)
        end

      %HTTPoison.AsyncHeaders{id: ^ref, headers: headers} ->
        Logger.info("[HttpoisonSse] Received headers: #{inspect(headers)}")
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        sse_receive_loop(ref, buffer)

      %HTTPoison.AsyncChunk{id: ^ref, chunk: chunk} ->
        Logger.info("[HttpoisonSse] 🎯 Received chunk (#{byte_size(chunk)} bytes): #{inspect(String.slice(chunk, 0..100))}...")

        new_buffer = buffer <> chunk
        {events, remaining_buffer} = extract_complete_events(new_buffer)

        Logger.info("[HttpoisonSse] Extracted #{length(events)} complete events")

        Enum.each(events, fn event ->
          case parse_sse_event(event) do
            {:tick_event, tick_name, timestamp} ->
              :actors@clock_actor.process_tick_event(tick_name, timestamp)
            {:parse_error, reason} ->
              Logger.error("[HttpoisonSse] Failed to parse SSE event: #{reason}")
          end
        end)

        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        sse_receive_loop(ref, remaining_buffer)

      %HTTPoison.AsyncEnd{id: ^ref} ->
        Logger.info("[HttpoisonSse] Stream ended")

      %HTTPoison.Error{id: ^ref, reason: reason} ->
        Logger.error("[HttpoisonSse] Stream error: #{inspect(reason)}")

      other ->
        Logger.warning("[HttpoisonSse] Unexpected message: #{inspect(other)}")
        sse_receive_loop(ref, buffer)
    after
      5_000 ->
        Logger.debug("[HttpoisonSse] No message received in 5 seconds, still waiting...")
        sse_receive_loop(ref, buffer)
    end
  end

  @doc """
  Parse SSE event data to extract tick information.
  Returns {:tick_event, tick_name, timestamp} or {:parse_error, reason}
  """
  def parse_sse_event(event_data) when is_binary(event_data) do
    lines = String.split(event_data, "\n")

    event_type = find_event_type(lines)
    data_json = find_data_json(lines)

    case {event_type, data_json} do
      {nil, _} ->
        {:parse_error, "No event type found"}

      {_, nil} ->
        {:parse_error, "No data found"}

      {_, json_str} ->
        case Jason.decode(json_str) do
          {:ok, %{"tick" => tick_name, "timestamp" => timestamp}} ->
            {:tick_event, tick_name, timestamp}

          {:ok, _} ->
            {:parse_error, "Missing tick or timestamp in data"}

          {:error, _} ->
            {:parse_error, "Invalid JSON in data"}
        end
    end
  end

  defp find_event_type(lines) do
    Enum.find_value(lines, fn line ->
      case String.split(line, ": ", parts: 2) do
        ["event", type] -> String.trim(type)
        _ -> nil
      end
    end)
  end

  defp find_data_json(lines) do
    Enum.find_value(lines, fn line ->
      case String.split(line, ": ", parts: 2) do
        ["data", json] -> String.trim(json)
        _ -> nil
      end
    end)
  end

  @doc """
  Extract complete SSE events from a buffer.
  Returns {complete_events, remaining_buffer}
  """
  def extract_complete_events(buffer) when is_binary(buffer) do
    Logger.debug("[HttpoisonSse] Extracting events from buffer: #{inspect(buffer)}")
    case String.split(buffer, "\n\n") do
      [incomplete] ->
        {[], incomplete}

      parts when length(parts) > 1 ->
        {complete, [remaining]} = Enum.split(parts, -1)
        filtered = Enum.filter(complete, &(String.trim(&1) != ""))
        Logger.debug("[HttpoisonSse] Found #{length(filtered)} complete events")
        {filtered, remaining || ""}

      [] ->
        {[], ""}
    end
  end
end

