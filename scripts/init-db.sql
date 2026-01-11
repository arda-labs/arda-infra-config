-- Database arda_central is created by POSTGRES_DB env var

-- Create arda_iam if it doesn't exist
SELECT 'CREATE DATABASE arda_iam'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'arda_iam')\gexec

-- Connect to arda_central to create tables
\c arda_central;

CREATE TABLE IF NOT EXISTS tenants (
    id SERIAL PRIMARY KEY,
    tenant_key VARCHAR(50) UNIQUE NOT NULL,
    db_url VARCHAR(255) NOT NULL,
    db_type VARCHAR(20) CHECK (db_type IN ('Postgres', 'Oracle')) NOT NULL
);
