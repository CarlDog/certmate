# Documentation Index

**Cambridge Inventory Management System v2.0**

---

## Documentation Conventions

**Source of Truth Policy:** Each document is the authoritative source for exactly one concern. Other documents may summarize (1–2 sentences max) and link but **never duplicate detail**.

**Cross-Referencing Rules:**
- Use `See <document>.md` for full detail
- Use `See <document>.md § <section>` for specific subsection
- Summaries must be <3 sentences; longer = move to authoritative doc

**Update Discipline:**
- Changing a design constraint? Update the source-of-truth doc first
- Adding context? If it affects multiple docs, add to the authoritative source and link from others
- Found duplication? Remove from non-authoritative doc and replace with link

**Authoritative Source Map:** See `architecture/architecture-overview.md` § Authoritative Sources for complete mapping.

---

## Quick Navigation by Role

### 👤 New Developer (Start Here)

1. **Codebase Overview:** `architecture/csharp-scaffold-overview.md` (Project structure & dependencies)
2. **Implementation Guide:** `implementation/developer-guide.md` (to be created)
3. **Architecture Overview:** `architecture/architecture-overview.md`
4. **Current Phase:** `planning/implementation-roadmap.md`

### 🏗️ Architect / Senior Engineer

1. **Architecture Overview:** `architecture/architecture-overview.md`
2. **Architectural Decisions (ADRs):** `architecture/architectural-decisions.md`
3. **Data Model Design:** `architecture/data-model-design.md`
4. **Component Architectures:** `architecture/domain-architecture.md`, `application-architecture.md`, etc.

### 📋 Project Manager / Stakeholder

1. **Implementation Roadmap:** `planning/implementation-roadmap.md`
2. **Architecture Overview (Executive Summary):** `architecture/architecture-overview.md` (first 2 sections)

### 🔧 Operations / DBA

1. **Schema DDL:** `architecture/schema-ddl.sql`
2. **Data Model Design:** `architecture/data-model-design.md`
3. **Configuration Reference:** `implementation/configuration-reference.md` (to be created)

---

## Documentation Structure

### `architecture/` - Design Authority

**Purpose:** Long-lived architectural decisions and design rationale. Rarely changes after Phase 1.

**Key Documents:**

- `architecture-overview.md` - System context, goals, quality attributes, workflows, layer mapping
- `csharp-scaffold-overview.md` - **Current Codebase Structure**: Hexagonal architecture implementation details
- `architectural-decisions.md` - All ADRs (ADR-001 through ADR-009)
- `data-model-design.md` - Schema design rationale, invariants, lifecycle states
- `domain-architecture.md` - Pure business logic layer design
- `application-architecture.md` - Use case orchestration patterns
- `infrastructure-architecture.md` - External adapter design
- `agent-architecture.md` - Windows Service hosting design
- `SENIOR-REVIEW-FINDINGS.md` - Feedback and required changes from architectural review
- `archive/` - SUPERSEDED historical documents

**Audience:** Architects, senior engineers, code reviewers, auditors

---

### `planning/` - Execution Roadmap

**Purpose:** Project phases, tasks, timelines, milestones. Evolves during project; archived post-delivery.

**Key Documents:**

- `implementation-roadmap.md` - Overall delivery plan (Phase 1-5)
- `phase-1-plan.md` - Phase 1: Foundation & Basic OS Harvest
- `phase-2-plan.md` - Phase 2: Scale & Resilience
- `phase-3-plan.md` - Phase 3: Machine Discovery & Lifecycle
- `phase-4-plan.md` - Phase 4: F5 & Repository Integration
- `phase-5-plan.md` - Phase 5: WebUI & Reporting
- `implementation-decisions.md` - Log of tactical implementation decisions
- `risk-register.md` - Active risks and mitigation strategies
- `testing-strategy.md` - Comprehensive testing approach (Unit, Integration, E2E)
- `release-management.md` - Versioning, packaging, and deployment strategy
- `metrics-and-kpis.md` - Success metrics and operational KPIs
- `dependency-map.md` - Project dependencies and integration points

**Audience:** Project managers, team leads, stakeholders

---

### `implementation/` - Phased Implementation & Developer Guides

**Purpose:** How to build, run, test, debug, deploy. Living documents updated as code evolves. Tracks progress through all 5 phases.

**Master Tracker:**

- `implementation-tracker.md` - **Single source of truth** for implementation progress. Phase/stage status, task checklists, acceptance criteria, risks, blockers.

**Phase-Specific Implementation Guides:**

- `1-phase-one/` - Foundation & Basic OS Harvest (Weeks 1-4)
  - `phase-1-stage-1-foundation.md` - Project scaffolding, core infrastructure setup
  - `phase-1-stage-2-core-features.md` - Agent, SQL logging, domain models
  - `phase-1-stage-3-scale.md` - Parallel collection, performance optimization
  - `phase-1-stage-4-observability.md` - Monitoring, alerting, diagnostics
  - `phase-1-stage-5-hardening.md` - Testing, deployment, security hardening
- `2-phase-two/` - Scale & Resilience (Weeks 5-8) *(to be created)*
- `3-phase-three/` - Machine Discovery & Lifecycle (Weeks 9-12) *(to be created)*
- `4-phase-four/` - F5 & Repository Integration (Weeks 13-17) *(to be created)*
- `5-phase-five/` - WebUI & Reporting (Weeks 18-22) *(to be created)*

