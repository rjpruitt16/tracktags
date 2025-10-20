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
  v_scope TEXT;
BEGIN
  -- Determine scope based on customer_id
  v_scope := CASE 
    WHEN p_customer_id IS NULL OR p_customer_id = '' THEN 'business'
    ELSE 'customer'
  END;

  -- Get current value
  SELECT COALESCE(value, 0) INTO v_old_value
  FROM metrics
  WHERE business_id = p_business_id
    AND (customer_id = p_customer_id OR (customer_id IS NULL AND p_customer_id IS NULL))
    AND metric_name = p_metric_name
    AND scope = v_scope
  ORDER BY flushed_at DESC
  LIMIT 1;

  -- Calculate new value
  v_new_value := COALESCE(v_old_value, 0) + p_increment;

  -- Insert new row with ALL required fields
  INSERT INTO metrics (
    business_id,
    customer_id,
    scope,
    metric_name,
    metric_type,
    value,
    tags,
    flushed_at,
    created_at
  ) VALUES (
    p_business_id,
    p_customer_id,
    v_scope,
    p_metric_name,
    'checkpoint',  -- ✅ Always checkpoint for this RPC
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
