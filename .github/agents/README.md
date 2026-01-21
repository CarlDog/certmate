# Cambridge Inventory Management - VS Code Agents

This directory contains specialized AI agents designed to assist with different aspects of the Cambridge Inventory Management system development. Each agent is optimized for a specific architectural layer, concern, or workflow.

## 🎯 Quick Start

**New to the project?** Start here:

1. Read this README to understand available agents
2. Use `@dev-workflow` for environment setup and common commands
3. Use `@phase-implementation` to understand current progress
4. Choose layer-specific agents as you begin coding

**Agent Count**: 7 specialized agents covering all aspects of development

---

## Available Agents

### 1. Domain Architect (`domain-architect.md`)

**Specialization**: Pure business logic and domain modeling

**Use for:**

-   Creating/refining domain entities (Certificate, Machine, MachineCertificate)
-   Implementing domain services (CertificateNormalizer, ExpiryEvaluator)
-   Defining port interfaces for infrastructure adapters
-   Enforcing domain invariants and business rules
-   Writing pure unit tests (no mocking needed)

**Key Responsibilities:**

-   Ensure Domain layer has ZERO external dependencies
-   Design rich domain models with proper encapsulation
-   Define clean contracts (ports) for infrastructure
-   Maintain business logic purity

**Example prompts:**

-   "Create a Certificate entity with thumbprint validation"
-   "Add business rule for SANs in wildcard certificates"
-   "Define ICertificateStoreReader port interface"

---

### 2. Infrastructure Adapter (`infrastructure-adapter.md`)

**Specialization**: External system integration and adapters

**Use for:**

-   Implementing WinRM collectors (OS, IIS certificates)
-   Building SQL Server persistence with MERGE statements
-   Integrating F5 REST API clients
-   Configuring Azure Key Vault secret providers
-   Applying Polly retry policies and resilience patterns

**Key Responsibilities:**

-   Implement domain port interfaces
-   Handle WinRM remoting, SQL queries, HTTP calls
-   Apply retry/circuit breaker patterns
-   Manage concurrency limits (10 WinRM, 5 rps F5)
-   Write integration tests with Testcontainers

**Example prompts:**

-   "Implement WinRmOSCollector with retry policy"
-   "Create SqlServerPersistence MERGE upsert logic"
-   "Build F5RestClient with rate limiting"

---

### 3. Application Orchestrator (`application-orchestrator.md`)

**Specialization**: Use case orchestration and workflow coordination

**Use for:**

-   Building use cases that coordinate domain + infrastructure
-   Implementing CollectionOrchestrator for multi-machine collection
-   Creating command/query handlers
-   Managing transactions and cross-cutting concerns
-   Handling errors and returning domain-friendly results

**Key Responsibilities:**

-   Orchestrate complex workflows
-   Coordinate multiple infrastructure adapters
-   Implement performance tracking
-   Apply error handling patterns
-   Write use case tests with mocked infrastructure

**Example prompts:**

-   "Create HarvestCertificatesUseCase with error handling"
-   "Build CollectionOrchestrator with concurrency limiting"
-   "Implement RegisterMachineUseCase with validation"

---

### 4. Data Persistence (`data-persistence.md`)

**Specialization**: SQL Server schema, queries, and stored procedures

**Use for:**

-   Designing SQL tables with constraints and indexes
-   Creating MERGE-based upsert stored procedures
-   Building table-valued parameters (TVPs)
-   Implementing soft delete logic
-   Optimizing query performance

**Key Responsibilities:**

-   Ensure all upserts use MERGE for idempotency
-   Design normalized schemas with proper relationships
-   Add indexes for performance
-   Create migration scripts in version-controlled files
-   Write SQL-focused integration tests

**Example prompts:**

-   "Create UpsertCertificates stored procedure with MERGE"
-   "Design MachineCertificates table with surrogate key"
-   "Implement soft delete with 90-day grace period"

---

### 5. Test Engineer (`test-engineer.md`)

**Specialization**: Testing strategy, unit tests, integration tests

**Use for:**

-   Writing domain unit tests (pure, no mocking)
-   Creating application tests with mocked infrastructure
-   Building integration tests with Testcontainers
-   Achieving 80%+ code coverage
-   Validating acceptance criteria

**Key Responsibilities:**

-   Follow AAA pattern (Arrange, Act, Assert)
-   Test behavior, not implementation details
-   Use FluentAssertions for readable assertions
-   Configure Testcontainers for SQL Server tests
-   Organize tests by layer (Domain, Application, Infrastructure)

**Example prompts:**

-   "Write unit tests for CertificateNormalizer"
-   "Create integration test for SqlServerPersistence with Testcontainers"
-   "Test HarvestCertificatesUseCase with mocked ports"

---

### 6. Phase Implementation (`phase-implementation.md`)

**Specialization**: Project tracking, progress management, and phase execution

