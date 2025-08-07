# TrackTags Metrics Guide

## Understanding Scopes: Business vs Customer

TrackTags supports two metric scopes:

### Business Metrics
Track company-wide metrics like total API calls, infrastructure costs, or system health.

```bash
# Business metric - tracks total API calls across ALL customers
curl -X POST "http://localhost:8080/api/v1/metrics" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "total_api_calls",
    "metric_type": "checkpoint",
    "flush_interval": "1m",
    "initial_value": 0.0
  }'

# Update business metric
curl -X PUT "http://localhost:8080/api/v1/metrics/total_api_calls" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{"value": 100.0}'

# Get business metric
curl "http://localhost:8080/api/v1/metrics/total_api_calls" \
  -H "Authorization: Bearer tk_live_your_key"
```

### Customer Metrics
Track per-customer usage for billing, rate limiting, or customer analytics.

```bash
# Customer metric - tracks usage for billing
curl -X POST "http://localhost:8080/api/v1/metrics?scope=customer&customer_id=cust_123" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "api_usage",
    "metric_type": "stripe_billing",
    "flush_interval": "5s",
    "initial_value": 0.0,
    "metadata": {
      "integrations": {
        "supabase": {
          "enabled": true,
          "batch_interval": "30s",
          "restore_on_startup": true
        }
      }
    }
  }'

# Update customer metric
curl -X PUT "http://localhost:8080/api/v1/metrics/api_usage?scope=customer&customer_id=cust_123" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{"value": 50.0}'

# Get customer metric
curl "http://localhost:8080/api/v1/metrics/api_usage?scope=customer&customer_id=cust_123" \
  -H "Authorization: Bearer tk_live_your_key"
```

## Metric Types

### 1. Reset Metrics
Automatically reset on billing cycles (monthly, daily, etc.)
```json
{
  "metric_type": "reset",
  "flush_interval": "1h"
}
```

### 2. Checkpoint Metrics
Never reset, continuously accumulate (lifetime values)
```json
{
  "metric_type": "checkpoint",
  "flush_interval": "5m"
}
```

### 3. StripeBilling Metrics
Reset when Stripe sends `invoice.created` webhook
```json
{
  "metric_type": "stripe_billing",
  "flush_interval": "5s",
  "metadata": {
    "integrations": {
      "supabase": {
        "batch_interval": "30s"  // Batch to avoid race conditions
      }
    }
  }
}
```

## Batching & Flushing

### Understanding the Two-Stage Process

1. **flush_interval**: How often the metric aggregates locally
2. **batch_interval**: How often aggregated data goes to database

```
Your App → MetricActor (flush_interval) → SupabaseActor (batch_interval) → Database
```

**Example Timeline:**
- `flush_interval: "5s"` - Aggregate every 5 seconds
- `batch_interval: "30s"` - Send to DB every 30 seconds
- Result: 6 aggregations before DB write

### Valid Intervals
- `1s`, `5s`, `15s`, `30s` - High frequency
- `1m`, `5m`, `15m`, `30m` - Medium frequency  
- `1h`, `6h`, `1d` - Low frequency

## Operations

- `SUM` - Add values together (default)
- `COUNT` - Count number of updates
- `AVG` - Calculate average
- `MAX` - Keep maximum value
- `MIN` - Keep minimum value

## Hydration & Recovery

### Enable Hydration
Restore metrics from database on restart:

```json
{
  "metadata": {
    "integrations": {
      "supabase": {
        "restore_on_startup": true
      }
    }
  }
}
```

### Cleanup Policy
Auto-delete old metrics:

```json
{
  "cleanup_after": "7d"  // Options: "1d", "7d", "30d", "never"
}
```

## Common Patterns

### Usage-Based Billing
```bash
# Create billing metric
curl -X POST "http://localhost:8080/api/v1/metrics?scope=customer&customer_id=cust_123" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "api_calls",
    "metric_type": "stripe_billing",
    "flush_interval": "5s",
    "metadata": {
      "integrations": {
        "supabase": {
          "batch_interval": "30s",
          "restore_on_startup": true
        },
        "stripe": {
          "price_id": "price_abc123"
        }
      }
    }
  }'
```

### Rate Limiting
```bash
# Create rate limit metric with plan limits
curl -X POST "http://localhost:8080/api/v1/metrics?scope=customer&customer_id=cust_123" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "requests_per_minute",
    "metric_type": "reset",
    "flush_interval": "1m",
    "plan_limit_value": 1000.0,
    "plan_limit_operator": "gte",
    "plan_breach_action": "block"
  }'
```

## Troubleshooting

### Metrics Not Appearing in Database
1. Check `batch_interval` - may not have flushed yet
2. Verify scope - business vs customer
3. Check logs for errors

### Customer Metrics Showing as Business
- Ensure `?scope=customer&customer_id=XXX` in URL
- Check customer exists in database

### Webhook Not Resetting Metrics  
- Verify `stripe_customer_id` in customers table
- Check webhook signature with Stripe CLI
- Ensure metric_type is `stripe_billing`

### Hydration Not Working
- Set `restore_on_startup: true` in metadata
- Check metrics exist in database
- Verify scope matches (business/customer)
```

This documentation should save us from these painful debugging sessions in the future!
