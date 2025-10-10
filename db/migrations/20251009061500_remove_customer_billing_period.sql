-- libs/tracktags/migrations/20251009061500_remove_customer_billing_period.sql
-- migrate:up
-- Remove the check constraint that's blocking plan limit creation
ALTER TABLE plan_limits 
DROP CONSTRAINT IF EXISTS check_single_reference;

-- Remove customer_id column from plan_limits (no longer needed)
ALTER TABLE plan_limits 
DROP COLUMN IF EXISTS customer_id CASCADE;

-- Remove billing_period_id column from plan_limits (no longer needed)
ALTER TABLE plan_limits 
DROP COLUMN IF EXISTS billing_period_id CASCADE;

-- Drop the customer_billing_period table (too complex, using Stripe webhooks instead)
DROP TABLE IF EXISTS customer_billing_period CASCADE;

--20250118000002_add_get_customer_context_function.sql Ensure plan_id is always set for plan limits
ALTER TABLE plan_limits
DROP CONSTRAINT IF EXISTS plan_limits_plan_id_not_null;

ALTER TABLE plan_limits
ADD CONSTRAINT plan_limits_plan_id_not_null 
CHECK (plan_id IS NOT NULL);

COMMENT ON TABLE plan_limits IS 'Plan limits are managed per plan. Metrics are reset via Stripe webhook invoice events.';

-- migrate:down
-- Recreate customer_billing_period table
CREATE TABLE IF NOT EXISTS customer_billing_period (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  business_id TEXT NOT NULL,
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'ended', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Add back billing_period_id column to plan_limits
ALTER TABLE plan_limits 
ADD COLUMN IF NOT EXISTS billing_period_id UUID REFERENCES customer_billing_period(id) ON DELETE CASCADE;

-- Add back customer_id column to plan_limits
ALTER TABLE plan_limits 
ADD COLUMN IF NOT EXISTS customer_id UUID REFERENCES customers(id) ON DELETE CASCADE;

-- Remove the plan_id constraint
ALTER TABLE plan_limits
DROP CONSTRAINT IF EXISTS plan_limits_plan_id_not_null;

-- Add back the check_single_reference constraint
ALTER TABLE plan_limits
ADD CONSTRAINT check_single_reference 
CHECK (
  (plan_id IS NOT NULL AND customer_id IS NULL AND billing_period_id IS NULL) OR
  (plan_id IS NULL AND customer_id IS NOT NULL AND billing_period_id IS NULL) OR
  (plan_id IS NULL AND customer_id IS NULL AND billing_period_id IS NOT NULL)
);

-- Remove comment
COMMENT ON TABLE plan_limits IS NULL;
