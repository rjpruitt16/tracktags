-- migrate:up
CREATE OR REPLACE FUNCTION increment_checkpoint_metric(
  p_business_id TEXT,
  p_customer_id TEXT,
  p_metric_name TEXT,
  p_delta FLOAT,
  p_scope TEXT,
  p_tags JSONB DEFAULT '{}'::jsonb
) RETURNS FLOAT AS $$
DECLARE
  new_value FLOAT;
BEGIN
  -- Try to update first
  UPDATE metrics
  SET value = value + p_delta,
      tags = p_tags,
      flushed_at = NOW()
  WHERE business_id = p_business_id
    AND (customer_id = p_customer_id OR (customer_id IS NULL AND p_customer_id IS NULL))
    AND metric_name = p_metric_name
    AND scope = p_scope
  RETURNING value INTO new_value;
  
  -- If no row was updated, insert
  IF NOT FOUND THEN
    INSERT INTO metrics (
      business_id, customer_id, metric_name, value, metric_type, scope, tags, flushed_at
    ) VALUES (
      p_business_id, p_customer_id, p_metric_name, p_delta, 'checkpoint', p_scope, p_tags, NOW()
    )
    RETURNING value INTO new_value;
  END IF;
  
  RETURN new_value;
END;
$$ LANGUAGE plpgsql;

-- migrate:down
DROP FUNCTION IF EXISTS increment_checkpoint_metric;
