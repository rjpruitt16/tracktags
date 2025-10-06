-- migrate:up

-- ============================================================================
-- 1. ENHANCE STRIPE EVENTS FOR DLQ
-- ============================================================================

ALTER TABLE stripe_events 
ADD COLUMN IF NOT EXISTS retry_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_retry_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_stripe_events_failed 
ON stripe_events(status) 
WHERE status = 'failed';

-- Function to increment retry count
CREATE OR REPLACE FUNCTION increment_stripe_event_retry(p_event_id TEXT)
RETURNS void AS $$
BEGIN
  UPDATE stripe_events 
  SET retry_count = retry_count + 1,
      last_retry_at = NOW()
  WHERE event_id = p_event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 2. CREATE AUDIT LOGS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  resource_type TEXT NOT NULL,
  resource_id TEXT NOT NULL,
  details JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_logs_actor ON audit_logs(actor_id);
CREATE INDEX idx_audit_logs_resource ON audit_logs(resource_type, resource_id);
CREATE INDEX idx_audit_logs_created ON audit_logs(created_at DESC);

-- ============================================================================
-- 3. CREATE STRIPE RECONCILIATION TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS stripe_reconciliation (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reconciliation_type TEXT NOT NULL, -- 'platform' or 'business'
  business_id TEXT,
  total_checked INTEGER NOT NULL,
  mismatches_found INTEGER NOT NULL,
  mismatches_fixed INTEGER NOT NULL,
  errors_encountered INTEGER NOT NULL,
  details JSONB,
  started_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_reconciliation_business 
    FOREIGN KEY (business_id) 
    REFERENCES businesses(business_id) 
    ON DELETE SET NULL
);

CREATE INDEX idx_reconciliation_type ON stripe_reconciliation(reconciliation_type);
CREATE INDEX idx_reconciliation_business ON stripe_reconciliation(business_id);
CREATE INDEX idx_reconciliation_completed ON stripe_reconciliation(completed_at DESC);

-- ============================================================================
-- 4. HELPER FUNCTIONS
-- ============================================================================

-- Get businesses with active Stripe subscriptions (platform)
CREATE OR REPLACE FUNCTION get_active_stripe_subscriptions()
RETURNS TABLE(
  business_id TEXT,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  subscription_status TEXT,
  stripe_price_id TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    b.business_id,
    b.stripe_customer_id,
    b.stripe_subscription_id,
    b.subscription_status,
    b.stripe_price_id
  FROM businesses b
  WHERE b.stripe_subscription_id IS NOT NULL
    AND b.subscription_status IN ('active', 'past_due', 'trialing');
END;
$$ LANGUAGE plpgsql;

-- Get businesses with Stripe integration (for customer reconciliation)
CREATE OR REPLACE FUNCTION get_businesses_with_stripe_integration()
RETURNS TABLE(
  business_id TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT ik.business_id
  FROM integration_keys ik
  WHERE ik.key_type = 'stripe'
    AND ik.is_active = true;
END;
$$ LANGUAGE plpgsql;

-- Get active customers for a business
CREATE OR REPLACE FUNCTION get_business_active_customers(p_business_id TEXT)
RETURNS TABLE(
  customer_id TEXT,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  stripe_product_id TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.customer_id,
    c.stripe_customer_id,
    c.stripe_subscription_id,
    c.stripe_product_id
  FROM customers c
  WHERE c.business_id = p_business_id
    AND c.stripe_subscription_id IS NOT NULL;
END;
$$ LANGUAGE plpgsql;

-- migrate:down

DROP FUNCTION IF EXISTS get_business_active_customers(TEXT);
DROP FUNCTION IF EXISTS get_businesses_with_stripe_integration();
DROP FUNCTION IF EXISTS get_active_stripe_subscriptions();
DROP TABLE IF EXISTS stripe_reconciliation;
DROP TABLE IF EXISTS audit_logs;
DROP FUNCTION IF EXISTS increment_stripe_event_retry(TEXT);
DROP INDEX IF EXISTS idx_stripe_events_failed;
ALTER TABLE stripe_events 
DROP COLUMN IF EXISTS retry_count,
DROP COLUMN IF EXISTS last_retry_at;
