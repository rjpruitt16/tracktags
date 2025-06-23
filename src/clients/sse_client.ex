defmodule :sse_client do
  @moduledoc """
  Minimal HTTPoison SSE streamer that calls back to Gleam
  """
  require Logger

  def start_stream(url, gleam_subject) do
    Logger.info("[SSE Elixir] 🚀 Starting SSE stream for: #{url}")
    Logger.info("[SSE Elixir] 📨 Gleam subject: #{inspect(gleam_subject)}")

    case spawn_link(fn -> stream_sse(url, gleam_subject) end) do
      pid when is_pid(pid) ->
        Logger.info("[SSE Elixir] ✅ SSE stream process started with PID: #{inspect(pid)}")
        {:ok, pid}

      error ->
        Logger.error("[SSE Elixir] ❌ Failed to start SSE stream process: #{inspect(error)}")
        {:error, "Failed to spawn SSE process"}
    end
  end

  defp stream_sse(url, gleam_subject) do
    Logger.info("[SSE Elixir] 🌐 Preparing HTTP request to: #{url}")

    options = [
      stream_to: self(),
      async: :once,
      recv_timeout: 30_000,
      timeout: 30_000
    ]

    headers = [
      {"Accept", "text/event-stream"},
      {"Connection", "keep-alive"},
      {"Cache-Control", "no-cache"}
    ]

    Logger.info("[SSE Elixir] 📋 Request options: #{inspect(options)}")
    Logger.info("[SSE Elixir] 📋 Request headers: #{inspect(headers)}")

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.AsyncResponse{id: ref}} ->
        Logger.info("[SSE Elixir] ✅ HTTP request initiated successfully, ref: #{inspect(ref)}")
        stream_loop(ref, gleam_subject, "")

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("[SSE Elixir] ❌ HTTPoison.get failed: #{inspect(reason)}")
        {:error, "HTTPoison failed: #{inspect(reason)}"}

      other ->
        Logger.error("[SSE Elixir] ❌ Unexpected HTTPoison response: #{inspect(other)}")
        {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  defp stream_loop(ref, gleam_subject, buffer) do
    Logger.debug(
      "[SSE Elixir] 🔄 Stream loop waiting for message, buffer size: #{byte_size(buffer)}"
    )

    receive do
      %HTTPoison.AsyncStatus{id: ^ref, code: 200} ->
        Logger.info("[SSE Elixir] ✅ HTTP 200 OK received - requesting next")
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        stream_loop(ref, gleam_subject, buffer)

      %HTTPoison.AsyncStatus{id: ^ref, code: code} ->
        Logger.error("[SSE Elixir] ❌ HTTP error status: #{code}")
        {:error, "HTTP #{code}"}

      %HTTPoison.AsyncHeaders{id: ^ref, headers: headers} ->
        Logger.info("[SSE Elixir] 📋 Headers received: #{inspect(headers)}")

        # Check content type
        content_type =
          headers
          |> Enum.find(fn {key, _} -> String.downcase(key) == "content-type" end)
          |> case do
            {_, type} -> type
            nil -> "unknown"
          end

        Logger.info("[SSE Elixir] 📋 Content-Type: #{content_type}")

        # IMPORTANT: Request the first chunk after headers
        Logger.info("[SSE Elixir] 🔄 Requesting first data chunk...")
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        stream_loop(ref, gleam_subject, buffer)

      %HTTPoison.AsyncChunk{id: ^ref, chunk: chunk} ->
        Logger.info("[SSE Elixir] 📦 Chunk received: #{byte_size(chunk)} bytes")
        Logger.debug("[SSE Elixir] 📦 Chunk content: #{inspect(String.slice(chunk, 0, 100))}")

        new_buffer = buffer <> chunk
        {events, remaining_buffer} = extract_complete_events(new_buffer)

        Logger.info("[SSE Elixir] ✅ Extracted #{length(events)} complete events")

        Enum.each(events, fn event ->
          Logger.info("[SSE Elixir] 📤 Sending event to Gleam: #{String.slice(event, 0, 50)}...")

          # First, let's check if the module exists
          module_atom = String.to_atom("clients@clockwork_client")
          Logger.info("[SSE Elixir] 🔍 Module atom: #{inspect(module_atom)}")

          case Code.ensure_loaded(module_atom) do
            {:module, ^module_atom} ->
              Logger.info("[SSE Elixir] ✅ Module loaded successfully")

              # Check if function exists
              if function_exported?(module_atom, :handle_sse_chunk, 2) do
                Logger.info("[SSE Elixir] ✅ Function handle_sse_chunk/2 exists")

                try do
                  result = apply(module_atom, :handle_sse_chunk, [gleam_subject, event])
                  Logger.info("[SSE Elixir] ✅ Function call successful: #{inspect(result)}")
                rescue
                  error ->
                    Logger.error("[SSE Elixir] ❌ Function call failed: #{inspect(error)}")

                    Logger.error(
                      "[SSE Elixir] ❌ Error details: #{Exception.format(:error, error, __STACKTRACE__)}"
                    )
                end
              else
                Logger.error("[SSE Elixir] ❌ Function handle_sse_chunk/2 does not exist")

                Logger.info(
                  "[SSE Elixir] 📋 Available functions: #{inspect(module_atom.__info__(:functions))}"
                )
              end

            {:error, reason} ->
              Logger.error("[SSE Elixir] ❌ Module failed to load: #{inspect(reason)}")
              Logger.info("[SSE Elixir] 📋 Checking if module file exists...")

              # List all loaded modules with 'client' in the name
              loaded_modules =
                :code.all_loaded()
                |> Enum.filter(fn {mod, _} ->
                  mod_str = Atom.to_string(mod)
                  String.contains?(mod_str, "client")
                end)
                |> Enum.map(fn {mod, _} -> mod end)

              Logger.info("[SSE Elixir] 📋 Modules with 'client': #{inspect(loaded_modules)}")
          end
        end)

        # IMPORTANT: Request the next chunk
        Logger.info("[SSE Elixir] 🔄 Requesting next chunk...")
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: ref})
        stream_loop(ref, gleam_subject, remaining_buffer)

      %HTTPoison.AsyncEnd{id: ^ref} ->
        Logger.info("[SSE Elixir] ✅ Stream ended normally")
        :stream_ended

      %HTTPoison.Error{id: ^ref, reason: reason} ->
        Logger.error("[SSE Elixir] ❌ Stream error: #{inspect(reason)}")
        {:error, "Stream error: #{inspect(reason)}"}

      other ->
        Logger.warn("[SSE Elixir] ⚠️ Unexpected message: #{inspect(other)}")
        stream_loop(ref, gleam_subject, buffer)
    after
      35_000 ->
        Logger.warn("[SSE Elixir] ⏰ Stream timeout after 35 seconds")
        {:error, "Stream timeout"}
    end
  end

  defp extract_complete_events(buffer) do
    Logger.debug("[SSE Elixir] 🔍 Extracting events from buffer: #{byte_size(buffer)} bytes")

    case String.split(buffer, "\n\n") do
      [incomplete] ->
        Logger.debug("[SSE Elixir] ⏳ No complete events found, keeping buffer")
        {[], incomplete}

      parts when length(parts) > 1 ->
        # All parts except the last are complete events
        # The last part might be incomplete
        {complete_events, [remaining]} = Enum.split(parts, -1)

        # Filter out empty events
        complete_events = Enum.filter(complete_events, fn event -> String.trim(event) != "" end)

        Logger.debug("[SSE Elixir] ✅ Found #{length(complete_events)} complete events")
        {complete_events, remaining || ""}

      [] ->
        Logger.debug("[SSE Elixir] ⚪ Empty buffer")
        {[], ""}
    end
  end
end
