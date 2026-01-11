# Arda Infrastructure Config

This repository contains the infrastructure configuration for the **Arda** Multi-tenant SaaS system, managed via Docker Compose.

## Structure

- `docker-compose/`: Contains the `docker-compose.yml` file.
- `apisix/`: Configuration files for APISIX Gateway.
- `keycloak/`: Configuration for Keycloak (if any).
- `scripts/`: Helper scripts for initialization and setup.

## Getting Started

### Prerequisites

- Docker Desktop (or Docker Engine + Compose Plugin) installed.

### Running the System

1. Navigate to the `docker-compose` directory:

   ```bash
   cd docker-compose
   ```

2. Start the services:
   ```bash
   docker-compose up -d
   ```

## Database Initialization

The Postgres database is automatically initialized using the `scripts/init-db.sql` script.

This is achieved by mounting the script into the `arda-postgres` container at runtime. The configuration is found in `docker-compose.yml`:

```yaml
volumes:
  - ../scripts/init-db.sql:/docker-entrypoint-initdb.d/init-db.sql
```

The script:

1. Creates `arda_central` and `arda_iam` databases.
2. Creates the `tenants` table in `arda_central`.

## APISIX Setup

After the services are up, run the route setup script to configure the Gateway routes.

1. Ensure you are in the root directory (or adjust path).
2. Run the script:
   ```bash
   bash scripts/setup-apisix-routes.sh
   # Or on Windows Git Bash
   ./scripts/setup-apisix-routes.sh
   ```

This will call the APISIX Admin API at `http://127.0.0.1:9180` to create routes for Central, IAM, CRM, BPM, and Frontend.

## Services

| Service | Port | Description |
|C---|---|---|
| Postgres | 5432 | Central DB & IAM DB |
| Oracle | 1521 | Tenant DBs (optional) |
| APISIX Gateway | 9080 | Public API Gateway |
| APISIX Admin | 9180 | Admin API |
| Keycloak | 8081 | Identity Management |
