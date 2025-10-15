-- db/migrations/YYYYMMDD_fix_customer_key_validation.sql
-- migrate:up

CREATE OR REPLACE FUNCTION validate_key_and_get_context(
  p_api_key_hash TEXT
) RETURNS JSON AS $$
DECLARE
  v_key integration_keys%ROWTYPE;
  v_context JSON;
  v_customer_id TEXT;
BEGIN
  SELECT * INTO v_key
  FROM integration_keys
  WHERE key_hash = p_api_key_hash
  AND is_active = true;

  IF NOT FOUND THEN
    RETURN json_build_object('error', 'Invalid key');
  END IF;

  IF v_key.key_type = 'customer_api' THEN
    -- Extract customer_id from key_name by removing the timestamp suffix
    -- key_name format: cust_XXXXX_YYYYYYYY -> extract cust_XXXXX
    v_customer_id := regexp_replace(v_key.key_name, '_[0-9]+$', '');
    
    SELECT json_build_object(
      'customer', row_to_json(c.*),
      'machines', COALESCE(
        (SELECT json_agg(cm.*)
         FROM customer_machines cm
         WHERE cm.customer_id = v_customer_id
         AND cm.status = 'running'),
        '[]'::json
      ),
      'plan_limits', COALESCE(
        (SELECT json_agg(pl.*)
         FROM plan_limits pl
         WHERE (pl.customer_id = v_customer_id)
            OR (pl.business_id = v_key.business_id AND pl.customer_id IS NULL)
         ORDER BY pl.customer_id NULLS LAST),
        '[]'::json
      )
    ) INTO v_context
    FROM customers c
    WHERE c.customer_id = v_customer_id
    AND c.business_id = v_key.business_id;

    RETURN json_build_object(
      'key_type', 'customer',
      'business_id', v_key.business_id,
      'customer_id', v_customer_id,
      'context', v_context
    );
  ELSE
    RETURN json_build_object(
      'key_type', 'business',
      'business_id', v_key.business_id
    );
  END IF;
END;
$$ LANGUAGE plpgsql;

-- migrate:down
-- (keep the old version)
