-- init-db.sql
-- Runs once when PostgreSQL container initializes (docker-entrypoint-initdb.d).
-- Creates all required databases for the Arda platform.
--
-- NOTE: arda_central is created automatically by POSTGRES_DB env var in docker-compose.
--       This script handles the remaining databases.

-- IAM database (used by Keycloak + arda-iam-service)
SELECT 'CREATE DATABASE arda_iam'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'arda_iam')\gexec

-- Notification database (used by arda-notification service)
SELECT 'CREATE DATABASE arda_notification'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'arda_notification')\gexec
