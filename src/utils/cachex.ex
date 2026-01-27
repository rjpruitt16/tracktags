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

  @doc """
  Put a value with TTL (time to live) in milliseconds
  """
  def put_with_ttl(cache, key, value, ttl_ms) do
    cache_name = if is_binary(cache), do: String.to_atom(cache), else: cache

    case Cachex.put(cache_name, key, value, ttl: ttl_ms) do
      {:ok, result} -> {:cachex_put_ok, result}
      {:error, reason} -> {:cachex_put_error, inspect(reason)}
    end
  end

  @doc """
  Check if a key exists in cache
  """
  def exists?(cache, key) do
    cache_name = if is_binary(cache), do: String.to_atom(cache), else: cache

    case Cachex.exists?(cache_name, key) do
      {:ok, exists} -> {:cachex_exists_ok, exists}
      {:error, reason} -> {:cachex_exists_error, inspect(reason)}
    end
  end

  @doc """
  Delete a key from cache
  """
  def delete(cache, key) do
    cache_name = if is_binary(cache), do: String.to_atom(cache), else: cache

    case Cachex.del(cache_name, key) do
      {:ok, result} -> {:cachex_delete_ok, result}
      {:error, reason} -> {:cachex_delete_error, inspect(reason)}
    end
  end

  @doc """
  Fetch a value from cache, or compute it using the fallback MFA if not present.

  This function provides automatic coalescing - if multiple requests hit the same
  key simultaneously while the fallback is executing, only ONE fallback runs and
  all requests share the result.

  The fallback should return {:ok, value} or {:error, reason}.
  On success, the value is cached with the specified TTL.
  """
  def fetch(cache, key, module, function, args, ttl_ms) do
    cache_name = if is_binary(cache), do: String.to_atom(cache), else: cache

    # Convert Gleam module name format to Elixir atom
    module_atom = if is_binary(module), do: String.to_atom(module), else: module
    function_atom = if is_binary(function), do: String.to_atom(function), else: function

    result = Cachex.fetch(cache_name, key, fn ->
      case apply(module_atom, function_atom, args) do
        {:ok, value} ->
          {:commit, {:ok, value}, ttl: ttl_ms}
        {:error, reason} ->
          # Don't cache errors
          {:ignore, {:error, reason}}
      end
    end)

    case result do
      {:ok, value} -> {:cachex_fetch_ok, value}
      {:commit, value} -> {:cachex_fetch_ok, value}
      {:ignore, value} -> {:cachex_fetch_ok, value}
      {:error, reason} -> {:cachex_fetch_error, inspect(reason)}
    end
  end

  @doc """
  Fetch with a function fallback. Works with Gleam closures (0-arity funs).
  The fallback should return {:ok, value} or {:error, reason}.
  Provides automatic coalescing - concurrent requests share one execution.
  """
  def fetch_with_fn(cache, key, fallback_fn, ttl_ms) when is_function(fallback_fn, 0) do
    cache_name = if is_binary(cache), do: String.to_atom(cache), else: cache

    result = Cachex.fetch(cache_name, key, fn ->
      case fallback_fn.() do
        {:ok, value} ->
          {:commit, {:ok, value}, ttl: ttl_ms}
        {:error, reason} ->
          {:ignore, {:error, reason}}
      end
    end)

    case result do
      {:ok, value} -> {:cachex_fetch_ok, value}
      {:commit, value} -> {:cachex_fetch_ok, value}
      {:ignore, value} -> {:cachex_fetch_ok, value}
      {:error, reason} -> {:cachex_fetch_error, inspect(reason)}
    end
  end
end
