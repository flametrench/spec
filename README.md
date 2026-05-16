# Flametrench

[![Conformance](https://github.com/flametrench/spec/actions/workflows/conformance.yml/badge.svg)](https://github.com/flametrench/spec/actions/workflows/conformance.yml)

**An open specification for the load-bearing parts of every application.**

Identity. Tenancy. Authorization. Every application needs them. Every team rebuilds them. Flametrench is the contract that lets you stop.

---

## What this is

Flametrench is a language-agnostic specification for the capabilities every serious application needs but nobody wants to own: who your users are, what organizations they belong to, what they're allowed to do, and who did what when.

The specification lives in this repository. Reference implementations live in parallel SDK repositories, one per supported language. A framework-agnostic admin UI speaks the specification and works against any compliant backend.

The promise is semantic parity. A Laravel backend and a Next.js backend implementing Flametrench produce identical behavior over the wire — identical error codes, identical event shapes, identical audit trails, identical permission checks. You can move between stacks without rebuilding your foundation.

## Why "Flametrench"

At every rocket launch pad, beneath the visible spectacle, there's a flame trench — a concrete channel that redirects exhaust sideways during liftoff. It absorbs acoustic and thermal forces that would otherwise destroy the rocket on the pad. Everyone watches the launch. Nobody watches the trench. But the launch only succeeds because the trench is there.

This project is named for that piece of infrastructure. Identity, tenancy, and authorization are load-bearing. They absorb real stress so your product can ship. They're almost always invisible when they work, and ruinous when they don't.

## The v0.1 scope

Flametrench v0.1 covers three capabilities. Detailed specs live in [`docs/identity.md`](docs/identity.md), [`docs/tenancy.md`](docs/tenancy.md), and [`docs/authorization.md`](docs/authorization.md); the design decisions behind them are recorded in [`decisions/`](decisions/).

**Identity.** Opaque users (`usr_`); multiple credentials per user (`cred_`) with three types — password (Argon2id, parameters pinned), passkey (WebAuthn), OIDC. User-bound sessions (`ses_`) with rotation on refresh. MFA arrives in v0.2 (see below); v0.1 applications can layer MFA on by chaining credential verifications until they upgrade.

**Tenancy.** Flat organizations (`org_`); multi-organization memberships (`mem_`); five-state invitations (`inv_`) with atomic acceptance and resource-scoped pre-declared tuples. Role changes use a revoke-and-re-add chain for tamper-evident history. Sole-owner protection on both self-leave and admin-remove paths. Invitation acceptance binding (ADR 0009) lands as a v0.1.x security backport.

**Authorization.** Relational tuples (`tup_`) as the only authz primitive; exact-match `check()` over single relations or non-empty relation sets. Six built-in relations (`owner`, `admin`, `member`, `guest`, `viewer`, `editor`) plus application-registered custom relations. No rewrite rules or derivations in v0.1 — applications materialize implied grants or compose checks at call sites. Rewrite rules arrive in v0.2 (ADR 0007); group subjects and parent-child inheritance remain deferred.

## What v0.2 adds

The spec is at `v0.3.0`, stable. SDK package versions are at `0.3.0` across all four families (`ids`, `identity`, `tenancy`, `authz`). The v0.2 work splits across nine ADRs (0007–0015) and one backport:

**Authorization rewrite rules (ADR 0007).** A subset of Zanzibar's `userset_rewrite`: the three node types `this`, `computed_userset`, and `tuple_to_userset`, composed via union. Cycle detection and depth/fan-out bounds (8 / 1024). Rules ride on top of v0.1's exact-match `check()` — when no rules are registered, behavior is byte-identical to v0.1.

**Multi-factor authentication (ADRs 0008 + 0010).** Three first-class factor types under a new `mfa_` ID prefix:

- **TOTP** (RFC 6238) — SHA-1 / SHA-256 / SHA-512 with the standard test vectors pinned in conformance.
- **WebAuthn assertion verification** — ES256 + RS256 + EdDSA, dispatched from the COSE_Key's `alg` field. Signature counter monotonicity per spec §6.1.1 cloned-authenticator detection.
- **Recovery codes** — 10 single-use codes in a 31-char alphabet excluding `0/O/1/I/L`.

Per-user enforcement via `usr_mfa_policy` (with grace window for rollout). `verifyMfa` does not mint sessions itself; the session-mint path becomes `verifyPassword → verifyMfa → createSession`, three calls the application sequences.

**Invitation acceptance binding (ADR 0009).** Closes a privilege-escalation primitive in v0.1 where any authenticated user could accept an admin-targeted invitation. Backported into v0.1.x; `acceptInvitation` now requires `accepting_identifier` to byte-match `invitation.identifier` when the caller asserts an existing `usr_id`.

**Share tokens (ADR 0012).** A new `shr_` ID prefix and `ShareStore` interface for time-bounded, presentation-bearer access to a single resource without minting an authenticated principal. Token storage matches sessions (SHA-256 → 32 bytes BYTEA, constant-time compare); `expires_at` capped at 365 days; optional `single_use` semantics with transactional consume on first verify.

**Postgres-backed reference adapters.** `PostgresIdentityStore`, `PostgresTenancyStore`, `PostgresTupleStore`, and `PostgresShareStore` now ship in every SDK family alongside the in-memory reference stores, mirroring in-memory semantics byte-for-byte at the SDK boundary. Postgres-backed rewrite-rule evaluation remains deferred — the in-memory store is the rules-enabled path in v0.2.

**Postgres adapter transaction nesting (ADR 0013).** Every Postgres adapter cooperates with adopter-side outer transactions: when constructed with a caller-owned connection, multi-statement operations open a SAVEPOINT instead of `BEGIN`, and single-statement writes shield the outer txn from constraint violations via `nested()`. Standalone construction (DataSource / pool / DSN) is unchanged.

**User display name + updateUser (ADR 0014).** `User` carries an optional `display_name` (max 200 chars, NFC-normalized) with partial-update semantics through a new `updateUser` operation.

**User enumeration (ADR 0015).** `IdentityStore.listUsers` provides cursor-paginated enumeration filtered by credential-identifier substring (case-insensitive) and/or user `status`.

Everything else — audit logs, notifications, file handling, billing hooks, feature flags, magic-link credentials — is out of scope for v0.2 and arrives in later versions. Shipping narrow is the point.

## SDK families

Flametrench ships five first-party SDK families, all conforming to the same fixture corpus:

| Language | Repos |
|---|---|
| Python 3.11+ | [`ids-python`](https://github.com/flametrench/ids-python), [`identity-python`](https://github.com/flametrench/identity-python), [`tenancy-python`](https://github.com/flametrench/tenancy-python), [`authz-python`](https://github.com/flametrench/authz-python) |
| Node 20+ (TypeScript, monorepo) | [`flametrench/node`](https://github.com/flametrench/node) — `@flametrench/{ids,identity,tenancy,authz}` |
| PHP 8.3+ | [`ids-php`](https://github.com/flametrench/ids-php), [`identity-php`](https://github.com/flametrench/identity-php), [`tenancy-php`](https://github.com/flametrench/tenancy-php), [`authz-php`](https://github.com/flametrench/authz-php) |
| Java 17+ | [`ids-java`](https://github.com/flametrench/ids-java), [`identity-java`](https://github.com/flametrench/identity-java), [`tenancy-java`](https://github.com/flametrench/tenancy-java), [`authz-java`](https://github.com/flametrench/authz-java) |
| Go 1.22+ (monorepo) | [`flametrench/flametrench-go`](https://github.com/flametrench/flametrench-go) — `github.com/flametrench/flametrench-go/packages/{ids,identity,tenancy,authz}` |

A framework adapter for Laravel ([`flametrench/laravel`](https://github.com/flametrench/laravel)) layers on top of the PHP SDK family.

A conformance test suite lives alongside the specification (29 fixture files spanning v0.1.0, v0.2.0, and v0.3.0). SDKs claim compliance by running the fixtures against themselves; cross-language parity is enforced by the same fixtures consumed by all five families.

## What this specification defines

At a high level, Flametrench defines:

- **The resources** a compliant backend exposes over HTTP — users, sessions, credentials, organizations, memberships, invitations, authorization tuples, and a meta-schema introspection endpoint.
- **The wire protocol** — OpenAPI 3.1 documents for every resource, with a JSON Schema for every payload.
- **The semantics OpenAPI can't express** — idempotency rules, error taxonomy, pagination behavior, event ordering, ID format, timestamp format, and version negotiation.
- **The conformance suite** — a black-box test runner that hits a configured `FLAMETRENCH_URL` and runs hundreds of test cases covering every contract endpoint.

What this specification does not define:

- **How a backend stores data.** Postgres, MySQL, SQLite, something else — the specification doesn't care, as long as the wire behavior is correct.
- **How a backend is architected internally.** Hexagonal, layered, MVC, serverless — irrelevant to compliance.
- **What a backend does beyond Flametrench.** Your application does whatever it does. Flametrench is the boring load-bearing layer underneath.

## Status

- **v0.1 spec**: shipped. Adopted by sitesource/admin (the first PHP adopter); spec#5 surfaced in adoption and was patched in v0.1.x via ADR 0009.
- **v0.2 spec**: stable, tagged `v0.2.0` (2026-04-30). Surface: rewrite rules (ADR 0007), MFA TOTP/WebAuthn/recovery (ADRs 0008 + 0010), invitation acceptance binding (ADR 0009, also in v0.1.x), org display name + slug (ADR 0011), share tokens (ADR 0012), Postgres adapter transaction nesting (ADR 0013), user display name (ADR 0014), and user enumeration (ADR 0015).
- **v0.3 spec**: stable, tagged `v0.3.0` (2026-05-15). The release **hold for the Go SDK family addition** (ADR 0018) is in effect — Go is the 5th SDK family, joining at v0.3.0 so the matrix advances in lockstep. v0.3.0 ships when Go reaches parity (~2-3 weeks post-Go-scaffold). Surface: personal access tokens (ADR 0016) — non-interactive bearer credentials for CLI / CI / server-to-server use, with prefix-routed verification (`pat_…` / `shr_…` / session) and a new `auth.kind` audit discriminator; Postgres-backed rewrite-rule evaluation (ADR 0017) — `PostgresTupleStore.check()` accepts the same `rules` option as `InMemoryTupleStore`, retiring the v0.2 in-memory-shadow workaround. The v0.3 security audit (32 findings) is closed: 22 fixed in code, 7 spec-documented, 2 explicit v0.4 deferrals — see [`docs/security-audit-v0.3.md`](docs/security-audit-v0.3.md). Migration guidance: [`docs/migrating-to-v0.3.md`](docs/migrating-to-v0.3.md).
- **SDKs**: Python / Node / PHP / Java / Go span `v0.3.0` across the family (`ids`, `identity`, `tenancy`, `authz`). Packagist + npm have v0.2.x stable today; v0.3.0 is queued and waiting on the Go family. PyPI and Maven Central are also bootstrapping (org / credential approvals pending) and will publish v0.3.0 once unblocked. Go publishes via `go get` directly from the GitHub tag (no central registry). Always verify a registry directly before quoting state: `npm view @flametrench/<pkg> versions --json` (note the plural — singular `version` returns only the `latest` dist-tag). The release checklist at `docs/release-checklist.md` is the canonical pre-publish process.
- **Postgres reference**: `postgres.sql` covers the full v0.1 + v0.2 + v0.3 data model (including the `mfa`, `usr_mfa_policy`, and `shr` tables added in v0.2, the `pat` table added in v0.3, and the `usr.display_name` column added in v0.2). `postgres-rls.sql` is an optional RLS companion. v0.3 also relaxes the `tup.subject_type` check constraint from a hard enum to `^[a-z]{2,6}$` to support `pat` and adopter-defined subject types in rewrite rules — see `migrating-to-v0.3.md` for the migration SQL.
- **Conformance suite**: 29 fixture files (27 v0.1/v0.2 + 2 v0.3 PAT fixtures), executed by all four SDK families.

## Structure of this repository

```
flametrench/spec/
├── README.md                    this document
├── LICENSE                      Apache 2.0
├── NOTICE                       copyright attribution
├── docs/
│   ├── ids.md                   ID format (normative)
│   ├── identity.md              identity capability (normative)
│   ├── tenancy.md               tenancy capability (normative)
│   ├── authorization.md         authorization capability (normative)
│   ├── shares.md                share tokens (v0.2; ADR 0012)
│   ├── security.md              threat model + adopter responsibilities (normative)
│   ├── security-audit-v0.3.md   v0.3 security audit — 32 findings + remediation table
│   ├── release-checklist.md     pre-publish process; required reading before any version bump
│   ├── external-idps.md         coexistence with Auth0 / Clerk / Cognito / etc. (non-normative)
│   ├── migrating-to-v0.2.md     upgrade guide for v0.1 adopters
│   └── migrating-to-v0.3.md     upgrade guide for v0.2 adopters
├── decisions/                   Architecture Decision Records (18 ADRs)
│   ├── README.md                index + ADR writing guide
│   ├── 0001 — authorization model
│   ├── 0002 — tenancy model
│   ├── 0003 — invitation state machine
│   ├── 0004 — identity model
│   ├── 0005 — revoke-and-re-add lifecycle pattern
│   ├── 0006 — legacy password migration
│   ├── 0007 — authorization rewrite rules                 (v0.2)
│   ├── 0008 — multi-factor authentication                 (v0.2)
│   ├── 0009 — invitation acceptance binding               (v0.1.x security)
│   ├── 0010 — WebAuthn RS256 + EdDSA                       (v0.2)
│   ├── 0011 — organization display name + slug             (v0.2)
│   ├── 0012 — share tokens                                 (v0.2)
│   ├── 0013 — Postgres adapter transaction nesting          (v0.2)
│   ├── 0014 — user display name                             (v0.2)
│   ├── 0015 — IdentityStore.listUsers                       (v0.2)
│   ├── 0016 — personal access tokens                         (v0.3)
│   ├── 0017 — Postgres rewrite-rule evaluation               (v0.3)
│   └── 0018 — Go SDK family addition                         (v0.3)
├── reference/                   non-normative implementation artifacts
│   ├── README.md                conventions; what's normative vs reference
│   ├── postgres.sql             reference Postgres DDL (v0.1 + v0.2 + v0.3 additive)
│   └── postgres-rls.sql         optional Row-Level Security companion
├── openapi/
│   ├── flametrench-v0.1.yaml              v0.1 wire surface (ADR 0009 patch included)
│   ├── flametrench-v0.2-additions.yaml    v0.2 additive overlay (MFA, display names, listUsers)
│   └── flametrench-v0.3-additions.yaml    v0.3 additive overlay (personal access tokens)
├── conformance/
│   ├── index.json               29-fixture manifest
│   ├── fixture.schema.json
│   ├── fixtures/                cross-SDK fixture corpus
│   └── (validator + harness in .github/scripts)
└── tools/                       fixture generators (Python, deterministic)
```

## How to follow along

- Watch this repository for specification changes.
- Watch the SDK repositories for implementation progress.
- Join GitHub Discussions (opening once v0.2 stabilizes) for design conversations.
- Read the commit history — specification work is happening in the open, with reasoning in commit messages where it matters.

## Contributing

The specification is at v0.2 stable and the surface area is small, so direct contributions are limited while v0.3 work is being scoped. What helps most right now:

- **Questions and challenges.** If something in the specification looks wrong, unclear, or underdefined, open an issue. Early feedback has disproportionate impact.
- **Prior art pointers.** If you know of a project that has solved one of these problems well, we want to learn from it.
- **Real-world requirements.** If you're running a Laravel or Next.js application in production and dealing with identity, tenancy, or authorization pain, tell us what hurts.

Pull requests for additional SDK languages will be welcomed once an adopter signals real demand.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution workflow, including the Developer Certificate of Origin (DCO) signoff requirement.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Copyright 2026 NDC Digital, LLC.
