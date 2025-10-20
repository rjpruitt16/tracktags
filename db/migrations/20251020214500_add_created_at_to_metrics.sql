-- migrate:up
-- Add created_at column to metrics table
ALTER TABLE metrics 
ADD COLUMN IF NOT EXISTS created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- Backfill existing rows (use flushed_at as created_at for historical data)
UPDATE metrics 
SET created_at = COALESCE(flushed_at, NOW())
WHERE created_at IS NULL;

-- Make created_at NOT NULL after backfilling
ALTER TABLE metrics 
ALTER COLUMN created_at SET NOT NULL;

-- Add index on created_at for time-based queries
CREATE INDEX IF NOT EXISTS idx_metrics_created_at ON metrics(created_at DESC);

-- migrate:down
-- Remove index
DROP INDEX IF EXISTS idx_metrics_created_at;

-- Remove column
ALTER TABLE metrics DROP COLUMN IF EXISTS created_at;
