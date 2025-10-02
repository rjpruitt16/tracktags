defmodule Tracktags.Utils.Cachex do
  def start_link(name, _opts) do
    IO.puts("Wrapper received name: #{inspect(name)}, is_atom: #{inspect(is_atom(name))}")

    # Convert string to atom if needed
    cache_name =
      if is_binary(name) do
        String.to_atom(name)
      else
        name
      end

    IO.puts("Calling Cachex.start_link with: #{inspect(cache_name)}")

    case Cachex.start_link(cache_name) do
      {:ok, pid} ->
        IO.puts("✓ Cachex started")
        {:cachex_start_ok, pid}

      {:error, {:already_started, pid}} ->
        {:cachex_start_ok, pid}

      {:error, reason} ->
        IO.puts("✗ Cachex failed: #{inspect(reason)}")
        {:cachex_start_error, inspect(reason)}
    end
  end

  def get(cache, key) do
    cache_name = if is_binary(cache), do: String.to_atom(cache), else: cache

    case Cachex.get(cache_name, key) do
      {:ok, value} -> {:cachex_get_ok, value}
      {:error, reason} -> {:cachex_get_error, inspect(reason)}
    end
  end

  def put(cache, key, value) do
    cache_name = if is_binary(cache), do: String.to_atom(cache), else: cache

    case Cachex.put(cache_name, key, value) do
      {:ok, result} -> {:cachex_put_ok, result}
      {:error, reason} -> {:cachex_put_error, inspect(reason)}
    end
  end
end
