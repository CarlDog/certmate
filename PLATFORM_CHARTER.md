# Cambridge Platform - Strategic Charter

**Document Version**: 1.0
**Last Updated**: January 21, 2026
**Status**: Active Reference Document

> This document defines the strategic objectives, architectural decisions, and technical challenges for the Cambridge Platform project. It serves as the authoritative reference for all development efforts and should be consulted before major architectural decisions.

---

## 1. Executive Overview

The Cambridge Platform is an **enterprise-grade Windows native background service** that automatically discovers, tracks, and manages certificate and infrastructure metadata across distributed systems in the Cambridge environment.

**Core Thesis**: Build an extensible, plugin-based Windows Service for collecting and managing infrastructure metadata across distributed systems. Start with certificate lifecycle automation and discovery; evolve to capture scheduled tasks, installed applications, Windows services, and other operational metadata via pluggable collectors.

---

## 2. Strategic Objectives

### 2.1 Primary Objectives (Phase 1-3, 6 months)

1. **Windows Native Service**: Build a production-ready background service that runs as a Windows Service, not Flask/Python web app
   - Service should auto-start, handle graceful shutdown, integrate with Windows Event Log
   - Eliminate Python runtime dependency

2. **Infrastructure Metadata Collection**: Discover and track infrastructure assets and metadata using pluggable adapters
   - **Phase 1 (Certificates)**: Remote cert discovery via WinRM, IIS bindings, F5 integration, filesystem scanning
   - **Phase 4+ (Extensible Collectors)**: Scheduled tasks, installed applications, Windows services, system patches, event logs, metrics
   - Adapter pattern allows new collectors (vSphere, AWS, Azure) without modifying core
   - SQL canonical store prevents duplication across multiple collectors

