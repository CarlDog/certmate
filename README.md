# Cambridge Platform

> Unified infrastructure management platform combining certificate lifecycle automation and asset inventory tracking

## Architecture

This repository implements a **hybrid platform** integrating two upstream systems:

```
cambridge-platform/
├── .certmate/              # Python/Flask certificate management (upstream subtree)
├── .inventorymanagement/   # C# infrastructure inventory (upstream subtree)
└── platform/               # Integration layer (this repository)
    ├── api-gateway/        # Unified REST API (routes to cert OR inventory services)
    ├── web-ui/             # Single-page application (React/Vue)
    ├── config/             # Shared configuration and orchestration
    └── docs/               # Platform architecture documentation
```

## Subsystems

### Certificate Management (.certmate/)
- **Technology**: Python 3.14, Flask, SQLite/PostgreSQL
- **Upstream**: [fabriziosalmi/certmate](https://github.com/fabriziosalmi/certmate)
- **Purpose**: ACME certificate lifecycle automation (Let's Encrypt, ZeroSSL)
- **Features**: DNS-01 challenges, multi-provider support, automated renewal
- **Update**: `git subtree pull --prefix=.certmate https://github.com/fabriziosalmi/certmate main --squash`

### Infrastructure Inventory (.inventorymanagement/)
- **Technology**: C# .NET 9, Hexagonal Architecture
- **Upstream**: [CarlDog-Cambridge/InventoryManagement](https://github.com/CarlDog-Cambridge/InventoryManagement)
- **Purpose**: Asset discovery and compliance tracking (machines, certificates, services)
- **Features**: WinRM polling, SQL storage, F5 integration, structured logging
- **Update**: `git subtree pull --prefix=.inventorymanagement https://github.com/CarlDog-Cambridge/InventoryManagement main --squash`

## Platform Integration Layer (platform/)

The platform layer orchestrates both subsystems without polluting their codebases:

- **API Gateway**: Routes `/api/certs/*` → .certmate, `/api/inventory/*` → .inventorymanagement
- **Web UI**: Unified dashboard showing certificates + inventory in single view
- **Config**: Docker Compose orchestration, shared secrets management
- **Docs**: Platform-level architecture decisions and integration patterns

## Getting Started

```bash
# Clone the repository
git clone https://github.com/fabriziosalmi/certmate.git cambridge-platform
cd cambridge-platform

# Start all services
docker compose up -d

# Access platform
open http://localhost:8080  # Unified UI
open http://localhost:5000  # Certmate API
open http://localhost:5001  # Inventory API
```

## Development

```bash
# Update certmate upstream
git subtree pull --prefix=.certmate https://github.com/fabriziosalmi/certmate main --squash

# Update inventory upstream
git subtree pull --prefix=.inventorymanagement https://github.com/CarlDog-Cambridge/InventoryManagement main --squash

# Work on platform code (this repo)
cd platform/api-gateway
# ... make changes to integration layer only
```

## Design Principles

1. **Upstream Independence**: Subtrees remain unmodified; pull updates freely
2. **Thin Integration**: Platform code orchestrates but doesn't duplicate business logic
3. **Domain Separation**: Certificates ≠ Inventory; each has distinct lifecycle
4. **Shared Context**: Single UI/API for operators who need both views

## Branch Strategy

- `main`: Stable platform releases
- `cambridge.v2.platform`: Active development (this branch)
- Upstream changes pulled via git subtree (not submodules)

## License

- Platform integration layer: MIT
- .certmate: See [.certmate/LICENSE](.certmate/LICENSE)
- .inventorymanagement: See [.inventorymanagement/LICENSE](.inventorymanagement/LICENSE)
