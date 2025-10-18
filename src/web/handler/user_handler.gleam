// src/web/handler/user_handler.gleam=
import clients/supabase_client
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glixir
import logging
import types/application_types
import types/customer_types
import utils/audit
import utils/auth
import utils/utils
import wisp.{type Request, type Response}

// ============================================================================
// TYPES
// ============================================================================

pub type CustomerRequest {
  CustomerRequest(
    customer_id: String,
    name: String,
    description: String,
    plan_id: String,
    subscription_ends_at: Option(String),
  )
}

pub type CustomerKeyRequest {
  CustomerKeyRequest(
    external_key: String,
    name: String,
    description: String,
    permissions: List(String),
  )
}

// ============================================================================
// AUTHENTICATION (copied from metric_handler pattern)
// ============================================================================

fn with_auth(req: Request, handler: fn(String) -> Response) -> Response {
  auth.with_auth(req, fn(auth_result, _api_key, is_admin) {
    case is_admin {
      True -> handler("admin")
      // Admin bypass
      False -> {
        case auth_result {
          auth.ActorCached(auth.BusinessActor(bid, _)) -> handler(bid)
          auth.ActorCached(auth.CustomerActor(bid, _, _)) -> handler(bid)
          auth.DatabaseValid(supabase_client.BusinessKey(bid)) -> handler(bid)
          auth.DatabaseValid(supabase_client.CustomerKey(bid, _)) ->
            handler(bid)
          _ -> {
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("error", json.string("Unauthorized")),
                  #("message", json.string("Invalid API key")),
                ]),
              ),
              401,
            )
          }
        }
      }
    }
  })
}

// ============================================================================
// JSON DECODERS
// ============================================================================

fn customer_request_decoder() -> decode.Decoder(CustomerRequest) {
  use customer_id <- decode.field("customer_id", decode.string)
  use plan_id <- decode.field("plan_id", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use subscription_ends_at <- decode.optional_field(
    "subscription_ends_at",
    None,
    decode.optional(decode.string),
  )
  decode.success(CustomerRequest(
    customer_id: customer_id,
    name: name,
    description: description,
    plan_id: plan_id,
    subscription_ends_at: subscription_ends_at,
  ))
}

// ============================================================================
// VALIDATION
// ============================================================================

fn validate_customer_request(
  req: CustomerRequest,
) -> Result(CustomerRequest, List(decode.DecodeError)) {
  // Validate customer_id
  case string.length(req.customer_id) {
    0 ->
      Error([decode.DecodeError("Invalid", "customer_id cannot be empty", [])])
    n if n > 100 ->
      Error([
        decode.DecodeError(
          "Invalid",
          "customer_id too long (max 100 chars)",
          [],
        ),
      ])
    _ -> Ok(Nil)
  }
  |> result.try(fn(_) {
    // Validate name length
    case string.length(req.name) > 200 {
      True ->
        Error([
          decode.DecodeError("Invalid", "name too long (max 200 chars)", []),
        ])
      False -> Ok(req)
    }
  })
}

// ============================================================================
// CRUD ENDPOINTS
// ============================================================================

pub fn get_customer_machines(req: Request, customer_id: String) -> Response {
  use <- wisp.require_method(req, http.Get)

  with_auth(req, fn(business_id) {
    case business_id {
      "admin" -> {
        // Admin gets direct database access, no actor check
        logging.log(
          logging.Info,
          "[CustomerHandler] Admin access for machines: " <> customer_id,
        )
        query_database_for_machines(customer_id)
      }
      _ -> {
        // For test customers, skip actor check
        case string.starts_with(customer_id, "test_") {
          True -> {
            logging.log(
              logging.Info,
              "[CustomerHandler] Test customer, skipping actor check: "
                <> customer_id,
            )
            query_database_for_machines(customer_id)
          }
          False -> {
            // Regular flow with registry check
            let registry_key = "client:" <> business_id <> ":" <> customer_id

            case
              glixir.lookup_subject_string(
                utils.tracktags_registry(),
                registry_key,
              )
            {
              Ok(customer_subject) -> {
                let reply = process.new_subject()
                process.send(
                  customer_subject,
                  customer_types.GetMachines(reply),
                )

                case process.receive(reply, 1000) {
                  Ok(_machine_ids) -> query_database_for_machines(customer_id)
                  Error(_) -> query_database_for_machines(customer_id)
                }
              }
              Error(_) -> {
                logging.log(
                  logging.Info,
                  "[CustomerHandler] No actor found, checking database",
                )
                query_database_for_machines(customer_id)
              }
            }
          }
        }
      }
    }
  })
}

fn query_database_for_machines(customer_id: String) -> Response {
  case supabase_client.get_customer_machines(customer_id) {
    Ok([]) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("No machines found for customer")),
          ]),
        ),
        404,
      )
    }
    Ok(machines) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("machines", json.array(machines, of: machine_to_json)),
          ]),
        ),
        200,
      )
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "[CustomerHandler] Database error: " <> string.inspect(err),
      )
      wisp.internal_server_error()
      |> wisp.string_body("Failed to get machines")
    }
  }
}

