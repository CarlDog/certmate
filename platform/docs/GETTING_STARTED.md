# Getting Started with Cambridge Platform

## Quick Start (Docker Compose)

```bash
# Clone the repository
git clone https://github.com/fabriziosalmi/certmate.git cambridge-platform
cd cambridge-platform
git checkout cambridge.v3.foundation

# Start all services
docker compose up -d

# Verify services are running
docker compose ps

# Access the platform
open http://localhost:3000   # Web UI
open http://localhost:8080   # API Gateway
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Cambridge Platform                    │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ┌──────────────┐          ┌──────────────────┐         │
│  │   Web UI     │          │   API Gateway    │         │
│  │  (React)     │──────────│   (Node.js)      │         │
│  │  Port 3000   │          │   Port 8080      │         │
│  └──────────────┘          └────────┬─────────┘         │
│                                     │                    │
│                      ┌──────────────┴──────────────┐     │
│                      │                             │     │
│           ┌──────────▼──────────┐    ┌────────────▼────┐│
│           │   Certmate          │    │   Inventory     ││
│           │   (Python/Flask)    │    │   (C#/.NET)     ││
│           │   Port 5000         │    │   Port 5001     ││
│           └──────────┬──────────┘    └────────┬────────┘│
│                      │                        │         │
│                 ┌────▼────┐            ┌──────▼──────┐  │
│                 │ SQLite  │            │  SQL Server │  │
│                 └─────────┘            └─────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Development Setup

### Prerequisites

- Git 2.40+
- Docker 24.0+ & Docker Compose 2.20+
- Node.js 20+ (for platform development)
- Python 3.10+ (for certmate development)
- .NET 9 SDK (for inventory development)

### Local Development (Without Docker)

#### 1. Certmate (Python)

```bash
cd .certmate
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r requirements.txt
flask run --port 5000
```

Access: http://localhost:5000

#### 2. Inventory Management (C#)

```bash
cd .inventorymanagement/src/Agent
dotnet restore
dotnet run --urls "http://localhost:5001"
```

Access: http://localhost:5001

#### 3. API Gateway (Node.js)

```bash
cd platform/api-gateway
npm install
npm run dev
```

Access: http://localhost:8080

#### 4. Web UI (React)

```bash
cd platform/web-ui
npm install
npm start
```

Access: http://localhost:3000

## Configuration

### Environment Variables

Create `.env` in the root directory:

```bash
# Certmate Configuration
CERTMATE_API_URL=http://localhost:5000
CERTMATE_DB_PATH=/data/certmate.db
CERTMATE_SECRET_KEY=your-secret-key-here

# Inventory Configuration
INVENTORY_API_URL=http://localhost:5001
INVENTORY_DB_CONNECTION=Server=localhost;Database=InventoryDB;User=sa;Password=YourPassword

# API Gateway Configuration
GATEWAY_PORT=8080
GATEWAY_JWT_SECRET=your-jwt-secret-here

# Web UI Configuration
REACT_APP_API_GATEWAY=http://localhost:8080/api
```

### Service-Specific Configuration

- **Certmate**: See [.certmate/README.md](.certmate/README.md)
- **Inventory**: See [.inventorymanagement/README.md](.inventorymanagement/README.md)

## Common Tasks

### Updating Upstream Code

```bash
# Update certmate from upstream
git subtree pull --prefix=.certmate \
  https://github.com/fabriziosalmi/certmate main --squash

# Update inventory from upstream
git subtree pull --prefix=.inventorymanagement \
  https://github.com/CarlDog-Cambridge/InventoryManagement main --squash
```

### Running Tests

```bash
# Test certmate
cd .certmate
pytest

# Test inventory
cd .inventorymanagement
dotnet test

# Test platform integration
cd platform/api-gateway
npm test
```

### Building for Production

```bash
# Build all services
docker compose build

# Or build individually
docker compose build certmate
docker compose build inventory-agent
docker compose build api-gateway
docker compose build web-ui
```

## Troubleshooting

### Services Not Starting

```bash
# Check service logs
docker compose logs certmate
docker compose logs inventory-agent
docker compose logs api-gateway

# Restart specific service
docker compose restart certmate
```

### Database Connection Issues

```bash
# Reset databases
docker compose down -v  # WARNING: Deletes all data
docker compose up -d

# Check database connectivity
docker compose exec db sqlcmd -S localhost -U sa -P 'YourPassword'
```

### Port Conflicts

If ports are already in use, edit `docker-compose.yml`:

```yaml
services:
  certmate:
    ports:
      - "5010:5000"  # Change host port (left side)
```

## Next Steps

1. **Read the Architecture**: [platform/docs/ARCHITECTURE.md](ARCHITECTURE.md)
2. **Configure Services**: Set up environment variables and secrets
3. **Run Tests**: Ensure all components work independently
4. **Deploy**: Follow production deployment guide (coming soon)

## Support

- **Certmate Issues**: [fabriziosalmi/certmate/issues](https://github.com/fabriziosalmi/certmate/issues)
- **Inventory Issues**: [CarlDog-Cambridge/InventoryManagement/issues](https://github.com/CarlDog-Cambridge/InventoryManagement/issues)
- **Platform Issues**: [Your repo]/issues

## License

See [LICENSE](../../LICENSE) for platform integration code.
See respective subtree directories for upstream license information.
