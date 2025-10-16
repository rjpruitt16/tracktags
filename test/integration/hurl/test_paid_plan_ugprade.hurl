# test/integration/hurl/test_paid_plan_upgrade.hurl
# Test: Paid Plan Upgrade Flow

### STEP 1: Create Business ###
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "UpgradeTest_{{test_id}}",
  "email": "upgrade_{{test_id}}@test.com"
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

### STEP 3: Verify business key ###
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 1000
HTTP 200

### STEP 4: Create FREE Plan ###
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

### STEP 5: Add FREE plan limit (10 api_calls) ###
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

### STEP 6: Create PAID Plan ###
POST {{TRACKTAGS_URL}}/api/v1/plans
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_name": "pro_{{test_id}}",
  "stripe_price_id": "price_pro_{{test_id}}"
}
HTTP 201
[Captures]
paid_plan_id: jsonpath "$.id"
paid_price_id: jsonpath "$.stripe_price_id"

### STEP 7: Add PAID plan limit (1000 api_calls) ###
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

### STEP 8: Create Customer on FREE plan ###
POST {{TRACKTAGS_URL}}/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "customer_id": "cust_{{test_id}}",
  "customer_name": "UpgradeCustomer_{{test_id}}",
  "plan_id": "{{free_plan_id}}"
}
HTTP 201
[Captures]
customer_id: jsonpath "$.customer_id"

### STEP 9: Create Customer API Key ###
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

### STEP 10: Wait for customer actor to load ###
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{customer_key}}
[Options]
delay: 2000
retry: 10
retry-interval: 1000
HTTP 200

### TEST 1: Verify FREE plan limits are active (10 api_calls) ###
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
  "body": "{\"test\": \"free_tier\"}"
}
HTTP 200
[Asserts]
jsonpath "$.status" == "allowed"

### TEST 2: Breach FREE tier limit (set to 15) ###
PUT {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "value": 15.0
}
HTTP 200

### TEST 3: Wait for update ###
GET {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 500
HTTP 200
[Asserts]
jsonpath "$.current_value" >= 15.0

### TEST 4: Verify denied on FREE tier ###
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
{
  "scope": "customer",
  "metric_name": "",
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "POST",
  "body": "{\"test\": \"should_deny\"}"
}
HTTP 429
[Asserts]
jsonpath "$.status" == "denied"

### TEST 5: Simulate Stripe upgrade - update customer to PAID plan ###
PUT {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "plan_id": "{{paid_plan_id}}",
  "stripe_price_id": "{{paid_price_id}}"
}
HTTP 200

### TEST 6: Wait for customer actor to reload with new plan ###
GET {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 1000
HTTP 200
[Asserts]
jsonpath "$.plan_id" == "{{paid_plan_id}}"

### TEST 7: Proxy should NOW be allowed (15 < 1000 on PAID tier) ###
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
  "body": "{\"test\": \"paid_tier_allowed\"}"
}
HTTP 200
[Asserts]
jsonpath "$.status" == "allowed"

### TEST 8: Breach PAID tier limit (set to 1500) ###
PUT {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "value": 1500.0
}
HTTP 200

### TEST 9: Wait for update ###
GET {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 500
HTTP 200
[Asserts]
jsonpath "$.current_value" >= 1500.0

### TEST 10: Now denied on PAID tier (1500 > 1000) ###
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
{
  "scope": "customer",
  "metric_name": "",
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "POST",
  "body": "{\"test\": \"paid_deny\"}"
}
HTTP 429
[Asserts]
jsonpath "$.status" == "denied"
