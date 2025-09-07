import clients/fly_client
import clients/supabase_client
import gleam/dict
import gleam/int
import gleam/string
import gleeunit
import utils/utils

pub fn main() {
  gleeunit.main()
}

pub fn provision_creates_machine_test() {
  // Set mock mode

  // Create a test provisioning task
  let assert Ok(_task_id) =
    supabase_client.insert_provisioning_queue(
      "test_biz",
      "test_customer",
      "provision",
      "fly",
      dict.from_list([
        #("expires_at", int.to_string(utils.current_timestamp() + 86_400)),
        #("docker_image", "nginx:latest"),
        #("machine_size", "shared-cpu-1x"),
      ]),
    )

  // Mock the machine creation directly (without actor)
  let assert Ok(machine) =
    fly_client.create_machine(
      "fake_token",
      "test_org",
      "test_app",
      "iad",
      "shared-cpu-1x",
      "nginx:latest",
    )

  // Verify it's a mock machine
  let assert True = string.starts_with(machine.id, "mock_")
  let assert "started" = machine.state

  // Test deletion
  let assert Ok(Nil) =
    fly_client.terminate_machine("fake_token", "test_app", machine.id)
}
