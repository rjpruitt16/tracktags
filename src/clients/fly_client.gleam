// src/clients/fly_client.gleam
import clients/supabase_client
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import utils/crypto
import utils/utils

// Types
pub type FlyMachine {
  FlyMachine(
    id: String,
    name: String,
    state: String,
    region: String,
    private_ip: String,
    created_at: String,
  )
}

pub type FlyError {
  ApiError(String)
  NetworkError(String)
  ParseError(String)
  NotFound(String)
  Unauthorized(String)
}

// Add mock mode support to create_machine
pub fn create_machine(
  api_token: String,
  org_slug: String,
  app_name: String,
  region: String,
  size: String,
  docker_image: String,
) -> Result(FlyMachine, FlyError) {
  // Check for mock mode
  case utils.get_env_or("MOCK_MODE", "false") {
    "true" -> {
      logging.log(logging.Info, "[FlyClient] MOCK MODE - Creating fake machine")
      let timestamp = utils.current_timestamp()
      Ok(FlyMachine(
        id: "mock_" <> int.to_string(timestamp),
        name: app_name,
        state: "started",
        region: region,
        private_ip: "10.0.0." <> int.to_string(timestamp % 254 + 1),
        created_at: int.to_string(timestamp),
      ))
    }
    _ -> {
      // Original implementation
      logging.log(
        logging.Info,
        "[FlyClient] Creating machine: " <> app_name <> " in " <> region,
      )

      let _ = ensure_app_exists(api_token, org_slug, app_name)

      let machine_config =
        json.object([
          #("name", json.string(app_name)),
          #("region", json.string(region)),
          #(
            "config",
            json.object([
              #("image", json.string(docker_image)),
              #(
                "guest",
                json.object([
                  #("cpu_kind", json.string("shared")),
                  #(
                    "cpus",
                    json.int(case size {
                      "shared-cpu-1x" -> 1
                      "shared-cpu-2x" -> 2
                      "shared-cpu-4x" -> 4
                      "shared-cpu-8x" -> 8
                      _ -> 1
                    }),
                  ),
                  #(
                    "memory_mb",
                    json.int(case size {
                      "shared-cpu-1x" -> 256
                      "shared-cpu-2x" -> 512
                      "shared-cpu-4x" -> 1024
                      "shared-cpu-8x" -> 2048
                      _ -> 256
                    }),
                  ),
                ]),
              ),
              #("env", json.object([])),
              #("services", json.array([], fn(x) { x })),
            ]),
          ),
        ])

      let url = "https://api.machines.dev/v1/apps/" <> app_name <> "/machines"

      case
        make_fly_request(
          api_token,
          http.Post,
          url,
          Some(json.to_string(machine_config)),
        )
      {
        Ok(response) -> {
          case response.status {
            201 | 200 -> parse_machine_response(response.body)
            _ -> Error(ApiError("Failed to create machine: " <> response.body))
          }
        }
        Error(err) -> Error(err)
      }
    }
  }
}

// Ensure app exists (create if not)
fn ensure_app_exists(
  api_token: String,
  org_slug: String,
  app_name: String,
) -> Result(Nil, FlyError) {
  let url = "https://api.machines.dev/v1/apps/" <> app_name

  // Check if app exists
  case make_fly_request(api_token, http.Get, url, None) {
    Ok(response) -> {
      case response.status {
        200 -> Ok(Nil)
        // App exists
        404 -> {
          // Create app
          let app_config =
            json.object([
              #("app_name", json.string(app_name)),
              #("org_slug", json.string(org_slug)),
            ])

          case
            make_fly_request(
              api_token,
              http.Post,
              "https://api.machines.dev/v1/apps",
              Some(json.to_string(app_config)),
            )
          {
            Ok(create_response) -> {
              case create_response.status {
                201 | 200 -> Ok(Nil)
                _ -> Error(ApiError("Failed to create app"))
              }
            }
            Error(err) -> Error(err)
          }
        }
        _ -> Error(ApiError("Failed to check app existence"))
      }
    }
    Error(err) -> Error(err)
  }
}

