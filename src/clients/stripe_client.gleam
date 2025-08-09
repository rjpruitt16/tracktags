// src/clients/stripe_client.gleam
import clients/supabase_client
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import logging
import utils/crypto
import utils/utils

/// Report usage to Stripe - handles key lookup
pub fn report_usage(
  business_id: String,
  key_name: Option(String),
  subscription_item_id: String,
  quantity: Int,
  flush_ts: Int,
) -> Result(Nil, String) {
  // Get API key - either customer's or internal
  use api_key <- result.try(case key_name {
    Some(name) -> {
      // Customer provided their own key
      case supabase_client.get_integration_keys(business_id, Some("stripe")) {
        Ok(keys) -> {
          // Find the key with matching name
          case list.find(keys, fn(k) { k.key_name == name }) {
            Ok(key) -> {
              // decrypt -> parse JSON -> extract "secret_key"
              case crypto.decrypt_from_json(key.encrypted_key) {
                Ok(creds_json) -> {
                  let decoder =
                    decode.field("secret_key", decode.string, decode.success)
                  case json.parse(creds_json, decoder) {
                    Ok(secret_key) -> Ok(secret_key)
                    Error(_) -> Error("Failed to parse Stripe credentials")
                  }
                }
                Error(_) -> Error("Failed to decrypt Stripe key")
              }
            }
            Error(_) -> Error("Stripe key not found: " <> name)
          }
        }
        Error(_) -> Error("Failed to fetch integration keys")
      }
    }
    None -> Ok(utils.get_env_or("STRIPE_API_KEY", ""))
  })

  // Check if we actually got a key
  case api_key {
    "" -> Error("No Stripe API key configured")
    _ -> {
      // Body uses the flush timestamp we were passed
      let body =
        "quantity="
        <> int.to_string(quantity)
        <> "&timestamp="
        <> int.to_string(flush_ts)
        <> "&action=increment"

      // Keep Idempotency-Key = flush_ts (simple + safe per flush)
      let req =
        request.new()
        |> request.set_header("Idempotency-Key", int.to_string(flush_ts))
        |> request.set_method(http.Post)
        |> request.set_scheme(http.Https)
        |> request.set_host("api.stripe.com")
        |> request.set_path(
          "/v1/subscription_items/" <> subscription_item_id <> "/usage_records",
        )
        |> request.set_header("Authorization", "Bearer " <> api_key)
        |> request.set_header(
          "Content-Type",
          "application/x-www-form-urlencoded",
        )
        |> request.set_body(body)

      case httpc.send(req) {
        Ok(resp) if resp.status >= 200 && resp.status < 300 -> {
          logging.log(logging.Info, "[StripeClient] ✅ Reported usage to Stripe")
          Ok(Nil)
        }
        Ok(resp) -> Error("Stripe API error: " <> int.to_string(resp.status))
        Error(_) -> Error("HTTP request failed")
      }
    }
  }
}
