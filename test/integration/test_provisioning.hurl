# test/integration/test_provisioning.hurl
# Layer 2: Test Admin Provisioning Endpoints

# Step 1: Create test provisioning task and trigger processing
POST {{TRACKTAGS_URL}}/admin/provision/test
HTTP 200
[Captures]
customer_id: jsonpath "$.customer_id"
[Asserts]
jsonpath "$.status" == "queued"

# Step 2: Wait for initial processing
GET {{TRACKTAGS_URL}}/health
[Options]
delay: 2000
HTTP 200

# Step 3: Force poll to ensure processing
POST {{TRACKTAGS_URL}}/admin/force-provision
HTTP 200
[Asserts]
body contains "Polling triggered"

# Step 4: Wait for processing and replica sync
GET {{TRACKTAGS_URL}}/health
[Options]
delay: 5000
HTTP 200

# Step 5: Check if machines were created (with extended retries)
GET {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}/machines
[Options]
retry: 10
retry-interval: 2000
HTTP 200
[Asserts]
jsonpath "$.machines[0].status" == "running"
jsonpath "$.machines[0].machine_id" matches "mock_.*"

# Step 6: Test termination
POST {{TRACKTAGS_URL}}/admin/terminate/test
Content-Type: application/json
{
  "customer_id": "{{customer_id}}"
}
HTTP 200

# Step 7: Force processing of termination
POST {{TRACKTAGS_URL}}/admin/force-provision
[Options]
delay: 2000
HTTP 200

# Step 8: Verify machines are terminated (with retries for replica lag)
GET {{TRACKTAGS_URL}}/api/v1/customers/{{customer_id}}/machines
[Options]
delay: 3000
retry: 10
retry-interval: 2000
HTTP 200
[Asserts]
jsonpath "$.machines[0].status" == "terminated"