fn machine_to_json(machine: customer_types.CustomerMachine) -> json.Json {
  json.object([
    #("machine_id", json.string(machine.machine_id)),
    #("status", json.string(machine.status)),
    #("fly_app_name", json.nullable(machine.fly_app_name, of: json.string)),
    #("machine_url", json.nullable(machine.machine_url, of: json.string)),
    #("ip_address", json.nullable(machine.ip_address, of: json.string)),
    #("docker_image", json.nullable(machine.docker_image, of: json.string)),
    #("expires_at", json.int(machine.expires_at)),
  ])
}

pub fn create_customer(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 CREATE CUSTOMER REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Post)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let result = {
    use customer_req <- result.try(decode.run(
      json_data,
      customer_request_decoder(),
    ))
    use validated_req <- result.try(validate_customer_request(customer_req))
    Ok(process_create_customer(business_id, validated_req))
  }

  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 CREATE CUSTOMER REQUEST END - ID: " <> request_id,
  )

  case result {
    Ok(response) -> response
    Error(decode_errors) -> {
      logging.log(
        logging.Warning,
        "[CustomerHandler] Bad request: " <> string.inspect(decode_errors),
      )
      let error_json =
        json.object([
          #("error", json.string("Bad Request")),
          #("message", json.string("Invalid request data")),
        ])
      wisp.json_response(json.to_string_tree(error_json), 400)
    }
  }
}

