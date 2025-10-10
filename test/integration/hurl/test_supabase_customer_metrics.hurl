# Test: Customer-scoped metrics flush correctly

# Step 1: Health check
GET {{TRACKTAGS_URL}}/health
HTTP 200

# Step 2: Create test business
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "test_customer_metric_{{test_id}}",
  "email": "customer_metric_{{test_id}}@example.com"
}
HTTP 201
[Captures]
business_id: jsonpath "$.business_id"

# Step 3: Create business API key
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "key_type": "business",
  "key_name": "customer_key_{{test_id}}",
  "credentials": {
    "description": "Customer Test Key"
  }
}
HTTP 201
[Captures]
business_key: jsonpath "$.api_key"

# Step 4: Verify key works
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{business_key}}
[Options]
retry: 15
retry-interval: 2000
HTTP 200

# Step 5: Create customer
POST {{TRACKTAGS_URL}}/api/v1/customers
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "customer_id": "customer_{{test_id}}",
  "customer_name": "Test Customer",
  "email": "customer_{{test_id}}@example.com",
  "plan_id": ""
}
HTTP 201
[Captures]
customer_id: jsonpath "$.customer_id"

# Step 6: Create customer-scoped metric
POST {{TRACKTAGS_URL}}/api/v1/metrics?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "customer_api_{{test_id}}",
  "operation": "SUM",
  "flush_interval": "5s",
  "metric_type": "checkpoint",
  "initial_value": 100.0,
  "metadata": {
    "integrations": {
      "supabase": {
        "enabled": true,
        "batch_interval": "5s"
      }
    }
  }
}
HTTP 201
[Captures]
customer_metric: jsonpath "$.metric_name"

# Step 7: Add value to customer metric (retry until metric actor is ready)
PUT {{TRACKTAGS_URL}}/api/v1/metrics/{{customer_metric}}?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
[Options]
retry: 10
retry-interval: 500
{
  "value": 50.0
}
HTTP 200

# Step 8: Verify customer metric flushes with correct scope
GET {{SUPABASE_URL}}/rest/v1/metrics?business_id=eq.{{business_id}}&customer_id=eq.{{customer_id}}&metric_name=eq.{{customer_metric}}&select=*&order=flushed_at.desc&limit=1
apikey: {{SUPABASE_ANON_KEY}}
Authorization: Bearer {{SUPABASE_ANON_KEY}}
[Options]
delay: 12000
retry: 10
retry-interval: 2000
HTTP 200
[Asserts]
jsonpath "$" count > 0
jsonpath "$[0].metric_name" == "{{customer_metric}}"
jsonpath "$[0].business_id" == "{{business_id}}"
jsonpath "$[0].customer_id" == "{{customer_id}}"
jsonpath "$[0].value" >= 150.0
jsonpath "$[0].scope" == "customer"

# Cleanup
DELETE {{TRACKTAGS_URL}}/api/v1/metrics/{{customer_metric}}?scope=customer&customer_id={{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
HTTP 200

DELETE {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
HTTP 200

DELETE {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
HTTP 200
