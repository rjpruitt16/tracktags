-- Just create one more migration for remaining changes
-- db/migrations/20250117000001_machine_provisioning_final.sql

-- migrate:up
ALTER TABLE plan_machines ADD COLUMN grace_period_days INT DEFAULT 3;
ALTER TABLE businesses ADD COLUMN machine_grace_period_days INT DEFAULT 3;  -- Fallback

-- migrate:down  
ALTER TABLE plan_machines DROP COLUMN IF EXISTS grace_period_days;
ALTER TABLE businesses DROP COLUMN IF EXISTS machine_grace_period_days;
