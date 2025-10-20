# test/integration/hurl/test_checkpoint_with_atomic_increment.hurl
# Test: Checkpoint metrics with atomic increment RPC

### STEP 1: Health check ###
GET {{TRACKTAGS_URL}}/health
HTTP 200
[Asserts]
body == "OK"

### STEP 2: Create test business ###
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "test_atomic_{{test_id}}",
  "email": "atomic_{{test_id}}@example.com"
}
HTTP 201
[Captures]
business_id: jsonpath "$.business_id"

### STEP 3: Create business API key ###
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "key_type": "business",
  "key_name": "atomic_key_{{test_id}}",
  "credentials": {}
}
HTTP 201
[Captures]
business_key: jsonpath "$.api_key"

### STEP 4: Verify key works ###
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{business_key}}
[Options]
retry: 15
retry-interval: 2000
HTTP 200

### STEP 5: Create customer ###
POST {{TRACKTAGS_URL}}/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
[Options]
retry: 30
retry-interval: 500
{
  "customer_id": "cust_checkpoint_increment_{{test_id}}",
  "customer_name": "test_customer_{{test_id}}",
  "email": "customer_{{test_id}}@example.com",
  "plan_id": ""
}
HTTP 201
[Captures]
customer_id: jsonpath "$.customer_id"

### STEP 6: Create customer API key ###
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/customers/{{customer_id}}/keys
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "key_type": "customer_api",
  "key_name": "{{customer_id}}",
  "credentials": {}
}
HTTP 201
[Captures]
customer_key: jsonpath "$.api_key"

### STEP 7: Create checkpoint metric for customer ###
POST {{TRACKTAGS_URL}}/api/v1/metrics?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "jobs_submitted",
  "operation": "SUM",
  "flush_interval": "5s",
  "cleanup_after": "1d",
  "metric_type": "checkpoint",
  "initial_value": 0.0
}
HTTP 201

### STEP 8: Wait for metric actor to initialize ###
GET {{TRACKTAGS_URL}}/api/v1/metrics/jobs_submitted?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
[Options]
retry: 10
retry-interval: 1000
HTTP 200

### STEP 9: Increment via PUT ###
PUT {{TRACKTAGS_URL}}/api/v1/metrics/jobs_submitted?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "value": 1.0
}
HTTP 200

### STEP 10: Verify metric incremented ###
GET {{TRACKTAGS_URL}}/api/v1/metrics/jobs_submitted?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.current_value" == 1.0

### STEP 11: Increment again ###
PUT {{TRACKTAGS_URL}}/api/v1/metrics/jobs_submitted?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "value": 1.0
}
HTTP 200

### STEP 12: Verify accumulation ###
GET {{TRACKTAGS_URL}}/api/v1/metrics/jobs_submitted?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.current_value" == 2.0

### STEP 13: Wait for flush to Supabase ###
GET {{SUPABASE_URL}}/rest/v1/metrics?business_id=eq.{{business_id}}&customer_id=eq.{{customer_id}}&metric_name=eq.jobs_submitted&select=*&order=flushed_at.desc&limit=1
apikey: {{SUPABASE_ANON_KEY}}
Authorization: Bearer {{SUPABASE_ANON_KEY}}
[Options]
delay: 8000
retry: 5
retry-interval: 2000
HTTP 200
[Asserts]
jsonpath "$" count > 0
jsonpath "$[0].value" >= 2.0

### CLEANUP ###
DELETE {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
HTTP 200

DELETE {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}
X-Admin-Key: {{ADMIN_SECRET_KEY}}
HTTP 200
