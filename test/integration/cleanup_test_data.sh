#!/bin/bash

# Clean up test data using Supabase REST API directly
# Expects SUPABASE_URL and SUPABASE_KEY environment variables

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
    echo "⚠️  Skipping cleanup - SUPABASE_URL or SUPABASE_KEY not set"
    exit 0
fi

echo "Cleaning up test data from Supabase..."

# Delete test businesses (those created by tests usually have email test*@example.com)
echo "Deleting test businesses..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/businesses?email=like.test*@example.com" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test customers (those with customer_id starting with cust_ followed by timestamp)
echo "Deleting test customers..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/customers?customer_id=like.cust_*" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

# Delete test integration keys using key_hash or key_name
echo "Deleting test integration keys..."
curl -X DELETE \
  "${SUPABASE_URL}/rest/v1/integration_keys?key_name=like.%test%" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Prefer: return=minimal" \
  -s

echo "✅ Test data cleanup completed"
