# Web UI

Unified single-page application providing integrated views of certificates and infrastructure inventory.

## Features

- **Certificate Dashboard**: View all managed certificates, expiry tracking, renewal status
- **Inventory Dashboard**: Machine inventory, certificate deployment status, compliance
- **Unified Search**: Find assets by certificate CN, machine name, or IP address
- **Alert Center**: Expiry warnings, compliance violations, failed renewals

## Technology Stack

- React 18 + TypeScript
- Material-UI components
- React Router for client-side navigation
- API client generated from OpenAPI specs

## Development

```bash
cd platform/web-ui
npm install
npm start  # Runs on http://localhost:3000
```

## Environment Variables

```bash
REACT_APP_API_GATEWAY=http://localhost:8080/api
REACT_APP_CERTMATE_DIRECT=http://localhost:5000   # Optional: direct access
REACT_APP_INVENTORY_DIRECT=http://localhost:5001  # Optional: direct access
```
