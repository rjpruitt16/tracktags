# TrackTags 🚀

**The only service you need to launch your product in a weekend.**

Built for indie hackers who need **billing metrics** and **auto-scaling** without the enterprise complexity. Launch fast, scale automatically, stay focused on your customers.

## 🎯 Why TrackTags?

- **⚡ Weekend Launch Ready**: Get metrics, billing, and scaling in hours, not weeks
- **💰 Revenue-First**: Built-in Stripe integration for usage-based billing  
- **🔄 Auto-Scale**: Fly.io machine API integration for demand-based scaling
- **🛡️ Fault Tolerant**: Built on the BEAM with OTP supervision trees
- **🔐 Security First**: Encrypted API keys with Doppler integration (coming soon)

Perfect for **GTM engineers** who need reliability without the DevOps overhead.

---

## 🚀 Quick Start

### 1. Create an API Key
```bash
curl -X POST "https://api.tracktags.com/api/v1/keys" \
  -H "Authorization: Bearer your_admin_key" \
  -H "Content-Type: application/json" \
  -d '{
    "integration_type": "api",
    "key_name": "production",
    "credentials": {
      "environment": "production"
    }
  }'
```

### 2. Submit Business Metrics
```bash
# Track company-wide metrics
curl -X POST "https://api.tracktags.com/api/v1/metrics" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "api_calls",
    "initial_value": 1.0,
    "flush_interval": "5s",
    "operation": "SUM",
    "metric_type": "reset"
  }'
```

### 3. Submit Client Metrics
```bash
# Track per-customer usage for billing
curl -X POST "https://api.tracktags.com/api/v1/metrics?scope=client&client_id=customer_123" \
  -H "Authorization: Bearer tk_live_your_key" \
  -H "Content-Type: application/json" \
  -d '{
    "metric_name": "api_usage",
    "initial_value": 50.0,
    "flush_interval": "1m",
    "operation": "COUNT",
    "metric_type": "checkpoint",
    "metadata": {
      "integrations": {
        "stripe": {
          "enabled": true,
          "price_id": "price_1234"
        }
      }
    }
  }'
```

### 4. Machine Metrics (Coming Soon)
Auto-scale your infrastructure based on real usage patterns.

---

## 🏗️ Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Your App      │───▶│   TrackTags      │───▶│   Fly.io        │
│                 │    │                  │    │   Auto-Scale    │
│ Send Metrics    │    │ • Process        │    │                 │
│ Get Billed      │    │ • Aggregate      │    │ Spin up/down    │
│ Scale on Demand │    │ • Bill via Stripe│    │ based on load   │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

**Built on the BEAM**: Erlang/OTP supervision trees ensure your metrics never get lost, even under heavy load or system failures.

---

## 💡 Use Cases

### For SaaS Builders
- **Usage-based billing**: Track API calls, storage, compute time
- **Customer analytics**: Per-tenant metrics and insights  
- **Auto-scaling**: Scale infrastructure based on real usage

### For API Companies  
- **Rate limiting**: Enforce plan limits automatically
- **Revenue optimization**: Convert usage into revenue streams
- **Reliability**: Never lose billing data, even during outages

### For Indie Hackers
- **Fast validation**: Get billing infrastructure in a weekend
- **Focus on product**: Let TrackTags handle the infrastructure
- **Scale when ready**: Built-in auto-scaling for when you hit PMF

---

## 🔐 Security & Reliability

- **🔑 Encrypted API Keys**: All credentials encrypted at rest
- **🛡️ Webhook Signature Verification**: Stripe webhook security built-in  
- **⚡ Fault Tolerance**: BEAM supervision trees prevent data loss
- **🔄 Automatic Recovery**: Self-healing actors and automatic restarts
- **📊 Real-time Processing**: Sub-second metric aggregation

---

📄 License

TrackTags is licensed under the Business Source License 1.1.

What this means:

✅ You CAN:

Use TrackTags for your own business

Self-host for internal use

Modify and fork the code

Contribute to the project

❌ You CANNOT:

Sell TrackTags as a hosted service to third parties

Compete with the official TrackTags hosting platform---

Timeline:

Until July 19, 2029: BSL restrictions apply

After July 19, 2029: Automatically becomes Apache 2.0 (fully open source)

This gives you 4 years to use TrackTags freely while protecting the commercial hosting business during the critical growth phase.

```bash
# Docker deployment
docker run -p 8080:8080 \
  -e SUPABASE_URL=your_db_url \
  -e SUPABASE_KEY=your_db_key \
  tracktags/server:latest

# Or build from source
git clone https://github.com/yourusername/tracktags
cd tracktags
gleam run
```

**Requirements**: 
- PostgreSQL database (or Supabase)
- Optional: Fly.io account for auto-scaling
- Optional: Stripe account for billing

---

## 🔧 Integrations

### Current
- ✅ **Supabase/PostgreSQL**: Metrics storage and analytics
- ✅ **Stripe**: Usage-based billing and webhooks  
- ✅ **Fly.io**: Auto-scaling machine management

### Coming Soon
- 🚧 **Doppler**: Secure API key rotation
- 🚧 **Webhooks**: Send metrics to your own services
- 🚧 **Dashboard**: Real-time metrics visualization

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

---

## 📞 Support

- 🐛 Issues: [GitHub Issues](https://github.com/yourusername/tracktags/issues)

**Built for indie hackers, by an indie hacker. Let's ship fast and scale smart.** 🚀