**Use for:**

-   Updating implementation tracker with task completion
-   Managing phase/stage transitions
-   Documenting blockers and risks
-   Tracking velocity and metrics
-   Ensuring acceptance criteria are met

**Key Responsibilities:**

-   Keep `docs/implementation/implementation-tracker.md` current
-   Guide through 5-phase roadmap (22 weeks)
-   Identify and resolve blockers
-   Generate status reports
-   Coordinate phase transitions

**Example prompts:**

-   "Update tracker to mark Stage 1 tasks complete"
-   "Document blocker for Azure Key Vault access"
-   "Generate weekly status report for Phase 1"

---

### 7. Development Workflow (`dev-workflow.md`)

**Specialization**: Build, test, deploy, and common development tasks

**Use for:**

-   Running build and test commands
-   Setting up local development environment
-   Configuring SQL Server (Docker, LocalDB, full installation)
-   Git workflow and commit conventions
-   Troubleshooting build errors and test failures
-   Code quality checks and formatting
-   Windows Service deployment

**Key Responsibilities:**

-   Execute dotnet CLI commands efficiently
-   Guide environment setup and prerequisites
-   Provide Git best practices and branch conventions
-   Troubleshoot common development issues
-   Configure logging and diagnostics
-   Deploy Windows Service

**Example prompts:**

-   "How do I setup my local development environment?"
-   "Run all tests with coverage"
-   "What's the commit message format?"
-   "Deploy as a Windows Service"

---

## How to Use Agents

### Option 1: Direct Agent Selection (VS Code Chat)

When using GitHub Copilot Chat in VS Code, you can directly specify which agent to use:

```
@domain-architect Create a Certificate entity with validation
```

### Option 2: Agent Chaining

Some tasks may require multiple agents working together:

```
@domain-architect Define ICertificateStoreReader port interface
@infrastructure-adapter Implement WinRmOSCollector for this port
@test-engineer Write integration tests for the collector
```

### Option 3: Context-Aware Agent Selection

Based on your current file, Copilot may automatically suggest the appropriate agent:

-   Editing `src/Domain/Certificates/Certificate.cs` → Suggests `domain-architect`
-   Editing `src/Infrastructure/Persistence/SqlServerPersistence.cs` → Suggests `infrastructure-adapter` or `data-persistence`
-   Editing `tests/Domain.Tests/CertificateTests.cs` → Suggests `test-engineer`

---

## Agent Selection Guide

**What are you working on?**

| Task                               | Recommended Agent          |
| ---------------------------------- | -------------------------- |
| Creating business entities         | `domain-architect`         |
| Implementing WinRM/SQL/F5 adapters | `infrastructure-adapter`   |
| Building use cases                 | `application-orchestrator` |
| Designing SQL schema               | `data-persistence`         |
| Writing tests                      | `test-engineer`            |
| Tracking progress                  | `phase-implementation`     |
| Build/test/deploy tasks            | `dev-workflow`             |
| Environment setup                  | `dev-workflow`             |

**What layer are you in?**

| Layer                 | Primary Agent              | Secondary Agent        |
| --------------------- | -------------------------- | ---------------------- |
| `src/Domain/`         | `domain-architect`         | `test-engineer`        |
| `src/Application/`    | `application-orchestrator` | `test-engineer`        |
| `src/Infrastructure/` | `infrastructure-adapter`   | `data-persistence`     |
| `src/Agent/`          | `application-orchestrator` | `dev-workflow`         |
| `tests/`              | `test-engineer`            | `dev-workflow`         |
| `docs/`               | `phase-implementation`     | (all agents)           |
| `.vscode/`            | `dev-workflow`             | `phase-implementation` |

---

## Architecture Context

All agents understand the following architectural principles:

### Hexagonal Architecture (Ports & Adapters)

```
┌─────────────────────────────────────────────┐
│  Agent (Windows Service)                    │
│  ├─ Worker.cs                               │
│  ├─ Program.cs (DI Composition Root)        │
│  └─ appsettings.json                        │
└─────────────────────────────────────────────┘
           ▲                          ▲
           │                          │
           │ Depends On               │ Depends On
           │                          │
┌──────────┴──────────┐    ┌──────────┴──────────┐
│  Application Layer  │    │ Infrastructure Layer│
│  ├─ Use Cases       │    │  ├─ WinRM Adapter   │
│  ├─ Orchestrators   │    │  ├─ SQL Adapter     │
│  └─ Commands/Queries│    │  ├─ F5 Adapter      │
└──────────┬──────────┘    │  ├─ Key Vault       │
           │                │  └─ Polly Policies  │
           │                └──────────┬──────────┘
           │                           │
           │ Depends On                │ Depends On
           │                           │
           ▼                           ▼
┌─────────────────────────────────────────────┐
│  Domain Layer (Pure Business Logic)         │
│  ├─ Entities (Certificate, Machine)         │
│  ├─ Domain Services                         │
│  ├─ Port Interfaces                         │
│  └─ Value Objects                           │
│  ⚠️  ZERO external dependencies              │
└─────────────────────────────────────────────┘
```

