#!/bin/bash
# test/test_daily_limits.sh

echo "🧪 Testing Daily Limits..."

# First, create 999 calls quickly to get close to limit
echo "Setting up free tier near limit (999 calls)..."
curl -X POST http://localhost:8080/api/v1/metrics/daily_api_calls \
  -H "Authorization: Bearer test_free_api_key" \
  -H "Content-Type: application/json" \
  -d '{"value": 999}' \
  -s -o /dev/null

# Test call 1000 (should work - at limit)
echo "Testing call 1000 (at limit)..."
response=$(curl -s -w "%{http_code}" -o /dev/null \
  -X POST http://localhost:8080/api/v1/metrics \
  -H "Authorization: Bearer test_free_api_key" \
  -H "Content-Type: application/json" \
  -d '{"metric_name": "test_at_limit", "flush_interval": "1d", "operation": "SUM"}')

if [ "$response" = "201" ]; then
  echo "✅ Call 1000 allowed (at limit)"
else
  echo "❌ Call 1000 blocked (unexpected - got $response)"
fi

# Test call 1001 (should block - over limit)
echo "Testing call 1001 (over limit)..."
response=$(curl -s -w "%{http_code}" -o /dev/null \
  -X POST http://localhost:8080/api/v1/metrics \
  -H "Authorization: Bearer test_free_api_key" \
  -H "Content-Type: application/json" \
  -d '{"metric_name": "test_over_limit", "flush_interval": "1d", "operation": "SUM"}')

if [ "$response" = "429" ] || [ "$response" = "403" ]; then
  echo "✅ Call 1001 blocked (expected)"
else
  echo "❌ Call 1001 NOT blocked (got $response)"
fi

# Test pro tier
echo "Testing pro tier (should allow)..."
response=$(curl -s -w "%{http_code}" -o /dev/null \
  -X POST http://localhost:8080/api/v1/metrics \
  -H "Authorization: Bearer test_pro_api_key" \
  -H "Content-Type: application/json" \
  -d '{"metric_name": "test_pro", "flush_interval": "1d", "operation": "SUM"}')

if [ "$response" = "201" ]; then
  echo "✅ Pro tier allowed"
else
  echo "❌ Pro tier blocked (got $response)"
fi
