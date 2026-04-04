# Arda Infrastructure Manager

Unified TUI tool for managing Arda Platform infrastructure.

## Features

- 📊 **Status Monitoring** - Check container health and status
- 🧹 **Clean & Reset** - Clean all Docker volumes and data
- 🚀 **Bootstrap** - Full setup from scratch
- 🔐 **Keycloak Setup** - Configure clients, roles, users
- 🗄️  **DB Migrations** - Run database migrations
- 🌐 **APISIX Setup** - Configure API gateway routes
- 🔑 **JWT Keys** - Generate RSA keypair for internal auth

## Installation

```bash
# Install dependencies
pip install -r requirements.txt

# Make executable (Linux/Mac)
chmod +x arda-manager.py
```

## Usage

### Interactive Menu

```bash
python arda-manager.py
```

Displays interactive menu with all options.

### Command Line

```bash
# Show infrastructure status
python arda-manager.py status

# Clean all data (requires confirmation)
python arda-manager.py clean

# Clean without confirmation
python arda-manager.py clean --force

# Full bootstrap from scratch
python arda-manager.py bootstrap

# Setup individual components
python arda-manager.py setup-keycloak
python arda-manager.py setup-db
python arda-manager.py setup-apisix
python arda-manager.py generate-keys
python arda-manager.py start
```

## Example Output

```
╔════════════════════════════════════════════════════════╗
║           Arda Infrastructure Manager                         ║
║           TUI Tool for Arda Platform                    ║
╚════════════════════════════════════════════════════════╝

╭───────────────────────────────────────────────────────────╮
│                    Main Menu                         │
├───────────────────────────────────────────────────────────┤
│ Option │ Action                                     │
├────────┼─────────────────────────────────────────────────┤
│ 1      │ 📊 Show Status                            │
│ 2      │ 🧹 Clean All                               │
│ 3      │ 🚀 Full Bootstrap                         │
│ 4      │ 🔐 Setup Keycloak                          │
│ 5      │ 🗄️  Setup DB                               │
│ 6      │ 🌐 Setup APISIX                           │
│ 7      │ 🔑 Generate Keys                          │
│ 8      │ ▶️  Start Services                         │
│ 0      │ ❌ Exit                                   │
╰────────┴─────────────────────────────────────────────────╯
```

## Requirements

- Python 3.7+
- Docker & Docker Compose
- PowerShell (Windows) or Bash (Linux/Mac)

## Troubleshooting

### Permission errors on Windows

Run PowerShell as Administrator or disable execution policy:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

### Docker not found

Ensure Docker Desktop is running:

```bash
docker --version
docker compose version
```

## Notes

- All commands run in `scripts/` directory context
- Keys are generated in `keys/` directory
- Uses existing PowerShell scripts for core operations
