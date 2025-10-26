-- migrate:up

-- Drop ALL old versions to prevent conflicts
DROP FUNCTION IF EXISTS increment_checkpoint_metric(text, text, text, double precision, jsonb);
DROP FUNCTION IF EXISTS increment_checkpoint_metric(text, text, text, numeric, jsonb);
DROP FUNCTION IF EXISTS increment_checkpoint_metric(text, text, text, double precision, text, jsonb);

-- Create the new version with scope parameter
CREATE OR REPLACE FUNCTION increment_checkpoint_metric(
  p_business_id TEXT,
  p_customer_id TEXT,
  p_metric_name TEXT,
  p_delta NUMERIC,
  p_scope TEXT,
  p_tags JSONB DEFAULT '{}'::jsonb
)
RETURNS NUMERIC AS $$
DECLARE
  v_old_value NUMERIC;
  v_new_value NUMERIC;
BEGIN
  -- Get current value with scope filter
  SELECT COALESCE(value, 0) INTO v_old_value
  FROM metrics
  WHERE business_id = p_business_id
    AND (customer_id = p_customer_id OR (customer_id IS NULL AND p_customer_id IS NULL))
    AND metric_name = p_metric_name
    AND scope = p_scope
  ORDER BY flushed_at DESC
  LIMIT 1;
  
  -- Calculate new value
  v_new_value := COALESCE(v_old_value, 0) + p_delta;
  
  -- Insert new row with all required fields
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
    p_scope,
    p_metric_name,
    'checkpoint',
    v_new_value,
    p_tags,
    NOW(),
    NOW()
  );
  
  -- Return new value directly (not as table)
  RETURN v_new_value;
END;
$$ LANGUAGE plpgsql;

-- migrate:down

-- Drop the new version
DROP FUNCTION IF EXISTS increment_checkpoint_metric(text, text, text, numeric, text, jsonb);

-- Revert to old signature (without scope)
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
  SELECT COALESCE(value, 0) INTO v_old_value
  FROM metrics
  WHERE business_id = p_business_id
    AND customer_id = p_customer_id
    AND metric_name = p_metric_name
  ORDER BY flushed_at DESC
  LIMIT 1;
  
  v_new_value := COALESCE(v_old_value, 0) + p_increment;
  
  INSERT INTO metrics (
    business_id,
    customer_id,
    metric_name,
    value,
    tags,
    flushed_at,
    created_a
