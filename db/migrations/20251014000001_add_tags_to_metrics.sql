-- migrate:up
ALTER TABLE metrics ADD COLUMN tags JSONB DEFAULT '{}';
CREATE INDEX idx_metrics_tags ON metrics USING GIN (tags);

-- migrate:down
DROP INDEX IF EXISTS idx_metrics_tags;
ALTER TABLE metrics DROP COLUMN tags;
