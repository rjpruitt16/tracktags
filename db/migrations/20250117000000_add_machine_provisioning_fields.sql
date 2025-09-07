-- migrate:up

-- Business defaults (docker_image NULL to force configuration)
ALTER TABLE businesses 
ADD COLUMN default_docker_image TEXT DEFAULT NULL,
ADD COLUMN default_machine_size TEXT DEFAULT 'shared-cpu-1x',
ADD COLUMN default_region TEXT DEFAULT 'iad';

-- Plan overrides
ALTER TABLE plan_machines 
ADD COLUMN docker_image TEXT,
ADD COLUMN allowed_regions TEXT[];

-- Customer machine tracking
ALTER TABLE customer_machines
ADD COLUMN docker_image TEXT,
ADD COLUMN fly_state TEXT,
ADD COLUMN fly_app_name TEXT UNIQUE,
ADD COLUMN expires_at TIMESTAMPTZ;

-- Provisioning queue improvements
ALTER TABLE provisioning_queue
ADD COLUMN dead_letter_at TIMESTAMPTZ,
ADD COLUMN notification_sent BOOLEAN DEFAULT FALSE;

-- Indexes
CREATE INDEX idx_customer_machines_expires ON customer_machines(expires_at) 
WHERE status != 'terminated';

CREATE INDEX idx_provisioning_dead_letter ON provisioning_queue(dead_letter_at)
WHERE status = 'dead_letter' AND notification_sent = FALSE;

-- migrate:down

-- Remove indexes
DROP INDEX IF EXISTS idx_customer_machines_expires;
DROP INDEX IF EXISTS idx_provisioning_dead_letter;

-- Remove provisioning queue columns
ALTER TABLE provisioning_queue
DROP COLUMN IF EXISTS dead_letter_at,
DROP COLUMN IF EXISTS notification_sent;

-- Remove customer machine columns
ALTER TABLE customer_machines
DROP COLUMN IF EXISTS docker_image,
DROP COLUMN IF EXISTS fly_state,
DROP COLUMN IF EXISTS fly_app_name,
DROP COLUMN IF EXISTS expires_at;

-- Remove plan machine columns
ALTER TABLE plan_machines
DROP COLUMN IF EXISTS docker_image,
DROP COLUMN IF EXISTS allowed_regions;

-- Remove business columns
ALTER TABLE businesses 
DROP COLUMN IF EXISTS default_docker_image,
DROP COLUMN IF EXISTS default_machine_size,
DROP COLUMN IF EXISTS default_region;
