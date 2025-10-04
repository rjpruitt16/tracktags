-- migrate:up

-- Ensure businesses table has all required columns
ALTER TABLE businesses 
  ADD COLUMN IF NOT EXISTS subscription_status TEXT,
  ADD COLUMN IF NOT EXISTS stripe_price_id TEXT,
  ADD COLUMN IF NOT EXISTS default_docker_image TEXT,
  ADD COLUMN IF NOT EXISTS default_machine_size TEXT,
  ADD COLUMN IF NOT EXISTS default_region TEXT,
  ADD COLUMN IF NOT EXISTS machine_grace_period_days INTEGER;

-- Ensure customers table has user_id for Supabase auth integration
ALTER TABLE customers 
  ADD COLUMN IF NOT EXISTS user_id UUID;

-- Create customer_billing_periods if it doesn't exist
CREATE TABLE IF NOT EXISTS customer_billing_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id),
  metric_name TEXT NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  stripe_subscription_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create machine_events if it doesn't exist  
CREATE TABLE IF NOT EXISTS machine_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id TEXT REFERENCES customers(customer_id),
  machine_id TEXT,
  event_type TEXT NOT NULL,
  provider TEXT NOT NULL,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add expires_at to customer_machines if missing
ALTER TABLE customer_machines 
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

-- Add key_hash to integration_keys for faster lookups
ALTER TABLE integration_keys
  ADD COLUMN IF NOT EXISTS key_hash TEXT;

-- Create index on key_hash if it doesn't exist
CREATE INDEX IF NOT EXISTS idx_integration_keys_key_hash ON integration_keys(key_hash);

-- Reload PostgREST schema cache
NOTIFY pgrst, 'reload schema';

-- migrate:down

ALTER TABLE businesses 
  DROP COLUMN IF EXISTS subscription_status,
  DROP COLUMN IF EXISTS stripe_price_id,
  DROP COLUMN IF EXISTS default_docker_image,
  DROP COLUMN IF EXISTS default_machine_size,
  DROP COLUMN IF EXISTS default_region,
  DROP COLUMN IF EXISTS machine_grace_period_days;

ALTER TABLE customers DROP COLUMN IF EXISTS user_id;
ALTER TABLE customer_machines DROP COLUMN IF EXISTS expires_at;
ALTER TABLE integration_keys DROP COLUMN IF EXISTS key_hash;

DROP TABLE IF EXISTS customer_billing_periods;
DROP TABLE IF EXISTS machine_events;
DROP INDEX IF EXISTS idx_integration_keys_key_hash;
