defmodule ClockActor do
  use GenServer
  require Logger

  # Public API - Called from Gleam via FFI
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
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
  def init(_) do
    Logger.info("[ClockActor] Starting clock actor")

    # Trap exits for proper supervision
    Process.flag(:trap_exit, true)

    # Start timers for different tick intervals
    timer_1s = :timer.send_interval(1_000, self(), {:tick, "tick_1s"})
    timer_5s = :timer.send_interval(5_000, self(), {:tick, "tick_5s"})
    timer_30s = :timer.send_interval(30_000, self(), {:tick, "tick_30s"})

    # Initialize ETS table for subscribers
    :ets.new(:tick_subscribers, [:set, :named_table, :public])

    state = %{
      timers: %{
        tick_1s: timer_1s,
        tick_5s: timer_5s,
        tick_30s: timer_30s
      },
      restart_count: 0
    }

    {:ok, state}
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

    # Extract PID from Gleam subject
    {:subject, pid, _ref} = gleam_subject

    # Get existing subscribers for this tick
    subscribers =
      case :ets.lookup(:tick_subscribers, tick_name) do
        [{^tick_name, subs}] -> subs
        [] -> []
      end

    # Remove subscriber
    updated_subscribers = List.delete(subscribers, pid)

    # Update ETS table
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
      timer_count: map_size(state.timers)
    }

    {:reply, status, state}
  end

  def handle_info({:tick, tick_name}, state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    tick_message = %{"tick_type" => tick_name, "timestamp" => timestamp}

    # Grab whatever is in ETS (no pruning)
    subscribers =
      case :ets.lookup(:tick_subscribers, tick_name) do
        [{^tick_name, subs}] -> subs
        [] -> []
      end

    Logger.debug(
      "[ClockActor] Broadcasting #{tick_name} to #{length(subscribers)} subs: #{inspect(subscribers)}"
    )

    Enum.each(subscribers, fn
      subject = {:subject, pid, _ref} ->
        # Try both Gleam send and raw send so we can compare
        Logger.debug(" → sending via gleam@erlang@process.send to subject #{inspect(subject)}")

        try do
          :gleam@erlang@process.send(subject, tick_message)
        rescue
          e -> Logger.error("   gleam send failed: #{inspect(e)}")
        end

        Logger.debug(" → sending via raw send to pid #{inspect(pid)}")

        try do
          send(pid, tick_message)
        rescue
          e -> Logger.error("   raw send failed: #{inspect(e)}")
        end

      pid when is_pid(pid) ->
        Logger.debug(" → sending raw to pid #{inspect(pid)}")

        try do
          send(pid, tick_message)
        rescue
          e -> Logger.error("   raw send failed: #{inspect(e)}")
        end
    end)

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warn("[ClockActor] Child process died: #{inspect(reason)}")

    # For clock actor, we don't have child processes to restart
    # Just log and continue
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[ClockActor] Unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(reason, state) do
    Logger.info("[ClockActor] Terminating: #{inspect(reason)}")

    # Cancel all timers
    Enum.each(state.timers, fn {_name, timer_ref} ->
      :timer.cancel(timer_ref)
    end)

    # Clean up ETS table
    :ets.delete(:tick_subscribers)

    :ok
  end
end