pub fn update_customer(req: Request, customer_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 UPDATE CUSTOMER REQUEST START - ID: "
      <> request_id
      <> " customer: "
      <> customer_id,
  )

  use <- wisp.require_method(req, http.Put)
  use business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let decoder = {
    use plan_id <- decode.optional_field(
      "plan_id",
      None,
      decode.optional(decode.string),
    )
    use stripe_price_id <- decode.optional_field(
      "stripe_price_id",
      None,
      decode.optional(decode.string),
    )
    use subscription_ends_at <- decode.optional_field(
      "subscription_ends_at",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(plan_id, stripe_price_id, subscription_ends_at))
  }

  case decode.run(json_data, decoder) {
    Ok(#(plan_id, stripe_price_id, subscription_ends_at)) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔄 Updating customer: "
          <> business_id
          <> "/"
          <> customer_id,
      )

      // Perform updates in sequence, handling each result
      let update_result = {
        // Step 1: Update plan/price if provided
        case plan_id, stripe_price_id {
          Some(_), _ | _, Some(_) -> {
            logging.log(
              logging.Info,
              "[CustomerHandler] Updating plan and/or price",
            )
            case
              supabase_client.update_customer_plan(
                business_id,
                customer_id,
                plan_id,
                stripe_price_id,
              )
            {
              Ok(_) -> {
                // Step 2: Update expiry if provided
                case subscription_ends_at {
                  Some(_) -> {
                    logging.log(
                      logging.Info,
                      "[CustomerHandler] Updating subscription_ends_at",
                    )
                    supabase_client.update_customer_subscription_expiry(
                      business_id,
                      customer_id,
                      subscription_ends_at,
                    )
                  }
                  None -> {
                    // No expiry update, fetch final state
                    supabase_client.get_customer_by_id(business_id, customer_id)
                  }
                }
              }
              Error(e) -> Error(e)
            }
          }
          None, None -> {
            // No plan update, just update expiry if provided
            case subscription_ends_at {
              Some(_) -> {
                logging.log(
                  logging.Info,
                  "[CustomerHandler] Updating subscription_ends_at only",
                )
                supabase_client.update_customer_subscription_expiry(
                  business_id,
                  customer_id,
                  subscription_ends_at,
                )
              }
              None -> {
                // Nothing to update, just fetch current state
                supabase_client.get_customer_by_id(business_id, customer_id)
              }
            }
          }
        }
      }

      case update_result {
        Ok(updated_customer) -> {
          logging.log(
            logging.Info,
            "[CustomerHandler] ✅ Customer updated successfully",
          )

          // 🔔 NOTIFY CUSTOMER ACTOR - use the updated customer's ACTUAL plan
          let registry_key = "client:" <> business_id <> ":" <> customer_id
          case
            glixir.lookup_subject_string(
              utils.tracktags_registry(),
              registry_key,
            )
          {
            Ok(customer_subject) -> {
              logging.log(
                logging.Info,
                "[CustomerHandler] 🔔 Notifying customer actor of plan change",
              )
              process.send(
                customer_subject,
                customer_types.RealtimePlanChange(
                  plan_id: updated_customer.plan_id,
                  price_id: updated_customer.stripe_price_id,
                ),
              )
            }
            Error(_) -> {
              logging.log(
                logging.Warning,
                "[CustomerHandler] Customer actor not running, will load on next spawn",
              )
            }
          }

          let success_json =
            json.object([
              #("status", json.string("updated")),
              #("customer_id", json.string(customer_id)),
              #("plan_id", case updated_customer.plan_id {
                Some(pid) -> json.string(pid)
                None -> json.null()
              }),
              #("stripe_price_id", case updated_customer.stripe_price_id {
                Some(spid) -> json.string(spid)
                None -> json.null()
              }),
              #(
                "subscription_ends_at",
                case updated_customer.subscription_ends_at {
                  Some(exp) -> json.string(exp)
                  None -> json.null()
                },
              ),
            ])

          logging.log(
            logging.Info,
            "[CustomerHandler] 🔍 UPDATE CUSTOMER REQUEST END - ID: "
              <> request_id,
          )

          wisp.json_response(json.to_string_tree(success_json), 200)
        }
        Error(supabase_client.NotFound(_)) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Not Found")),
                #("message", json.string("Customer not found")),
              ]),
            ),
            404,
          )
        }
        Error(_) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Internal Server Error")),
                #("message", json.string("Failed to update customer")),
              ]),
            ),
            500,
          )
        }
      }
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Bad Request")),
            #("message", json.string("Invalid request data")),
          ]),
        ),
        400,
      )
    }
  }
}

pub fn list_customers(req: Request) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 LIST CUSTOMERS REQUEST START - ID: " <> request_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] 📋 Listing customers for business: " <> business_id,
  )

  case supabase_client.get_business_customers(business_id) {
    Ok(customers) -> {
      let response_data =
        customers
        |> list.map(fn(customer) {
          json.object([
            #("customer_id", json.string(customer.customer_id)),
            #("customer_name", json.string(customer.customer_name)),
            #("plan_id", case customer.plan_id {
              Some(pid) -> json.string(pid)
              None -> json.null()
            }),
          ])
        })
        |> json.array(from: _, of: fn(item) { item })

      let success_json =
        json.object([
          #("customers", response_data),
          #("count", json.int(list.length(customers))),
        ])

      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 LIST CUSTOMERS REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(_) -> {
      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to fetch customers")),
        ])
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 LIST CUSTOMERS REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

