# Complete TracktTags integration test with environment variables

# Step 1: Create business (admin operation)
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "Test Business {{test_id}}",
  "email": "test{{test_id}}@example.com"
}
HTTP 201
[Captures]
business_id: jsonpath "$.business_id"

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
business_key: jsonpath "$.api_key"    # <-- ADD THIS LINE

# Step 3: Verify business key with retries
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{business_key}}
[Options]
retry: 15
retry-interval: 2000
HTTP 200

# Step 4: Create customer
POST {{TRACKTAGS_URL}}/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "customer_id": "cust_{{test_id}}",
  "customer_name": "Test Customer",
  "email": "customer{{test_id}}@example.com",
  "plan_id": ""
}
HTTP 201
[Captures]
customer_id: jsonpath "$.customer_id"

# Step 5: Create customer API key (NEW ROUTE)
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

# Step 6: Verify customer key with retries
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{customer_key}}
[Options]
delay: 3000
retry: 15
retry-interval: 2000
HTTP 200

# Step 7: Business creates customer metric
POST {{TRACKTAGS_URL}}/api/v1/metrics?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "api_calls",
  "operation": "SUM",
  "metric_type": "reset",
  "flush_interval": "1m",
  "initial_value": 0.0,
  "limit_value": 10.0,
  "limit_operator": "gte",
  "breach_action": "deny"
}
HTTP 201

# Step 8: Verify metric exists with retries (use business key, not customer key)
GET {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 15
retry-interval: 2000
HTTP 200

# Step 9: Customer cannot update metric directly
PUT {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{customer_key}}
Content-Type: application/json
{"value": 1.0}
HTTP 403
[Asserts]
jsonpath "$.error" == "Forbidden"

# Step 10: Customer can use proxy (under limit)
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
[Options]
retry: 10
retry-interval: 500
{
  "scope": "customer",
  "metric_name": "api_calls",
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "POST",
  "body": "{\"test\": \"under_limit\"}"
}
HTTP 200
[Asserts]
jsonpath "$.status" == "allowed"
jsonpath "$.breach_status.is_breached" == false

# Step 10.5: Provision a machine for the customer (admin)
POST {{TRACKTAGS_URL}}/admin/provision/test
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "customer_id": "{{customer_id}}",
  "business_id": "{{business_id}}"
}
HTTP 200

# Step 10.6: Verify context updated with machine (via proxy headers)
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
{
  "scope": "customer",
  "metric_name": "api_calls", 
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "GET"
}
HTTP 200

# Step 10.6: Verify context updated with machine (via proxy headers)
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json

{
  "scope": "customer",
  "metric_name": "api_calls", 
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "GET"
}
HTTP 200
# The proxy should add X-TracktTags-Owned-Machines header with machine IDs

# Step 11: Business updates metric to limit
PUT {{TRACKTAGS_URL}}/api/v1/metrics/api_calls?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{"value": 10.0}
HTTP 200

# Step 12: Customer proxy request denied (at limit)
POST {{TRACKTAGS_URL}}/api/v1/proxy
Authorization: Bearer {{customer_key}}
Content-Type: application/json
{
  "scope": "customer",
  "metric_name": "api_calls",
  "target_url": "{{PROXY_TARGET_URL}}",
  "method": "POST",
  "body": "{\"test\": \"should_be_denied\"}"
}
HTTP 429
[Asserts]
jsonpath "$.status" == "denied"
jsonpath "$.breach_status.is_breached" == true
jsonpath "$.error" == "Plan limit exceeded"
