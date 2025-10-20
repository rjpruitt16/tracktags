-- migrate:up
CREATE OR REPLACE FUNCTION increment_checkpoint_metric(
  p_business_id TEXT,
  p_customer_id TEXT,
  p_metric_name TEXT,
  p_increment NUMERIC,
  p_tags JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  new_value NUMERIC,
  previous_value NUMERIC
) AS $$
DECLARE
  v_old_value NUMERIC;
  v_new_value NUMERIC;
BEGIN
  -- Get current value (or 0 if doesn't exist)
  SELECT COALESCE(value, 0) INTO v_old_value
  FROM metrics
  WHERE business_id = p_business_id
    AND customer_id = p_customer_id
    AND metric_name = p_metric_name
  ORDER BY flushed_at DESC
  LIMIT 1;

  -- Calculate new value
  v_new_value := COALESCE(v_old_value, 0) + p_increment;

  -- Insert new row with tags
  INSERT INTO metrics (
    business_id,
    customer_id,
    metric_name,
    value,
    tags,
    flushed_at,
    created_at
  ) VALUES (
    p_business_id,
    p_customer_id,
    p_metric_name,
    v_new_value,
    p_tags,
    NOW(),
    NOW()
  );

  -- Return values
  RETURN QUERY SELECT v_new_value, COALESCE(v_old_value, 0);
END;
$$ LANGUAGE plpgsql;

-- migrate:down
DROP FUNCTION IF EXISTS increment_checkpoint_metric(TEXT, TEXT, TEXT, NUMERIC, JSONB);
