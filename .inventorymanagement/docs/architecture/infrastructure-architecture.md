# Infrastructure Architecture

**Last Updated:** November 20, 2025
**Status:** Draft – Sections marked TODO will be completed during Phase 1.
**Owner:** Carl R. Yeager

---

## Purpose & Design Intent

The **Infrastructure layer** implements adapters for external systems (SQL, WinRM, F5, Teams). It contains **all I/O operations** and translates between external formats and Domain models.

**Key Responsibility:** "How the system interacts with the outside world."

---

## Architectural Responsibilities

### What Infrastructure Owns

- SQL persistence (ADO.NET with MERGE statements)
- WinRM remoting (PowerShell runspaces)
- F5 REST API client (HttpClient with rate limiting)
- Repository CIFS reader (file I/O for PFX files)
- Teams webhook publisher (HTTP POST for alerts)
- SQLite buffering (fallback persistence)
- Polly retry policies (resilience patterns)

### What Infrastructure Does NOT Own

- Business rules (Domain responsibility)
- Use case orchestration (Application responsibility)
- Configuration binding (Agent responsibility)

---

## Design Constraints

1. **Depends on Domain Only:** No references to Application or Agent
2. **Implements Ports Defined in Domain:** All interfaces from Domain layer
3. **Adapters Are Swappable:** Can replace SQL with Cosmos, WinRM with SSH (in theory)

---

## Key Abstractions

**TODO:** Populate during Phase 1 implementation (Weeks 2-6)

**Expected Adapters:**

- `SqlServerPersistence : IIngestionWriter`
- `WinRmCertificateCollector : ICertificateStoreReader`
- `F5RestClient : IF5RestClient`
- `RepositoryPfxReader : ICertificateStoreReader`
- `TeamsWebhookPublisher : ITeamsNotifier`
- `SqliteBuffer` (fallback persistence)

**Expected Policies:**

- `PollyPolicies` (retry, circuit breaker, rate limiting)

---

## Collaboration Patterns

**TODO:** Add after implementation

---

## Failure & Resilience Design

**Infrastructure Responsibilities:**

- Implement Polly retry policies (3 attempts for WinRM, 5 for F5)
- Circuit breaker for F5 (trip after 5 consecutive failures)
- SQLite buffering on SQL connection failures
- Structured exception logging

---

## Testing Strategy

**TODO:** Populate during Phase 1

**Expected Tests:**

- Integration tests with Testcontainers (SQL Server)
- WinRM tests with mocked PowerShell runspaces
- F5 tests with mock HTTP handlers

---

## Extension Points

**TODO:** Document after initial implementation

---

## Related Documents

- **Domain Architecture:** `domain-architecture.md`
- **Application Architecture:** `application-architecture.md`

---

## Related ADRs

| ADR | Topic | Relevance to Infrastructure |
|-----|-------|-----------------------------|
| 001 | Central WinRM Orchestrator | Defines remote collection approach implemented by adapters |
| 002 | Hexagonal Architecture | Governs port/adapter pattern the layer implements |
| 003 | Conditional SQLite Buffering | Implements buffering adapter and replay logic |
| 004 | Soft Delete Policy | Persistence logic updates soft delete columns |
| 006 | MERGE Registration Pattern | SQL adapter executes MERGE statements for upsert |
| 007 | Surrogate Key Strategy | Persistence uses surrogate keys + business unique constraints |
| 005 | Service Account & Key Vault | Secrets retrieval for external system access |
