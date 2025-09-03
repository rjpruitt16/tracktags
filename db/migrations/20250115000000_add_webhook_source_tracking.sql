-- db/migrations/20250115000000_add_webhook_source_tracking.sql
-- migrate:up

ALTER TABLE stripe_events 
ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'platform',
ADD COLUMN IF NOT EXISTS source_business_id TEXT;

-- Add index for efficient lookups
CREATE INDEX IF NOT EXISTS idx_stripe_events_source ON stripe_events(source, source_business_id);

-- migrate:down
ALTER TABLE stripe_events 
DROP COLUMN IF EXISTS source,
DROP COLUMN IF EXISTS source_business_id;

DROP INDEX IF EXISTS idx_stripe_events_source;
