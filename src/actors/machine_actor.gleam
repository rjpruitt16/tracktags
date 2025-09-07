// src/actors/machine_actor.gleamprocess_taskprocess_task
import clients/fly_client
import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import glixir
import logging
import types/customer_types
import utils/utils

pub type Message {
  InitializeSelf(process.Subject(Message))
  PollProvisioningQueue
  PollExpiredMachines
  ProcessProvisioningTask(task: supabase_client.ProvisioningTask)
  TerminateExpiredMachine(machine: customer_types.CustomerMachine)
}

pub type State {
  State(
    active_tasks: Dict(String, supabase_client.ProvisioningTask),
    last_poll: Int,
    self_subject: process.Subject(Message),
  )
}

pub fn start() -> Result(process.Subject(Message), actor.StartError) {
  let placeholder_subject = process.new_subject()
  let initial_state =
    State(
      active_tasks: dict.new(),
      last_poll: 0,
      self_subject: placeholder_subject,
    )

  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) {
    let subject = started.data

    // Register in registry so it can be found
    case
      glixir.register_subject(
        utils.tracktags_registry(),
        utils.machine_actor_key(),
        subject,
        glixir.atom_key_encoder,
      )
    {
      Ok(_) ->
        logging.log(logging.Info, "[MachineActor] Registered in registry")
      Error(e) ->
        logging.log(
          logging.Error,
          "[MachineActor] Failed to register: " <> string.inspect(e),
        )
    }

    process.send(subject, InitializeSelf(subject))
    subject
  })
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    InitializeSelf(self_subject) -> {
      logging.log(
        logging.Info,
        "[MachineActor] Initializing with self reference",
      )

      // Schedule polling using the self reference
      let _ = process.send_after(self_subject, 30_000, PollProvisioningQueue)
      let _ = process.send_after(self_subject, 3_600_000, PollExpiredMachines)

      actor.continue(State(..state, self_subject: self_subject))
    }

    PollProvisioningQueue -> {
      logging.log(logging.Debug, "[MachineActor] Polling provisioning queue")

      // Get pending tasks
      case supabase_client.get_pending_provisioning_tasks(10) {
        Ok(tasks) -> {
          logging.log(
            logging.Info,
            "[MachineActor] Found "
              <> int.to_string(list.length(tasks))
              <> " pending tasks",
          )

          // Process each task - use self_subject from state
          list.each(tasks, fn(task) {
            process.send(state.self_subject, ProcessProvisioningTask(task))
          })
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[MachineActor] Failed to get tasks: " <> string.inspect(e),
          )
        }
      }

      // Schedule next poll
      let _ =
        process.send_after(state.self_subject, 30_000, PollProvisioningQueue)

      actor.continue(State(..state, last_poll: utils.current_timestamp()))
    }

    ProcessProvisioningTask(task) -> {
      logging.log(
        logging.Info,
        "[MachineActor] Processing task: "
          <> task.id
          <> " action: "
          <> task.action,
      )

      case task.action {
        "provision" -> handle_provision(task)
        "terminate" -> handle_terminate(task)
        _ -> {
          logging.log(
            logging.Warning,
            "[MachineActor] Unknown action: " <> task.action,
          )
        }
      }

      actor.continue(state)
    }
    PollExpiredMachines -> {
      logging.log(logging.Debug, "[MachineActor] Checking for expired machines")

      // Get expired machines
      case supabase_client.get_expired_machines() {
        Ok(machines) -> {
          logging.log(
            logging.Info,
            "[MachineActor] Found "
              <> int.to_string(list.length(machines))
              <> " expired machines",
          )

          list.each(machines, fn(machine) {
            process.send(state.self_subject, TerminateExpiredMachine(machine))
          })
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[MachineActor] Failed to get expired machines: "
              <> string.inspect(e),
          )
        }
      }

      // Schedule next check
      process.send_after(state.self_subject, 3_600_000, PollExpiredMachines)
      actor.continue(state)
    }

    TerminateExpiredMachine(machine) -> {
      logging.log(
        logging.Info,
        "[MachineActor] Terminating expired machine: " <> machine.machine_id,
      )

      // Get Fly credentials
      case fly_client.get_fly_credentials(machine.business_id) {
        Ok(#(api_token, _org_slug, _region)) -> {
          case
            fly_client.terminate_machine(
              api_token,
              machine.fly_app_name |> option.unwrap(""),
              machine.machine_id,
            )
          {
            Ok(_) -> {
              // Update database
              let _ =
                supabase_client.update_machine_status(machine.id, "terminated")

              // Update customer actor
              update_customer_actor_machines(machine.customer_id)

              logging.log(
                logging.Info,
                "[MachineActor] Successfully terminated: " <> machine.machine_id,
              )
            }
            Error(e) -> {
              logging.log(
                logging.Error,
                "[MachineActor] Failed to terminate: " <> string.inspect(e),
              )
            }
          }
        }
        Error(e) -> {
          logging.log(logging.Error, "[MachineActor] No Fly credentials: " <> e)
        }
      }

      actor.continue(state)
    }
  }
}

