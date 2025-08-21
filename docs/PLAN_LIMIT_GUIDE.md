# TrackTags Plan Limits & Customer API Guide

## Overview
TrackTags lets you set usage limits for your customers and automatically enforce them via our proxy. When customers hit limits, you can deny requests, allow overage billing, or trigger webhooks.

## 1. Setting Up Plan Limits

### Create a Plan Limit
```bash
curl -X POST https://your-tracktags.com/api/v1/plan_limits \
  -H "Authorization: Bearer tk_live_your_business_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "api_calls",
    "limit_value": 1000,
    "limit_period": "monthly",
    "breach_operator": "gte",
    "breach_action": "deny"
  }'
```

**Fields:**
- `metric_name` - What you're measuring (api_calls, requests, storage_mb)
- `limit_value` - The threshold (1000)
- `limit_period` - Time window (monthly, daily, realtime)
- `breach_operator` - When to trigger (gte = greater than or equal)
- `breach_action` - What to do (deny, allow_overage, webhook)

## 2. Stripe Webhook Integration

### How It Works
1. **Your Stripe webhooks** fire when subscriptions change
2. **TrackTags listens** to plan_limits table changes via realtime
3. **Limits update automatically** across all customer metrics
4. **Enforcement happens immediately** on next request

### Stripe Webhook Flow
```
Customer upgrades plan → Stripe webhook → Your system updates plan_limits → 
TrackTags realtime → CustomerActors get new limits → Immediate enforcement
```

### Example: Plan Upgrade
```bash
# When customer upgrades, update their limits
curl -X PUT https://your-tracktags.com/api/v1/plan_limits/{limit_id} \
  -H "Authorization: Bearer tk_live_your_business_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "api_calls", 
    "limit_value": 10000,
    "limit_period": "monthly",
    "breach_operator": "gte",
    "breach_action": "allow_overage"
  }'
```

## 3. Customer API Keys

### Generate Customer Keys
```bash
curl -X POST https://your-tracktags.com/api/v1/customers/customer_123/keys \
  -H "Authorization: Bearer tk_live_your_business_key"
```

**Response:**
```json
{
  "status": "created",
  "api_key": "ck_live_customer_123_45678901",
  "customer_id": "customer_123",
  "warning": "Save this key securely. It will not be shown again"
}
```

### Give Keys to Customers
Provide the `customer_key` to your customers. They'll use it to call your API through TrackTags proxy.

## 4. Using the Proxy

### Customer Makes Request
```bash
curl -X POST https://your-tracktags.com/api/v1/proxy \
  -H "Authorization: Bearer ck_live_customer_123_45678901" \
  -H "Content-Type: application/json" \
  -d '{
    "scope": "customer",
    "customer_id": "customer_123",
  "warning": "Save this key securely. It will not be shown again",
    "metric_name": "api_calls", 
    "target_url": "https://your-api.com/endpoint",
    "method": "POST",
    "headers": {"Content-Type": "application/json"},
    "body": "{\"data\": \"customer request\"}"
  }'
```

### Proxy Response (Allowed)
```json
{
  "status": "allowed",
  "breach_status": {
    "is_breached": false,
    "current_usage": 234,
    "limit_value": 1000,
    "remaining": 766
  },
  "forwarded_response": {
    "status_code": 200,
    "body": "Your API response"
  }
}
```

### Proxy Response (Denied)
```json
{
  "status": "denied", 
  "breach_status": {
    "is_breached": true,
    "current_usage": 1001,
    "limit_value": 1000,
    "breach_action": "deny"
  },
  "error": "Plan limit exceeded",
  "retry_after": 3600
}
```

## 5. Complete Workflow

### Setup (Once)
1. **Create metrics** for tracking usage
2. **Set plan limits** for enforcement  
3. **Generate customer keys**
4. **Configure Stripe webhooks** (optional)

### Runtime (Every Request)
1. **Customer calls proxy** with their key
2. **TrackTags validates** key and checks limits
3. **Request forwarded** if under limit
4. **Request denied** if over limit
5. **Usage tracked** automatically

### Plan Changes (As Needed)
1. **Customer upgrades/downgrades** in your system
2. **Update plan limits** via API
3. **Changes propagate instantly** via realtime
4. **Next customer request** uses new limits

## 6. Best Practices

- **Use meaningful metric names** (api_calls, storage_gb, users)
- **Set appropriate time periods** (monthly for billing, daily for burst protection)
- **Choose breach actions wisely** (deny for free tiers, allow_overage for paid)
- **Monitor usage patterns** via metrics history
- **Test limit changes** before customer-facing releases

This gives your customers a seamless experience while you maintain full control over usage limits and billing!
