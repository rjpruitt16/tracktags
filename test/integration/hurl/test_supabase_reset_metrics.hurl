# Test: Reset metrics flush then reset to initial value

# Step 1: Health check
GET {{TRACKTAGS_URL}}/health
HTTP 200

# Step 2: Create test business
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "test_reset_{{test_id}}",
  "email": "reset_{{test_id}}@example.com"
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
  "key_name": "reset_key_{{test_id}}",
  "credentials": {
    "description": "Reset Test Key"
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

# Step 5: Create reset metric with initial value
POST {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{business_key}}
Content-Type: application/json
{
  "metric_name": "reset_{{test_id}}",
  "operation": "COUNT",
  "flush_interval": "5s",
  "cleanup_after": "1d",
  "metric_type": "reset",
  "initial_value": 50.0,
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
reset_metric: jsonpath "$.metric_name"

# Step 6: Add value to reset metric (retry until metric actor is ready)
PUT {{TRACKTAGS_URL}}/api/v1/metrics/{{reset_metric}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
[Options]
retry: 10
retry-interval: 500
{
  "value": 25.0
}
HTTP 200

# Step 7: Verify metric flushed at least once (after we added value)
# ✅ FIXED: Changed from count >= 2 to count >= 1
# (First flush after creation has diff=0.0 and is skipped)
GET {{SUPABASE_URL}}/rest/v1/metrics?business_id=eq.{{business_id}}&metric_name=eq.{{reset_metric}}&select=*&order=flushed_at.desc
apikey: {{SUPABASE_ANON_KEY}}
Authorization: Bearer {{SUPABASE_ANON_KEY}}
[Options]
delay: 15000
retry: 5
retry-interval: 3000
HTTP 200
[Asserts]
jsonpath "$" count >= 1
jsonpath "$[0].metric_type" == "reset"

# Step 8: Verify in-memory was reset to initial value (50)
GET {{TRACKTAGS_URL}}/api/v1/metrics/{{reset_metric}}
Authorization: Bearer {{business_key}}
[Options]
delay: 2000
HTTP 200
[Asserts]
jsonpath "$.current_value" >= 45.0
jsonpath "$.current_value" <= 55.0

# Cleanup
DELETE {{TRACKTAGS_URL}}/api/v1/metrics/{{reset_metric}}
Authorization: Bearer {{business_key}}
Content-Type: application/json
HTTP 200

# Wait for metric actor to fully shut down
GET {{TRACKTAGS_URL}}/health
[Options]
delay: 1000
HTTP 200

DELETE {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
HTTP 200
