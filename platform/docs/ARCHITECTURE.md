# Cambridge Platform Architecture

## Overview

The Cambridge Platform is a **hybrid integration system** that unifies two independently-developed subsystems:

1. **Certmate** (Python): Certificate lifecycle automation
2. **Inventory Management** (C#): Infrastructure asset tracking

Both subsystems are vendored as **git subtrees** from their upstream repositories, ensuring they remain independently updateable while providing a unified operator experience.

## Architectural Principles

### 1. Upstream Independence

Both `.certmate/` and `.inventorymanagement/` are **unmodified upstream code**. Changes to these subsystems happen in their respective upstream repositories, then pulled into this platform via git subtree.

**Rationale**: Avoids forking; allows free upstream updates; maintains clean separation of concerns.

### 2. Thin Integration Layer

The `platform/` directory contains **only integration code**:
- API Gateway: Routes requests to appropriate backend
- Web UI: Unified dashboard consuming both APIs
- Config: Docker Compose orchestration, shared secrets

**What's NOT in platform/**: Business logic, domain models, data persistence (those live in subtrees).

### 3. Domain-Driven Boundaries

```
Certificate Domain (.certmate/)
├── Entities: Certificate, DNSProvider, CAAccount
├── Use Cases: Issue, Renew, Revoke, DNS-01 Challenge
└── Infrastructure: SQLite, ACME clients, DNS APIs

Inventory Domain (.inventorymanagement/)
├── Entities: Machine, InstalledCertificate, Service
├── Use Cases: Discover, Track Compliance, Generate Reports
└── Infrastructure: SQL Server, WinRM, F5 APIs

Platform Domain (platform/)
├── Entities: None (pure orchestration)
├── Use Cases: Unified Search, Cross-Domain Reporting, SSO
└── Infrastructure: API Gateway, React UI, Reverse Proxy
```

### 4. Hexagonal Influence

The `.inventorymanagement/` subsystem uses **full hexagonal architecture** (ports & adapters). The platform respects this by treating it as a black box accessed via its public API port.

`.certmate/` is more traditional Flask, but the platform still treats it as an external adapter.

## Communication Patterns

### Service-to-Service

```
┌─────────────┐
│   Web UI    │  React SPA (client-side)
└──────┬──────┘
       │ HTTP/REST
┌──────▼──────┐
│ API Gateway │  Node.js Express
└──────┬──────┘
       ├─────────────┐
       │             │
┌──────▼──────┐ ┌───▼────────────┐
│  Certmate   │ │   Inventory    │
│   (Flask)   │ │ (C# ASP.NET)   │
└─────────────┘ └────────────────┘
```

- **UI → Gateway**: All requests go through gateway (CORS, auth, rate limiting)
- **Gateway → Services**: Internal HTTP (Docker network)
- **Services → DB**: Direct connections (certmate → SQLite, inventory → SQL Server)

### Data Sharing

**No shared database**. Each service owns its data:
- Certmate: SQLite file (`/data/certmate.db`)
- Inventory: SQL Server (`InventoryDB`)

**Cross-domain queries**: Via API Gateway aggregation (e.g., "show machines with expiring certs" queries both APIs and joins in memory).

## Deployment Architecture

### Production (Docker Compose)

```
Host Machine (Cambridge Server)
├── Docker: certmate (Python)
├── Docker: inventory-agent (C#)
├── Docker: db (SQL Server)
├── Docker: api-gateway (Node.js)
└── Docker: web-ui (Nginx serving static React)
```

All services on private bridge network; only gateway/UI exposed externally.

### Development

- Certmate: Run locally with `flask run` or Docker
- Inventory: Run in Rider/VS with `dotnet run`
- Gateway: `npm run dev` (watches for changes)
- UI: `npm start` (hot reload)

## Update Strategy

### Pulling Upstream Changes

```bash
# Update certmate
git subtree pull --prefix=.certmate \
  https://github.com/fabriziosalmi/certmate main --squash

# Update inventory management
git subtree pull --prefix=.inventorymanagement \
  https://github.com/CarlDog-Cambridge/InventoryManagement main --squash
```

### Conflict Resolution

If upstream introduces breaking API changes:
1. Update `platform/api-gateway` routing logic to adapt
2. Update `platform/web-ui` API client code
3. **Do not** modify subtree code; use adapter pattern in gateway if needed

## Security Boundaries

- **Gateway**: Validates JWT tokens, enforces rate limits
- **Certmate**: Internal-only; no direct external access
- **Inventory**: Internal-only; no direct external access
- **UI**: Static assets; no secrets (API key passed via gateway)

## Testing Strategy

- **Unit Tests**: Live in each subtree (not duplicated in platform/)
- **Integration Tests**: Platform layer tests API gateway routing
- **E2E Tests**: Platform layer tests full user flows (UI → Gateway → Services)

## Future Enhancements

- **Event Bus**: Replace HTTP polling with event-driven (RabbitMQ/Redis Streams)
- **GraphQL**: Unified query language for cross-domain data
- **Shared SSO**: Keycloak/OAuth integration
- **Multi-tenancy**: Isolate data per Cambridge tenant
