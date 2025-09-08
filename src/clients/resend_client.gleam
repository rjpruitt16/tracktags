// src/clients/resend_client.gleam
import clients/supabase_client
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/string
import logging
import utils/utils

pub type EmailError {
  SendFailed(String)
  NoApiKey
  NoEmail
}

// Store API key at module level after validation

pub fn send_provision_failed(
  business_id: String,
  customer_id: String,
  error_message: String,
  attempt_count: Int,
) -> Result(Nil, EmailError) {
  // Get business email from database
  case supabase_client.get_business(business_id) {
    Ok(business) -> {
      send_email(
        business.email,
        "Machine Provisioning Failed - " <> customer_id,
        provision_failed_template(customer_id, error_message, attempt_count),
      )
    }
    Error(_) -> {
      logging.log(
        logging.Error,
        "[Resend] Could not find business email for: " <> business_id,
      )
      Error(NoEmail)
    }
  }
}

pub fn send_all_terminated(
  business_id: String,
  customer_id: String,
  machine_count: Int,
) -> Result(Nil, EmailError) {
  case supabase_client.get_business(business_id) {
    Ok(business) -> {
      send_email(
        business.email,
        "All Machines Terminated - " <> customer_id,
        terminated_template(customer_id, machine_count),
      )
    }
    Error(_) -> {
      logging.log(
        logging.Error,
        "[Resend] Could not find business email for: " <> business_id,
      )
      Error(NoEmail)
    }
  }
}

fn send_email(
  to: String,
  subject: String,
  html: String,
) -> Result(Nil, EmailError) {
  let api_key = utils.require_env("RESEND_API_KEY")

  let body =
    json.object([
      #("from", json.string("TrackerTags <noreply@trackertags.com>")),
      #("to", json.array([json.string(to)], fn(x) { x })),
      #("subject", json.string(subject)),
      #("html", json.string(html)),
    ])

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("api.resend.com")
    |> request.set_path("/emails")
    |> request.set_header("Authorization", "Bearer " <> api_key)
    |> request.set_header("Content-Type", "application/json")
    |> request.set_body(json.to_string(body))

  case httpc.send(req) {
    Ok(resp) if resp.status >= 200 && resp.status < 300 -> {
      logging.log(logging.Info, "[Resend] Email sent to: " <> to)
      Ok(Nil)
    }
    Ok(resp) -> {
      logging.log(
        logging.Error,
        "[Resend] Failed with status "
          <> int.to_string(resp.status)
          <> " Body: "
          <> resp.body,
      )
      Error(SendFailed("HTTP " <> int.to_string(resp.status)))
    }
    Error(e) -> Error(SendFailed(string.inspect(e)))
  }
}

fn provision_failed_template(
  customer_id: String,
  error: String,
  attempts: Int,
) -> String {
  "<div style='font-family: sans-serif; max-width: 600px; margin: 0 auto;'>
    <h2 style='color: #dc2626;'>Machine Provisioning Failed</h2>
    <p>We were unable to provision machines for customer: <strong>" <> customer_id <> "</strong></p>
    <p style='background: #fef2f2; border-left: 4px solid #dc2626; padding: 12px; margin: 16px 0;'>
      <strong>Error:</strong> " <> error <> "<br>
      <strong>Attempts:</strong> " <> int.to_string(attempts) <> "
    </p>
    <p>Please check your Fly.io credentials and account limits.</p>
    <p style='color: #6b7280; font-size: 14px; margin-top: 32px;'>
      TrackerTags Team
    </p>
  </div>"
}

fn terminated_template(customer_id: String, count: Int) -> String {
  "<div style='font-family: sans-serif; max-width: 600px; margin: 0 auto;'>
    <h2>Machines Terminated</h2>
    <p>All " <> int.to_string(count) <> " machines for customer <strong>" <> customer_id <> "</strong> have been terminated.</p>
    <p style='color: #6b7280; font-size: 14px; margin-top: 32px;'>
      TrackerTags Team
    </p>
  </div>"
}
