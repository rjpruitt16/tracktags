#!/bin/bash
# Clean up test data using Supabase REST API directly
# Expects SUPABASE_URL and SUPABASE_KEY environment variables

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
    echo "⚠️  Skipping cleanup - SUPABASE_URL or SUPABASE_KEY not set"
    exit 0
fi

echo "🧹 Cleaning up test data from Supabase..."

# Delete test businesses (various patterns)
echo "Deleting test businesses..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/businesses?business_name=like.*Test*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/businesses?business_id=like.test_biz*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test customers (various patterns)
echo "Deleting test customers..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customers?customer_id=like.test_customer*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customers?customer_id=like.cust_billing_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customers?customer_id=like.cust_test_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customers?customer_id=like.cust_reset_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test plans
echo "Deleting test plans..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/plans?plan_name=like.*test*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/plans?plan_name=like.pro_plan*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test plan limits
echo "Deleting test plan limits..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/plan_limits?metric_name=like.test_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test customer machines
echo "Deleting test customer machines..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customer_machines?customer_id=like.test_customer*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customer_machines?customer_id=like.cust_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test provisioning tasks
echo "Deleting test provisioning tasks..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/provisioning_queue?customer_id=like.test_customer*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/provisioning_queue?customer_id=like.cust_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test integration keys
echo "Deleting test integration keys..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/integration_keys?key_name=like.%test%" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/integration_keys?key_name=eq.primary" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test metrics (cleanup by timestamp patterns)
echo "Deleting test metrics..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/metrics?metric_name=like.test_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete old billing test data (older than 1 hour)
echo "Deleting old billing test data..."
ONE_HOUR_AGO=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/businesses?business_name=like.BillingCycleTest*&created_at=lt.${ONE_HOUR_AGO}" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

echo "✅ Test data cleanup completed"
