-- db/migrations/YYYYMMDDHHMMSS_add_business_subscription_ends_at.sql

-- migrate:up
ALTER TABLE businesses
ADD COLUMN IF NOT EXISTS subscription_ends_at TIMESTAMPTZ;

-- migrate:down
ALTER TABLE businesses
DROP COLUMN IF EXISTS subscription_ends_at;