**Developer Guides (To Be Created):**

- `developer-guide.md` - Setup, build, run instructions
- `database-setup.md` - SQL Server configuration, schema deployment
- `testing-guide.md` - Unit, integration, end-to-end test patterns
- `configuration-reference.md` - appsettings.json schema, Azure Key Vault setup
- `debugging-tips.md` - Common issues and solutions
- `code-patterns.md` - MERGE examples, WinRM sessions, Polly policies

**Audience:** Developers actively building features

---

### `reference/` - Executable Artifacts

**Purpose:** Generated or versioned artifacts. Treat as build outputs.

**Key Documents:**

- `schema-ddl.sql` - Executable SQL DDL (canonical source)
- `interface-catalog.md` - (to be generated from code)
- `api-reference.md` - (to be created for Phase 3 WebUI)
- `dependencies.puml` - (to be generated from `dotnet list reference`)

**Audience:** DBAs, operations, automation scripts

---

## Document Lifecycle Rules

### Architecture Documents

- **Changes Rarely:** Only when design decisions shift (requires ADR)
- **Review Required:** Architect approval for any modifications
- **Versioning:** Git commit history is authoritative

### Planning Documents

- **Active During Project:** Updated weekly/sprint
- **Frozen After Phase:** Archived when phase completes (e.g., `phase-1-plan.md` → `planning/archive/`)
- **No Retroactive Edits:** Once phase done, treat as historical record

### Implementation Documents

- **Living Docs:** Update with code changes
- **CI Validation:** (Future) Scripts verify examples still work
- **Generated Sections:** (Future) Auto-update from code comments

### Reference Documents

- **Generated or Executable:** Prefer automation over manual updates
- **Versioned Artifacts:** Tag schema DDL with release numbers
- **Test on Deploy:** Validate DDL executes cleanly before commit

---

## Cross-References

### From Architecture → Planning

**Pattern:** "See `planning/implementation-roadmap.md` for delivery timeline."

**Example:** `architecture-overview.md` links to roadmap for current phase status.

### From Planning → Architecture

**Pattern:** "Implements ADR-002 hexagonal structure; see `architecture/architectural-decisions.md`."

**Example:** `planning/phase-1-plan.md` references specific ADRs for design context.

### From Implementation → Architecture

**Pattern:** "For design rationale, see `architecture/domain-architecture.md`."

**Example:** `implementation/1-phase-one/phase-1-stage-2-core-features.md` links to architecture for invariant rules.

### From Implementation → Reference

**Pattern:** "Run schema DDL: `sqlcmd -i docs/architecture/schema-ddl.sql`."

**Example:** `implementation/database-setup.md` provides executable commands.

---

## Finding What You Need

### "I want to understand why we made a decision"

→ `architecture/architectural-decisions.md` (ADRs)

### "I want to see the big picture design"

→ `architecture/architecture-overview.md`

### "I want to know what's being built next"

→ `planning/implementation-roadmap.md`

### "I want to track implementation progress"

→ `implementation/implementation-tracker.md` (master dashboard for all phases)

### "I want to implement a specific phase/stage"

→ `implementation/1-phase-one/phase-1-stage-X-<name>.md` (detailed stage guides)

### "I want to set up my dev environment"

→ `implementation/developer-guide.md` (to be created)

### "I want to deploy the database schema"

→ `architecture/schema-ddl.sql`

### "I want to understand a specific layer (Domain, Application, etc.)"

→ `architecture/<layer>-architecture.md` (e.g., `domain-architecture.md`)

---

## Contributing to Documentation

### When to Create New Docs

- **Architecture:** Only when adding new cross-cutting concern (e.g., `security-architecture.md`) or new layer
- **Planning:** Create phase plan when starting that phase
- **Implementation:** Create guide when solving non-trivial setup problem (> 10 steps)
- **Reference:** Generate from code when possible; manual only for DDL or diagrams

### When to Update Existing Docs

- **Architecture:** Design shift (requires ADR), new invariant discovered
- **Planning:** Task complete, milestone reached, risk identified
- **Implementation:** Code pattern changes, new dependency added, setup steps refined

### Style Guidelines

- **Headers:** Use `**Last Updated:**`, `**Status:**`, `**Owner:**` at top
- **Sections:** Keep ≤ 250 lines per doc; split into multiple files if exceeds
- **Code Examples:** Always specify language (` ```csharp `, ` ```sql `, ` ```json `)
- **Links:** Use relative paths (`../planning/implementation-roadmap.md`)
- **TODOs:** Mark incomplete sections with `**TODO:**` + target phase

---

## Maintenance Schedule

- **Daily (During Active Development):** Update `implementation/implementation-tracker.md` with task completions, blockers
- **Weekly:** Review phase progress, update risks in tracker
- **End of Stage:** Mark stage complete in tracker, verify acceptance criteria met
- **End of Phase:** Freeze phase folder, update roadmap, create next phase guides
- **Architecture Change:** Add ADR, update affected component docs
- **Major Refactor:** Regenerate reference docs (interface catalog, dependencies)
- **Quarterly:** Review all docs for stale TODOs, outdated links

---

## Historical Context

For superseded planning documents and earlier architectural explorations, see:

- `architecture/archive/` - Historical design documents marked SUPERSEDED
