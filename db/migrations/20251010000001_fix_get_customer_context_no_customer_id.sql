-- migrate:up
CREATE OR REPLACE FUNCTION get_customer_context(
  p_business_id TEXT,
  p_customer_id TEXT
) RETURNS JSON AS $$
DECLARE
  v_context JSON;
BEGIN
  SELECT json_build_object(
    'customer', row_to_json(c.*),
    'machines', COALESCE(
      (SELECT json_agg(cm.*) 
       FROM customer_machines cm 
       WHERE cm.customer_id = p_customer_id 
       AND cm.business_id = p_business_id), 
      '[]'::json
    ),
    'plan_limits', COALESCE(
      (SELECT json_agg(pl.*)
       FROM plan_limits pl
       WHERE pl.business_id = p_business_id 
       AND (
         pl.plan_id IS NULL 
         OR pl.plan_id = c.plan_id
       )),
      '[]'::json
    )
  ) INTO v_context
  FROM customers c
  WHERE c.customer_id = p_customer_id
  AND c.business_id = p_business_id;
  
  IF v_context IS NULL THEN
    RETURN json_build_object('error', 'Customer not found');
  END IF;
  
  RETURN v_context;
END;
$$ LANGUAGE plpgsql;

-- migrate:down
DROP FUNCTION IF EXISTS get_customer_context(TEXT, TEXT);
