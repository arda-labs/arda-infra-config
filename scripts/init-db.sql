-- Database arda_central is created by POSTGRES_DB env var

-- Create arda_iam if it doesn't exist
SELECT 'CREATE DATABASE arda_iam'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'arda_iam')\gexec

-- Connect to arda_central to create tables
\c arda_central;

-- ============================================================================
-- Tenants Table
-- Stores tenant metadata and database connection information
-- ============================================================================
CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_key VARCHAR(50) UNIQUE NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',

    -- UI Configuration
    logo_url VARCHAR(500),
    primary_color VARCHAR(7),

    -- Database Infrastructure Configuration
    db_type VARCHAR(20) NOT NULL CHECK (db_type IN ('POSTGRES', 'ORACLE')),
    jdbc_url VARCHAR(500) NOT NULL,
    db_username VARCHAR(100) NOT NULL,
    db_password VARCHAR(255) NOT NULL,
    driver_class_name VARCHAR(255) NOT NULL,

    -- Audit Fields
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Create index on tenant_key for fast lookups
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_key ON tenants(tenant_key);

-- ============================================================================
-- Sample Seed Data (Optional - for development)
-- ============================================================================
-- Uncomment to insert sample tenant data
/*
INSERT INTO tenants (tenant_key, display_name, status, primary_color, db_type, jdbc_url, db_username, db_password, driver_class_name)
VALUES
    ('acme-corp', 'ACME Corporation', 'ACTIVE', '#3B82F6', 'POSTGRES', 'jdbc:postgresql://localhost:5432/acme_corp', 'postgres', 'postgres', 'org.postgresql.Driver'),
    ('tech-startup', 'Tech Startup Inc', 'ACTIVE', '#10B981', 'POSTGRES', 'jdbc:postgresql://localhost:5432/tech_startup', 'postgres', 'postgres', 'org.postgresql.Driver')
ON CONFLICT (tenant_key) DO NOTHING;
*/