pub fn get_customer(req: Request, customer_id: String) -> Response {
  let request_id = string.inspect(utils.system_time())
  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 GET CUSTOMER REQUEST START - ID: "
      <> request_id
      <> " customer: "
      <> customer_id,
  )

  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] 🔍 Getting customer: "
      <> business_id
      <> "/"
      <> customer_id,
  )

  case supabase_client.get_customer_by_id(business_id, customer_id) {
    Ok(customer) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 GET CUSTOMER REQUEST END - ID: " <> request_id,
      )

      let success_json =
        json.object([
          #("customer_id", json.string(customer.customer_id)),
          #("customer_name", json.string(customer.customer_name)),
          #("plan_id", case customer.plan_id {
            Some(pid) -> json.string(pid)
            None -> json.null()
          }),
          // 🆕 ADD THIS:
          #("subscription_ends_at", case customer.subscription_ends_at {
            Some(exp) -> json.string(exp)
            None -> json.null()
          }),
        ])
      wisp.json_response(json.to_string_tree(success_json), 200)
    }
    Error(supabase_client.NotFound(_)) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 GET CUSTOMER REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Customer not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] 🔍 GET CUSTOMER REQUEST END - ID: " <> request_id,
      )

      wisp.json_response(
        json.to_string_tree(
          json.object([#("error", json.string("Internal Server Error"))]),
        ),
        500,
      )
    }
  }
}

pub fn delete_customer(req: Request, customer_id: String) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] Attempting to delete customer: " <> customer_id,
  )

  // Verify customer belongs to this business BEFORE deleting
  case supabase_client.get_customer_by_id(business_id, customer_id) {
    Ok(_customer) -> {
      // Customer exists and belongs to this business, safe to delete
      case
        supabase_client.soft_delete_customer(
          business_id,
          customer_id,
          business_id,
        )
      {
        Ok(_) -> {
          let _ =
            audit.log_action(
              "delete_customer",
              "customer",
              customer_id,
              dict.from_list([#("business_id", json.string(business_id))]),
            )
          logging.log(
            logging.Info,
            "[CustomerHandler] Successfully deleted customer: " <> customer_id,
          )
          wisp.ok() |> wisp.string_body("Customer deleted")
        }
        Error(_) -> {
          logging.log(
            logging.Error,
            "[CustomerHandler] Failed to delete customer: " <> customer_id,
          )
          wisp.internal_server_error()
        }
      }
    }
    Error(supabase_client.NotFound(_)) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("error", json.string("Not Found")),
            #("message", json.string("Customer not found")),
          ]),
        ),
        404,
      )
    }
    Error(_) -> wisp.internal_server_error()
  }
}

// ============================================================================
// HELPER FUNCTION - Add this near the top with other helpers
// ============================================================================

fn get_application_actor() -> Result(
  process.Subject(application_types.ApplicationMessage),
  String,
) {
  case
    glixir.lookup_subject(
      utils.tracktags_registry(),
      utils.application_actor_key(),
      glixir.atom_key_encoder,
    )
  {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error("Application actor not found in registry")
  }
}

// ============================================================================
// UPDATED PROCESS_CREATE_CUSTOMER FUNCTION
// ============================================================================

