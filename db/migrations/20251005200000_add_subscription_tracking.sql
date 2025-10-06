-- db/migrations/20251005200000_add_subscription_tracking.sql
-- migrate:up
ALTER TABLE customers 
ADD COLUMN IF NOT EXISTS subscription_ends_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS last_invoice_date TIMESTAMPTZ;

ALTER TABLE businesses
ADD COLUMN IF NOT EXISTS subscription_override_expires_at TIMESTAMPTZ;

-- migrate:down
ALTER TABLE customers 
DROP COLUMN IF EXISTS subscription_ends_at,
DROP COLUMN IF EXISTS last_invoice_date;

ALTER TABLE businesses
DROP COLUMN IF EXISTS subscription_override_expires_at;
