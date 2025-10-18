###############################################################################
# test_subscription_expiry.hurl
# Tests that expired subscriptions automatically use free tier limits
###############################################################################

# Step 1: Create business
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "ExpiryTest_{{test_id}}",
  "email": "expiry_{{test_id}}@test.com"
}
HTTP 201
[Captures]
business_id: jsonpath "$['business_id']"

# Step 2: Create business API key
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "key_type": "business",
  "key_name": "primary",
  "credentials": {
    "description": "Primary API Key"
  }
}
HTTP 201
[Captures]
business_key: jsonpath "$['api_key']"

# Step 3: Create FREE plan (api_calls: 10)
POST {{TRACKTAGS_URL}}/api/v1/plans
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_name": "free_plan"
}
HTTP 201
[Captures]
free_plan_id: jsonpath "$['id']"

# Step 4: Add free plan limit (10 api_calls)
POST {{TRACKTAGS_URL}}/api/v1/plan_limits
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_id": "{{free_plan_id}}",
  "metric_name": "api_calls",
  "limit_value": 10.0,
  "breach_operator": "gte",
  "breach_action": "deny",
  "metric_type": "reset"
}
HTTP 201

# Step 5: Create PAID plan (api_calls: 1000)
POST {{TRACKTAGS_URL}}/api/v1/plans
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_name": "pro_plan",
  "stripe_price_id": "price_pro_monthly"
}
HTTP 201
[Captures]
paid_plan_id: jsonpath "$['id']"

# Step 6: Add paid plan limit (1000 api_calls)
POST {{TRACKTAGS_URL}}/api/v1/plan_limits
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_id": "{{paid_plan_id}}",
  "metric_name": "api_calls",
  "limit_value": 1000.0,
  "breach_operator": "gte",
  "breach_action": "deny",
  "metric_type": "reset"
}
HTTP 201

# Step 7: Create customer on PAID plan
POST {{TRACKTAGS_URL}}/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "customer_id": "cust_expiry_{{test_id}}",
  "customer_name": "Expiry Test Customer",
  "plan_id": "{{paid_plan_id}}",
  "stripe_price_id": "price_pro_monthly"
}
HTTP 201
[Captures]
customer_id: jsonpath "$['customer_id']"

# Wait for CustomerActor to spawn and load plan limits
GET {{TRACKTAGS_URL}}/health
[Options]
delay: 3000
HTTP 200

# Step 8: Verify api_calls metric exists with paid limit (1000)
GET {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "api_calls"
jsonpath "$.current_value" == 0.0
jsonpath "$.limit_value" == 1000.0

# Step 9: Record 50 api_calls
POST {{TRACKTAGS_URL}}/api/v1/metrics?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "api_calls",
  "initial_value": 50.0,
  "operation": "SUM"
}
HTTP 201

# Wait for metric to be recorded
GET {{TRACKTAGS_URL}}/health
[Options]
delay: 2000
HTTP 200

###############################################################################
# TEST 1: Verify paid limits work (50 < 1000 = ALLOWED)
###############################################################################

POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "scope": "customer",
  "customer_id": "{{customer_id}}",
  "metric_name": "api_calls",
  "target_url": "{{PROXY_TARGET_URL}}/echo",
  "method": "GET"
}
HTTP 200
[Asserts]
jsonpath "$.status" == "allowed"
jsonpath "$.breach_status.is_breached" == false

###############################################################################
# TEST 2: Expire the subscription (set to past date)
###############################################################################

PUT {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "subscription_ends_at": "{{expired_date}}"
}
HTTP 200

###############################################################################
# TEST 3: Next proxy call should use FREE limits (50 > 10 = DENIED)
###############################################################################

POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "scope": "customer",
  "customer_id": "{{customer_id}}",
  "metric_name": "api_calls",
  "target_url": "{{PROXY_TARGET_URL}}/echo",
  "method": "GET"
}
HTTP 429
[Asserts]
jsonpath "$.status" == "denied"
jsonpath "$.breach_status.limit_value" == 10.0
jsonpath "$.breach_status.current_usage" == 50.0

###############################################################################
# TEST 4: Verify customer record unchanged in DB
###############################################################################

GET {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.plan_id" == "{{paid_plan_id}}"
jsonpath "$.subscription_ends_at" isString  # ← Just verify it exists and is a string

###############################################################################
# TEST 5: Re-activate subscription (set to future date)
###############################################################################

PUT {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "subscription_ends_at": "{{future_date}}"
}
HTTP 200

###############################################################################
# TEST 6: Paid limits restored (50 < 1000 = ALLOWED)
###############################################################################

POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "scope": "customer",
  "customer_id": "{{customer_id}}",
  "metric_name": "api_calls",
  "target_url": "{{PROXY_TARGET_URL}}/echo",
  "method": "GET"
}
HTTP 200
[Asserts]
jsonpath "$.status" == "allowed"
jsonpath "$.breach_status.limit_value" == 1000.0
jsonpath "$.breach_status.is_breached" == false

###############################################################################
# TEST 7: Customer created with ALREADY-EXPIRED subscription
###############################################################################

POST {{TRACKTAGS_URL}}/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "customer_id": "cust_expired_from_start_{{test_id}}",
  "customer_name": "Already Expired Customer",
  "plan_id": "{{paid_plan_id}}",
  "stripe_price_id": "price_pro_monthly",
  "subscription_ends_at": "{{expired_date}}"
}
HTTP 201
[Captures]
expired_customer_id: jsonpath "$['customer_id']"

# Wait for CustomerActor to spawn and check expiry
GET {{TRACKTAGS_URL}}/health
[Options]
delay: 3000
HTTP 200

# Record usage over free limit
POST {{TRACKTAGS_URL}}/api/v1/metrics?scope=customer&customer_id={{expired_customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "api_calls",
  "initial_value": 15.0,
  "operation": "SUM"
}
HTTP 201

# Wait for metric to be recorded
GET {{TRACKTAGS_URL}}/health
[Options]
delay: 1000
HTTP 200

# First proxy request should IMMEDIATELY enforce free limits
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "scope": "customer",
  "customer_id": "{{expired_customer_id}}",
  "metric_name": "api_calls",
  "target_url": "{{PROXY_TARGET_URL}}/echo",
  "method": "GET"
}
HTTP 429
[Asserts]
jsonpath "$.status" == "denied"
jsonpath "$.breach_status.limit_value" == 10.0
jsonpath "$.breach_status.current_usage" == 15.0