fn process_create_customer(
  business_id: String,
  req: CustomerRequest,
) -> Response {
  logging.log(
    logging.Info,
    "[CustomerHandler] 🏗️ Processing CREATE customer: "
      <> business_id
      <> "/"
      <> req.customer_id
      <> " (name: "
      <> req.name
      <> ")",
  )

  // Actually create the customer in the database
  case
    supabase_client.create_customer(
      business_id,
      req.customer_id,
      req.name,
      req.plan_id,
      option.None,
      req.subscription_ends_at,
    )
  {
    Ok(_) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] ✅ Customer created successfully in database",
      )

      // 🚀 NEW: Spawn the CustomerActor immediately after database creation
      logging.log(
        logging.Info,
        "[CustomerHandler] 🚀 Attempting to spawn CustomerActor for: "
          <> req.customer_id,
      )

      case
        supabase_client.get_customer_full_context(business_id, req.customer_id)
      {
        Ok(context) -> {
          logging.log(
            logging.Info,
            "[CustomerHandler] ✅ Loaded customer context successfully",
          )

          case get_application_actor() {
            Ok(app_actor) -> {
              let reply = process.new_subject()

              logging.log(
                logging.Info,
                "[CustomerHandler] 📤 Sending EnsureCustomerActor message to ApplicationActor",
              )

              process.send(
                app_actor,
                application_types.EnsureCustomerActor(
                  business_id,
                  req.customer_id,
                  context,
                  "",
                  // No API key yet
                  reply,
                ),
              )

              // Wait briefly for the actor to spawn (optional, non-blocking)
              case process.receive(reply, 500) {
                Ok(_customer_subject) -> {
                  logging.log(
                    logging.Info,
                    "[CustomerHandler] ✅ CustomerActor spawned successfully for: "
                      <> req.customer_id,
                  )
                }
                Error(_) -> {
                  logging.log(
                    logging.Warning,
                    "[CustomerHandler] ⚠️ CustomerActor spawn timeout (may still be initializing)",
                  )
                }
              }
            }
            Error(e) -> {
              logging.log(
                logging.Warning,
                "[CustomerHandler] ⚠️ Could not get application actor: " <> e,
              )
            }
          }
        }
        Error(e) -> {
          logging.log(
            logging.Warning,
            "[CustomerHandler] ⚠️ Could not load customer context: "
              <> string.inspect(e),
          )
        }
      }

      // Return success response regardless of actor spawn status
      let success_json =
        json.object([
          #("status", json.string("created")),
          #("business_id", json.string(business_id)),
          #("customer_id", json.string(req.customer_id)),
          #("name", json.string(req.name)),
          #("description", json.string(req.description)),
          #("timestamp", json.int(utils.current_timestamp())),
        ])

      wisp.json_response(json.to_string_tree(success_json), 201)
    }

    Error(supabase_client.DatabaseError(msg)) -> {
      logging.log(
        logging.Error,
        "[CustomerHandler] ❌ Failed to create customer: " <> msg,
      )

      let error_json =
        json.object([
          #("error", json.string("Database Error")),
          #("message", json.string("Failed to create customer: " <> msg)),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }

    Error(error) -> {
      logging.log(
        logging.Error,
        "[CustomerHandler] ❌ Failed to create customer: "
          <> string.inspect(error),
      )

      let error_json =
        json.object([
          #("error", json.string("Internal Server Error")),
          #("message", json.string("Failed to create client")),
        ])

      wisp.json_response(json.to_string_tree(error_json), 500)
    }
  }
}

pub fn list_client_keys(req: Request, customer_id: String) -> Response {
  use <- wisp.require_method(req, http.Get)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] Listing keys for customer: " <> customer_id,
  )

  let success_json =
    json.object([
      #("message", json.string("List customer keys - LOGGED")),
      #("business_id", json.string(business_id)),
      #("customer_id", json.string(customer_id)),
    ])

  wisp.json_response(json.to_string_tree(success_json), 200)
}

pub fn delete_client_key(
  req: Request,
  customer_id: String,
  key_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Delete)
  use business_id <- with_auth(req)

  logging.log(
    logging.Info,
    "[CustomerHandler] Deleting key: "
      <> key_id
      <> " for customer: "
      <> customer_id,
  )

  let success_json =
    json.object([
      #("message", json.string("Delete customer key - LOGGED")),
      #("business_id", json.string(business_id)),
      #("customer_id", json.string(customer_id)),
      #("key_id", json.string(key_id)),
    ])

  wisp.json_response(json.to_string_tree(success_json), 200)
}

