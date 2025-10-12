defmodule SupabaseRealtime do
  @moduledoc """
  Supabase Realtime WebSocket wrapper for multiple tables.
  """
  require Logger

  def start_realtime_connection(realtime_url, anon_key, retry_count) do
    Logger.info("[SupabaseRealtime] Starting connection to: #{realtime_url}")

    pid = spawn_link(fn -> realtime_websocket_loop(realtime_url, anon_key, retry_count) end)

    {:realtime_started, pid}
  end

  defp realtime_websocket_loop(realtime_url, anon_key, retry_count) do
    # Parse WebSocket URL
    uri = URI.parse(realtime_url)
    host = String.to_charlist(uri.host)
    port = uri.port || 443
    path = uri.path || "/realtime/v1/websocket"

    # Add query parameters for Supabase
    query_params = [
      {"apikey", anon_key},
      {"vsn", "1.0.0"}
    ]

    query_string = URI.encode_query(query_params)
    full_path = "#{path}?#{query_string}"

    Logger.info("[SupabaseRealtime] Connecting to #{host}:#{port}#{full_path}")

    # Start gun connection
    case :gun.open(host, port, %{protocols: [:http], transport: :tls}) do
      {:ok, conn_pid} ->
        case :gun.await_up(conn_pid, 5000) do
          {:ok, _protocol} ->
            Logger.info("[SupabaseRealtime] Connection established, upgrading to WebSocket")
            websocket_upgrade(conn_pid, full_path, anon_key, retry_count)

          {:error, reason} ->
            Logger.error("[SupabaseRealtime] Connection failed: #{inspect(reason)}")
            :gun.close(conn_pid)
            # Call realtime_actor instead of supabase_actor
            handle_reconnect(retry_count + 1)
        end

      {:error, reason} ->
        Logger.error("[SupabaseRealtime] Failed to open connection: #{inspect(reason)}")
        handle_reconnect(retry_count + 1)
    end
  end

  defp websocket_upgrade(conn_pid, path, anon_key, retry_count) do
    headers = [
      {"authorization", "Bearer #{anon_key}"},
      {"apikey", anon_key}
    ]

    stream_ref = :gun.ws_upgrade(conn_pid, path, headers)

    receive do
      {:gun_upgrade, ^conn_pid, ^stream_ref, ["websocket"], _headers} ->
        Logger.info("[SupabaseRealtime] ✅ WebSocket upgrade successful")

        # Join channels for multiple tables
        join_channels(conn_pid, stream_ref)

        # Start message loop
        websocket_receive_loop(conn_pid, stream_ref, retry_count)

      {:gun_response, ^conn_pid, ^stream_ref, _fin, status, _headers} ->
        Logger.error("[SupabaseRealtime] WebSocket upgrade failed: #{status}")
        :gun.close(conn_pid)
        handle_reconnect(retry_count + 1)

      {:gun_error, ^conn_pid, ^stream_ref, reason} ->
        Logger.error("[SupabaseRealtime] WebSocket error: #{inspect(reason)}")
        :gun.close(conn_pid)
        handle_reconnect(retry_count + 1)
    after
      10_000 ->
        Logger.error("[SupabaseRealtime] WebSocket upgrade timeout")
        :gun.close(conn_pid)
        handle_reconnect(retry_count + 1)
    end
  end

  defp join_channels(conn_pid, stream_ref) do
    # Join multiple table channels
    tables = [
      {"customers", ["INSERT", "UPDATE", "DELETE"]},
      {"customer_machines", ["INSERT", "UPDATE", "DELETE"]},
      {"provisioning_queue", ["INSERT", "UPDATE"]},
      {"plan_limits", ["UPDATE"]},
      {"metrics", ["INSERT", "UPDATE"]}
    ]

    Enum.each(tables, fn {table, events} ->
      join_message = %{
        "topic" => "realtime:#{table}",
        "event" => "phx_join",
        "payload" => %{
          "config" => %{
            "postgres_changes" =>
              Enum.map(events, fn event ->
                %{
                  "event" => event,
                  "schema" => "public",
                  "table" => table
                }
              end)
          }
        },
        "ref" => table
      }

      json_message = Jason.encode!(join_message)
      Logger.info("[SupabaseRealtime] 📡 Joining #{table} channel")
      :gun.ws_send(conn_pid, stream_ref, {:text, json_message})
    end)
  end

  defp websocket_receive_loop(conn_pid, stream_ref, retry_count) do
    receive do
      {:gun_ws, ^conn_pid, ^stream_ref, {:text, message}} ->
        Logger.debug("[SupabaseRealtime] 📨 Received: #{String.slice(message, 0..200)}...")

        case Jason.decode(message) do
          {:ok, %{"event" => "postgres_changes", "payload" => payload}} ->
            handle_postgres_change(payload)

          {:ok, %{"event" => "phx_reply", "ref" => ref, "payload" => %{"status" => "ok"}}} ->
            Logger.info("[SupabaseRealtime] ✅ Joined channel: #{ref}")

          {:ok, %{"event" => "system", "payload" => %{"status" => "ok"}}} ->
            Logger.debug("[SupabaseRealtime] System event acknowledged")

          {:ok, %{"event" => "presence_state"}} ->
            Logger.debug("[SupabaseRealtime] Presence state received")

          {:ok, %{"event" => "heartbeat"}} ->
            Logger.debug("[SupabaseRealtime] Heartbeat received")

          _ ->
            Logger.debug("[SupabaseRealtime] Unhandled message type")
        end

        websocket_receive_loop(conn_pid, stream_ref, retry_count)

      {:gun_ws, ^conn_pid, ^stream_ref, {:close, code, reason}} ->
        Logger.warning("[SupabaseRealtime] WebSocket closed: #{code} - #{reason}")
        :gun.close(conn_pid)
        handle_reconnect(retry_count + 1)

      {:gun_down, ^conn_pid, _protocol, reason, _killed_streams} ->
        Logger.warning("[SupabaseRealtime] Connection down: #{inspect(reason)}")
        :gun.close(conn_pid)
        handle_reconnect(retry_count + 1)

      {:gun_error, ^conn_pid, reason} ->
        Logger.error("[SupabaseRealtime] Gun error: #{inspect(reason)}")
        :gun.close(conn_pid)
        handle_reconnect(retry_count + 1)

      other ->
        Logger.debug("[SupabaseRealtime] Unexpected message: #{inspect(other)}")
        websocket_receive_loop(conn_pid, stream_ref, retry_count)
    after
      60_000 ->
        # Send heartbeat
        heartbeat = %{
          "topic" => "phoenix",
          "event" => "heartbeat",
          "payload" => %{},
          "ref" => "heartbeat"
        }

        :gun.ws_send(conn_pid, stream_ref, {:text, Jason.encode!(heartbeat)})
        websocket_receive_loop(conn_pid, stream_ref, retry_count)
    end
  end

  defp handle_postgres_change(payload) do
    Logger.info("[SupabaseRealtime] Received postgres change: #{inspect(payload)}")

    case payload do
      %{"data" => %{"type" => event_type, "table" => table, "record" => record}} ->
        Logger.info("[SupabaseRealtime] Attempting to publish: #{table} #{event_type}")

        try do
          :actors@realtime_actor.publish_table_change(
            table,
            String.downcase(event_type),
            Jason.encode!(record),
            Jason.encode!(Map.get(payload["data"], "old_record", %{}))
          )

          # Broadcast via Phoenix PubSub
          Phoenix.PubSub.broadcast(
            LiveTags.PubSub,
            "business:#{record["business_id"]}:metrics",
            {:metric_updated, record}
          )

          Logger.info("[SupabaseRealtime] Successfully published to realtime actor")
        rescue
          e ->
            Logger.error("[SupabaseRealtime] Failed to publish: #{inspect(e)}")
        end

      _ ->
        Logger.debug("[SupabaseRealtime] Unhandled format")
    end
  end

  defp handle_reconnect(retry_count) do
    try do
      :actors@realtime_actor.handle_reconnect(retry_count)
    rescue
      _ ->
        Logger.error("[SupabaseRealtime] Cannot reconnect - realtime actor not available")
    end
  end
end
