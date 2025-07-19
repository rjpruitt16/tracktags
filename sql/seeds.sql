-- TrackTags Sample Data
-- Run this after schema.sql to get demo data

-- Insert test businesses
INSERT INTO businesses (business_id, business_name, email, plan_type) VALUES 
  ('biz_001', 'Acme SaaS Co', 'founder@acme-saas.com', 'pro'),
  ('biz_002', 'StartupXYZ', 'hello@startupxyz.com', 'free'),
  ('biz_003', 'Scale Corp', 'team@scalecorp.com', 'enterprise');

-- Insert test clients (customers of the businesses above)
INSERT INTO clients (client_id, business_id, client_name) VALUES
  ('mobile_app', 'biz_001', 'Mobile Application'),
  ('web_portal', 'biz_001', 'Web Portal'),
  ('api_service', 'biz_001', 'API Service'),
  ('customer_app', 'biz_002', 'Main Customer App'),
  ('enterprise_client', 'biz_003', 'Enterprise Integration');

-- Insert test API keys (correspond to your hardcoded test keys)
INSERT INTO integration_keys (business_id, key_type, key_name, encrypted_key) VALUES
  ('biz_001', 'api', 'production', 'tk_live_test123'),
  ('biz_001', 'api', 'staging', 'tk_test_staging456'),
  ('biz_002', 'api', 'main', 'tk_live_test456'),
  ('biz_003', 'api', 'main', 'tk_live_test789'),
  ('biz_003', 'stripe', 'production', 'sk_live_encrypted_stripe_key');

-- Insert sample plan limits
INSERT INTO plan_limits (business_id, metric_name, limit_value, limit_period) VALUES
  ('biz_001', 'api_calls', 10000, 'monthly'),
  ('biz_001', 'storage_mb', 1000, 'monthly'),
  ('biz_002', 'api_calls', 1000, 'monthly'),
  ('biz_002', 'storage_mb', 100, 'monthly'),
  ('biz_003', 'api_calls', 100000, 'monthly'),
  ('biz_003', 'storage_mb', 10000, 'monthly');

-- Insert sample breach thresholds for auto-scaling
INSERT INTO breach_thresholds (business_id, metric_name, threshold_value, threshold_operator, is_active) VALUES
  ('biz_001', 'cpu_usage', 80.0, 'gt', true),
  ('biz_001', 'memory_usage', 85.0, 'gt', true),
  ('biz_003', 'request_latency', 500.0, 'gt', true),
  ('biz_003', 'queue_depth', 100.0, 'gt', true);

-- Insert some sample metrics to see data in dashboards
INSERT INTO metrics (business_id, client_id, metric_name, value, metric_type, scope, adapters) VALUES
  -- Business-level metrics
  ('biz_001', NULL, 'total_revenue', 15420.50, 'checkpoint', 'business', '{"enabled_integrations": "stripe"}'),
  ('biz_001', NULL, 'active_users', 1337, 'checkpoint', 'business', '{"enabled_integrations": "supabase"}'),
  
  -- Client-level metrics  
  ('biz_001', 'mobile_app', 'api_calls', 5234, 'reset', 'client', '{"enabled_integrations": "supabase"}'),
  ('biz_001', 'mobile_app', 'session_duration', 847.3, 'checkpoint', 'client', '{"enabled_integrations": "supabase"}'),
  ('biz_001', 'web_portal', 'page_views', 12847, 'reset', 'client', '{"enabled_integrations": "supabase"}'),
  
  -- StartupXYZ metrics
  ('biz_002', 'customer_app', 'signups', 42, 'reset', 'client', '{"enabled_integrations": "supabase"}'),
  ('biz_002', NULL, 'mrr', 2450.00, 'checkpoint', 'business', '{"enabled_integrations": "stripe"}'),
  
  -- Scale Corp metrics  
  ('biz_003', 'enterprise_client', 'data_processed_gb', 1024.7, 'reset', 'client', '{"enabled_integrations": "supabase,stripe"}'),
  ('biz_003', NULL, 'infrastructure_cost', 8945.32, 'checkpoint', 'business', '{"enabled_integrations": "fly,stripe"}');

-- Note: Timestamps will be automatically set to NOW() by the database