pub fn create_business(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)

  auth.with_auth(req, fn(_auth_result, _api_key, is_admin) {
    case is_admin {
      False -> {
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Forbidden")),
              #("message", json.string("Admin authentication required")),
            ]),
          ),
          403,
        )
      }

      True -> {
        use json_data <- wisp.require_json(req)

        let decoder = {
          use business_name <- decode.field("business_name", decode.string)
          use email <- decode.field("email", decode.string)
          use user_id <- decode.optional_field(
            "user_id",
            None,
            decode.optional(decode.string),
          )
          decode.success(#(business_name, email, user_id))
        }

        case decode.run(json_data, decoder) {
          Error(_) -> {
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("error", json.string("Bad Request")),
                  #("message", json.string("Invalid request data")),
                ]),
              ),
              400,
            )
          }

          Ok(#(business_name, email, user_id)) -> {
            let business_id = "biz_" <> utils.generate_uuid()

            case
              supabase_client.create_business(business_id, business_name, email)
            {
              Ok(business) -> {
                logging.log(
                  logging.Info,
                  "[UserHandler] Created business: " <> business.business_id,
                )

                // If user_id provided, link user to business
                let link_result = case user_id {
                  Some(uid) -> {
                    logging.log(
                      logging.Info,
                      "[UserHandler] Linking user "
                        <> uid
                        <> " to business "
                        <> business_id,
                    )
                    supabase_client.link_user_to_business(
                      uid,
                      business_id,
                      "owner",
                    )
                  }
                  None -> Ok(Nil)
                }

                case link_result {
                  Ok(_) -> {
                    wisp.json_response(
                      json.to_string_tree(
                        json.object([
                          #("business_id", json.string(business.business_id)),
                          #(
                            "business_name",
                            json.string(business.business_name),
                          ),
                          #("email", json.string(business.email)),
                        ]),
                      ),
                      201,
                    )
                  }
                  Error(err) -> {
                    logging.log(
                      logging.Error,
                      "[UserHandler] Failed to link user to business: "
                        <> string.inspect(err),
                    )
                    // Business was created but linking failed
                    wisp.json_response(
                      json.to_string_tree(
                        json.object([
                          #("error", json.string("Partial Success")),
                          #(
                            "message",
                            json.string(
                              "Business created but user linking failed",
                            ),
                          ),
                          #("business_id", json.string(business.business_id)),
                        ]),
                      ),
                      207,
                      // Multi-Status
                    )
                  }
                }
              }

              Error(err) -> {
                logging.log(
                  logging.Error,
                  "[UserHandler] Failed to create business: "
                    <> string.inspect(err),
                )

                wisp.json_response(
                  json.to_string_tree(
                    json.object([
                      #("error", json.string("Internal Server Error")),
                      #("message", json.string("Failed to create business")),
                    ]),
                  ),
                  500,
                )
              }
            }
          }
        }
      }
    }
  })
}

pub fn delete_business(req: Request, business_id: String) -> Response {
  use <- wisp.require_method(req, http.Delete)

  auth.with_auth(req, fn(_auth_result, _api_key, is_admin) {
    case is_admin {
      False -> {
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Forbidden")),
              #("message", json.string("Admin authentication required")),
            ]),
          ),
          403,
        )
      }
      True -> {
        // Simple version - no JSON body required
        case supabase_client.soft_delete_business(business_id, None, None) {
          Ok(message) -> {
            let _ =
              audit.log_action(
                "delete_business",
                "business",
                business_id,
                dict.new(),
              )
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("success", json.bool(True)),
                  #("message", json.string(message)),
                  #("business_id", json.string(business_id)),
                ]),
              ),
              200,
            )
          }
          Error(_) -> {
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("error", json.string("Failed to delete business")),
                ]),
              ),
              500,
            )
          }
        }
      }
    }
  })
}

pub fn restore_business(req: Request, business_id: String) -> Response {
  use <- wisp.require_method(req, http.Post)

  auth.with_auth(req, fn(_auth_result, _api_key, is_admin) {
    case is_admin {
      False -> {
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Forbidden")),
              #("message", json.string("Admin authentication required")),
            ]),
          ),
          403,
        )
      }
      True -> {
        case supabase_client.restore_deleted_business(business_id) {
          Ok(message) -> {
            // In restore_business - after successful restore (around line 865)
            let _ =
              audit.log_action(
                "restore_business",
                "business",
                business_id,
                dict.new(),
              )
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("success", json.bool(True)),
                  #("message", json.string(message)),
                ]),
              ),
              200,
            )
          }
          Error(_) -> {
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("error", json.string("Failed to restore business")),
                ]),
              ),
              500,
            )
          }
        }
      }
    }
  })
}