### Key Constraints

1. **Domain Purity**: No external dependencies in `src/Domain/`
2. **Dependency Rule**: Dependencies point inward (Infrastructure → Application → Domain)
3. **MERGE Upserts**: All SQL upserts use MERGE for idempotency (ADR-006)
4. **Concurrency Limits**: Max 10 WinRM sessions, 5 rps to F5 (ADR-009)
5. **Soft Delete**: 90-day grace period before hard delete (ADR-004)
6. **Hexagonal Structure**: Full 7-project architecture with incremental population (ADR-002)

---

## Phase Roadmap Context

All agents understand the current phase context:

| Phase       | Weeks | Status     | Focus                                    |
| ----------- | ----- | ---------- | ---------------------------------------- |
| **Phase 1** | 1-4   | 🔴 Current | Foundation & Basic OS Harvest            |
| **Phase 2** | 5-8   | ⚪ Pending | Scale & Resilience (IIS, SQLite buffer)  |
| **Phase 3** | 9-12  | ⚪ Pending | Machine Discovery (AD sync, soft delete) |
| **Phase 4** | 13-17 | ⚪ Pending | F5 & Repository Integration              |
| **Phase 5** | 18-22 | ⚪ Pending | WebUI & Reporting                        |

**Current Phase Details**: See `docs/planning/phase-1-plan.md`

---

## Documentation References

All agents have access to:

-   **Architecture**: `docs/architecture/`

    -   `architecture-overview.md` - System design
    -   `architectural-decisions.md` - ADR-001 through ADR-009
    -   `domain-architecture.md` - Domain layer design
    -   `infrastructure-architecture.md` - Infrastructure patterns
    -   `application-architecture.md` - Use case orchestration

-   **Planning**: `docs/planning/`

    -   `implementation-roadmap.md` - 22-week timeline
    -   `phase-1-plan.md` through `phase-5-plan.md` - Detailed plans
    -   `risk-register.md` - Risks and mitigations
    -   `testing-strategy.md` - Test approach

-   **Implementation**: `docs/implementation/`
    -   `implementation-tracker.md` - **Master progress tracker**
    -   `1-phase-one/` - Stage-by-stage execution guides

---

## Agent Maintenance

### Adding New Agents

When creating a new specialized agent:

1. Create `<agent-name>.md` in `.github/agents/`
2. Follow the template structure (see existing agents)
3. Define clear responsibilities and scope
4. Provide code examples (✅ GOOD / ❌ BAD patterns)
5. Link to relevant documentation
6. Update this README with agent description

### Agent Updates

Agents should be updated when:

-   Architecture patterns change (new ADRs added)
-   Phase transitions occur (update status context)
-   New tools/frameworks are adopted
-   Anti-patterns are discovered

---

## Quick Start Examples

### Example 1: New Developer Onboarding

```
@dev-workflow How do I setup my local development environment?
@dev-workflow Deploy SQL schema to local database
@phase-implementation What are the Phase 1, Stage 1 tasks?
@dev-workflow Run all tests to verify setup
```

### Example 2: Starting Phase 1, Stage 1

```
@phase-implementation What are the Phase 1, Stage 1 tasks?
@domain-architect Create Certificate entity with thumbprint validation
@test-engineer Write unit tests for Certificate entity
@dev-workflow Run tests and check coverage
@phase-implementation Mark A1 task complete in tracker
```

### Example 3: Implementing WinRM Collector

```
@domain-architect Define ICertificateStoreReader port interface
@infrastructure-adapter Implement WinRmOSCollector with retry policy
@test-engineer Create integration test for WinRmOSCollector
@dev-workflow Run integration tests with Testcontainers
```

### Example 4: Building SQL Persistence

```
@data-persistence Design Certificates table with constraints
@data-persistence Create UpsertCertificates stored procedure
@infrastructure-adapter Implement SqlServerPersistence adapter
@test-engineer Write Testcontainers integration tests
@dev-workflow Verify build and test pass
```

### Example 5: Deploying to Production

```
@dev-workflow Publish application for Windows Service
@dev-workflow Install and configure Windows Service
@phase-implementation Update tracker with deployment completion
@dev-workflow Verify service logs for errors
```

---

## Support

For questions or issues with agents:

1. Check agent-specific documentation (each `.md` file)
2. Review architecture docs (`docs/architecture/`)
3. Consult implementation tracker (`docs/implementation/implementation-tracker.md`)
4. Ask in team chat or during standup

---

**Last Updated**: 2025-11-21
**Agent Count**: 7
**Current Phase**: Phase 1 - Foundation & Basic OS Harvest
