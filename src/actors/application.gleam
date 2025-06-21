import actors/metric_actor
import actors/user_actor.{type State}
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/static_supervisor
import gleam/string

// External functions to interact with ClockActor
// Now we pass raw PIDs instead of Subjects
@external(erlang, "Elixir.TrackTagsApplication", "start")
fn start_elixir_application() -> dynamic.Dynamic

fn build_user_loop(
  build: static_supervisor.Builder,
  user_states: dict.Dict(user_actor.State, List(metric_actor.State)),
) -> static_supervisor.Builder {
  io.println("[Application] build_metric_loop called with ")
  dict.to_list(user_states)
  |> list.fold(build, fn(build, user_to_metrics) {
    let #(user_state, metric_states) = user_to_metrics
    static_supervisor.add(build, user_actor.start(user_state, metric_states))
  })
}

pub fn start_app(
  users_to_metrics: dict.Dict(user_actor.State, List(metric_actor.State)),
) {
  io.println("[Application] Starting elixir application")
  start_elixir_application()

  io.println(
    "[Application] Building supervision tree with "
    <> int.to_string(list.length(dict.to_list(users_to_metrics)))
    <> " user states",
  )
  let supervisor_result =
    build_user_loop(
      static_supervisor.new(static_supervisor.OneForOne),
      users_to_metrics,
    )
    |> static_supervisor.start

  io.println(
    "[Application] Supervisor start result: "
    <> string.inspect(supervisor_result),
  )
  supervisor_result
}
