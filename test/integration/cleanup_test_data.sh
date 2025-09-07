#!/bin/bash
# Clean up test data using Supabase REST API directly
# Expects SUPABASE_URL and SUPABASE_KEY environment variables

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
    echo "⚠️  Skipping cleanup - SUPABASE_URL or SUPABASE_KEY not set"
    exit 0
fi

echo "Cleaning up test data from Supabase..."

# Delete test businesses
echo "Deleting test businesses..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/businesses?business_id=like.test_biz*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test customers  
echo "Deleting test customers..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customers?customer_id=like.test_customer*" \
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

# Delete test provisioning tasks
echo "Deleting test provisioning tasks..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/provisioning_queue?customer_id=like.test_customer*" \
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

echo "✅ Test data cleanup completed"
