-- db/migrations/20250118000002_add_get_customer_context_function.sql

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
      (SELECT json_agg(subquery.*)
       FROM (
         SELECT * FROM plan_limits pl
         WHERE (pl.customer_id = p_customer_id AND pl.business_id = p_business_id)
            OR (pl.business_id = p_business_id AND pl.customer_id IS NULL AND 
                EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND plan_id = pl.plan_id))
         ORDER BY pl.customer_id DESC NULLS LAST
       ) subquery),
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
