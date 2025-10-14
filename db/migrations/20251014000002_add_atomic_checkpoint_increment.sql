-- migrate:up
CREATE OR REPLACE FUNCTION increment_checkpoint_metric(
  p_business_id TEXT,
  p_customer_id TEXT,
  p_metric_name TEXT,
  p_delta FLOAT,
  p_scope TEXT DEFAULT 'business'
) RETURNS FLOAT AS $$
DECLARE
  new_value FLOAT;
BEGIN
  -- Upsert: increment if exists, insert if not
  INSERT INTO metrics (
    business_id,
    customer_id,
    metric_name,
    value,
    metric_type,
    scope,
    created_at,
    updated_at
  ) VALUES (
    p_business_id,
    p_customer_id,
    p_metric_name,
    p_delta,
    'checkpoint',
    p_scope,
    NOW(),
    NOW()
  )
  ON CONFLICT (business_id, COALESCE(customer_id, ''), metric_name, scope)
  DO UPDATE SET
    value = metrics.value + p_delta,
    updated_at = NOW()
  RETURNING value INTO new_value;
  
  RETURN new_value;
END;
$$ LANGUAGE plpgsql;

-- migrate:down
DROP FUNCTION IF EXISTS increment_checkpoint_metric;
