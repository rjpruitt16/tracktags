-- TracKTags Database Schema
-- Generated: October 16, 2025
-- Includes: Tables, Indexes, Foreign Keys, Unique Constraints

-- ============================================================================
-- BUSINESSES
-- ============================================================================
CREATE TABLE IF NOT EXISTS businesses (
    business_id TEXT PRIMARY KEY,
    business_name TEXT NOT NULL,
    email TEXT NOT NULL,
    plan_type TEXT DEFAULT 'free',
    current_plan_id UUID,
    stripe_customer_id TEXT UNIQUE,
    stripe_subscription_id TEXT,
    stripe_price_id TEXT,
    subscription_status TEXT DEFAULT 'active',
    subscription_ends_at TIMESTAMP WITH TIME ZONE,
    subscription_override_expires_at TIMESTAMP WITH TIME ZONE,
    default_region TEXT,
    default_machine_size TEXT,
    default_docker_image TEXT,
    machine_grace_period_days INTEGER DEFAULT 7,
    user_id UUID,
    deletion_scheduled_for TIMESTAMP WITH TIME ZONE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_businesses_email ON businesses(email);
CREATE INDEX IF NOT EXISTS idx_businesses_status ON businesses(subscription_status);
CREATE INDEX IF NOT EXISTS idx_businesses_stripe_customer ON businesses(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_businesses_stripe_subscription ON businesses(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_businesses_user ON businesses(user_id);
CREATE INDEX IF NOT EXISTS idx_businesses_deleted ON businesses(deleted_at) WHERE deleted_at IS NOT NULL;

-- ============================================================================
-- CUSTOMERS
-- ============================================================================
CREATE TABLE IF NOT EXISTS customers (
    business_id TEXT NOT NULL,
    customer_id TEXT PRIMARY KEY,
    customer_name TEXT NOT NULL,
    plan_id UUID,
    stripe_customer_id TEXT,
    stripe_subscription_id TEXT,
    stripe_product_id TEXT,
    stripe_price_id TEXT,
    subscription_ends_at TIMESTAMP WITH TIME ZONE,
    last_invoice_date TIMESTAMP WITH TIME ZONE,
    user_id UUID,
    deleted_at TIMESTAMP WITH TIME ZONE,
    deleted_by TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT customers_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_customers_business ON customers(business_id);
CREATE INDEX IF NOT EXISTS idx_customers_stripe_customer ON customers(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_customers_plan ON customers(plan_id);
CREATE INDEX IF NOT EXISTS idx_customers_stripe_subscription ON customers(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_customers_user ON customers(user_id);
CREATE INDEX IF NOT EXISTS idx_customers_deleted_at ON customers(deleted_at) WHERE deleted_at IS NOT NULL;

-- ============================================================================
-- PLANS
-- ============================================================================
CREATE TABLE IF NOT EXISTS plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    plan_name TEXT NOT NULL,
    stripe_price_id TEXT,
    plan_status TEXT DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT plans_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id)
);

-- Indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_one_free_plan_per_business ON plans(business_id) WHERE stripe_price_id IS NULL;

-- Foreign key from businesses back to plans
ALTER TABLE businesses ADD CONSTRAINT IF NOT EXISTS fk_current_plan FOREIGN KEY (current_plan_id) REFERENCES plans(id);

-- Foreign key from customers to plans
ALTER TABLE customers ADD CONSTRAINT IF NOT EXISTS customers_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES plans(id);

-- ============================================================================
-- PLAN_LIMITS
-- ============================================================================
CREATE TABLE IF NOT EXISTS plan_limits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    plan_id UUID NOT NULL,
    metric_name TEXT NOT NULL,
    metric_type TEXT DEFAULT 'checkpoint',
    limit_value DOUBLE PRECISION NOT NULL,
    breach_operator TEXT DEFAULT 'gte',
    breach_action TEXT DEFAULT 'deny',
    webhook_urls TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT plan_limits_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    CONSTRAINT plan_limits_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_plan_limits_plan ON plan_limits(plan_id);
CREATE INDEX IF NOT EXISTS idx_plan_limits_business ON plan_limits(business_id);
CREATE INDEX IF NOT EXISTS idx_plan_limits_metric ON plan_limits(metric_name);

-- ============================================================================
-- PLAN_MACHINES
-- ============================================================================
CREATE TABLE IF NOT EXISTS plan_machines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id UUID NOT NULL,
    provider TEXT DEFAULT 'fly',
    machine_count INTEGER DEFAULT 0,
    machine_size TEXT,
    machine_memory INTEGER,
    region TEXT,
    allowed_regions TEXT[],
    docker_image TEXT,
    auto_scale BOOLEAN DEFAULT FALSE,
    grace_period_days INTEGER DEFAULT 7,
    environment_vars JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT plan_machines_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE,
    UNIQUE(plan_id, provider)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_plan_machines_plan ON plan_machines(plan_id);

-- ============================================================================
-- METRICS
-- ============================================================================
CREATE TABLE IF NOT EXISTS metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    customer_id TEXT,
    scope TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    metric_type TEXT DEFAULT 'reset',
    value DOUBLE PRECISION DEFAULT 0.0,
    tags JSONB,
    adapters JSONB,
    threshold_value DOUBLE PRECISION,
    threshold_operator TEXT,
    threshold_action TEXT,
    webhook_urls TEXT,
    region TEXT,
    machine_id TEXT,
    flushed_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT metrics_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    CONSTRAINT metrics_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_metrics_scope ON metrics(scope);
CREATE INDEX IF NOT EXISTS idx_metrics_type ON metrics(metric_type);
CREATE INDEX IF NOT EXISTS idx_metrics_name ON metrics(metric_name);
CREATE INDEX IF NOT EXISTS idx_metrics_business_time ON metrics(business_id, flushed_at DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_customer_time ON metrics(customer_id, flushed_at DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_tags ON metrics USING gin(tags);

-- ============================================================================
-- CUSTOMER_MACHINES
-- ============================================================================
CREATE TABLE IF NOT EXISTS customer_machines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    customer_id TEXT NOT NULL,
    machine_id TEXT NOT NULL,
    provider TEXT DEFAULT 'fly',
    status TEXT DEFAULT 'pending',
    fly_state TEXT,
    app_name TEXT,
    fly_app_name TEXT UNIQUE,
    machine_url TEXT,
    internal_url TEXT,
    ip_address TEXT,
    machine_size TEXT,
    region TEXT,
    docker_image TEXT,
    environment_vars JSONB,
    expires_at TIMESTAMP WITH TIME ZONE,
    last_invoice_date TIMESTAMP WITH TIME ZONE,
    next_invoice_expected TIMESTAMP WITH TIME ZONE,
    grace_period_ends TIMESTAMP WITH TIME ZONE,
    last_health_check TIMESTAMP WITH TIME ZONE,
    terminated_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT customer_machines_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    CONSTRAINT customer_machines_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    UNIQUE(customer_id, provider, machine_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_customer_machines_customer ON customer_machines(customer_id);
CREATE INDEX IF NOT EXISTS idx_customer_machines_status ON customer_machines(status);
CREATE INDEX IF NOT EXISTS idx_customer_machines_expires ON customer_machines(expires_at) WHERE status <> 'terminated';
CREATE INDEX IF NOT EXISTS idx_customer_machines_billing ON customer_machines(next_invoice_expected, grace_period_ends);

-- ============================================================================
-- INTEGRATION_KEYS
-- ============================================================================
CREATE TABLE IF NOT EXISTS integration_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    key_name TEXT NOT NULL,
    key_type TEXT NOT NULL,
    key_hash TEXT NOT NULL,
    encrypted_key TEXT NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT integration_keys_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    UNIQUE(business_id, key_type, key_name),
    UNIQUE(business_id, key_hash)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_integration_keys_business ON integration_keys(business_id);
CREATE INDEX IF NOT EXISTS idx_integration_keys_key_hash ON integration_keys(key_hash);
CREATE INDEX IF NOT EXISTS idx_integration_keys_type ON integration_keys(key_type);
CREATE INDEX IF NOT EXISTS idx_integration_keys_active ON integration_keys(is_active);

-- ============================================================================
-- STRIPE_EVENTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS stripe_events (
    event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    business_id TEXT,
    customer_id TEXT,
    source TEXT DEFAULT 'platform',
    source_business_id TEXT,
    status TEXT DEFAULT 'pending',
    retry_count INTEGER DEFAULT 0,
    error_message TEXT,
    raw_payload JSONB NOT NULL,
    processed_at TIMESTAMP WITH TIME ZONE,
    last_retry_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT stripe_events_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    CONSTRAINT stripe_events_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_stripe_events_status ON stripe_events(status);
CREATE INDEX IF NOT EXISTS idx_stripe_events_business ON stripe_events(business_id);
CREATE INDEX IF NOT EXISTS idx_stripe_events_customer ON stripe_events(customer_id);
CREATE INDEX IF NOT EXISTS idx_stripe_events_source ON stripe_events(source, source_business_id);
CREATE INDEX IF NOT EXISTS idx_stripe_events_failed ON stripe_events(status) WHERE status = 'failed';

-- ============================================================================
-- PROVISIONING_QUEUE
-- ============================================================================
CREATE TABLE IF NOT EXISTS provisioning_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    customer_id TEXT NOT NULL,
    action TEXT NOT NULL,
    provider TEXT DEFAULT 'fly',
    status TEXT DEFAULT 'pending',
    idempotency_key TEXT UNIQUE,
    payload JSONB,
    attempt_count INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 5,
    error_message TEXT,
    notification_sent BOOLEAN DEFAULT FALSE,
    next_retry_at TIMESTAMP WITH TIME ZONE,
    last_attempt_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    dead_letter_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT provisioning_queue_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    CONSTRAINT provisioning_queue_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_provisioning_queue_status ON provisioning_queue(status);
CREATE INDEX IF NOT EXISTS idx_provisioning_queue_next_retry ON provisioning_queue(next_retry_at);
CREATE INDEX IF NOT EXISTS idx_provisioning_dead_letter ON provisioning_queue(dead_letter_at) WHERE status = 'dead_letter' AND notification_sent = false;

-- ============================================================================
-- BREACH_THRESHOLDS
-- ============================================================================
CREATE TABLE IF NOT EXISTS breach_thresholds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    client_id TEXT,
    metric_name TEXT NOT NULL,
    threshold_value DOUBLE PRECISION NOT NULL,
    threshold_operator TEXT DEFAULT 'gte',
    webhook_url TEXT,
    integration_key_id UUID,
    scaling_config JSONB,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT breach_thresholds_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    UNIQUE(business_id, client_id, metric_name)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_breach_thresholds_business ON breach_thresholds(business_id);
CREATE INDEX IF NOT EXISTS idx_breach_thresholds_client ON breach_thresholds(client_id);
CREATE INDEX IF NOT EXISTS idx_breach_thresholds_active ON breach_thresholds(is_active);

-- ============================================================================
-- AUDIT_LOGS
-- ============================================================================
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT NOT NULL,
    actor_id TEXT,
    details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_audit_logs_resource ON audit_logs(resource_type, resource_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON audit_logs(actor_id);

-- ============================================================================
-- CUSTOMER_BILLING_PERIODS
-- ============================================================================
CREATE TABLE IF NOT EXISTS customer_billing_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    stripe_subscription_id TEXT,
    period_end TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT customer_billing_periods_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    UNIQUE(customer_id, metric_name)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_customer_billing_periods_customer ON customer_billing_periods(customer_id);
CREATE INDEX IF NOT EXISTS idx_customer_billing_periods_metric ON customer_billing_periods(customer_id, metric_name);

-- ============================================================================
-- DELETED_BUSINESSES
-- ============================================================================
CREATE TABLE IF NOT EXISTS deleted_businesses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT NOT NULL,
    business_name TEXT,
    email TEXT,
    customer_count INTEGER DEFAULT 0,
    metrics_count INTEGER DEFAULT 0,
    deletion_reason TEXT,
    deleted_by_user_id UUID,
    deletion_requested_at TIMESTAMP WITH TIME ZONE,
    scheduled_permanent_deletion_at TIMESTAMP WITH TIME ZONE,
    last_activity_at TIMESTAMP WITH TIME ZONE,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_deleted_businesses_business_id ON deleted_businesses(business_id);
CREATE INDEX IF NOT EXISTS idx_deleted_businesses_scheduled ON deleted_businesses(scheduled_permanent_deletion_at);

-- ============================================================================
-- STRIPE_RECONCILIATION
-- ============================================================================
CREATE TABLE IF NOT EXISTS stripe_reconciliation (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id TEXT,
    reconciliation_type TEXT NOT NULL,
    total_checked INTEGER DEFAULT 0,
    mismatches_found INTEGER DEFAULT 0,
    mismatches_fixed INTEGER DEFAULT 0,
    errors_encountered INTEGER DEFAULT 0,
    details JSONB,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_reconciliation_business FOREIGN KEY (business_id) REFERENCES businesses(business_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_reconciliation_business ON stripe_reconciliation(business_id);
CREATE INDEX IF NOT EXISTS idx_reconciliation_type ON stripe_reconciliation(reconciliation_type);
CREATE INDEX IF NOT EXISTS idx_reconciliation_completed ON stripe_reconciliation(completed_at DESC);

-- ============================================================================
-- USER_BUSINESSES
-- ============================================================================
CREATE TABLE IF NOT EXISTS user_businesses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    business_id TEXT NOT NULL,
    role TEXT DEFAULT 'admin',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT user_businesses_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(business_id),
    UNIQUE(user_id, business_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_user_businesses_user_id ON user_businesses(user_id);
CREATE INDEX IF NOT EXISTS idx_user_businesses_business_id ON user_businesses(business_id);

-- ============================================================================
-- MACHINE_EVENTS
-- ============================================================================
CREATE TABLE IF NOT EXISTS machine_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    machine_id TEXT NOT NULL,
    customer_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    event_type TEXT NOT NULL,
    details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT machine_events_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_machine_events_customer ON machine_events(customer_id);
CREATE INDEX IF NOT EXISTS idx_machine_events_created ON machine_events(created_at DESC);

-- ============================================================================
-- SCHEMA_MIGRATIONS
-- ============================================================================
CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR PRIMARY KEY
);
