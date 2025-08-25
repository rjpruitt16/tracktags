-- TrackTags Database Schema v4 - Clean with customers table
-- Run this in Supabase SQL Editor after dropping all tables

-- 1. Plans table (MUST come BEFORE businesses due to foreign key)
CREATE TABLE plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT, -- Will add foreign key constraint later
  plan_name TEXT NOT NULL,
  stripe_price_id TEXT,
  plan_status TEXT DEFAULT 'active',
  monthly_price DECIMAL(10,2) DEFAULT 0.00,
  yearly_price DECIMAL(10,2) DEFAULT 0.00,
  features JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(business_id, plan_name)
);

-- 2. Businesses table
CREATE TABLE businesses (
  business_id TEXT PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id),
  stripe_customer_id TEXT UNIQUE,
  stripe_subscription_id TEXT,
  stripe_subscription_status TEXT DEFAULT 'free',
  stripe_price_id TEXT,
  business_name TEXT NOT NULL,
  email TEXT NOT NULL,
  plan_type TEXT DEFAULT 'free',
  current_plan_id UUID REFERENCES plans(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Add foreign key constraint to plans table (now that businesses exists)
ALTER TABLE plans ADD CONSTRAINT fk_plans_business 
  FOREIGN KEY (business_id) REFERENCES businesses(business_id) ON DELETE CASCADE;

-- 4. Customers table
CREATE TABLE customers (
  customer_id TEXT PRIMARY KEY,
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id),
  plan_id UUID REFERENCES plans(id) ON DELETE SET NULL,
  customer_name TEXT NOT NULL,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Integration keys (UPDATED with key_hash)
CREATE TABLE integration_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  key_type TEXT NOT NULL,
  key_name TEXT,
  encrypted_key TEXT NOT NULL,
  key_hash TEXT,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  is_active BOOLEAN DEFAULT TRUE,
  UNIQUE(business_id, key_type, key_name),
  UNIQUE(business_id, key_hash)
);

-- 6. Plan limits - Flexible for business/customer/plan level
CREATE TABLE plan_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id UUID REFERENCES plans(id) ON DELETE CASCADE,
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  
  metric_name TEXT NOT NULL,
  limit_value FLOAT NOT NULL,
  limit_period TEXT NOT NULL,
  breach_operator TEXT DEFAULT 'gte',
  breach_action TEXT DEFAULT 'deny',
  webhook_urls TEXT,
  metric_type TEXT DEFAULT 'reset',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Ensure only ONE reference is set
  CONSTRAINT check_single_reference CHECK (
    (plan_id IS NOT NULL AND business_id IS NULL AND customer_id IS NULL) OR
    (plan_id IS NULL AND business_id IS NOT NULL AND customer_id IS NULL) OR  
    (plan_id IS NULL AND business_id IS NULL AND customer_id IS NOT NULL)
  ),
  
  -- Unique constraints for each type
  UNIQUE(plan_id, metric_name, limit_period),
  UNIQUE(business_id, metric_name, limit_period),
  UNIQUE(customer_id, metric_name, limit_period)
);
ALTER PUBLICATION supabase_realtime ADD TABLE plan_limits;

-- 7. Customer billing periods (for individual billing cycles)
CREATE TABLE customer_billing_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  metric_name TEXT NOT NULL,
  period_end TIMESTAMP WITH TIME ZONE NOT NULL,
  stripe_subscription_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  UNIQUE(customer_id, metric_name)
);

-- 8. Metrics table
CREATE TABLE metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  machine_id TEXT,
  region TEXT,
  metric_name TEXT NOT NULL,
  value FLOAT NOT NULL,
  metric_type TEXT NOT NULL,
  scope TEXT NOT NULL,
  adapters JSONB,
  threshold_value FLOAT,
  threshold_operator TEXT,
  threshold_action TEXT,
  webhook_urls TEXT,
  flushed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Add webhook URL constraints
ALTER TABLE metrics ADD CONSTRAINT check_webhook_urls_count 
  CHECK (array_length(string_to_array(webhook_urls, ','), 1) <= 5 OR webhook_urls IS NULL);

ALTER TABLE plan_limits ADD CONSTRAINT check_plan_webhook_urls_count 
  CHECK (array_length(string_to_array(webhook_urls, ','), 1) <= 5 OR webhook_urls IS NULL);

-- Indexes for performance
CREATE INDEX idx_plans_business ON plans(business_id);
CREATE INDEX idx_plans_stripe_price ON plans(stripe_price_id);

CREATE INDEX idx_businesses_user ON businesses(user_id);
CREATE INDEX idx_businesses_stripe_customer ON businesses(stripe_customer_id);
CREATE INDEX idx_businesses_stripe_subscription ON businesses(stripe_subscription_id);
CREATE INDEX idx_businesses_email ON businesses(email);
CREATE INDEX idx_businesses_status ON businesses(stripe_subscription_status);

CREATE INDEX idx_customers_user ON customers(user_id);
CREATE INDEX idx_customers_business ON customers(business_id);
CREATE INDEX idx_customers_plan ON customers(plan_id);
CREATE INDEX idx_customers_stripe_customer ON customers(stripe_customer_id);
CREATE INDEX idx_customers_stripe_subscription ON customers(stripe_subscription_id);

CREATE INDEX idx_integration_keys_business ON integration_keys(business_id);
CREATE INDEX idx_integration_keys_type ON integration_keys(key_type);
CREATE INDEX idx_integration_keys_active ON integration_keys(is_active);
CREATE INDEX idx_integration_keys_hash ON integration_keys(key_hash);

CREATE INDEX idx_metrics_business_time ON metrics(business_id, flushed_at DESC);
CREATE INDEX idx_metrics_customer_time ON metrics(customer_id, flushed_at DESC);
CREATE INDEX idx_metrics_name ON metrics(metric_name);
CREATE INDEX idx_metrics_type ON metrics(metric_type);
CREATE INDEX idx_metrics_scope ON metrics(scope);

CREATE INDEX idx_plan_limits_plan ON plan_limits(plan_id);
CREATE INDEX idx_plan_limits_business ON plan_limits(business_id);
CREATE INDEX idx_plan_limits_customer ON plan_limits(customer_id);
CREATE INDEX idx_plan_limits_metric ON plan_limits(metric_name);

CREATE INDEX idx_customer_billing_periods_customer ON customer_billing_periods(customer_id);
CREATE INDEX idx_customer_billing_periods_metric ON customer_billing_periods(customer_id, metric_name);
