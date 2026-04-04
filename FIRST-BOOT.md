# Arda Platform - First Boot Guide

Complete guide for setting up Arda Platform from scratch (fresh machine).

## 📋 Prerequisites

- **Docker Desktop** - For running containers
- **Git** - For cloning repository
- **PowerShell** - For running scripts (Windows)
- **Python 3.7+** - For TUI tool (optional)
- **Maven** - For building backend (optional if using pre-built)
- **pnpm** - For frontend (optional if using pre-built)

## 🚀 Quick Start (One Command)

```powershell
# From arda-infra-config/scripts directory
.\first-boot.ps1
```

This script will:
1. ✅ Check all prerequisites
2. ✅ Clone/check repository
3. ✅ Install Python dependencies
4. ✅ Start Docker infrastructure
5. ✅ Wait for services to be healthy
6. ✅ Run full bootstrap (Keycloak, DB, APISIX)
7. ✅ Get Keycloak secret
8. ✅ Build backend library

## 📝 Manual Steps (If script fails)

### Step 1: Clone Repository

```bash
git clone <your-repo-url> arda.io.vn
cd arda.io.vn
```

### Step 2: Start Docker Infrastructure

```bash
cd arda-infra-config/docker-compose
docker compose up -d
```

### Step 3: Wait for Services

Wait for services to be healthy:
- PostgreSQL (arda-postgres) - ~30s
- Redis (arda-redis) - ~10s

Check status:
```bash
docker ps
```

### Step 4: Run Bootstrap

```powershell
cd arda-infra-config/scripts
.\bootstrap.ps1
```

This will:
- Setup Keycloak (clients, roles, users)
- Run DB migrations
- Configure APISIX routes
- Generate JWT keys

### Step 5: Update Keycloak Secret

After setup-keycloak.ps1 completes, copy the `CLIENT SECRET` and update `.env`:

```env
# arda-infra-config/docker-compose/.env
NOTIFICATION_KC_CLIENT_SECRET=<secret-from-output>
```

### Step 6: Restart Notification Service

```bash
cd arda-infra-config/docker-compose
docker compose restart arda-notification
```

### Step 7: Build Backend Libraries

```bash
cd arda-shared-kernel
.\mvnw.cmd clean install -DskipTests
```

### Step 8: Start Backend Services

```bash
# Terminal 1: Central Platform
cd arda-central-platform
mvn spring-boot:run

# Terminal 2: IAM Service
cd arda-iam-service
mvn spring-boot:run

# Terminal 3: Migration Worker (optional)
cd arda-migration-worker
mvn spring-boot:run

# Terminal 4: Notification Service (already running)
# Already started via docker compose
```

### Step 9: Start Frontend

```bash
cd arda-mfe
pnpm dev
```

This will start:
- Shell app: http://localhost:3000
- IAM MFE: http://localhost:3001
- BPM MFE: http://localhost:3002
- CRM MFE: http://localhost:3003

## 🛠️ Using TUI Tool (Optional)

For easier management, use the Python TUI tool:

```bash
cd arda-infra-config/scripts
python arda-manager.py
```

Available commands:
- `status` - Show infrastructure status
- `clean` - Clean all data
- `bootstrap` - Full bootstrap
- `setup-keycloak` - Setup Keycloak only
- `generate-keys` - Generate JWT keys only

## 🔍 Troubleshooting

### Docker compose fails

```bash
# Check Docker Desktop is running
docker --version

# Check for port conflicts
docker ps
```

### Keycloak not responding

```bash
# Check logs
docker logs arda-keycloak --tail 50

# Restart Keycloak
docker restart arda-keycloak
```

### Notification service 401 errors

1. Ensure CLIENT SECRET is updated in `.env`
2. Restart notification service
3. Check logs: `docker logs arda-notification`

### Backend services fail to start

```bash
# Check PostgreSQL connection
docker exec arda-postgres psql -U postgres -d arda_central -c "SELECT 1"

# Check network
docker network inspect arda-network
```

## 📊 Service Ports

| Service | Port | Description |
|----------|------|-------------|
| PostgreSQL | 5432 | Database |
| Redis | 6379 | Cache |
| Keycloak | 8081 | Identity Provider |
| Kafka | 9092, 29092 | Messaging |
| Kafka UI | 8082 | Kafka Web UI |
| APISIX Gateway | 9080 | API Gateway |
| APISIX Admin | 9180 | Gateway Admin API |
| Notification | 8090 | Notification Service |
| Central Platform | 8000 | Backend API |
| IAM Service | 8001 | IAM API |
| Migration Worker | 8095 | Provisioning API |
| Shell (Frontend) | 3000 | React App |
| IAM MFE | 3001 | IAM React App |
| BPM MFE | 3002 | BPM React App |
| CRM MFE | 3003 | CRM React App |

## 🧹 Cleanup & Reset

To reset everything and start fresh:

```bash
cd arda-infra-config/scripts
.\first-boot.ps1

# When prompted, choose to clean existing data
```

Or use TUI tool:

```bash
python arda-manager.py clean --force
python arda-manager.py bootstrap
```

## ✅ Verification Checklist

After completing first boot, verify:

- [ ] All Docker containers are running (`docker ps`)
- [ ] All services are healthy (check via `python arda-manager.py status`)
- [ ] Keycloak UI accessible: http://localhost:8081
- [ ] Can login: super_admin / 123456
- [ ] Backend services started (check logs)
- [ ] Frontend accessible: http://localhost:3000
- [ ] Can create tenant via Central Platform API
- [ ] Notifications working (check logs)

## 📚 Additional Resources

- [Architecture Documentation](../CLAUDE.md)
- [TUI Tool Documentation](scripts/README.md)
- [Keys README](../keys/README.md)
- [API Documentation](http://localhost:9080/docs) - APISIX (if configured)