3. **Certificate Lifecycle Automation**: Manage certificate creation, renewal, and deployment
   - Request new certificates via ACME (Let's Encrypt, DigiCert, private CAs)
   - DNS-01 challenge support for wildcard/subdomain certificates
   - Automatic renewal before expiry (configurable thresholds)
   - Deploy renewed certificates to discovered targets
   - Track certificate deployment history

4. **Enterprise-Grade Web UI**: Modern, intuitive operator interface
   - Real-time certificate status dashboard (Valid/Critical/Expired)
   - Machine inventory with environment tagging
   - Certificate request/renewal interface
   - Configuration management (DNS providers, CAs, deployment policies)
   - Audit trail of all certificate operations

5. **Plugin-Based Metadata Collection Architecture**: Enable arbitrary asset collection without core refactoring
   - Hexagonal architecture (ports & adapters) enforced throughout
   - Collector plugins for each metadata type (certificates, scheduled tasks, applications, services, patches)
   - Each collector runs independently, reports to canonical SQL store
   - Plugin interfaces for storage backends, DNS providers, CAs, credential vaults, collectors
   - Domain-driven design with rich domain models (Certificate, Machine, ScheduledTask, InstalledApplication)
   - Example: Adding "Windows Services Collector" requires only implementing IMetadataCollector interface

### 2.2 Secondary Objectives (Phase 4+, expandable via plugins)

**Additional Metadata Collectors** (via plugin architecture):
- Scheduled tasks inventory (name, schedule, account, status, results)
- Installed applications (name, version, publisher, install date)
- Windows services (name, status, startup type, dependencies)
- System patches and updates (KB numbers, installed date, criticality)
- Event log collection (security, certificate events, errors)
- Performance baselines and metrics

**Certificate Enhancements**:
- Client certificate management (OCSP, CRL support)
- Multi-CA support expansion (additional private CAs)

**Operational Enhancements**:
- Multi-tenancy support (metadata per department/team)
- Secret storage integrations (Azure KeyVault, AWS Secrets, Vault)
- Advanced cross-metadata reporting and compliance
- REST API for programmatic metadata access
- Enterprise SSO integration (Kerberos, SAML)
- Policy-based alerting framework
- Webhook support for external system integration

### 2.3 Non-Objectives (Out of Scope)

- OCSP responder or CRL hosting
- Certificate transparency log submission
- Kubernetes/container orchestration (Windows infrastructure only)
- Cross-platform deployment (Windows-only)
- Real-time event streaming (polling acceptable)
- Application dependency tracking (future consideration)

---

## 3. Current State Assessment

### 3.1 Existing Assets

**Certmate (Python, Third-Party OSS)**
- ✅ Production-ready ACME client implementation (battle-tested)
- ✅ 12+ DNS provider integrations (Cloudflare, Route53, Azure DNS, etc.)
- ✅ Multiple storage backend implementations (Azure KeyVault, AWS Secrets, Infisical, Vault)
- ✅ Web UI with certificate dashboard, settings, audit log
- ✅ Proven renewal automation logic
- ❌ Not a Windows Service (Flask web app architecture)
- ❌ Cannot discover existing infrastructure
- ❌ File-based storage (not SQL)

**InventoryManagement (C#, Proprietary)**
- ✅ Hexagonal architecture (proven pattern for enterprise applications)
- ✅ Windows Service foundation (existing agent harness)
- ✅ WinRM adapter for remote machine polling
- ✅ F5 Load Balancer integration via REST API
- ✅ SQL Server data model (canonical certificate storage)
- ✅ Domain-driven design with rich entity models
- ✅ Infrastructure for structured logging, retry policies, scheduled tasks
- ❌ No ACME/Let's Encrypt integration
- ❌ No DNS provider support
- ❌ No web UI (Phase 3 planned but not implemented)
- ❌ No certificate creation capability

### 3.2 Architectural Decision: InventoryManagement as Foundation

**Why InventoryManagement is the right foundation** (not Certmate, not orchestration):

| Requirement | Why InventoryManagement Wins |
|---|---|
| Windows Service | Built-in (NServiceBus/Topshelf); Certmate requires wrapper |
| Background Worker | Native windows service model; Certmate is web framework |
| Remote Polling | WinRM already integrated; Certmate has none |
| SQL Data Model | Enterprise-grade schema designed; Certmate stores files |
| Type Safety | C# compile-time checking; Python runtime validation |
| Extensibility | Hexagonal + DDD established; Certmate is modular but not plugin-oriented |
| Enterprise Patterns | Retry policies, structured logging, event sourcing ready; Certmate ad-hoc |

**Key Insight**: Certificate discovery and automation are **complementary domains, not competitors**. Certmate is specialist in ACME/DNS/certificate creation; InventoryManagement is specialist in infrastructure discovery and canonical storage. **Merge the two by building certificate automation ON TOP of InventoryManagement's discovery foundation.**

### 3.3 Why Not Orchestration Layer?

An earlier consideration was to run both systems independently and build a thin orchestration layer:

**Rejected because**:
- Adds unnecessary operational complexity (two services to deploy, monitor, troubleshoot)
- Requires cross-system data synchronization (canonical certificate truth becomes ambiguous)
- Delays getting value (UI takes longer, auth/routing needed)
- Two separate databases mean eventual consistency headaches
- Maintains Python runtime dependency (defeats Windows Service goal)

**Orchestration layer could be revisited only if**: InventoryManagement proves unsuitable for production use (unlikely given architectural quality).

---

## 4. Technical Challenges & Mitigation

### 4.1 ACME Protocol Implementation (HIGH RISK)

**Challenge**: Certmate wraps `certbot` CLI, which handles complex ACME state machines (authorization, validation, retry logic, cert chain assembly). Pure C# porting requires either:
- Option A: Use existing C# library (Certes) - untested in our environment
- Option B: Call certbot as subprocess - adds dependency, not pure C#
- Option C: Port ACME logic from Certmate - 2000+ lines, duplicates battle-tested code

**Mitigation**:
- Recommend Option B initially (subprocess call to certbot) - lowest risk, leverages proven implementation
- Certbot is stable, widely deployed; add to Windows Service container
- Plan for Option A (Certes library) as longer-term refactor if subprocess approach has limitations
- Comprehensive testing around ACME edge cases (retries, revocation, certificate chaining)

**Timeline Impact**: 2-3 weeks (Option B) vs 6-8 weeks (Option A or C)

### 4.2 DNS Provider Port (MEDIUM RISK)

**Challenge**: Certmate supports 12+ DNS providers with provider-specific credential formats, API quirks, and error handling. Porting requires:
- Understanding each provider's API (CloudFlare, Route53, Azure DNS, Google DNS, etc.)
- Credential management and encryption
- Rate limiting and retry logic
- Timeout handling

**Mitigation**:
- Prioritize top 3 providers (CloudFlare, Route53, Azure) - covers 80% of use cases
- Design adapter interface first, implement incrementally
- Leverage DNS provider SDKs where available (boto3 for Route53, azure-sdk for Azure DNS)
- Comprehensive integration tests for each provider

**Timeline Impact**: 2 weeks (top 3) + 1 week per additional provider

### 4.3 Certificate Deployment (MEDIUM RISK)

**Challenge**: Deploying renewed certificates to discovered targets is complex:
- Windows Certificate Store (requires elevated privileges)
- IIS bindings (requires IIS restart, potential downtime)
- F5 partitions (requires API credentials, multi-step workflow)
- Custom applications (require deployment scripts)

**Mitigation**:
- Implement as pluggable deployer interface (same hexagonal pattern)
- Start with read-only certificate tracking (no deployment) in Phase 1
- Phase 2: Add Windows Certificate Store deployment (simplest)
- Phase 3: IIS binding updates
- Phase 4: F5 deployment
- Allow manual deployment initiation until automation is proven stable

**Timeline Impact**: 1 week (foundation) + 2-3 weeks per deployment target

### 4.4 Web UI Rebuild (LOW RISK, HIGH EFFORT)

**Challenge**: Certmate's Flask UI needs to be rebuilt in ASP.NET (Razor Pages or Blazor Server):
- Dashboard patterns (expiry status, machine inventory)
- Configuration management (DNS credentials, CA settings)
- Operational workflows (manual cert request, renewal history)
- Responsive design for mobile operators

**Mitigation**:
- Use ASP.NET Razor Pages (simpler than Blazor, matches enterprise patterns)
- Adopt component library (Bootstrap 5) for consistency
- Build incrementally: Dashboard → Settings → Operations
- Consider React SPA alternative if time permits, but Razor faster initially

**Timeline Impact**: 4-6 weeks for production-quality UI

### 4.5 Data Model Integration (MEDIUM RISK)

**Challenge**: InventoryManagement's SQL schema is optimized for discovery (canonical certificates, machine relationships). Certificate automation adds requirements:
- Certificate request history (audit trail)
- Renewal configuration (thresholds, deployment targets)
- Provider credentials (encrypted storage)
- Deployment results tracking

**Mitigation**:
- Extend existing schema without breaking discovery queries
- Use ADR (Architecture Decision Record) process to document schema changes
- Comprehensive migration plan for schema versioning
- Maintain backward compatibility with existing harvester logic

**Timeline Impact**: 1 week (planning) + embedded in development phases

### 4.6 Windows Service Lifecycle (LOW RISK)

**Challenge**: InventoryManagement Agent needs to handle:
- Service startup/shutdown gracefully
- Long-running background tasks with cancellation tokens
- Dependency injection for mocked testing
- Windows Event Log integration
- Service recovery policies

**Mitigation**:
- InventoryManagement already has Windows Service harness
- Use existing infrastructure; extend carefully
- Comprehensive unit tests for cancellation scenarios

**Timeline Impact**: Minimal (existing patterns)

### 4.7 Credential Management (MEDIUM RISK)

**Challenge**: DNS providers, ACME CAs, F5/WinRM targets all require credentials:
- Secure storage (cannot be plaintext in DB)
- Encryption at rest and in transit
- Credential rotation support
- Audit trail of credential access

**Mitigation**:
- Use Data Protection API (DPAPI) for Windows local encryption
- Support Azure KeyVault integration for enterprise deployments
- Implement ICredentialVault interface for future backend swaps
- Separate credential management from usage logic

**Timeline Impact**: 2-3 weeks (integrated into infrastructure phase)

---

## 5. Architectural Principles

### 5.1 Hexagonal Architecture (Ports & Adapters)

The application follows strict hexagonal architecture enforced by InventoryManagement:

```
Domain (Core)
  ├── Certificates (entities, value objects, domain services)
  ├── Machines (entities, relationships)
  ├── Policies (renewal policies, deployment rules)
  └── Services (domain logic: expiry evaluation, policy matching)

Application (Orchestration)
  ├── Use Cases (RequestCertificate, RenewExpiringCertificates, DeployCertificate)
  └── Domain Service Coordination

Infrastructure (Adapters)
  ├── Persistence (SQL Server)
  ├── Remote Access (WinRM, F5 REST API)
  ├── Certificate Authority (ACME, Private CA, DigiCert)
  ├── DNS Providers (Cloudflare, Route53, Azure, etc.)
  ├── Certificate Storage (Windows Cert Store, IIS, file system)
  └── Secrets (DPAPI, Azure KeyVault)

Agent (Composition Root)
  └── Windows Service that instantiates and wires dependencies
```

**Strict Rules**:
- Domain layer has **zero** external dependencies (no HTTP, no SQL, no file I/O)
- Application layer coordinates domain + adapters but doesn't contain business logic
- Infrastructure layer adapts external systems; adapters are replaceable/mockable
- No direct dependencies upward (infrastructure → domain; domain never → infrastructure)

### 5.2 Domain-Driven Design

Rich domain models with validation and business logic:
- Certificate with value object Thumbprint (validated)
- Machine with environment classification
- CertificateRequest with policy matching
- Deployment with result tracking

### 5.3 SOLID Principles

- **S**ingle Responsibility: Each class/interface has one reason to change
- **O**pen/Closed: Open for extension (new DNS providers), closed for modification (core logic)
- **L**iskov Substitution: All DNS provider implementations interchangeable
- **I**nterface Segregation: Lean interfaces (ICertificateRequest, IDnsProvider, etc.)
- **D**ependency Inversion: Depend on abstractions, inject at composition root

### 5.5 Plugin Architecture Pattern

The Cambridge Platform is fundamentally built as an **extensible metadata collection platform**. The plugin architecture enables adding new capabilities without modifying core systems.

**Plugin Types**:

1. **Metadata Collectors** (IMetadataCollector)
   - Certificate Collector (existing: certificates from stores, F5, repos)
   - Scheduled Task Collector (future: scheduled tasks and configurations)
   - Application Collector (future: installed software inventory)
   - Service Collector (future: Windows services status)
   - Patch Collector (future: installed updates and hotfixes)
   - Event Log Collector (future: security and application events)
   - Example Implementation: `public interface IMetadataCollector { Task<IEnumerable<MetadataEntity>> CollectAsync(...); }`

2. **Certificate Authority Adapters** (ICertificateAuthority)
   - ACME (Let's Encrypt, DigiCert)
   - Private CA
   - Future: DigiCert API, Sectigo, custom CAs

3. **DNS Providers** (IDnsProvider)
   - Top 3: Cloudflare, Route53, Azure DNS
   - Future: Google Cloud DNS, GoDaddy, Akamai, custom

4. **Storage Backends** (ISecretVault)
   - SQL Server (primary)
   - Azure KeyVault
   - AWS Secrets Manager
   - HashiCorp Vault

5. **Deployment Targets** (ICertificateDeployer)
   - Windows Certificate Store
   - IIS bindings
   - F5 Load Balancers
   - Custom applications

**Adding a New Collector (Example)**:
```
1. Define domain model (ScheduledTask: Name, Schedule, Status, LastRun)
2. Implement IMetadataCollector interface
3. Register in composition root (Agent/Program.cs)
4. Wire into WebUI for visibility
5. Done - no core changes required
```

This design allows teams to extend capabilities by **adding adapters, not modifying the platform**.

---

## 6. Phased Delivery Plan

### Phase 1: Foundation (Weeks 1-8)
**Objective**: Core certificate automation working end-to-end

- Port ACME logic (certbot subprocess integration)
- Port top-3 DNS providers (Cloudflare, Route53, Azure)
- Extend domain: CertificateRequest, RenewalPolicy
- Extend Application: RequestCertificate, RenewExpiringCertificates use cases
- Implement SQL schema extensions for certificate automation
- Windows Service integration testing

**Success Criteria**:
- Service can successfully request certificate via Let's Encrypt + Cloudflare DNS-01
- Service can renew expiring test certificates
- Results tracked in SQL Server
- No manual intervention required (fully automated)

### Phase 2: Web UI (Weeks 9-14)
**Objective**: Operator interface for monitoring and configuration

- Build ASP.NET Razor Pages dashboard
- Certificate status overview (expiry timeline, critical/warning/valid)
- Configuration interface (DNS credentials, CA selection, renewal policies)
- Manual certificate request form
- Deployment history and audit log

**Success Criteria**:
- Dashboard shows real certificate data from Phase 1
- Operators can configure renewal policies without code changes
- Request new certificate via UI
- Audit log captures all actions

### Phase 3: Deployment & Integration (Weeks 15-20)
**Objective**: Automated certificate deployment to infrastructure

- Implement Windows Certificate Store deployment
- IIS binding update automation
- F5 certificate deployment
- Comprehensive end-to-end testing

**Success Criteria**:
- Renewed certificate automatically deployed to 3+ Windows machines
- IIS bindings updated without downtime
- F5 certificates rotated successfully
- Service scales to 50+ machines without performance degradation

### Phase 4: Advanced Features (Weeks 21+, if time permits)
- Storage backend integrations (Azure KeyVault, AWS Secrets)
- Client certificate management
- Advanced reporting and compliance
- REST API for programmatic access
- Multi-tenancy skeleton

---

## 6A. Certificate Collection Plugin Roadmap

**Strategic Focus**: Deliver three stable, production-proven certificate collection plugins sequentially. Each plugin must be fully tested, documented, and proven stable before moving to the next.

### Plugin Priority 1: Windows Machine Certificates (MY/ROOT Stores)
**Objective**: Collect personal and root certificates from Windows Certificate Stores on remote machines via WinRM

**Scope**:
- Connect to remote machines via WinRM (existing InventoryManagement capability)
- Enumerate MY store (personal certificates, private key status)
- Enumerate ROOT store (trusted root CAs)
- Extract: subject, issuer, thumbprint, expiry, key algorithm, key size, usage
- Track certificate locations with source metadata (MY vs ROOT, machine path)
- Store in canonical SQL table via existing MachineCertificate relationship

**Dependencies**: WinRM adapter (existing), Windows Certificate Store API via PowerShell/C#

**Timeline**: 2-3 weeks (Phase 1 focus)

**Success Criteria**:
- Discovers 100+ certificates from test machines
- Correctly identifies expiry dates and critical certificates
- WinRM connection handling and retries robust
- Data stored in existing InventoryManagement schema without conflicts
- Plugin can be toggled on/off without affecting core service

### Plugin Priority 2: IIS Certificate Bindings
**Objective**: Collect certificates bound to IIS websites and application pools on remote Windows servers

**Scope**:
- Connect to remote IIS servers via WinRM (existing capability)
- Enumerate IIS sites and their SSL/TLS bindings
- Extract certificate binding details: site name, binding IP/port, hostname, SNI configuration
- Link IIS-bound certificates to Windows store certificates (by thumbprint)
- Track binding context: which sites/apps use which certificates
- Identify certificate usage (single site vs. multiple sites using same cert)

**Dependencies**: WinRM adapter (existing), IIS PowerShell module (Get-WebBinding), Plugin 1 completion

**Timeline**: 2-3 weeks (Phase 1, after Plugin 1 stable)

**Success Criteria**:
- Discovers all IIS sites and their certificate bindings from test servers
- Correctly links IIS bindings to Windows store certificates (via thumbprint)
- Captures SNI and hostname binding configurations
- Identifies unused certificates in store (not bound to any IIS site)
- Handles IIS servers with missing or expired certificates gracefully
- Plugin integrates with existing MachineCertificate data model

### Plugin Priority 3: Remote Folder Backup Repository
**Objective**: Collect certificates from a designated backup/repository folder on remote network share

**Scope**:
- Monitor remote network shares (SMB) for certificate files
- Support multiple formats: .pem, .pfx, .cer, .crt
- Extract certificate metadata from files (no private keys from .pem backups)
- Track: file location, last modified date, certificate properties
- Deduplicate against existing discovered certificates (compare thumbprints)
- Useful for: backups created by external scripts, purchased certificates stored in repos

**Dependencies**: SMB/UNC path enumeration, certificate file parsing, deduplication logic

**Timeline**: 2-3 weeks (Phase 1, after Plugins 1-2 stable)

**Success Criteria**:
- Discovers certificates in test repository folder
- Correctly parses .pem, .pfx, .cer formats
- Deduplicates against Windows/IIS discoveries (no double-counting)
- Handles network timeouts and missing paths gracefully
- Plugin integrates seamlessly with existing data model

### Plugin Priority 4: F5 Load Balancer Integration
**Objective**: Collect certificates deployed on F5 BIG-IP Load Balancers

**Scope**:
- Connect to F5 REST API (existing InventoryManagement integration)
- Enumerate certificates in certificate stores
- Extract properties: CN, expiry, issuer, certificate chain
- Track F5 partition and virtual server associations
- Link to discovered Windows machine certificates (if same cert deployed on both)

**Dependencies**: F5 REST client (existing), certificate chain parsing

**Timeline**: 2-3 weeks (Phase 1, after Plugins 1-3 proven stable)

**Success Criteria**:
- Discovers all certificates on F5 device
- F5 API authentication and error handling robust
- Certificate properties correctly extracted and stored
- Can correlate F5 certs with Windows machine certs (same thumbprint)
- Plugin handles F5 API rate limits and timeouts

### Gate Before Further Plugin Development

**DO NOT PROCEED** with additional metadata collectors (scheduled tasks, applications, services, patches, event logs) until:

✅ **All four certificate plugins are stable** (running 30+ days without crashes)
✅ **Data quality is verified** (spot checks of collected data vs. reality)
✅ **Deduplication logic works** (no false positives across plugins)
✅ **Performance is acceptable** (collection cycle completes in <5 minutes for 50+ machines)
✅ **Operator can see results in Web UI** (dashboard shows collected certificates grouped by source: Windows stores, IIS bindings, backup repos, F5 devices)
✅ **Renewal automation tested end-to-end** (collected cert identified as expiring → renewal triggered → new cert deployed back to Windows store or F5)

**Rationale**: Certificate collection is the foundation use case. Stabilizing these three plugins proves the plugin architecture works and identifies systemic issues (data model, deduplication, UI) before expanding to other metadata types.

---

## 7. Success Criteria

### Mandatory (Project Complete Without These = Failure)
- ✅ Windows Service runs stably for 30 days without manual intervention
- ✅ Service successfully renews certificates before expiry
- ✅ Web UI provides operational visibility (status, history, alerts)
- ✅ Certificates deployed to at least 3 remote machines automatically
- ✅ Audit trail captures all certificate operations
- ✅ Code is production-ready (tested, documented, type-safe)

### Highly Desirable
- ✅ Service handles 50+ machines without performance degradation
- ✅ UI is intuitive for non-technical operators
- ✅ Extensible enough to add new DNS providers in <1 day
- ✅ Comprehensive deployment documentation

### Nice-to-Have
- ✅ Multi-tenancy support
- ✅ Advanced compliance reporting
- ✅ Integration with enterprise SSO

---

## 8. Key Risks & Mitigation Summary

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| ACME implementation complexity | 4 weeks slip | Medium | Use certbot subprocess (proven), not pure C# port |
| DNS provider API incompatibilities | 2-3 weeks slip | Medium | Start with top 3 providers, design adapter interface first |
| Certificate deployment edge cases | 3-4 weeks slip | Medium | Phased rollout, manual approval gate before automation |
| SQL schema conflicts | 2-3 weeks slip | Low | Design schema changes via ADR, test migrations early |
| Windows Service stability issues | Project blocker | Low | Leverage existing InventoryManagement harness, stress testing |
| UI UX inadequate for operators | Adoption risk | Low | Early mockups/feedback, iterative design |

---

## 9. Constraints & Assumptions

### Constraints
- **Language**: C# only (Windows Service requirement)
- **Target Framework**: .NET 9+ (current InventoryManagement version)
- **Database**: SQL Server (enterprise standard for Cambridge)
- **Deployment**: Windows Server only (no Linux/containers beyond Docker for development)
- **Timeline**: No hard deadline, but 6-month delivery expected
- **Team**: 1-2 developers (plan accordingly)

### Assumptions
- Certmate ACME logic can be called via certbot subprocess (proven)
- InventoryManagement's hexagonal architecture is stable enough for foundation
- SQL Server schema can be extended without breaking existing discovery logic
- Windows WinRM is available on all target machines
- Operators have administrative access to machines being managed

---

## 10. References & Decision History

### Architecture Decision Records (ADRs) to Create
- **ADR-001**: Why InventoryManagement C# is foundation (vs Certmate, vs orchestration)
- **ADR-002**: Why certbot subprocess for ACME (vs pure C# Certes library)
- **ADR-003**: Hexagonal architecture enforcement
- **ADR-004**: SQL schema extension strategy
- **ADR-005**: Credential encryption and storage approach

### Key Files for Reference
- `.inventorymanagement/docs/architecture/` - Existing architecture docs
- `.inventorymanagement/src/Domain/Certificates/Certificate.cs` - Certificate domain model
- `.inventorymanagement/src/Infrastructure/Persistence/SqlServerPersistence.cs` - Data layer
- `.certmate/modules/core/certificates.py` - ACME implementation reference
- `.certmate/modules/core/dns_providers.py` - DNS provider patterns
- `.certmate/modules/core/storage_backends.py` - Storage abstraction reference

### Codebase Analysis Performed
- Full code review of both Certmate and InventoryManagement
- Data model comparison
- Architecture pattern evaluation
- Integration challenge assessment
- 6000+ lines of code analyzed
- Decision rationale documented

---

## 11. Document Maintenance

**This charter is a living document.** Review and update:
- After each major phase completion (document lessons learned)
- When significant risks materialize (add to constraints)
- When requirements change (update objectives)
- Every 3 months (sanity check against reality)

**Version History**:

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-01-21 | Initial charter created |

---

## 12. Questions for Clarification (None - All Decided)

All major architectural questions have been resolved:
- ✅ Foundation platform: InventoryManagement C#
- ✅ ACME strategy: certbot subprocess
- ✅ Architecture: Hexagonal (existing InventoryManagement pattern)
- ✅ UI: ASP.NET Razor Pages
- ✅ Phases: Foundation → UI → Deployment → Advanced

**Proceed with restructuring repository to make InventoryManagement root application.**

---

**Approved By**: [Project Stakeholder/Date]
**Last Reviewed**: 2026-01-21
**Next Review**: 2026-04-21
