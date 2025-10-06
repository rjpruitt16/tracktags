-- migrate:up

-- ============================================================================
-- 1. CREATE DELETION AUDIT TABLE
-- ============================================================================

CREATE TABLE deleted_businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id TEXT NOT NULL,
  business_name TEXT NOT NULL,
  email TEXT NOT NULL,
  deleted_by_user_id UUID,
  deletion_requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  scheduled_permanent_deletion_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '30 days',
  deletion_reason TEXT,
  customer_count INTEGER,
  metrics_count INTEGER,
  last_activity_at TIMESTAMPTZ,
  metadata JSONB,  -- Store snapshot of business data
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_deleted_businesses_scheduled ON deleted_businesses(scheduled_permanent_deletion_at);
CREATE INDEX idx_deleted_businesses_business_id ON deleted_businesses(business_id);

-- ============================================================================
-- 2. ADD SOFT DELETE COLUMNS TO BUSINESSES
-- ============================================================================

ALTER TABLE businesses 
ADD COLUMN deleted_at TIMESTAMPTZ,
ADD COLUMN deletion_scheduled_for TIMESTAMPTZ;

CREATE INDEX idx_businesses_deleted ON businesses(deleted_at) WHERE deleted_at IS NOT NULL;

-- ============================================================================
-- 3. ADD CASCADE DELETE CONSTRAINTS
-- ============================================================================

-- Customers cascade when business is hard-deleted
ALTER TABLE customers
DROP CONSTRAINT IF EXISTS customers_business_id_fkey,
ADD CONSTRAINT customers_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- Customer machines cascade when customer is deleted
ALTER TABLE customer_machines
DROP CONSTRAINT IF EXISTS customer_machines_customer_id_fkey,
ADD CONSTRAINT customer_machines_customer_id_fkey 
  FOREIGN KEY (customer_id) 
  REFERENCES customers(customer_id) 
  ON DELETE CASCADE;

ALTER TABLE customer_machines
DROP CONSTRAINT IF EXISTS customer_machines_business_id_fkey,
ADD CONSTRAINT customer_machines_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- Metrics cascade when business is deleted
ALTER TABLE metrics
DROP CONSTRAINT IF EXISTS metrics_business_id_fkey,
ADD CONSTRAINT metrics_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- Plan limits cascade when business is deleted
ALTER TABLE plan_limits
DROP CONSTRAINT IF EXISTS plan_limits_business_id_fkey,
ADD CONSTRAINT plan_limits_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- Integration keys cascade when business is deleted
ALTER TABLE integration_keys
DROP CONSTRAINT IF EXISTS integration_keys_business_id_fkey,
ADD CONSTRAINT integration_keys_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- Breach thresholds cascade when business is deleted
ALTER TABLE breach_thresholds
DROP CONSTRAINT IF EXISTS breach_thresholds_business_id_fkey,
ADD CONSTRAINT breach_thresholds_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- Provisioning queue cascade when business is deleted
ALTER TABLE provisioning_queue
DROP CONSTRAINT IF EXISTS provisioning_queue_business_id_fkey,
ADD CONSTRAINT provisioning_queue_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- User-business links cascade (user can still exist)
ALTER TABLE user_businesses
DROP CONSTRAINT IF EXISTS user_businesses_business_id_fkey,
ADD CONSTRAINT user_businesses_business_id_fkey 
  FOREIGN KEY (business_id) 
  REFERENCES businesses(business_id) 
  ON DELETE CASCADE;

-- ============================================================================
-- 4. FUNCTION TO SOFT DELETE BUSINESS
-- ============================================================================

CREATE OR REPLACE FUNCTION soft_delete_business(
  p_business_id TEXT,
  p_user_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_business RECORD;
  v_customer_count INTEGER;
  v_metrics_count INTEGER;
  v_deletion_id UUID;
BEGIN
  -- Get business info
  SELECT * INTO v_business 
  FROM businesses 
  WHERE business_id = p_business_id 
  AND deleted_at IS NULL;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Business not found or already deleted'
    );
  END IF;
  
  -- Count related records
  SELECT COUNT(*) INTO v_customer_count 
  FROM customers 
  WHERE business_id = p_business_id;
  
  SELECT COUNT(*) INTO v_metrics_count 
  FROM metrics 
  WHERE business_id = p_business_id;
  
  -- Create audit record
  INSERT INTO deleted_businesses (
    business_id,
    business_name,
    email,
    deleted_by_user_id,
    deletion_reason,
    customer_count,
    metrics_count,
    last_activity_at,
    metadata
  ) VALUES (
    p_business_id,
    v_business.business_name,
    v_business.email,
    p_user_id,
    p_reason,
    v_customer_count,
    v_metrics_count,
    v_business.updated_at,
    jsonb_build_object(
      'plan_type', v_business.plan_type,
      'subscription_status', v_business.subscription_status,
      'stripe_customer_id', v_business.stripe_customer_id
    )
  ) RETURNING id INTO v_deletion_id;
  
  -- Soft delete the business
  UPDATE businesses 
  SET 
    deleted_at = NOW(),
    deletion_scheduled_for = NOW() + INTERVAL '30 days',
    updated_at = NOW()
  WHERE business_id = p_business_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'deletion_id', v_deletion_id,
    'scheduled_for', NOW() + INTERVAL '30 days',
    'customer_count', v_customer_count,
    'metrics_count', v_metrics_count
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. FUNCTION TO RESTORE DELETED BUSINESS
-- ============================================================================