fn handle_provision(task: supabase_client.ProvisioningTask) -> Nil {
  // Check if this is a mock mode test
  let is_mock =
    dict.get(task.payload, "mock_mode") |> result.unwrap("false") == "true"

  case is_mock {
    True -> {
      // Skip Fly, just create mock machine record
      let mock_machine_id = "mock_" <> int.to_string(utils.current_timestamp())
      let expires_at =
        dict.get(task.payload, "expires_at")
        |> result.try(int.parse)
        |> result.unwrap(utils.current_timestamp() + 86_400)
      let region = "iad"
      let size = "shared-cpu-1x"

      logging.log(
        logging.Info,
        "[MachineActor] Creating mock machine: "
          <> mock_machine_id
          <> " for customer: "
          <> task.customer_id,
      )

      case
        supabase_client.insert_customer_machine(
          task.customer_id,
          task.business_id,
          mock_machine_id,
          "mock_app",
          "10.0.0.1",
          "running",
          expires_at,
          size,
          region,
        )
      {
        Ok(_) -> {
          logging.log(
            logging.Info,
            "[MachineActor] Successfully inserted mock machine",
          )
          let _ =
            supabase_client.update_provisioning_task_status(
              task.id,
              "completed",
            )
          update_customer_actor_machines(task.customer_id)
          logging.log(
            logging.Info,
            "[MachineActor] Mock machine created for " <> task.customer_id,
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[MachineActor] Failed to insert mock machine: "
              <> string.inspect(e),
          )
          handle_provision_failure(task, "Failed to create mock machine")
        }
      }
    }
    False -> {
      // Original Fly provisioning logic
      case supabase_client.get_business(task.business_id) {
        Ok(business) -> {
          let docker_image =
            business.default_docker_image
            |> option.unwrap("flyio/hellofly:latest")
          let region = business.default_region |> option.unwrap("iad")
          let size =
            business.default_machine_size |> option.unwrap("shared-cpu-1x")

          case fly_client.get_fly_credentials(task.business_id) {
            Ok(#(api_token, org_slug, _default_region)) -> {
              let app_name =
                task.customer_id
                <> "_"
                <> int.to_string(utils.current_timestamp())

              case
                fly_client.create_machine(
                  api_token,
                  org_slug,
                  app_name,
                  region,
                  size,
                  docker_image,
                )
              {
                Ok(machine) -> {
                  let expires_at =
                    dict.get(task.payload, "expires_at")
                    |> result.try(int.parse)
                    |> result.unwrap(utils.current_timestamp() + 2_851_200)

                  let _ =
                    supabase_client.insert_customer_machine(
                      task.customer_id,
                      task.business_id,
                      machine.id,
                      app_name,
                      machine.private_ip,
                      "running",
                      expires_at,
                      size,
                      region,
                    )

                  let _ =
                    supabase_client.update_provisioning_task_status(
                      task.id,
                      "completed",
                    )
                  update_customer_actor_machines(task.customer_id)

                  logging.log(
                    logging.Info,
                    "[MachineActor] Successfully provisioned machine for "
                      <> task.customer_id,
                  )
                }
                Error(e) -> handle_provision_failure(task, string.inspect(e))
              }
            }
            Error(e) -> {
              logging.log(
                logging.Error,
                "[MachineActor] No Fly credentials for business: " <> e,
              )
              handle_provision_failure(task, "No Fly credentials")
            }
          }
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "[MachineActor] Failed to get business: " <> string.inspect(e),
          )
          handle_provision_failure(task, "Failed to get business config")
        }
      }
    }
  }

  Nil
}

