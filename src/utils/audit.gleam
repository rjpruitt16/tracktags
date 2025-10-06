import clients/supabase_client
import gleam/dict.{type Dict}
import gleam/json

/// Log an admin action to the audit trail
pub fn log_action(
  action: String,
  resource_type: String,
  resource_id: String,
  details: Dict(String, json.Json),
) -> Nil {
  let details_json = json.object(dict.to_list(details))

  let _ =
    supabase_client.insert_audit_log(
      "admin",
      action,
      resource_type,
      resource_id,
      details_json,
    )

  Nil
}
