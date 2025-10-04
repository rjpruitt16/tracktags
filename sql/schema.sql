-- businesses table
CREATE TABLE IF NOT EXISTS businesses (
  business_id TEXT PRIMARY KEY,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  business_name TEXT NOT NULL,
  email TEXT NOT NULL,
  plan_type TEXT,
  subscription_status TEXT,
  current_plan_id UUID,
  stripe_price_id TEXT,
  user_id UUID,
  default_docker_image TEXT,
  default_machine_size TEXT,
  default_region TEXT,
  machine_grace_period_days INTEGER,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- customers table
CREATE TABLE IF NOT EXISTS customers (
  customer_id TEXT PRIMARY KEY,
  business_id TEXT REFERENCES businesses(business_id),
  plan_id UUID,
  customer_name TEXT NOT NULL,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  user_id UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- integration_keys table
CREATE TABLE IF NOT EXISTS integration_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id),
  key_type TEXT NOT NULL,
  key_name TEXT,
  encrypted_key TEXT NOT NULL,
  key_hash TEXT,
  metadata JSONB,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_integration_keys_key_hash ON integration_keys(key_hash);

-- customer_machines table
CREATE TABLE IF NOT EXISTS customer_machines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id),
  business_id TEXT REFERENCES businesses(business_id),
  provider TEXT NOT NULL,
  machine_id TEXT NOT NULL,
  app_name TEXT NOT NULL,
  machine_url TEXT,
  internal_url TEXT,
  ip_address TEXT,
  status TEXT NOT NULL,
  machine_size TEXT NOT NULL,
  region TEXT NOT NULL,
  environment_vars JSONB,
  docker_image TEXT,
  fly_state TEXT,
  fly_app_name TEXT,
  expires_at TIMESTAMPTZ,
  last_invoice_date TIMESTAMPTZ,
  next_invoice_expected TIMESTAMPTZ,
  grace_period_ends TIMESTAMPTZ,
  last_health_check TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  terminated_at TIMESTAMPTZ
);

-- metrics table
CREATE TABLE IF NOT EXISTS metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT REFERENCES businesses(business_id),
  customer_id TEXT REFERENCES customers(customer_id),
  machine_id TEXT,
  region TEXT,
  metric_name TEXT NOT NULL,
  value DOUBLE PRECISION NOT NULL,
  metric_type TEXT NOT NULL,
  scope TEXT NOT NULL,
  adapters JSONB,
  threshold_value DOUBLE PRECISION,
  threshold_operator TEXT,
  threshold_action TEXT,
  webhook_urls TEXT,
  flushed_at TIMESTAMPTZ
);

-- breach_thresholds table
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

-- plan_limits table
CREATE TABLE IF NOT EXISTS plan_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id UUID,
  business_id TEXT REFERENCES businesses(business_id)
);

-- customer_billing_periods table
CREATE TABLE IF NOT EXISTS customer_billing_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id),
  metric_name TEXT NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  stripe_subscription_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- machine_events table
CREATE TABLE IF NOT EXISTS machine_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id),
  machine_id TEXT,
  event_type TEXT NOT NULL,
  provider TEXT NOT NULL,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
