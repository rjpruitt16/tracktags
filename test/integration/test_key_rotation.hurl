# Key Rotation Test

# Step 1: Create business
POST {{TRACKTAGS_URL}}/api/v1/businesses
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_name": "Key Rotation Test {{test_id}}",
  "email": "keytest{{test_id}}@example.com"
}
HTTP 201
[Captures]
business_id: jsonpath "$.business_id"

# Step 2: Create PRIMARY key
POST {{TRACKTAGS_URL}}/api/v1/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_id": "{{business_id}}",
  "key_type": "business",
  "key_name": "primary",
  "credentials": {
    "business_id": "{{business_id}}",
    "api_key": "tk_test_primary_{{test_id}}"
  }
}
HTTP 201
[Captures]
primary_key: jsonpath "$.api_key"

# Step 3: Create SECONDARY key
POST {{TRACKTAGS_URL}}/api/v1/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_id": "{{business_id}}",
  "key_type": "business",
  "key_name": "secondary",
  "credentials": {
    "business_id": "{{business_id}}",
    "api_key": "tk_test_secondary_{{test_id}}"
  }
}
HTTP 201
[Captures]
secondary_key: jsonpath "$.api_key"

# Step 4: Try to create THIRD key (should fail with 409)
POST {{TRACKTAGS_URL}}/api/v1/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "business_id": "{{business_id}}",
  "key_type": "business",
  "key_name": "third",
  "credentials": {
    "business_id": "{{business_id}}",
    "api_key": "tk_test_third_{{test_id}}"
  }
}
HTTP 409
[Asserts]
jsonpath "$.error" == "Key Limit Reached"

# Step 5: Wait for actor to spawn
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{primary_key}}
[Options]
retry: 10
retry-interval: 1000
HTTP 200

# Step 6: Delete PRIMARY key using business auth
DELETE {{TRACKTAGS_URL}}/api/v1/keys/business/primary
Authorization: Bearer {{primary_key}}
HTTP 200

# Step 7: Wait a moment for the delete to propagate
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{secondary_key}}
[Options]
delay: 2000
HTTP 200

# Step 8: Create NEW key (should succeed now)
POST {{TRACKTAGS_URL}}/api/v1/keys
Authorization: Bearer {{secondary_key}}
Content-Type: application/json
{
  "business_id": "{{business_id}}",
  "key_type": "business",
  "key_name": "new_primary",
  "credentials": {
    "business_id": "{{business_id}}",
    "api_key": "tk_test_new_{{test_id}}"
  }
}
HTTP 201
[Asserts]
jsonpath "$.api_key" == "tk_test_new_{{test_id}}"
jsonpath "$.key_name" == "new_primary"
