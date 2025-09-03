-- migrate:up

-- 1. Stripe event deduplication table
CREATE TABLE stripe_events (
  event_id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending',
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  error_message TEXT,
  raw_payload JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Plan-to-machine configuration
CREATE TABLE plan_machines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id UUID REFERENCES plans(id) ON DELETE CASCADE,
  provider TEXT NOT NULL DEFAULT 'fly',
  machine_count INT NOT NULL DEFAULT 1,
  machine_size TEXT NOT NULL,
  machine_memory INT NOT NULL,
  region TEXT NOT NULL DEFAULT 'iad',
  environment_vars JSONB DEFAULT '{}',
  auto_scale BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(plan_id, provider)
);

-- 3. Customer machines tracking
CREATE TABLE customer_machines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  provider TEXT NOT NULL DEFAULT 'fly',
  machine_id TEXT NOT NULL,
  app_name TEXT NOT NULL,
  machine_url TEXT,
  internal_url TEXT,
  ip_address TEXT,
  status TEXT NOT NULL DEFAULT 'provisioning',
  machine_size TEXT NOT NULL,
  region TEXT NOT NULL,
  environment_vars JSONB DEFAULT '{}',
  last_invoice_date TIMESTAMPTZ,
  next_invoice_expected TIMESTAMPTZ,
  grace_period_ends TIMESTAMPTZ,
  last_health_check TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  terminated_at TIMESTAMPTZ,
  UNIQUE(customer_id, provider, machine_id)
);

-- 4. Provisioning queue
CREATE TABLE provisioning_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('provision', 'suspend', 'resume', 'terminate')),
  provider TEXT NOT NULL DEFAULT 'fly',
  status TEXT DEFAULT 'pending',
  attempt_count INT DEFAULT 0,
  max_attempts INT DEFAULT 3,
  next_retry_at TIMESTAMPTZ DEFAULT NOW(),
  last_attempt_at TIMESTAMPTZ,
  error_message TEXT,
  payload JSONB DEFAULT '{}',
  idempotency_key TEXT UNIQUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);

-- 5. Machine events audit
CREATE TABLE machine_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  machine_id TEXT,
  event_type TEXT NOT NULL,
  provider TEXT NOT NULL,
  details JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_stripe_events_status ON stripe_events(status);
CREATE INDEX idx_stripe_events_business ON stripe_events(business_id);
CREATE INDEX idx_stripe_events_customer ON stripe_events(customer_id);

CREATE INDEX idx_plan_machines_plan ON plan_machines(plan_id);

CREATE INDEX idx_customer_machines_customer ON customer_machines(customer_id);
CREATE INDEX idx_customer_machines_status ON customer_machines(status);
CREATE INDEX idx_customer_machines_billing ON customer_machines(next_invoice_expected, grace_period_ends);

CREATE INDEX idx_provisioning_queue_status ON provisioning_queue(status);
CREATE INDEX idx_provisioning_queue_next_retry ON provisioning_queue(next_retry_at);

CREATE INDEX idx_machine_events_customer ON machine_events(customer_id);
CREATE INDEX idx_machine_events_created ON machine_events(created_at DESC);

-- Updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_plan_machines_updated_at BEFORE UPDATE ON plan_machines
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_customer_machines_updated_at BEFORE UPDATE ON customer_machines
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- migrate:down

DROP TABLE IF EXISTS machine_events CASCADE;
DROP TABLE IF EXISTS provisioning_queue CASCADE;
DROP TABLE IF EXISTS customer_machines CASCADE;
DROP TABLE IF EXISTS plan_machines CASCADE;
DROP TABLE IF EXISTS stripe_events CASCADE;
DROP FUNCTION IF EXISTS update_updated_at_column() CASCADE;
