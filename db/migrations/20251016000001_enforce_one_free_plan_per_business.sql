-- migrate:up
-- Remove duplicate free plans (keep only the oldest one per business)
DELETE FROM plan_limits 
WHERE plan_id IN (
  SELECT p.id 
  FROM plans p
  INNER JOIN (
    SELECT business_id, MIN(created_at) as first_created
    FROM plans
    WHERE stripe_price_id IS NULL
    GROUP BY business_id
    HAVING COUNT(*) > 1
  ) dupes ON p.business_id = dupes.business_id
  WHERE p.stripe_price_id IS NULL 
  AND p.created_at > dupes.first_created
);

DELETE FROM plans
WHERE id IN (
  SELECT p.id 
  FROM plans p
  INNER JOIN (
    SELECT business_id, MIN(created_at) as first_created
    FROM plans
    WHERE stripe_price_id IS NULL
    GROUP BY business_id
    HAVING COUNT(*) > 1
  ) dupes ON p.business_id = dupes.business_id
  WHERE p.stripe_price_id IS NULL 
  AND p.created_at > dupes.first_created
);

-- Now create the unique index
CREATE UNIQUE INDEX idx_one_free_plan_per_business 
ON plans (business_id) 
WHERE stripe_price_id IS NULL;

COMMENT ON INDEX idx_one_free_plan_per_business IS 
'Ensures each business can only have one free plan (where stripe_price_id is NULL)';

-- migrate:down
DROP INDEX IF EXISTS idx_one_free_plan_per_business;
