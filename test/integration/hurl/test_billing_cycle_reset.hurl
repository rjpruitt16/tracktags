# test_billing_cycle_reset.hurl
# Tests that plan limit metrics reset properly during billing cycle

###############################################################################
# SETUP: Create business, plan, and customer with plan limits
###############################################################################

# Step 1: Create business with unique name
POST http://localhost:8080/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "BillingCycleTest_{{test_id}}",
  "email": "billing_{{test_id}}@test.com"
}
HTTP 201
[Captures]
business_id: jsonpath "$['business_id']"

# Step 2: Create business API key
POST http://localhost:8080/api/v1/businesses/{{business_id}}/keys
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

# Step 3: Create plan with Stripe price
POST http://localhost:8080/api/v1/plans
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_name": "pro_plan",
  "stripe_price_id": "price_pro_monthly"
}
HTTP 201
[Captures]
plan_id: jsonpath "$['id']"

# Step 4: Add api_calls plan limit (1000)
POST http://localhost:8080/api/v1/plan_limits
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_id": "{{plan_id}}",
  "metric_name": "api_calls",
  "limit_value": 1000.0,
  "breach_operator": "gte",
  "breach_action": "deny",
  "metric_type": "reset"
}
HTTP 201

# Step 5: Add storage_gb plan limit (50)
POST http://localhost:8080/api/v1/plan_limits
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_id": "{{plan_id}}",
  "metric_name": "storage_gb",
  "limit_value": 50.0,
  "breach_operator": "gte",
  "breach_action": "deny",
  "metric_type": "reset"
}
HTTP 201

# Step 6: Create customer with plan
POST http://localhost:8080/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "customer_id": "cust_billing_{{test_id}}",
  "customer_name": "Billing Test Customer",
  "plan_id": "{{plan_id}}"
}
HTTP 201
[Captures]
customer_id: jsonpath "$['customer_id']"

# Step 7: Update customer with Stripe metadata
PUT http://localhost:8080/api/v1/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "stripe_price_id": "price_pro_monthly"
}
HTTP 200

# Wait for CustomerActor to spawn and load plan limits
GET http://localhost:8080/health
[Options]
delay: 3000
HTTP 200

###############################################################################
# TEST 1: Verify plan limits are active (metrics exist with value 0)
###############################################################################

GET http://localhost:8080/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "api_calls"
jsonpath "$.current_value" == 0.0

GET http://localhost:8080/api/v1/metrics/storage_gb?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "storage_gb"
jsonpath "$.current_value" == 0.0

###############################################################################
# TEST 2: Record usage - increment api_calls to 150
###############################################################################

POST http://localhost:8080/api/v1/metrics?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "api_calls",
  "initial_value": 150.0,
  "operation": "SUM"
}
HTTP 201

# Wait for metric to be recorded
GET http://localhost:8080/health
[Options]
delay: 1000
HTTP 200

###############################################################################
# TEST 3: Verify usage accumulated to 150
###############################################################################

GET http://localhost:8080/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "api_calls"
jsonpath "$.current_value" == 150.0

###############################################################################
# TEST 4: Manually reset billing metrics (simulating invoice.finalized)
###############################################################################

POST http://localhost:8080/admin/v1/customers/{{business_id}}/{{customer_id}}/reset-billing
X-Admin-Key: {{ADMIN_SECRET_KEY}}
HTTP 200

###############################################################################
# TEST 5: Verify metrics reset to 0 after billing cycle (with retry)
###############################################################################

# Poll api_calls until it resets to 0 (max 10 retries, 500ms between)
GET http://localhost:8080/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 500
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "api_calls"
jsonpath "$.current_value" == 0.0

# Poll storage_gb until it resets to 0
GET http://localhost:8080/api/v1/metrics/storage_gb?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 500
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "storage_gb"
jsonpath "$.current_value" == 0.0

###############################################################################
# TEST 6: Verify plan limits still active (can record new usage)
###############################################################################

POST http://localhost:8080/api/v1/metrics?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "api_calls",
  "initial_value": 50.0,
  "operation": "SUM"
}
HTTP 201

# Wait for metric update
GET http://localhost:8080/health
[Options]
delay: 1000
HTTP 200

# Verify new usage recorded
GET http://localhost:8080/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "api_calls"
jsonpath "$.current_value" == 50.0

###############################################################################
# TEST 7: Verify limit enforcement still works
###############################################################################

# Record api_calls to 1001 (over the 1000 limit)
POST http://localhost:8080/api/v1/metrics?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "api_calls",
  "initial_value": 951.0,
  "operation": "SUM"
}
HTTP 201  # ← Recording SUCCEEDS (metrics are for monitoring)

# Wait for metric to update
GET http://localhost:8080/health
[Options]
delay: 1000
HTTP 200

# Verify we're now over the limit
GET http://localhost:8080/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.metric_name" == "api_calls"
jsonpath "$.current_value" == 1001.0
jsonpath "$.limit_breached" == true

# Now try to USE the proxy - should be DENIED
POST http://localhost:8080/api/v1/proxy
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "scope": "customer",
  "customer_id": "{{customer_id}}",
  "metric_name": "api_calls",
  "target_url": "https://httpbin.org/get",
  "method": "GET"
}
HTTP 429  # ← Proxy DENIES because limit breached
[Asserts]
jsonpath "$.status" == "denied"
jsonpath "$.breach_status.is_breached" == true
