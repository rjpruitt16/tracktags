-- TrackTags Sample Data v4 - Using customers table
-- Run this after schema.sql to get demo data

INSERT INTO businesses (
    business_id,
    business_name,
    email,
    plan_type,
    stripe_customer_id,
    stripe_subscription_id,
    stripe_subscription_status,
    stripe_price_id
) VALUES
    ('biz_001', 'Acme SaaS Co', 'founder@acme-saas.com', 'pro', 'cus_acme123', 'sub_acme456', 'active', 'price_pro_123'),
    ('biz_002', 'Beta Startup', 'ceo@beta.io', 'starter', 'cus_beta456', 'sub_beta789', 'active', 'price_starter_456');

-- Insert test plans
INSERT INTO plans (business_id, plan_name, stripe_price_id, plan_status) VALUES
  ('biz_001', 'free', NULL, 'active'),
  ('biz_001', 'pro', 'price_pro_123', 'active'),
  ('biz_001', 'enterprise', 'price_ent_456', 'active'),
  
  ('biz_002', 'free', NULL, 'active'),
  ('biz_002', 'pro', 'price_pro_789', 'active'),
  
  ('biz_003', 'free', NULL, 'active'),
  ('biz_003', 'enterprise', 'price_ent_012', 'active');

-- Update businesses with current plan references
UPDATE businesses SET current_plan_id = (
  SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'
) WHERE business_id = 'biz_001';

UPDATE businesses SET current_plan_id = (
  SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'free'
) WHERE business_id = 'biz_002';

UPDATE businesses SET current_plan_id = (
  SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'enterprise'
) WHERE business_id = 'biz_003';

-- Insert test customers (was clients)
INSERT INTO customers (customer_id, business_id, plan_id, customer_name) VALUES
  ('mobile_app', 'biz_001', (SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'), 'Mobile Application'),
  ('web_portal', 'biz_001', (SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'), 'Web Portal'),
  ('api_service', 'biz_001', (SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'enterprise'), 'API Service'),
  ('customer_app', 'biz_002', (SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'free'), 'Main Customer App'),
  ('enterprise_customer', 'biz_003', (SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'enterprise'), 'Enterprise Integration');

-- Insert test API keys
INSERT INTO integration_keys (business_id, key_type, key_name, encrypted_key) VALUES
  -- Business API keys
  ('biz_001', 'api', 'production', 'tk_live_test123'),
  ('biz_001', 'api', 'staging', 'tk_test_staging456'),
  ('biz_002', 'api', 'main', 'tk_live_test456'),
  ('biz_003', 'api', 'main', 'tk_live_test789'),
  ('biz_003', 'stripe', 'production', 'sk_live_encrypted_stripe_key'),
  
  -- Customer API keys (for proxy API rate limiting)
  ('biz_001', 'customer', 'customer_001', 'cust_key_abc123'),
  ('biz_001', 'customer', 'customer_002', 'cust_key_def456'),
  ('biz_002', 'customer', 'user_123', 'cust_key_xyz789'),
  ('biz_003', 'customer', 'enterprise_user_1', 'cust_key_ent001');

-- Insert plan limits
INSERT INTO plan_limits (plan_id, metric_name, limit_value, limit_period, breach_operator, breach_action, webhook_urls) VALUES
  -- Free plan limits
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'free'), 'api_calls', 1000, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'free'), 'storage_mb', 100, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'free'), 'api_calls', 1000, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'free'), 'storage_mb', 100, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'free'), 'api_calls', 1000, 'monthly', 'gte', 'deny', NULL),
  
  -- Pro plan limits
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'), 'api_calls', 10000, 'monthly', 'gte', 'allow_overage', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'), 'storage_mb', 1000, 'monthly', 'gte', 'allow_overage', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'pro'), 'api_calls', 10000, 'monthly', 'gte', 'allow_overage', NULL),
  
  -- Enterprise plan limits
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'enterprise'), 'api_calls', 100000, 'monthly', 'gte', 'webhook', 'https://acme-saas.com/webhooks/limit-breach'),
  ((SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'enterprise'), 'api_calls', 1000000, 'monthly', 'gte', 'webhook', 'https://scalecorp.com/api/limits'),
  ((SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'enterprise'), 'data_processed_gb', 10000, 'monthly', 'gte', 'allow_overage', NULL);

-- Insert some sample metrics
INSERT INTO metrics (business_id, customer_id, metric_name, value, metric_type, scope, adapters) VALUES
  -- Business-level metrics
  ('biz_001', NULL, 'total_revenue', 15420.50, 'checkpoint', 'business', '{"stripe": {"enabled": true}}'),
  ('biz_001', NULL, 'active_users', 1337, 'checkpoint', 'business', '{"supabase": {"enabled": true}}'),
  ('biz_001', NULL, 'monthly_api_calls', 8500, 'reset', 'business', '{"supabase": {"enabled": true}}'),
  
  -- Customer-level metrics
  ('biz_001', 'mobile_app', 'api_calls', 5234, 'reset', 'customer', '{"supabase": {"enabled": true}}'),
  ('biz_001', 'mobile_app', 'session_duration', 847.3, 'checkpoint', 'customer', '{"supabase": {"enabled": true}}'),
  ('biz_001', 'web_portal', 'page_views', 12847, 'reset', 'customer', '{"supabase": {"enabled": true}}'),
  
  -- StartupXYZ metrics
  ('biz_002', 'customer_app', 'api_calls', 950, 'reset', 'customer', '{"supabase": {"enabled": true}}'),
  ('biz_002', 'customer_app', 'signups', 42, 'reset', 'customer', '{"supabase": {"enabled": true}}'),
  ('biz_002', NULL, 'mrr', 2450.00, 'checkpoint', 'business', '{"stripe": {"enabled": true}}'),
  
  -- Scale Corp metrics
  ('biz_003', 'enterprise_customer', 'data_processed_gb', 1024.7, 'reset', 'customer', '{"supabase": {"enabled": true}}'),
  ('biz_003', 'enterprise_customer', 'api_calls', 89543, 'reset', 'customer', '{"supabase": {"enabled": true}}'),
  ('biz_003', NULL, 'infrastructure_cost', 8945.32, 'checkpoint', 'business', '{"fly": {"enabled": true}}');

-- Verify the data
SELECT 'Businesses' as table_name, count(*) as count FROM businesses
UNION ALL
SELECT 'Plans', count(*) FROM plans  
UNION ALL
SELECT 'Plan Limits', count(*) FROM plan_limits
UNION ALL
SELECT 'Customers', count(*) FROM customers
UNION ALL
SELECT 'Integration Keys', count(*) FROM integration_keys
UNION ALL
SELECT 'Metrics', count(*) FROM metrics;