pub fn update_business_info(req: Request, business_id: String) -> Response {
  use <- wisp.require_method(req, http.Put)

  auth.with_auth(req, fn(_auth_result, _api_key, is_admin) {
    case is_admin {
      False -> {
        wisp.json_response(
          json.to_string_tree(
            json.object([
              #("error", json.string("Forbidden")),
              #("message", json.string("Admin authentication required")),
            ]),
          ),
          403,
        )
      }
      True -> {
        use json_data <- wisp.require_json(req)

        let decoder = {
          use business_name <- decode.field("business_name", decode.string)
          use email <- decode.field("email", decode.string)
          decode.success(#(business_name, email))
        }

        case decode.run(json_data, decoder) {
          Ok(#(business_name, email)) -> {
            case
              supabase_client.update_business_info(
                business_id,
                business_name,
                email,
              )
            {
              Ok(_) -> {
                wisp.json_response(
                  json.to_string_tree(
                    json.object([
                      #("success", json.bool(True)),
                      #("message", json.string("Business updated successfully")),
                    ]),
                  ),
                  200,
                )
              }
              Error(_) -> {
                wisp.json_response(
                  json.to_string_tree(
                    json.object([
                      #("error", json.string("Failed to update business")),
                    ]),
                  ),
                  500,
                )
              }
            }
          }
          Error(_) -> {
            wisp.json_response(
              json.to_string_tree(
                json.object([
                  #("error", json.string("Invalid request")),
                ]),
              ),
              400,
            )
          }
        }
      }
    }
  })
}

pub fn link_user_to_customer(
  req: Request,
  business_id: String,
  customer_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Post)
  use _auth_business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let decoder = {
    use user_id <- decode.field("user_id", decode.string)
    decode.success(user_id)
  }

  case decode.run(json_data, decoder) {
    Ok(user_id) -> {
      logging.log(
        logging.Info,
        "[CustomerHandler] Linking user "
          <> user_id
          <> " to customer "
          <> customer_id,
      )

      case
        supabase_client.link_user_to_customer(business_id, customer_id, user_id)
      {
        Ok(_) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("success", json.bool(True)),
                #("message", json.string("User linked to customer")),
              ]),
            ),
            200,
          )
        }
        Error(_) -> {
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("error", json.string("Failed to link user")),
              ]),
            ),
            500,
          )
        }
      }
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([#("error", json.string("Invalid request"))]),
        ),
        400,
      )
    }
  }
}

pub fn unlink_user_from_customer(
  req: Request,
  business_id: String,
  customer_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Post)
  use _auth_business_id <- with_auth(req)

  case supabase_client.unlink_user_from_customer(business_id, customer_id) {
    Ok(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([
            #("success", json.bool(True)),
            #("message", json.string("User unlinked from customer")),
          ]),
        ),
        200,
      )
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([#("error", json.string("Failed to unlink user"))]),
        ),
        500,
      )
    }
  }
}

/// Get or create customer for a user (used for auto-join)
pub fn get_or_create_customer_for_user(
  req: Request,
  business_id: String,
) -> Response {
  use <- wisp.require_method(req, http.Post)
  use _auth_business_id <- with_auth(req)
  use json_data <- wisp.require_json(req)

  let decoder = {
    use user_id <- decode.field("user_id", decode.string)
    use user_email <- decode.field("user_email", decode.string)
    decode.success(#(user_id, user_email))
  }

  case decode.run(json_data, decoder) {
    Ok(#(user_id, user_email)) -> {
      // Try to get existing customer by user_id first
      case supabase_client.get_customer_by_user_id(user_id, business_id) {
        // ✅ SIMPLER
        Ok(existing_customer) -> {
          // Customer already exists
          wisp.json_response(
            json.to_string_tree(
              json.object([
                #("customer_id", json.string(existing_customer.customer_id)),
                #("already_linked", json.bool(True)),
              ]),
            ),
            200,
          )
        }
        Error(_) -> {
          // Create new customer
          let customer_id =
            "cust_" <> string.replace(utils.generate_uuid(), "-", "")

          case
            supabase_client.create_customer(
              business_id,
              customer_id,
              user_email,
              "",
              option.Some(user_id),
              option.None,
            )
          {
            Ok(_) -> {
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("customer_id", json.string(customer_id)),
                    #("created_new", json.bool(True)),
                  ]),
                ),
                201,
              )
            }
            Error(err) -> {
              logging.log(
                logging.Error,
                "[UserHandler] Failed to create: " <> string.inspect(err),
              )
              wisp.json_response(
                json.to_string_tree(
                  json.object([
                    #("error", json.string("Failed to create customer")),
                  ]),
                ),
                500,
              )
            }
          }
        }
      }
    }
    Error(_) -> {
      wisp.json_response(
        json.to_string_tree(
          json.object([#("error", json.string("Invalid request"))]),
        ),
        400,
      )
    }
  }
}
