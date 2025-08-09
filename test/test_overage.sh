#!/bin/bash

echo "🧪 Testing Overage Reporting..."

# 1. Create metric with overage config
echo "Creating metric with overage limits..."
curl -X POST http://localhost:8080/api/v1/metrics \
  -H "Authorization: Bearer test_pro_api_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "test_overage",
    "flush_interval": "5s",
    "operation": "SUM",
    "metric_type": "reset",
    "initial_value": 0.0,
    "limit_value": 10.0,
    "limit_operator": "gte",
    "breach_action": "allow_overage",
    "metadata": {
      "integrations": {
        "stripe": {
          "enabled": true,
          "overage_product_id": "si_test_overage",
          "overage_threshold": 5
        }
      }
    }
  }'

# test/test_overage.sh - FIX THE ENDPOINT
echo "Sending 20 events to exceed limit..."
for i in {1..20}; do
  curl -X POST http://localhost:8080/api/v1/metrics/test_overage/record \
    -H "Authorization: Bearer test_pro_api_key" \
    -H "Content-Type: application/json" \
    -d '{"value": 1.0}' \
    -s -o /dev/null
done

echo "Waiting for flush..."
sleep 6

echo "✅ Check logs for: [MetricActor] 💰 Reported 2 overage units"
