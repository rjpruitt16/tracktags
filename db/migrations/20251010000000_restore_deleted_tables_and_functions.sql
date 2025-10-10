-- migrate:up

-- 1. Stripe event deduplication table
CREATE TABLE IF NOT EXISTS stripe_events (
  event_id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  business_id TEXT REFERENCES businesses(business_id) ON DELETE CASCADE,
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending',
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  error_message TEXT,
  raw_payload JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  source TEXT NOT NULL DEFAULT 'platform',
  source_business_id TEXT
);

-- 2. Plan-to-machine configuration
CREATE TABLE IF NOT EXISTS plan_machines (
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
  docker_image TEXT,
  allowed_regions TEXT[],
  grace_period_days INT DEFAULT 3,
  UNIQUE(plan_id, provider)
);

-- 3. Customer machines tracking
CREATE TABLE IF NOT EXISTS customer_machines (
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
  docker_image TEXT,
  fly_state TEXT,
  fly_app_name TEXT UNIQUE,
  expires_at TIMESTAMPTZ,
  UNIQUE(customer_id, provider, machine_id)
);

-- 4. Provisioning queue
CREATE TABLE IF NOT EXISTS provisioning_queue (
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
  completed_at TIMESTAMPTZ,
  dead_letter_at TIMESTAMPTZ,
  notification_sent BOOLEAN DEFAULT FALSE
);

-- 5. Machine events audit
CREATE TABLE IF NOT EXISTS machine_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id) ON DELETE CASCADE,
  machine_id TEXT,
  event_type TEXT NOT NULL,
  provider TEXT NOT NULL,
  details JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add columns to businesses table if they don't exist
ALTER TABLE businesses 
ADD COLUMN IF NOT EXISTS default_docker_image TEXT DEFAULT NULL,
ADD COLUMN IF NOT EXISTS default_machine_size TEXT DEFAULT 'shared-cpu-1x',
ADD COLUMN IF NOT EXISTS default_region TEXT DEFAULT 'iad',
ADD COLUMN IF NOT EXISTS machine_grace_period_days INT DEFAULT 3;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_stripe_events_status ON stripe_events(status);
CREATE INDEX IF NOT EXISTS idx_stripe_events_business ON stripe_events(business_id);
CREATE INDEX IF NOT EXISTS idx_stripe_events_customer ON stripe_events(customer_id);
CREATE INDEX IF NOT EXISTS idx_stripe_events_source ON stripe_events(source, source_business_id);

CREATE INDEX IF NOT EXISTS idx_plan_machines_plan ON plan_machines(plan_id);

CREATE INDEX IF NOT EXISTS idx_customer_machines_customer ON customer_machines(customer_id);
CREATE INDEX IF NOT EXISTS idx_customer_machines_status ON customer_machines(status);
CREATE INDEX IF NOT EXISTS idx_customer_machines_billing ON customer_machines(next_invoice_expected, grace_period_ends);
CREATE INDEX IF NOT EXISTS idx_customer_machines_expires ON customer_machines(expires_at) WHERE status != 'terminated';

CREATE INDEX IF NOT EXISTS idx_provisioning_queue_status ON provisioning_queue(status);
CREATE INDEX IF NOT EXISTS idx_provisioning_queue_next_retry ON provisioning_queue(next_retry_at);
CREATE INDEX IF NOT EXISTS idx_provisioning_dead_letter ON provisioning_queue(dead_letter_at)
WHERE status = 'dead_letter' AND notification_sent = FALSE;

CREATE INDEX IF NOT EXISTS idx_machine_events_customer ON machine_events(customer_id);
CREATE INDEX IF NOT EXISTS idx_machine_events_created ON machine_events(created_at DESC);

-- Updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS update_plan_machines_updated_at ON plan_machines;
CREATE TRIGGER update_plan_machines_updated_at BEFORE UPDATE ON plan_machines
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_customer_machines_updated_at ON customer_machines;
CREATE TRIGGER update_customer_machines_updated_at BEFORE UPDATE ON customer_machines
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Restore validate_key_and_get_context function
CREATE OR REPLACE FUNCTION validate_key_and_get_context(
  p_api_key_hash TEXT
) RETURNS JSON AS $$
DECLARE
  v_key integration_keys%ROWTYPE;
  v_context JSON;
BEGIN
  SELECT * INTO v_key 
  FROM integration_keys 
  WHERE key_hash = p_api_key_hash 
  AND is_active = true;
  
  IF NOT FOUND THEN
    RETURN json_build_object('error', 'Invalid key');
  END IF;
  
  IF v_key.key_type = 'customer_api' THEN
    SELECT json_build_object(
      'customer', row_to_json(c.*),
      'machines', COALESCE(
        (SELECT json_agg(cm.*) 
         FROM customer_machines cm 
         WHERE cm.customer_id = v_key.key_name 
         AND cm.status = 'running'), 
        '[]'::json
      ),
      'plan_limits', COALESCE(
        (SELECT json_agg(pl.*)
         FROM plan_limits pl
         WHERE (pl.customer_id = v_key.key_name)
            OR (pl.business_id = v_key.business_id AND pl.customer_id IS NULL)
         ORDER BY pl.customer_id NULLS LAST),
        '[]'::json
      )
    ) INTO v_context
    FROM customers c
    WHERE c.customer_id = v_key.key_name
    AND c.business_id = v_key.business_id;
    
    RETURN json_build_object(
      'key_type', 'customer',
      'business_id', v_key.business_id,
      'customer_id', v_key.key_name,
      'context', v_context
    );
  ELSE
    RETURN json_build_object(
      'key_type', 'business',
      'business_id', v_key.business_id
    );
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Restore get_customer_context function
CREATE OR REPLACE FUNCTION get_customer_context(
  p_business_id TEXT,
  p_customer_id TEXT
) RETURNS JSON AS $$
DECLARE
  v_context JSON;
BEGIN
  SELECT json_build_object(
    'customer', row_to_json(c.*),
    'machines', COALESCE(
      (SELECT json_agg(cm.*) 
       FROM customer_machines cm 
       WHERE cm.customer_id = p_customer_id 
       AND cm.business_id = p_business_id), 
      '[]'::json
    ),
    'plan_limits', COALESCE(
      (SELECT json_agg(subquery.*)
       FROM (
         SELECT * FROM plan_limits pl
         WHERE (pl.customer_id = p_customer_id AND pl.business_id = p_business_id)
            OR (pl.business_id = p_business_id AND pl.customer_id IS NULL AND 
                EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND plan_id = pl.plan_id))
         ORDER BY pl.customer_id DESC NULLS LAST
       ) subquery),
      '[]'::json
    )
  ) INTO v_context
  FROM customers c
  WHERE c.customer_id = p_customer_id
  AND c.business_id = p_business_id;
  
  IF v_context IS NULL THEN
    RETURN json_build_object('error', 'Customer not found');
  END IF;
  
  RETURN v_context;
END;
$$ LANGUAGE plpgsql;

-- migrate:down

DROP FUNCTION IF EXISTS get_customer_context(TEXT, TEXT);
DROP FUNCTION IF EXISTS validate_key_and_get_context(TEXT);
DROP TABLE IF EXISTS machine_events CASCADE;
DROP TABLE IF EXISTS provisioning_queue CASCADE;
DROP TABLE IF EXISTS customer_machines CASCADE;
DROP TABLE IF EXISTS plan_machines CASCADE;
DROP TABLE IF EXISTS stripe_events CASCADE;

ALTER TABLE businesses 
DROP COLUMN IF EXISTS default_docker_image,
DROP COLUMN IF EXISTS default_machine_size,
DROP COLUMN IF EXISTS default_region,
DROP COLUMN IF EXISTS machine_grace_period_days;