CREATE OR REPLACE FUNCTION restore_deleted_business(
  p_business_id TEXT
) RETURNS JSONB AS $$
BEGIN
  UPDATE businesses 
  SET 
    deleted_at = NULL,
    deletion_scheduled_for = NULL,
    updated_at = NOW()
  WHERE business_id = p_business_id
  AND deleted_at IS NOT NULL
  AND deletion_scheduled_for > NOW();
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Business not found or recovery period expired'
    );
  END IF;
  
  -- Mark audit record as restored
  UPDATE deleted_businesses
  SET metadata = jsonb_set(
    COALESCE(metadata, '{}'::jsonb),
    '{restored_at}',
    to_jsonb(NOW())
  )
  WHERE business_id = p_business_id
  AND metadata->>'restored_at' IS NULL;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Business restored successfully'
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. FUNCTION TO PERMANENTLY DELETE EXPIRED BUSINESSES
-- ============================================================================

CREATE OR REPLACE FUNCTION permanently_delete_expired_businesses()
RETURNS TABLE(business_id TEXT, deleted_count INTEGER) AS $$
DECLARE
  v_business RECORD;
  v_deleted_count INTEGER := 0;
BEGIN
  FOR v_business IN 
    SELECT b.business_id
    FROM businesses b
    WHERE b.deletion_scheduled_for <= NOW()
    AND b.deleted_at IS NOT NULL
  LOOP
    -- Hard delete (cascades to all related tables)
    DELETE FROM businesses WHERE business_id = v_business.business_id;
    v_deleted_count := v_deleted_count + 1;
    
    -- Update audit log
    UPDATE deleted_businesses
    SET metadata = jsonb_set(
      COALESCE(metadata, '{}'::jsonb),
      '{permanently_deleted_at}',
      to_jsonb(NOW())
    )
    WHERE business_id = v_business.business_id;
    
    RETURN QUERY SELECT v_business.business_id, v_deleted_count;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- migrate:down

-- Remove functions
DROP FUNCTION IF EXISTS permanently_delete_expired_businesses();
DROP FUNCTION IF EXISTS restore_deleted_business(TEXT);
DROP FUNCTION IF EXISTS soft_delete_business(TEXT, UUID, TEXT);

-- Remove cascade constraints (revert to NO ACTION)
ALTER TABLE user_businesses DROP CONSTRAINT IF EXISTS user_businesses_business_id_fkey;
ALTER TABLE provisioning_queue DROP CONSTRAINT IF EXISTS provisioning_queue_business_id_fkey;
ALTER TABLE breach_thresholds DROP CONSTRAINT IF EXISTS breach_thresholds_business_id_fkey;
ALTER TABLE integration_keys DROP CONSTRAINT IF EXISTS integration_keys_business_id_fkey;
ALTER TABLE plan_limits DROP CONSTRAINT IF EXISTS plan_limits_business_id_fkey;
ALTER TABLE metrics DROP CONSTRAINT IF EXISTS metrics_business_id_fkey;
ALTER TABLE customer_machines DROP CONSTRAINT IF EXISTS customer_machines_business_id_fkey;
ALTER TABLE customer_machines DROP CONSTRAINT IF EXISTS customer_machines_customer_id_fkey;
ALTER TABLE customers DROP CONSTRAINT IF EXISTS customers_business_id_fkey;

-- Remove soft delete columns
ALTER TABLE businesses 
DROP COLUMN IF EXISTS deleted_at,
DROP COLUMN IF EXISTS deletion_scheduled_for;

-- Remove audit table
DROP TABLE IF EXISTS deleted_businesses;
