-- TrackTags Database Schema v3 - Fixed UUIDs + Webhook URLs
-- BusinessActor → ClientActor → MachineActor hierarchy
-- Run this in Supabase SQL Editor

-- 1. Businesses table (top level) - ENHANCED with subscription info
CREATE TABLE businesses (
  business_id TEXT PRIMARY KEY,
  stripe_customer_id TEXT UNIQUE,
  stripe_subscription_id TEXT, -- NEW: Track active subscription
  business_name TEXT NOT NULL,
  email TEXT NOT NULL,
  plan_type TEXT DEFAULT 'free', -- 'free', 'pro', 'enterprise'
  subscription_status TEXT DEFAULT 'active', -- NEW: 'active', 'past_due', 'canceled', 'trialing'
  current_plan_id UUID, -- NEW: References plans(id) - will add FK after plans table
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Clients table (under businesses) - UNCHANGED
CREATE TABLE clients (
  client_id TEXT PRIMARY KEY,
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  client_name TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Integration keys - ENHANCED for customer API keys
CREATE TABLE integration_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  key_type TEXT NOT NULL, -- 'api', 'stripe', 'fly', 'supabase', 'customer'
  key_name TEXT, -- e.g., 'production', 'staging', 'customer_123'
  encrypted_key TEXT NOT NULL,
  metadata JSONB, -- Store additional config (app names, regions, etc.)
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  is_active BOOLEAN DEFAULT TRUE,
  UNIQUE(business_id, key_type, key_name)
);

-- 4. Single metrics table - ENHANCED with threshold columns
CREATE TABLE metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  client_id TEXT REFERENCES clients(client_id) ON DELETE CASCADE, -- NULL for business-level
  machine_id TEXT, -- For machine metrics (NULL for business/client)
  region TEXT, -- For regional metrics (NULL for business/client)
  metric_name TEXT NOT NULL,
  value FLOAT NOT NULL,
  metric_type TEXT NOT NULL, -- 'reset', 'checkpoint'
  scope TEXT NOT NULL, -- 'business', 'client', 'machine'
  adapters JSONB, -- Integration references + rate limiting
  -- NEW: Threshold columns (optional - only set when needed)
  threshold_value FLOAT, -- e.g., 10000 for API limit, 80.0 for CPU
  threshold_operator TEXT, -- 'gt', 'gte', 'lt', 'lte', 'eq'
  threshold_action TEXT, -- 'deny', 'allow_overage', 'webhook', 'scale'
  webhook_urls TEXT, -- Comma-separated URLs (max 5): "url1,url2,url3"
  flushed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Plans table - SIMPLIFIED
CREATE TABLE plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  plan_name TEXT NOT NULL, -- 'free', 'pro', 'enterprise'
  stripe_price_id TEXT, -- NULL for free plans
  plan_status TEXT DEFAULT 'active', -- 'active', 'deprecated', 'draft'
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 6. Plan limits table - Templates for what each plan allows
-- 6. Plan limits table - ENHANCED to support business + client + plan limits
CREATE TABLE plan_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Flexible references - only ONE should be set
  plan_id UUID REFERENCES plans(id) ON DELETE CASCADE,        -- For plan templates
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE, -- For business-level limits
  client_id TEXT REFERENCES clients(client_id) ON DELETE CASCADE,     -- For client-specific limits
  
  metric_name TEXT NOT NULL,
  limit_value FLOAT NOT NULL,
  limit_period TEXT NOT NULL, -- 'daily', 'monthly', 'yearly', 'realtime'
  breach_operator TEXT DEFAULT 'gte', -- 'gt', 'gte', 'lt', 'lte', 'eq'
  breach_action TEXT DEFAULT 'deny', -- 'deny', 'allow_overage', 'webhook', 'scale'
  webhook_urls TEXT, -- Webhook URLs for this limit
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Ensure only ONE reference is set
  CONSTRAINT check_single_reference CHECK (
    (plan_id IS NOT NULL AND business_id IS NULL AND client_id IS NULL) OR
    (plan_id IS NULL AND business_id IS NOT NULL AND client_id IS NULL) OR  
    (plan_id IS NULL AND business_id IS NULL AND client_id IS NOT NULL)
  ),
  
  -- Unique constraints for each type
  UNIQUE(plan_id, metric_name, limit_period),
  UNIQUE(business_id, metric_name, limit_period),
  UNIQUE(client_id, metric_name, limit_period)
);

-- Add foreign key constraint to businesses table
ALTER TABLE businesses ADD CONSTRAINT fk_current_plan 
  FOREIGN KEY (current_plan_id) REFERENCES plans(id);

-- Add constraint to limit webhook URLs (max 5, comma-separated)
ALTER TABLE metrics ADD CONSTRAINT check_webhook_urls_count 
  CHECK (array_length(string_to_array(webhook_urls, ','), 1) <= 5);

ALTER TABLE plan_limits ADD CONSTRAINT check_plan_webhook_urls_count 
  CHECK (array_length(string_to_array(webhook_urls, ','), 1) <= 5);

-- Indexes for performance
CREATE INDEX idx_businesses_stripe_customer ON businesses(stripe_customer_id);
CREATE INDEX idx_businesses_stripe_subscription ON businesses(stripe_subscription_id);
CREATE INDEX idx_businesses_email ON businesses(email);
CREATE INDEX idx_businesses_status ON businesses(subscription_status);
CREATE INDEX idx_businesses_plan ON businesses(current_plan_id);

CREATE INDEX idx_clients_business ON clients(business_id);

CREATE INDEX idx_integration_keys_business ON integration_keys(business_id);
CREATE INDEX idx_integration_keys_type ON integration_keys(key_type);
CREATE INDEX idx_integration_keys_active ON integration_keys(is_active);
CREATE INDEX idx_integration_keys_lookup ON integration_keys(business_id, key_type, key_name);

CREATE INDEX idx_metrics_business_time ON metrics(business_id, flushed_at DESC);
CREATE INDEX idx_metrics_client_time ON metrics(client_id, flushed_at DESC);
CREATE INDEX idx_metrics_machine ON metrics(machine_id, flushed_at DESC);
CREATE INDEX idx_metrics_region ON metrics(region, flushed_at DESC);
CREATE INDEX idx_metrics_name ON metrics(metric_name);
CREATE INDEX idx_metrics_type ON metrics(metric_type);
CREATE INDEX idx_metrics_scope ON metrics(scope);
CREATE INDEX idx_metrics_adapters ON metrics USING GIN(adapters);
CREATE INDEX idx_metrics_billing_period ON metrics(business_id, metric_name, flushed_at DESC);
CREATE INDEX idx_metrics_threshold ON metrics(threshold_value, threshold_operator) WHERE threshold_value IS NOT NULL;

CREATE INDEX idx_plans_business ON plans(business_id);
CREATE INDEX idx_plans_status ON plans(plan_status);
CREATE INDEX idx_plans_stripe ON plans(stripe_price_id);

CREATE INDEX idx_plan_limits_plan ON plan_limits(plan_id);
CREATE INDEX idx_plan_limits_metric ON plan_limits(metric_name);
CREATE INDEX idx_plan_limits_breach ON plan_limits(breach_operator, breach_action);
