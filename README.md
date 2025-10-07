# TrackTags 🚀

**The only service you need to launch your product in a weekend.**

Built for indie hackers who need **billing metrics** and **usage tracking** without the enterprise complexity. Launch fast, scale automatically, stay focused on your customers.

## 🎯 Why TrackTags?

- **⚡ Weekend Launch Ready**: Get metrics, billing, and plan limits in hours, not weeks
- **💰 Revenue-First**: Built-in Stripe integration for usage-based billing  
- **🔄 Business Logic Focus**: Let your services focus on features, not billing infrastructure
- **🛡️ Fault Tolerant**: Built on the BEAM with OTP supervision trees
- **🔐 Security First**: Encrypted API keys and webhook signature verification

Perfect for **GTM engineers** who need reliability without the DevOps overhead.

---

## 💡 Why I Built This

I created TrackTags to power [EZThrottle.network](https://ezthrottle.network) - a rate limiting service that needed robust billing, auth, and usage tracking **without getting distracted from the core business logic**.

The beauty of TrackTags is simple: **your services handle business logic, TrackTags handles everything else.**

- Proxy API checks plan limits **before** forwarding requests
- Your service processes successfully, **then** increments usage
- No failed requests = no wasted quota
- No billing infrastructure in your codebase

---

## 🚀 Quick Start

### 1. Create a Business (Platform Admin)
```bash
curl -X POST "https://api.tracktags.com/api/v1/businesses" \
  -H "X-Admin-Key: your_admin_key" \
  -H "Content-Type: application/json" \
  -d '{
    "business_name": "Acme Corp",
    "email": "admin@acme.com"
  }'

# Response: {"business_id": "biz_abc123", ...}
```

### 2. Generate Business API Key
```bash
curl -X POST "https://api.tracktags.com/api/v1/keys" \
  -H "X-Admin-Key: your_admin_key" \
  -H "Content-Type: application/json" \
  -d '{
    "business_id": "biz_abc123",
    "key_type": "business",
    "key_name": "primary",
    "credentials": {
      "business_id": "biz_abc123",
      "api_key": "tk_live_generated_key"
    }
  }'

# Response: {"api_key": "tk_live_...", "warning": "Save this key!"}
```

### 3. Create a Customer
```bash
curl -X POST "https://api.tracktags.com/api/v1/customers" \
  -H "Authorization: Bearer tk_live_your_business_key" \
  -H "Content-Type: application/json" \
  -d '{
    "customer_id": "cust_xyz789",
    "customer_name": "Customer Inc",
    "email": "contact@customer.com",
    "plan_id": "plan_pro"
  }'
```

### 4. Generate Customer API Key
```bash
curl -X POST "https://api.tracktags.com/api/v1/customers/cust_xyz789/keys" \
  -H "Authorization: Bearer tk_live_your_business_key" \
  -H "Content-Type: application/json" \
  -d '{"key_name": "customer_primary"}'

# Response: {"api_key": "tk_cust_...", "warning": "Save this key!"}
```

### 5. Create Plan Limit Metrics
```bash
# Business creates metrics for customer (with plan limits)
curl -X POST "https://api.tracktags.com/api/v1/metrics?scope=customer&customer_id=cust_xyz789" \
  -H "Authorization: Bearer tk_live_your_business_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "api_calls",
    "operation": "SUM",
    "metric_type": "reset",
    "flush_interval": "1d",
    "initial_value": 0.0,
    "limit_value": 1000.0,
    "limit_operator": "gte",
    "breach_action": "deny"
  }'
```

### 6. Use Proxy for Plan Enforcement
```bash
# Customer makes request through proxy
curl -X POST "https://api.tracktags.com/api/v1/proxy" \
  -H "Authorization: Bearer tk_cust_customer_key" \
  -H "Content-Type: application/json" \
  -d '{
    "scope": "customer",
    "metric_name": "api_calls",
    "target_url": "https://your-service.com/api/endpoint",
    "method": "POST",
    "body": "{\"data\": \"your_payload\"}"
  }'

# If under limit: {"status": "allowed", "forwarded_response": {...}}
# If over limit: {"status": "denied", "error": "Plan limit exceeded"}
```

### 7. Increment After Success (Your Service)
```bash
# Your service successfully processes request, then increments
curl -X PUT "https://api.tracktags.com/api/v1/metrics/api_calls?scope=customer&customer_id=cust_xyz789" \
  -H "Authorization: Bearer tk_live_your_business_key" \
  -H "Content-Type: application/json" \
  -d '{"value": 1.0}'
```

### 8. Stripe Billing Integration
```bash
# Create StripeBilling metric for metered usage
curl -X POST "https://api.tracktags.com/api/v1/metrics?scope=customer&customer_id=cust_xyz789" \
  -H "Authorization: Bearer tk_live_your_business_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "storage_gb",
    "operation": "SUM",
    "metric_type": "stripe_billing",
    "flush_interval": "1m",
    "initial_value": 0.0,
    "metadata": {
      "integrations": {
        "stripe": {
          "enabled": true,
          "price_id": "price_1234567890",
          "restore_on_startup": false,
          "batch_interval": "1d"
        }
      }
    }
  }'

# Webhook URL for your business: https://api.tracktags.com/api/v1/webhooks/stripe/{business_id}
# On invoice.finalized, TrackTags auto-reports usage to Stripe and resets metric
```

---

## 🏗️ Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Your Service  │───▶│   TrackTags      │───▶│   Stripe API    │
│                 │    │                  │    │                 │
│ Business Logic  │    │ • Plan Limits    │    │ Usage Billing   │
│ Only!           │    │ • Usage Tracking │    │                 │
│                 │    │ • Proxy Checks   │    │ Auto-reports    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

**Built on the BEAM**: Erlang/OTP supervision trees ensure your metrics never get lost, even under heavy load or system failures.

---

## 🔧 Metric Types

### Reset
Resets to initial value on flush interval (e.g., daily API call limits)

### Checkpoint  
Accumulates indefinitely until explicitly reset (e.g., total lifetime usage)

### StripeBilling
Accumulates during billing period, reports to Stripe on `invoice.finalized`, then resets

---

## ⚠️ Experimental Features

### Fly.io Auto-Scaling
**Status**: 🚧 Experimental - Not production tested

Machine provisioning via Fly.io API integration is implemented but **not battle-tested**. Use at your own risk for now.

---

## 🔐 Security & Reliability

- **🔑 Encrypted API Keys**: All credentials encrypted at rest
- **🛡️ Webhook Signature Verification**: Stripe webhook security built-in  
- **⚡ Fault Tolerance**: BEAM supervision trees prevent data loss
- **🔄 Automatic Recovery**: Self-healing actors and automatic restarts
- **📊 Real-time Processing**: Sub-second metric aggregation

---

## 📄 License

TrackTags is licensed under the **Business Source License 1.1**.

**What this means:**

✅ You CAN:
- Use TrackTags for your own business
- Self-host for internal use
- Modify and fork the code
- Contribute to the project

❌ You CANNOT:
- Sell TrackTags as a hosted service to third parties
- Compete with the official TrackTags hosting platform

**Timeline:**
- Until **3-4 years after official launch** (date TBD): BSL restrictions apply
- After restriction period: Automatically becomes Apache 2.0 (fully open source)

This protects the commercial hosting business during the critical growth phase while ensuring eventual full open source.

---

## ☁️ Hosted Version

A cloud version of TrackTags is available at **https://tracktags.fly.dev**

⚠️ **Important**: I'm not guaranteeing support until **Q3 2026**. Use the hosted version at your own risk until then.

For production use, **self-hosting is recommended** until the hosted version stabilizes.

---

## 🚢 Self-Hosting

```bash
# Docker deployment
docker run -p 8080:8080 \
  -e SUPABASE_URL=your_db_url \
  -e SUPABASE_KEY=your_db_key \
  -e STRIPE_API_KEY=your_stripe_key \
  -e STRIPE_WEBHOOK_SECRET=your_webhook_secret \
  tracktags/server:latest

# Or build from source
git clone https://github.com/yourusername/tracktags
cd tracktags
gleam run
```

**Requirements**: 
- PostgreSQL database (or Supabase)
- Stripe account for billing (optional)

---

## 🔧 Integrations

### Current
- ✅ **Supabase/PostgreSQL**: Metrics storage and analytics
- ✅ **Stripe**: Usage-based billing and webhooks  
- 🚧 **Fly.io**: Auto-scaling machine management (experimental)

### Coming Soon
- 🚧 **Dashboard**: Real-time metrics visualization
- 🚧 **Webhooks**: Send metrics to your own services

---

## 🤝 Contributing

TrackTags is built with [Gleam](https://gleam.run) and powered by [Glixir](https://github.com/rjpruitt16/glixir) for type-safe OTP integration.

```bash
# Development setup
git clone https://github.com/yourusername/tracktags
cd tracktags
gleam deps download
gleam test
gleam run
```

**Architecture**: BusinessActor → ClientActor → MetricActor hierarchy with supervision trees for fault tolerance.

---

## About the Author

Built by **Rahmi Pruitt** - Ex-Twitch/Amazon Engineer turned indie hacker, on a mission to bring Gleam to the mainstream! 🚀

*"Making concurrent programming delightful, one type at a time."*

### Glixir: Type-Safe OTP for Gleam
Check out [Glixir](https://github.com/rjpruitt16/glixir) - my safe(ish) OTP wrapper for bringing Elixir's battle-tested concurrency to Gleam with type safety.

### Consulting Available
Tired of being paged for Elixir bugs? I can write Gleam packages or services that interop with your Elixir infrastructure. **100 hours available** for teams ready to embrace type safety without losing BEAM reliability.

*Hope this isn't too forward, but damn I could use some better opportunities!* 😄

---

**⭐ Star this repo if TrackTags helps you launch faster!** Your support helps bring mature tooling to the Gleam ecosystem.
