-- migrate:up
DROP FUNCTION IF EXISTS increment_checkpoint_metric(TEXT, TEXT, TEXT, FLOAT8, JSONB) CASCADE;

CREATE OR REPLACE FUNCTION increment_checkpoint_metric(
  p_business_id TEXT,
  p_customer_id TEXT,
  p_metric_name TEXT,
  p_increment FLOAT8,
  p_tags JSONB
)
RETURNS TABLE(new_value FLOAT8, previous_value FLOAT8)
LANGUAGE plpgsql
AS $$
DECLARE
  v_old_value NUMERIC;
  v_new_value NUMERIC;
  v_scope TEXT;
  v_customer_id TEXT;
BEGIN
  -- ✅ Convert "anonymous" to NULL to avoid foreign key constraint violation
  v_customer_id := CASE 
    WHEN p_customer_id = 'anonymous' OR p_customer_id = '' THEN NULL
    ELSE p_customer_id
  END;
  
  v_scope := CASE 
    WHEN v_customer_id IS NULL THEN 'business'
    ELSE 'customer'
  END;

  -- Get current value
  SELECT COALESCE(value, 0) INTO v_old_value
  FROM metrics
  WHERE business_id = p_business_id
    AND (customer_id = v_customer_id OR (customer_id IS NULL AND v_customer_id IS NULL))
    AND metric_name = p_metric_name
    AND scope = v_scope
  ORDER BY flushed_at DESC
  LIMIT 1;

  v_new_value := COALESCE(v_old_value, 0) + p_increment;

  -- Insert with NULL customer_id if business scope
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
    v_customer_id,  -- ✅ NULL for business scope
    v_scope,
    p_metric_name,
    'checkpoint',
    v_new_value,
    p_tags,
    NOW(),
    NOW()
  );

  RETURN QUERY SELECT v_new_value::FLOAT8, v_old_value::FLOAT8;
END;
$$;

-- migrate:down
DROP FUNCTION IF EXISTS increment_checkpoint_metric(TEXT, TEXT, TEXT, FLOAT8, JSONB) CASCADE;
