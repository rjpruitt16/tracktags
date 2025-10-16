## test/integration/hurl/test_free_plan_limits.hurl
# Test: Free Plan Limit Enforcement

### STEP 1: Create Business ###
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "FreePlanTest_{{test_id}}",
  "email": "freeplan_{{test_id}}@test.com"
}
HTTP 201
[Captures]
business_id: jsonpath "$.business_id"

### STEP 2: Create Business API Key ###
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
business_key: jsonpath "$.api_key"

### STEP 3: Verify business key works ###
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 1000
HTTP 200

### STEP 4: Create FREE Plan (no stripe_price_id) ###
POST {{TRACKTAGS_URL}}/api/v1/plans
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_name": "free_{{test_id}}",
  "stripe_price_id": null
}
HTTP 201
[Captures]
free_plan_id: jsonpath "$.id"

### STEP 5: Add api_calls limit (10 calls) to FREE plan ###
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

### STEP 6: Add storage_mb limit (100 MB) to FREE plan ###
POST {{TRACKTAGS_URL}}/api/v1/plan_limits
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_id": "{{free_plan_id}}",
  "metric_name": "storage_mb",
  "limit_value": 100.0,
  "breach_operator": "gte",
  "breach_action": "deny",
  "metric_type": "reset"
}
HTTP 201

### STEP 7: Create Customer on FREE plan ###
POST {{TRACKTAGS_URL}}/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "customer_id": "cust_{{test_id}}",
  "customer_name": "FreeCustomer_{{test_id}}",
  "plan_id": "{{free_plan_id}}"
}
HTTP 201
[Captures]
customer_id: jsonpath "$.customer_id"

### STEP 8: Create Customer API Key ###
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/customers/{{customer_id}}/keys
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "key_type": "customer_api",
  "key_name": "{{customer_id}}",
  "credentials": {
    "description": "Customer API Key"
  }
}
HTTP 201
[Captures]
customer_key: jsonpath "$.api_key"

### STEP 9: Verify customer key works (wait for customer actor to load) ###
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{customer_key}}
[Options]
delay: 2000
retry: 10
retry-interval: 1000
HTTP 200

### TEST 1: First proxy call - should be ALLOWED (metrics at 0, limits are 10 and 100) ###
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
[Options]
retry: 10
retry-interval: 1000
{
  "scope": "customer",
  "metric_name": "",
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "POST",
  "body": "{\"test\": \"free_plan_ok\"}"
}
HTTP 200
[Asserts]
jsonpath "$.status" == "allowed"

### TEST 2: Breach api_calls limit - update to 15 (over limit of 10) ###
PUT {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "value": 15.0
}
HTTP 200

### TEST 3: Wait for metric update to propagate ###
GET {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 15
retry-interval: 1000
HTTP 200
[Asserts]
jsonpath "$.current_value" >= 15.0

### TEST 4: Proxy request should be DENIED (api_calls is 15, limit is 10) ###
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
[Options]
retry: 5
retry-interval: 1000
{
  "scope": "customer",
  "metric_name": "",
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "POST",
  "body": "{\"test\": \"should_be_denied\"}"
}
HTTP 429
[Asserts]
jsonpath "$.status" == "denied"
jsonpath "$.breach_status.is_breached" == true
jsonpath "$.error" == "Plan limit exceeded"

### TEST 5: storage_mb should still be OK (only checking storage_mb metric) ###
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
{
  "scope": "customer",
  "metric_name": "storage_mb",
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "POST"
}
HTTP 200
[Asserts]
jsonpath "$.status" == "allowed"
jsonpath "$.breach_status.is_breached" == false
