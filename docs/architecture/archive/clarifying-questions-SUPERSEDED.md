# ⚠️ SUPERSEDED DOCUMENT - CLARIFYING QUESTIONS (Historical)

**Original Date:** November 19, 2025
**Archived:** November 20, 2025
**Superseded By:** ADRs (`architectural-decisions.md`) and finalized pre-implementation review.

Purpose of this document was to capture early requirements and operational clarifications. All meaningful answers have been incorporated into ADRs 001-009 (e.g., scale, WinRM usage, weekly digest, canonical certificate model, soft delete, buffering strategy).

No further edits should be made; retain for historical traceability.

---

## Original Q&A (Preserved)

Scale: Approximate number of Windows machines and F5 devices? Expected total certificates?
    [User: Approx. 300 Windows servers and 5 F5 devices, totaling around 1,000 certificates.]
Performance: Target max harvest duration? Parallelism constraints (e.g., limit concurrent WinRM/Remote Registry sessions)?
    [User: Target harvest duration is under 30 minutes. Limit to 10 concurrent sessions to avoid network saturation.]
Protocols: How will we pull remote OS/IIS certs without agents? WinRM? Remote Registry? CIFS share? Any blocked ports?
    [User: We'll use WinRM for OS/IIS certs. Ports 5985 and 5986 should be open.]
Permissions: Do we have a single AD service account with rights to enumerate all remote stores? Any domains/forests boundaries?
    [User: Yes, we have a single AD service account with necessary rights across all domains.]
F5 API: Version variability? Need capability negotiation? Rate limit thresholds?
    [User: F5 devices run versions 17.x. We need to handle capability negotiation and respect a rate limit of 5 requests per second.]
Expiry Policy: Different windows per environment (e.g., non-prod lax vs prod strict)? Need override rules?
    [User: We currently expect to be alerting on prod environments with a strict 30-day expiry window.]
Alerting: Should cert expiry alerts consolidate daily into digest or fire immediately? Suppression after first alert?
    [User: A weekly digest is preferred, with suppression after the first alert for each certificate.]
Repository Source: What exactly is the “certificate repository”? Filesystem share? Database? Format?
    [User: The certificate repository is a remote machine that currently holds exported PFX files in a secure CIFS share.]
Chain Building: Do we need full chain for compliance auditing or only leaf metadata?
    [User: Not sure. But I think only leaf metadata is required for our compliance auditing.]
Deduplication: Should identical thumbprint across multiple machines store multiple rows or single canonical with references?
    [User: We prefer a single canonical record with references to all machines that have the same certificate.]
Historical Data: Keep previous NotAfter values if renewed? Need timeline of changes?
    [User: No, we do not need to keep previous NotAfter values. Only the current value is necessary.]
Compliance: Need to flag weak key sizes, deprecated algorithms (SHA1) automatically?
    [User: Not in our current scope, but it could be useful in the future.]
Secrets: Which store first—Windows Credential Manager, DPAPI-protected JSON, or external vault? Rotation process?
    [User: We'll be using a GMSA for authentication, so no secrets storage is needed.]
Scheduling: Should different ports run on different cadences (e.g., F5 hourly, OS nightly)?
    [User: Having the ability to handle different cadences would be helpful, but not necessary for initial implementation.]
Failure Handling: After N consecutive failures collecting from a machine, mark as inactive? escalate?
    [User: Failures should be logged, and will be remediated as needed.]
Persistence: Is transaction atomicity needed per machine harvest? If partial failure, rollback or keep partial?
    [User: Keep partial and log failures.]
Serialization: Will we expose an API early? If yes, contract versioning (DTO layer) needed now?
    [User: Unsure. Please clarify.]
Observability: Preferred metrics backend (Prometheus endpoint vs Seq vs App Insights)?
    [User: Unsure. Please clarify.]
Deployment: Windows Service only or container orchestrated? Need self-update mechanism?
    [User: Windows service. Application updates will be handled with Azure DevOps pipelines.]
Security: Any requirement for FIPS compliance or restricted crypto algorithms?
    [User: Not that I am aware of.]
Data Retention: How long to retain expired certificate records? Clean-up policy?
    [User: All data is to be kept current. Retention is not expected or requested in our scope at this time.]
Multi-tenancy: Any future need to support multiple divisions/clients with isolated visibility?
    [User: No.]
Machine Rename: Strategy when hostnames change—match by SID? Domain GUID? IP?
    [User: Outside of of current scope]
Partial Collections: If one adapter fails (e.g., F5) should harvest mark outcome degraded? With alerts?
    [User: See above. Log the failure and collect what we can.]
Throttling: Need central rate limiter to avoid saturating network or F5 control plane?
    [User: Possibly. Unable to speculate at this time.]
Migration: Do we need a dual-write phase (PowerShell + C#) for validation before cutover?
    [User: No.]
Alert Escalation: After initial alert, escalate severity as expiry date approaches?
    [User: Yes.]
API Authentication: If we add controllers, what auth (Kerberos, OAuth, mutual TLS)?
    [User: Unsure. We'll have to experiment and see what method works best.]
Testing Data: Can we create a synthetic lab with sample cert topologies (expired, weak keys, duplicates)?
    [User: Yes.]
Source Attribution: Need to track which adapter produced each certificate for diagnostics?
    [User: Yes.]

---
_End of historical document._
