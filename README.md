# Arda Infrastructure Config

Infrastructure configuration for the **Arda** Multi-tenant SaaS platform, managed via Docker Compose.

## Directory Structure

```
arda-infra-config/
├── docker-compose/
│   └── docker-compose.yml       # All infrastructure services
├── apisix/
│   └── config.yaml              # APISIX Gateway configuration
├── keycloak/                    # Keycloak realm configs (if any)
└── scripts/
    ├── init-db.sql              # PostgreSQL init: creates arda_central & arda_iam DBs
    ├── migrate-tenants-schema.sql  # Tenant schema migrations
    ├── create-menus-table.sql   # Menu table DDL
    ├── seed-tenants.sql         # Sample tenant seed data
    ├── setup-apisix-routes.sh   # APISIX route setup (Linux/Mac/Git Bash)
    └── setup-apisix-routes.ps1  # APISIX route setup (Windows PowerShell)
```

---

## Services

| Service        | Port(s)    | Image                            | Description                             |
| -------------- | ---------- | -------------------------------- | --------------------------------------- |
| PostgreSQL     | 5432       | `postgres:16-alpine`             | Central DB (`arda_central`, `arda_iam`) |

| etcd           | —          | `bitnamilegacy/etcd:3.5.11`      | APISIX config store                     |
| APISIX Gateway | 9080       | `apache/apisix:3.14.1-debian`    | Public API Gateway                      |
| APISIX Admin   | 9180       | ↑ same container                 | Admin API for route management          |
| Keycloak       | 8081       | `quay.io/keycloak/keycloak:26.0` | Identity & Access Management            |
| Kafka (KRaft)  | 9092/29092 | `apache/kafka:latest`            | Event streaming (KRaft mode, no ZK)     |
| Kafka UI       | 8082       | `provectuslabs/kafka-ui:latest`  | Web UI for Kafka management             |

### Resource Limits (RAM)

| Service    | Memory Limit |
| ---------- | ------------ |
| PostgreSQL | 512 MB       |

| etcd       | 128 MB       |
| APISIX     | 256 MB       |
| Keycloak   | 512 MB       |
| Kafka      | 768 MB       |
| Kafka UI   | 256 MB       |

---

## Getting Started

### Prerequisites

- Docker Desktop (or Docker Engine + Compose Plugin)

### Start All Services

```bash
cd arda-infra-config/docker-compose
docker-compose up -d
```

**Stop services:**

```bash
docker-compose down
```

**Stop and remove volumes (full reset):**

```bash
docker-compose down -v
```

---

## Database Initialization

PostgreSQL is automatically initialized on first start using `scripts/init-db.sql`:

- Creates `arda_iam` database (alongside `arda_central` from `POSTGRES_DB` env var)
- Creates the `tenants` table in `arda_central` with columns for tenant metadata, DB connection info, and UI config

**Mounted via:**

```yaml
volumes:
  - ../scripts/init-db.sql:/docker-entrypoint-initdb.d/init-db.sql
```

> ⚠️ The init script only runs on **first container startup** (empty data volume). To re-run, remove the `arda-postgres-data` volume: `docker volume rm arda-postgres-data`

### Other SQL Scripts

| Script                       | Purpose                                       |
| ---------------------------- | --------------------------------------------- |
| `migrate-tenants-schema.sql` | Schema updates for the `tenants` table        |
| `create-menus-table.sql`     | Creates the application menu/navigation table |
| `seed-tenants.sql`           | Sample tenant data for development            |

---

## APISIX Route Setup

After services are up, configure the Gateway routes by running the setup script:

**Linux / Mac / Git Bash:**

```bash
bash scripts/setup-apisix-routes.sh
```

**Windows PowerShell:**

```powershell
.\scripts\setup-apisix-routes.ps1
```

This calls the APISIX Admin API at `http://127.0.0.1:9180` to create routes for:

- Central Platform → `/api/central/v1/*`
- IAM Service → `/api/iam/v1/*`
- CRM Service → `/api/crm/v1/*`
- BPM Service → `/api/bpm/v1/*`

---

## Kafka

Kafka runs in **KRaft mode** (no ZooKeeper required):

- **Internal listener**: `arda-kafka:9092` (for Docker services)
- **External listener**: `localhost:29092` (for host machine / Spring Boot apps)
- **Kafka UI**: http://localhost:8082 — manage topics, messages, consumers

---

## Default Credentials

| Service    | Username   | Password   |
| ---------- | ---------- | ---------- |
| PostgreSQL | `postgres` | `password` |

| Keycloak   | `admin`    | `admin`    |

> ⚠️ These are development defaults only. Change them in production.