// Add mock mode support to terminate_machine
pub fn terminate_machine(
  api_token: String,
  app_name: String,
  machine_id: String,
) -> Result(Nil, FlyError) {
  case utils.get_env_or("MOCK_MODE", "false") {
    "true" -> {
      logging.log(
        logging.Info,
        "[FlyClient] MOCK MODE - Terminating machine: " <> machine_id,
      )
      case string.starts_with(machine_id, "mock_") {
        True -> Ok(Nil)
        False ->
          Error(ApiError(
            "Mock mode: Cannot terminate non-mock machine: " <> machine_id,
          ))
      }
    }
    _ -> {
      // Original implementation
      logging.log(
        logging.Info,
        "[FlyClient] Terminating machine: " <> machine_id,
      )

      let stop_url =
        "https://api.machines.dev/v1/apps/"
        <> app_name
        <> "/machines/"
        <> machine_id
        <> "/stop"
      let _ = make_fly_request(api_token, http.Post, stop_url, None)

      let delete_url =
        "https://api.machines.dev/v1/apps/"
        <> app_name
        <> "/machines/"
        <> machine_id

      case make_fly_request(api_token, http.Delete, delete_url, None) {
        Ok(response) -> {
          case response.status {
            200 | 204 -> Ok(Nil)
            404 -> Ok(Nil)
            _ -> Error(ApiError("Failed to terminate machine"))
          }
        }
        Error(err) -> Error(err)
      }
    }
  }
}

// List machines for an app
pub fn list_machines(
  api_token: String,
  app_name: String,
) -> Result(List(FlyMachine), FlyError) {
  logging.log(
    logging.Info,
    "[FlyClient] Listing machines for app: " <> app_name,
  )

  let url = "https://api.machines.dev/v1/apps/" <> app_name <> "/machines"

  case make_fly_request(api_token, http.Get, url, None) {
    Ok(response) -> {
      case response.status {
        200 -> parse_machines_list(response.body)
        404 -> Ok([])
        // App doesn't exist, no machines
        _ -> Error(ApiError("Failed to list machines"))
      }
    }
    Error(err) -> Error(err)
  }
}

// Helper to make authenticated requests to Fly API
fn make_fly_request(
  api_token: String,
  method: http.Method,
  url: String,
  body: Option(String),
) -> Result(response.Response(String), FlyError) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("Invalid URL: " <> url) }),
  )

  let req_with_headers =
    req
    |> request.set_header("Authorization", "Bearer " <> api_token)
    |> request.set_header("Content-Type", "application/json")
    |> request.set_method(method)

  let final_req = case body {
    Some(json_body) -> request.set_body(req_with_headers, json_body)
    None -> req_with_headers
  }

  case httpc.send(final_req) {
    Ok(response) -> Ok(response)
    Error(err) -> {
      logging.log(
        logging.Error,
        "[FlyClient] Request failed: " <> string.inspect(err),
      )
      Error(NetworkError("Request failed"))
    }
  }
}

// Parse machine response
fn parse_machine_response(body: String) -> Result(FlyMachine, FlyError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use state <- decode.field("state", decode.string)
    use region <- decode.field("region", decode.string)
    use private_ip <- decode.optional_field("private_ip", "", decode.string)
    use created_at <- decode.field("created_at", decode.string)

    decode.success(FlyMachine(
      id: id,
      name: name,
      state: state,
      region: region,
      private_ip: private_ip,
      created_at: created_at,
    ))
  }

  case json.parse(body, decoder) {
    Ok(machine) -> Ok(machine)
    Error(_) -> Error(ParseError("Invalid machine response"))
  }
}

// Parse list of machines
fn parse_machines_list(body: String) -> Result(List(FlyMachine), FlyError) {
  case json.parse(body, decode.list(parse_machine_decoder())) {
    Ok(machines) -> Ok(machines)
    Error(_) -> Error(ParseError("Invalid machines list"))
  }
}

fn parse_machine_decoder() -> decode.Decoder(FlyMachine) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use state <- decode.field("state", decode.string)
  use region <- decode.field("region", decode.string)
  use private_ip <- decode.optional_field("private_ip", "", decode.string)
  use created_at <- decode.field("created_at", decode.string)

  decode.success(FlyMachine(
    id: id,
    name: name,
    state: state,
    region: region,
    private_ip: private_ip,
    created_at: created_at,
  ))
}

// Helper to get Fly credentials from integration_keys
pub fn get_fly_credentials(
  business_id: String,
) -> Result(#(String, String, String), String) {
  case supabase_client.get_integration_keys(business_id, Some("fly")) {
    Ok([key, ..]) -> {
      case crypto.decrypt_from_json(key.encrypted_key) {
        Ok(decrypted) -> {
          // Parse the JSON to get credentials
          let creds_decoder = {
            use api_token <- decode.field("api_token", decode.string)
            use org_slug <- decode.field("org_slug", decode.string)
            use default_region <- decode.optional_field(
              "default_region",
              "iad",
              decode.string,
            )
            decode.success(#(api_token, org_slug, default_region))
          }

          case json.parse(decrypted, creds_decoder) {
            Ok(creds) -> Ok(creds)
            Error(_) -> Error("Invalid Fly credentials format")
          }
        }
        Error(_) -> Error("Failed to decrypt Fly credentials")
      }
    }
    Ok([]) -> Error("No Fly credentials configured for business")
    Error(_) -> Error("Failed to fetch Fly credentials")
  }
}
