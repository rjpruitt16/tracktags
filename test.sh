#!/bin/bash
echo "🧪 Complete Overage Test"

# 1. Start the server
echo "Starting server..."
gleam run &
SERVER_PID=$!
sleep 5  # Wait for server to fully start

# 2. Create metric with overage configuration
echo "Creating overage metric..."
curl -X POST http://localhost:8080/api/v1/metrics \
  -H "Authorization: Bearer test_pro_api_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "overage_metric",
    "flush_interval": "5s",
    "metric_type": "reset",
    "initial_value": 0.0,
    "limit_value": 5.0,
    "limit_operator": "gte",
    "breach_action": "allow_overage",
    "metadata": {
      "integrations": {
        "stripe": {
          "enabled": true,
          "overage_product_id": "prod_test",
          "overage_threshold": 5
        }
      }
    }
  }'

echo -e "\n\nWaiting for metric actor to initialize..."
sleep 3

# 3. Send 12 updates to trigger overage (5 base + 7 overage = 1 unit to report)
echo "Sending 12 events to exceed limit..."
for i in {1..12}; do
  curl -s -X PUT http://localhost:8080/api/v1/metrics/overage_metric \
    -H "Authorization: Bearer test_pro_api_key" \
    -H "Content-Type: application/json" \
    -d '{"value": 1.0}'
  echo "Sent update $i"
  sleep 0.2  # Small delay between requests
done

echo -e "\nWaiting for flush cycle..."
sleep 6

echo -e "\n✅ Test complete! Check logs for:"
echo "  1. Value reaching 12.0"
echo "  2. 🚨 BREACH STATE CHANGED: True action=allow_overage"
echo "  3. 💰 Reported 1 overage units (if Stripe is configured)"

# Optional: Kill the server
# kill $SERVER_PID
