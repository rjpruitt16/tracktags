# Since we're in a Gleam project, this goes in the Gleam supervision tree
# This would be added to your Gleam application supervisor

# For now, you can start it manually in Gleam or create a simple Elixir app file:
defmodule TrackTagsApplication do
  use Application

  def start() do
    children = [
      # Start the Clock Actor with supervision
      {ClockActor, []}
    ]

    # One-for-one strategy with exponential backoff built into ClockActor
    opts = [strategy: :one_for_one, name: TrackTagsApplication.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
