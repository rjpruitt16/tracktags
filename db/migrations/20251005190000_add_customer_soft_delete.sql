-- db/migrations/20251005190000_add_customer_soft_delete.sql
-- migrate:up

-- Add soft delete columns to customers table
ALTER TABLE customers 
ADD COLUMN deleted_at TIMESTAMPTZ,
ADD COLUMN deleted_by TEXT;

-- Index for filtering out deleted customers (partial index for efficiency)
CREATE INDEX idx_customers_deleted_at ON customers(deleted_at) WHERE deleted_at IS NOT NULL;

-- migrate:down

-- Remove index
DROP INDEX IF EXISTS idx_customers_deleted_at;

-- Remove columns
ALTER TABLE customers 
DROP COLUMN IF EXISTS deleted_at,
DROP COLUMN IF EXISTS deleted_by;
