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

# Step 2: Create PRIMARY key (NEW ROUTE)
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
primary_key: jsonpath "$.api_key"

# Step 3: Create SECONDARY key (NEW ROUTE)
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "key_type": "business",
  "key_name": "secondary",
  "credentials": {
    "description": "Secondary API Key"
  }
}
HTTP 201
[Captures]
secondary_key: jsonpath "$.api_key"

# Step 4: Try to create THIRD key (should fail with 409)
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
X-Admin-Key: {{ADMIN_SECRET_KEY}}
Content-Type: application/json
{
  "key_type": "business",
  "key_name": "third",
  "credentials": {
    "description": "Third API Key"
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

# Step 6: Delete PRIMARY key (NEW ROUTE)
DELETE {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys/business/primary
Authorization: Bearer {{primary_key}}
HTTP 200

# Step 7: Verify primary key is deactivated
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{primary_key}}
HTTP 401

# Step 8: Secondary key still works
GET {{TRACKTAGS_URL}}/api/v1/metrics
Authorization: Bearer {{secondary_key}}
HTTP 200

# Step 9: Create NEW key (should succeed now - only 1 active)
POST {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
Authorization: Bearer {{secondary_key}}
Content-Type: application/json
{
  "key_type": "business",
  "key_name": "new_primary",
  "credentials": {
    "description": "New Primary API Key"
  }
}
HTTP 201
[Asserts]
jsonpath "$.key_name" == "new_primary"

# Step 10: List keys - should show 2 active keys
GET {{TRACKTAGS_URL}}/api/v1/businesses/{{business_id}}/keys
Authorization: Bearer {{secondary_key}}
HTTP 200
[Asserts]
jsonpath "$.count" == 2
