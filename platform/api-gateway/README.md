# API Gateway

Unified REST API that routes requests to the appropriate backend service.

## Routing Strategy

```
/api/certs/*        → .certmate Flask API (Python)
/api/inventory/*    → .inventorymanagement Agent API (C#)
/health             → Aggregated health check from both
```

## Technology

- Node.js + Express (lightweight reverse proxy)
- JWT authentication (shared across both services)
- Rate limiting and request logging

## Development

```bash
cd platform/api-gateway
npm install
npm run dev
```

## Configuration

See `platform/config/gateway.yml` for routing rules and service endpoints.
