# Dependency Map

**Last Updated:** November 20, 2025
**Status:** Draft
**Owner:** Carl R. Yeager

---
## 1. Purpose
Visualize internal sequencing and external system dependencies across phases.

---
## 2. Internal Layer Dependencies
```plaintext
Domain ← Application ← Agent
   ↑          ↑
Infrastructure (adapters) → Domain
```
Rules: Domain pure; Application depends only on Domain; Infrastructure implements ports; Agent composes Application + Infrastructure.

---
## 3. Phase Feature Dependencies
```plaintext
Phase 1: Domain & WinRM OS (sequential harvest)
   ↓
Phase 2: Scale (parallel) + IIS + Buffer + Tracking
   ↓
Phase 3: AD Discovery + Soft Delete (lifecycle)
   ↓
Phase 4: F5 + Repository (additional sources)
   ↓
Phase 5: WebUI (consumes stable backend)
```

---
## 4. External System Dependencies
| System | Phase | Dependency Type | Notes |
|--------|------|-----------------|-------|
| WinRM (Target Servers) | 1 | Remote interface | Requires firewall + credentials |
| SQL Server | 1 | Persistence | Must support MERGE + computed cols |
| AD (LDAP) | 3 | Discovery | Machine enumeration + filtering |
| CIFS Repository | 4 | File share | Read permission only |
| F5 LTM Devices | 4 | REST API | Rate limit & auth |
| Azure Key Vault | 1-4 | Secrets | For F5/SQL creds (optional Phase 1) |
| AD (Auth) | 5 | Security | WebUI Windows auth |
| Teams Webhook | 1-5 | Alerts | Expiry + error notifications |

---
## 5. Timing Constraints
| Dependency | Constraint | Mitigation |
|------------|-----------|-----------|
| WinRM Connectivity | Must baseline early | Pre-kickoff test script |
| AD LDAP Access | Credentials needed by Week 9 (Phase 3) | Early request submission |
| F5 Access | Credentials needed by Week 13 (Phase 4) | Request during Phase 2 |
| Repository Path | Confirm before scanner dev | Inventory share during Phase 3 |
| SQL Schema Stability | Needed before WebUI | Freeze schema by Phase 4 end |

---
## 6. Risk Links
Refer to `risk-register.md` for risks tied to dependencies (R1, R6, R9, R10, R11).

---
## 7. Change Impact Examples
| Change | Impact |
|--------|-------|
| Modify MachineCertificates unique constraint | All ingestion adapters; possible migration |
| Add new SourceType (Cloud) | Ingestion pipeline + metrics adjustments |
| Replace WinRM with alternative | Collector redesign; Domain unchanged |

---
## 8. Related Documents
- Phase plans
- `architecture-overview.md`
- `risk-register.md`
