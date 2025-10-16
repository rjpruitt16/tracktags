-- migrate:up
ALTER TABLE customers 
ADD COLUMN stripe_price_id TEXT;

COMMENT ON COLUMN customers.stripe_price_id IS 'The Stripe Price ID for the customer''s current subscription plan';

-- migrate:down
ALTER TABLE customers 
DROP COLUMN stripe_price_id;
