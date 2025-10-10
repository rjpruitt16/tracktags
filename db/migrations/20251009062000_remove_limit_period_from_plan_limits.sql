-- migrate:up
-- Remove the limit_period column - we'll use Stripe subscription expiry instead
ALTER TABLE plan_limits 
DROP COLUMN IF EXISTS limit_period CASCADE;

COMMENT ON TABLE plan_limits IS 'Plan limits are simple thresholds. Metrics reset when Stripe subscription expires (via webhook). No periods needed.';

-- migrate:down
-- Add back limit_period column
ALTER TABLE plan_limits 
ADD COLUMN IF NOT EXISTS limit_period TEXT;

-- Add a check constraint for valid periods
ALTER TABLE plan_limits
ADD CONSTRAINT valid_limit_period 
CHECK (limit_period IS NULL OR limit_period IN ('daily', 'monthly', 'yearly'));
