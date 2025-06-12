# File: lib/tracktags/sse_client.ex
defmodule :sse_client do
  use GenServer
  require Logger

  # This matches what Gleam is calling: start_link(url, handler_pid)
  def start_link(url, handler_pid) do
    GenServer.start_link(__MODULE__, {url, handler_pid})
  end

  def init({url, handler_pid}) do
    send(self(), {:connect, url, handler_pid})
    {:ok, %{conn: nil, url: url, handler_pid: handler_pid, buffer: "", ref: nil}}
  end

  def handle_info({:connect, url, handler_pid}, state) do
    uri = URI.parse(url)
    port = uri.port || 80
    host = uri.host || "localhost"
    path = uri.path || "/event"

    Logger.info("Connecting to SSE at #{url}")

    {:ok, conn} = Mint.HTTP.connect(:http, host, port)

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "GET",
        path,
        [
          {"accept", "text/event-stream"},
          {"connection", "keep-alive"}
        ],
        nil
      )

    {:noreply, %{state | conn: conn, ref: ref}}
  end

  def handle_info(message, %{conn: conn, buffer: buffer, handler_pid: handler_pid} = state) do
    case Mint.HTTP.stream(conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        new_buffer = handle_responses(responses, buffer, handler_pid)
        {:noreply, %{state | conn: conn, buffer: new_buffer}}

      {:error, conn, error, _responses} ->
        Logger.error("SSE connection error: #{inspect(error)}")
        # Reconnect after a delay
        Process.send_after(self(), {:connect, state.url, handler_pid}, 5000)
        {:noreply, %{state | conn: conn}}
    end
  end

  defp handle_responses(responses, buffer, handler_pid) do
    Enum.reduce(responses, buffer, fn
      {:data, _ref, data}, acc ->
        acc = acc <> data
        parse_sse(acc, handler_pid)

      {:status, _ref, status}, acc ->
        Logger.info("SSE status: #{status}")
        acc

      {:headers, _ref, headers}, acc ->
        Logger.debug("SSE headers: #{inspect(headers)}")
        acc

      _, acc ->
        acc
    end)
  end

  defp parse_sse(buffer, handler_pid) do
    case String.split(buffer, "\n\n", parts: 2) do
      [event, rest] ->
        # Send event to handler
        if event != "" do
          send(handler_pid, {"sse_event", event})
          Logger.info("Sent SSE event to handler: #{String.slice(event, 0, 50)}...")
        end

        # Continue parsing rest
        parse_sse(rest, handler_pid)

      [incomplete] ->
        # Return incomplete buffer to accumulate more data
        incomplete
    end
  end
end
