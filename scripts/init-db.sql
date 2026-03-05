-- Database arda_central is created by POSTGRES_DB env var in docker-compose.yml

-- Create arda_iam database
SELECT 'CREATE DATABASE arda_iam'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'arda_iam')\gexec

-- Create arda_notification database
SELECT 'CREATE DATABASE arda_notification'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'arda_notification')\gexec

-- Log creation
\echo '============================================'
\echo 'PostgreSQL Databases initialized:'
\echo ' - arda_central (Main Config & Tenants)'
\echo ' - arda_iam (Keycloak & User Identity)'
\echo ' - arda_notification (Notification Service)'
\echo '============================================'

