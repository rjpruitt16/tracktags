-- migrate:up

-- Create missing tables FIRST (before trying to ALTER them)
CREATE TABLE IF NOT EXISTS breach_thresholds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id),
  client_id TEXT,
  metric_name TEXT NOT NULL,
  threshold_value DOUBLE PRECISION NOT NULL,
  threshold_operator TEXT NOT NULL,
  webhook_url TEXT,
  integration_key_id UUID REFERENCES integration_keys(id),
  scaling_config JSONB,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add subscription tracking columns
ALTER TABLE businesses 
  ADD COLUMN IF NOT EXISTS subscription_ends_at TIMESTAMPTZ;

ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS subscription_ends_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS stripe_product_id TEXT;

-- NOW disable RLS (after tables exist)
ALTER TABLE businesses DISABLE ROW LEVEL SECURITY;
ALTER TABLE customers DISABLE ROW LEVEL SECURITY;
ALTER TABLE integration_keys DISABLE ROW LEVEL SECURITY;
ALTER TABLE customer_machines DISABLE ROW LEVEL SECURITY;
ALTER TABLE metrics DISABLE ROW LEVEL SECURITY;
ALTER TABLE breach_thresholds DISABLE ROW LEVEL SECURITY;
ALTER TABLE plan_limits DISABLE ROW LEVEL SECURITY;
ALTER TABLE customer_billing_periods DISABLE ROW LEVEL SECURITY;
ALTER TABLE machine_events DISABLE ROW LEVEL SECURITY;

-- migrate:down

ALTER TABLE businesses DROP COLUMN IF EXISTS subscription_ends_at;
ALTER TABLE customers DROP COLUMN IF EXISTS subscription_ends_at, DROP COLUMN IF EXISTS stripe_product_id;

-- Re-enable RLS
ALTER TABLE businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE integration_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_machines ENABLE ROW LEVEL SECURITY;
ALTER TABLE metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE breach_thresholds ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_billing_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE machine_events ENABLE ROW LEVEL SECURITY;-- migrate:down

ALTER TABLE businesses DROP COLUMN IF EXISTS subscription_ends_at;
ALTER TABLE customers DROP COLUMN IF EXISTS subscription_ends_at, DROP COLUMN IF EXISTS stripe_product_id;

-- Re-enable RLS
ALTER TABLE businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE integration_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_machines ENABLE ROW LEVEL SECURITY;
ALTER TABLE metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE breach_thresholds ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_billing_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE machine_events ENABLE ROW LEVEL SECURITY;