fn handle_provision_failure(
  task: supabase_client.ProvisioningTask,
  error_message: String,
) -> Nil {
  let new_attempts = task.attempt_count + 1

  case new_attempts >= task.max_attempts {
    True -> {
      // Move to dead letter
      let _ =
        supabase_client.update_provisioning_task_dead_letter(
          task.id,
          error_message,
        )
      logging.log(
        logging.Error,
        "[MachineActor] Task "
          <> task.id
          <> " moved to dead letter: "
          <> error_message,
      )
    }
    False -> {
      // Schedule retry
      let next_retry = utils.current_timestamp() + { 300 * new_attempts }
      // Exponential backoff
      let _ =
        supabase_client.update_provisioning_task_retry(
          task.id,
          new_attempts,
          next_retry,
          error_message,
        )
      logging.log(
        logging.Warning,
        "[MachineActor] Task "
          <> task.id
          <> " will retry (attempt "
          <> int.to_string(new_attempts)
          <> ")",
      )
    }
  }

  Nil
}

fn handle_terminate(task: supabase_client.ProvisioningTask) -> Nil {
  logging.log(
    logging.Info,
    "[MachineActor] Terminating machines for " <> task.customer_id,
  )

  // Check if mock mode
  let is_mock =
    dict.get(task.payload, "mock_mode") |> result.unwrap("false") == "true"

  // Get all machines for this customer
  let _ = case supabase_client.get_customer_machines(task.customer_id) {
    Ok(machines) -> {
      list.each(machines, fn(machine) {
        case is_mock {
          True -> {
            // For mock, just update status
            let _ =
              supabase_client.update_machine_status(
                machine.machine_id,
                "terminated",
              )
            logging.log(
              logging.Info,
              "[MachineActor] Mock machine terminated: " <> machine.machine_id,
            )
          }
          False -> {
            // Real Fly termination
            case fly_client.get_fly_credentials(task.business_id) {
              Ok(#(api_token, _org_slug, _region)) -> {
                let _ =
                  fly_client.terminate_machine(
                    api_token,
                    machine.fly_app_name |> option.unwrap(""),
                    machine.machine_id,
                  )
                let _ =
                  supabase_client.update_machine_status(
                    machine.machine_id,
                    "terminated",
                  )
                logging.log(
                  logging.Info,
                  "[MachineActor] Terminated machine: " <> machine.machine_id,
                )
              }
              Error(e) -> {
                logging.log(
                  logging.Error,
                  "[MachineActor] No Fly credentials: " <> e,
                )
              }
            }
          }
        }
      })

      // Update customer actor to clear machines
      update_customer_actor_machines(task.customer_id)

      // Mark task complete
      let _ =
        supabase_client.update_provisioning_task_status(task.id, "completed")
      Ok(Nil)
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "[MachineActor] Failed to get machines: " <> string.inspect(e),
      )
      Error(e)
    }
  }

  Nil
}

fn update_customer_actor_machines(customer_id: String) -> Nil {
  // Get all active machines for customer
  case supabase_client.get_customer_machines(customer_id) {
    Ok(machines) -> {
      let machine_ids = list.map(machines, fn(m) { m.machine_id })
      let expires_at =
        list.first(machines)
        |> result.map(fn(m) { m.expires_at })
        |> result.unwrap(0)

      // Find customer actor
      case customer_types.lookup_client_subject("", customer_id) {
        // Need business_id
        Ok(customer_subject) -> {
          process.send(
            customer_subject,
            customer_types.UpdateMachines(machine_ids, expires_at),
          )
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "[MachineActor] Customer actor not found: " <> customer_id,
          )
        }
      }
    }
    Error(_) -> {
      logging.log(
        logging.Error,
        "[MachineActor] Failed to get machines for customer: " <> customer_id,
      )
    }
  }

  Nil
}

// In machine_actor.gleam, add this function:
pub fn lookup_machine_actor() -> Result(process.Subject(Message), String) {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.machine_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Machine actor not found in registry")
  }
}
