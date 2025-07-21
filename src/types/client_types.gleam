// src/types/client_types.gleam

pub type Client {
  Client(client_id: String, business_id: String, client_name: String)
}

pub type CustomerApiKey {
  CustomerApiKey(
    customer_uid: String,
    business_id: String,
    api_key: String,
    current_plan_id: String,
  )
}
