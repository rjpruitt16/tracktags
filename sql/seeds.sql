-- TrackTags Sample Data v3 - Fixed UUIDs
-- Run this after schema.sql to get demo data

-- Insert test businesses (without plan references yet)
INSERT INTO businesses (business_id, business_name, email, plan_type, stripe_customer_id, stripe_subscription_id, subscription_status) VALUES 
  ('biz_001', 'Acme SaaS Co', 'founder@acme-saas.com', 'pro', 'cus_acme123', 'sub_acme456', 'active'),
  ('biz_002', 'StartupXYZ', 'hello@startupxyz.com', 'free', NULL, NULL, 'active'),
  ('biz_003', 'Scale Corp', 'team@scalecorp.com', 'enterprise', 'cus_scale789', 'sub_scale012', 'active');

-- Insert test plans (let PostgreSQL generate UUIDs)
INSERT INTO plans (business_id, plan_name, stripe_price_id, plan_status) VALUES
  ('biz_001', 'free', NULL, 'active'),
  ('biz_001', 'pro', 'price_pro_123', 'active'),
  ('biz_001', 'enterprise', 'price_ent_456', 'active'),
  
  ('biz_002', 'free', NULL, 'active'),
  ('biz_002', 'pro', 'price_pro_789', 'active'),
  
  ('biz_003', 'free', NULL, 'active'),
  ('biz_003', 'enterprise', 'price_ent_012', 'active');

-- Update businesses with current plan references (using subqueries)
UPDATE businesses SET current_plan_id = (
  SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'
) WHERE business_id = 'biz_001';

UPDATE businesses SET current_plan_id = (
  SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'free'
) WHERE business_id = 'biz_002';

UPDATE businesses SET current_plan_id = (
  SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'enterprise'
) WHERE business_id = 'biz_003';

-- Insert test clients (customers of the businesses above)
INSERT INTO clients (client_id, business_id, client_name) VALUES
  ('mobile_app', 'biz_001', 'Mobile Application'),
  ('web_portal', 'biz_001', 'Web Portal'),
  ('api_service', 'biz_001', 'API Service'),
  ('customer_app', 'biz_002', 'Main Customer App'),
  ('enterprise_client', 'biz_003', 'Enterprise Integration');

-- Insert test API keys (business API keys + customer API keys)
INSERT INTO integration_keys (business_id, key_type, key_name, encrypted_key) VALUES
  -- Business API keys (for TrackTags platform)
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

-- Insert plan limits with breach detection and webhook URLs
INSERT INTO plan_limits (plan_id, metric_name, limit_value, limit_period, breach_operator, breach_action, webhook_urls) VALUES
  -- Free plan limits (using subqueries to get plan IDs)
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'free'), 'api_calls', 1000, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'free'), 'storage_mb', 100, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'free'), 'api_calls', 1000, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'free'), 'storage_mb', 100, 'monthly', 'gte', 'deny', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'free'), 'api_calls', 1000, 'monthly', 'gte', 'deny', NULL),
  
  -- Pro plan limits (with overages)
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'), 'api_calls', 10000, 'monthly', 'gte', 'allow_overage', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'pro'), 'storage_mb', 1000, 'monthly', 'gte', 'allow_overage', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_002' AND plan_name = 'pro'), 'api_calls', 10000, 'monthly', 'gte', 'allow_overage', NULL),
  
  -- Enterprise plan limits (with webhooks and scaling)
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'enterprise'), 'api_calls', 100000, 'monthly', 'gte', 'webhook', 'https://acme-saas.com/webhooks/limit-breach'),
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'enterprise'), 'cpu_usage', 80.0, 'realtime', 'gt', 'scale', NULL),
  ((SELECT id FROM plans WHERE business_id = 'biz_001' AND plan_name = 'enterprise'), 'memory_usage', 85.0, 'realtime', 'gt', 'webhook', 'https://acme-saas.com/webhooks/scaling,https://slack.com/api/webhook'),
  ((SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'enterprise'), 'api_calls', 1000000, 'monthly', 'gte', 'webhook', 'https://scalecorp.com/api/limits'),
  ((SELECT id FROM plans WHERE business_id = 'biz_003' AND plan_name = 'enterprise'), 'data_processed_gb', 10000, 'monthly', 'gte', 'allow_overage', NULL);

-- Insert some sample metrics with thresholds
INSERT INTO metrics (business_id, client_id, metric_name, value, metric_type, scope, adapters, threshold_value, threshold_operator, threshold_action, webhook_urls) VALUES
  -- Business-level metrics
  ('biz_001', NULL, 'total_revenue', 15420.50, 'checkpoint', 'business', '{"stripe": {"enabled": true}}', NULL, NULL, NULL, NULL),
  ('biz_001', NULL, 'active_users', 1337, 'checkpoint', 'business', '{"supabase": {"enabled": true}}', NULL, NULL, NULL, NULL),
  ('biz_001', NULL, 'monthly_api_calls', 8500, 'reset', 'business', '{"supabase": {"enabled": true}}', 10000, 'gte', 'allow_overage', NULL),
  
  -- Client-level metrics with thresholds
  ('biz_001', 'mobile_app', 'api_calls', 5234, 'reset', 'client', '{"supabase": {"enabled": true}}', 10000, 'gte', 'deny', NULL),
  ('biz_001', 'mobile_app', 'session_duration', 847.3, 'checkpoint', 'client', '{"supabase": {"enabled": true}}', NULL, NULL, NULL, NULL),
  ('biz_001', 'web_portal', 'page_views', 12847, 'reset', 'client', '{"supabase": {"enabled": true}}', NULL, NULL, NULL, NULL),
  
  -- StartupXYZ metrics (approaching free limit!)
  ('biz_002', 'customer_app', 'api_calls', 950, 'reset', 'client', '{"supabase": {"enabled": true}}', 1000, 'gte', 'deny', NULL),
  ('biz_002', 'customer_app', 'signups', 42, 'reset', 'client', '{"supabase": {"enabled": true}}', NULL, NULL, NULL, NULL),
  ('biz_002', NULL, 'mrr', 2450.00, 'checkpoint', 'business', '{"stripe": {"enabled": true}}', NULL, NULL, NULL, NULL),
  
  -- Scale Corp metrics with multiple webhooks
  ('biz_003', 'enterprise_client', 'data_processed_gb', 1024.7, 'reset', 'client', '{"supabase": {"enabled": true}, "stripe": {"enabled": true}}', 5000, 'gte', 'webhook', 'https://scalecorp.com/usage-alert,https://slack.com/webhook/scaling'),
  ('biz_003', 'enterprise_client', 'api_calls', 89543, 'reset', 'client', '{"supabase": {"enabled": true}}', 100000, 'gte', 'webhook', 'https://scalecorp.com/api/limits'),
  ('biz_003', NULL, 'infrastructure_cost', 8945.32, 'checkpoint', 'business', '{"fly": {"enabled": true}, "stripe": {"enabled": true}}', NULL, NULL, NULL, NULL);

-- Verify the data
SELECT 'Businesses' as table_name, count(*) as count FROM businesses
UNION ALL
SELECT 'Plans', count(*) FROM plans  
UNION ALL
SELECT 'Plan Limits', count(*) FROM plan_limits
UNION ALL
SELECT 'Clients', count(*) FROM clients
UNION ALL
SELECT 'Integration Keys', count(*) FROM integration_keys
UNION ALL
SELECT 'Metrics', count(*) FROM metrics;
