-- migrate:up
DROP FUNCTION IF EXISTS get_plan_limit_by_price(TEXT, TEXT);

CREATE OR REPLACE FUNCTION get_plan_limit_by_price(
  p_stripe_price_id TEXT,
  p_metric_name TEXT
)
RETURNS TABLE (
  id UUID,
  plan_id UUID,
  business_id TEXT,
  metric_name TEXT,
  limit_value DOUBLE PRECISION,
  breach_operator TEXT,
  breach_action TEXT,
  metric_type TEXT,
  webhook_urls TEXT,  -- ← Changed from TEXT[] to TEXT
  created_at TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pl.id,
    pl.plan_id,
    pl.business_id,
    pl.metric_name,
    pl.limit_value,
    pl.breach_operator,
    pl.breach_action,
    pl.metric_type,
    pl.webhook_urls,
    pl.created_at
  FROM plan_limits pl
  JOIN plans p ON p.id = pl.plan_id
  WHERE p.stripe_price_id = p_stripe_price_id
    AND pl.metric_name = p_metric_name
  LIMIT 1;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_plan_limit_by_price IS 'Look up plan limits by Stripe price ID for real-time plan upgrades';

-- migrate:down
DROP FUNCTION IF EXISTS get_plan_limit_by_price(TEXT, TEXT);
