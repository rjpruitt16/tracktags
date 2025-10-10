# Test: Checkpoint metrics accumulate and flush to Supabase

# Step 1: Health check
GET {{TRACKTAGS_URL}}/health
HTTP 200
[Asserts]
body == "OK"

# Step 2: Create test business
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "test_checkpoint_{{test_id}}",
  "email": "checkpoint_{{test_id}}@example.com"
}
HTTP 201
[Asserts]
jsonpath "$.business_id" exists
[Captures]
business_id: jsonpath "$.business_id"

# Step 3: Create business API key
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "key_type": "business",
  "key_name": "checkpoint_key_{{test_id}}",
  "credentials": {
    "description": "Checkpoint Test Key"
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

# Step 5: Create checkpoint metric
POST {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "checkpoint_{{test_id}}",
  "operation": "SUM",
  "flush_interval": "5s",
  "cleanup_after": "1d",
  "metric_type": "checkpoint",
  "initial_value": 100.0,
  "metadata": {
    "integrations": {
      "supabase": {
        "enabled": true,
        "batch_interval": "5s",
        "restore_on_startup": false
      }
    }
  }
}
HTTP 201
[Captures]
checkpoint_metric: jsonpath "$.metric_name"

# Step 6: Add value to checkpoint metric (retry until metric actor is ready)
PUT {{TRACKTAGS_URL}}/api/v1/metrics/{{checkpoint_metric}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
[Options]
retry: 10
retry-interval: 500
{
  "value": 50.0
}
HTTP 200

# Step 7: Verify first flush to Supabase (should be 150 = 100 + 50)
GET {{SUPABASE_URL}}/rest/v1/metrics?business_id=eq.{{business_id}}&metric_name=eq.{{checkpoint_metric}}&select=*&order=flushed_at.desc&limit=1
apikey: {{SUPABASE_ANON_KEY}}
Authorization: Bearer {{SUPABASE_ANON_KEY}}
[Options]
delay: 12000
retry: 10
retry-interval: 2000
HTTP 200
[Asserts]
jsonpath "$" count > 0
jsonpath "$[0].metric_name" == "{{checkpoint_metric}}"
jsonpath "$[0].value" >= 150.0
jsonpath "$[0].value" <= 250.0
jsonpath "$[0].metric_type" == "checkpoint"
jsonpath "$[0].scope" == "business"
[Captures]
first_flush_value: jsonpath "$[0].value"

# Step 8: Add more value
PUT {{TRACKTAGS_URL}}/api/v1/metrics/{{checkpoint_metric}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
[Options]
retry: 5
retry-interval: 500
{
  "value": 75.0
}
HTTP 200

# Step 9: Verify second flush shows accumulation
GET {{SUPABASE_URL}}/rest/v1/metrics?business_id=eq.{{business_id}}&metric_name=eq.{{checkpoint_metric}}&select=*&order=flushed_at.desc&limit=1
apikey: {{SUPABASE_ANON_KEY}}
Authorization: Bearer {{SUPABASE_ANON_KEY}}
[Options]
delay: 12000
retry: 10
retry-interval: 2000
HTTP 200
[Asserts]
jsonpath "$[0].value" > {{first_flush_value}}

# Step 10: Verify in-memory accumulation
GET {{TRACKTAGS_URL}}/api/v1/metrics/{{checkpoint_metric}}
Authorization: Bearer {{business_key}}
HTTP 200
[Asserts]
jsonpath "$.current_value" >= 150.0

# Cleanup
DELETE {{TRACKTAGS_URL}}/api/v1/metrics/{{checkpoint_metric}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
HTTP 200

DELETE {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
HTTP 200
