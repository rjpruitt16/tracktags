-- migrate:up
CREATE TABLE IF NOT EXISTS user_businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  business_id TEXT NOT NULL REFERENCES businesses(business_id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, business_id)
);

-- Create index for faster lookups
CREATE INDEX idx_user_businesses_user_id ON user_businesses(user_id);
CREATE INDEX idx_user_businesses_business_id ON user_businesses(business_id);

-- migrate:down
DROP TABLE IF EXISTS user_businesses CASCADE;
