# Test IP Rate Limiting and Ban System
# This test verifies:
# 1. Normal requests work (200)
# 2. After banning an IP, requests return 429
# 3. Body size limit returns 413

# ===========================================================================
# TEST 1: Health check works normally
# ===========================================================================
GET {{TRACKTAGS_URL}}/health
HTTP 200
[Asserts]
body == "OK"

# ===========================================================================
# TEST 2: Ban an IP via admin endpoint (we'll need to add this)
# For now, we can test the body size limit which IS implemented
# ===========================================================================

# ===========================================================================
# TEST 3: Request with body > 1MB should return 413
# ===========================================================================
POST {{TRACKTAGS_URL}}/api/v1/proxy
Content-Type: application/json
Content-Length: 2000000
```
{"large": "This would be a very large body that exceeds 1MB limit"}
```
HTTP 413
[Asserts]
jsonpath "$.error" == "Request Too Large"
jsonpath "$.max_bytes" == 1000000

# ===========================================================================
# TEST 4: Normal sized request should work (assuming valid auth)
# This will return 401 without auth, but proves the size check passed
# ===========================================================================
POST {{TRACKTAGS_URL}}/api/v1/proxy
Content-Type: application/json
```json
{"target_url": "https://example.com", "method": "GET"}
```
# Will be 401 without auth, but that means it passed the size check
HTTP *
[Asserts]
status != 413
status != 429
