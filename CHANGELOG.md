# Changelog

All notable spec changes are recorded here. Adopter-facing migration guidance lives in [`docs/migrating-to-v0.2.md`](docs/migrating-to-v0.2.md). Per-SDK changelogs live in their respective repos; this file tracks the spec contract only.

## [v0.3.0] — Unreleased (in development)

### Added
- **ADR 0016** — Personal access tokens. New `pat_` primitive for non-interactive (CLI / CI / server-to-server) auth. Wire format `pat_<32hex-id>_<base64url-secret>` (Stripe-style id-then-secret); the auth middleware prefix-routes incoming bearer tokens to session / share / PAT verifiers. Argon2id storage at the cred-password parameter floor; conflated `InvalidPatTokenError` shape on missing-row vs wrong-secret to avoid a token-presence timing oracle. New `auth.kind ∈ {session, pat, share, system}` audit discriminator (additive). Closes [`spec#14`](https://github.com/flametrench/spec/issues/14).
- **OpenAPI v0.3 additions** (`openapi/flametrench-v0.3-additions.yaml`) — four PAT management routes: `POST /v1/users/{usr_id}/pats`, `GET /v1/users/{usr_id}/pats`, `GET /v1/pats/{pat_id}`, `POST /v1/pats/{pat_id}/revoke`. Verification stays SDK-only (no public `/pats/verify`), mirroring the share-token precedent.
- **Reference Postgres** — new `pat` table with Argon2id `secret_hash`, `usr_id` FK, `name`, `scope TEXT[]`, `expires_at`, `last_used_at`, `revoked_at`, plus three indexes (per-user list, active filter, expiry sweep) and a `pat_touch` trigger. Lookup is by primary key (id), not token hash — contrast with `ses` and `shr`, whose wire formats are opaque.
- **`identity.md` chapter** — Personal access tokens (v0.3): wire format, bearer routing, normative verification semantics (8-step ordering), lifecycle, operations, `auth.kind` discriminator, cross-SDK parity contract.
- **ADR 0017** — Postgres rewrite-rule evaluation. Retires the v0.2 deferral in `docs/authorization.md`. `PostgresTupleStore.check()` now accepts the same `rules` option as `InMemoryTupleStore` and evaluates via iterative async expansion (one indexed SELECT per direct lookup / `tuple_to_userset` enumeration, recursive over `computed_userset`). Cycle detection, depth + fan-out bounds, and short-circuit semantics from ADR 0007 are unchanged. SQL push-down via recursive CTEs explicitly rejected for v0.3 — round-trip count isn't the bottleneck on properly-indexed `tup` tables. Revisit in v0.4+ as an opt-in escape hatch.
- **Node-only API change** — `evaluate()` (the internal rewrite-rule evaluator) becomes async-capable: `DirectLookup` and `ListByObject` callbacks return `Promise<...>`. `InMemoryTupleStore` wraps in `Promise.resolve(...)`; `PostgresTupleStore` issues real async queries. PHP/Python/Java keep synchronous callbacks (no language async coroutine bridge in v0.3).

### SDK matrix
- v0.3.0 SDK ports begin with PHP and Node (the unblocked registries). Python and Java implementations land code-ready and tagged but unpublished, pending the same registry blockers that held v0.2.0 (PyPI org approval, Maven Central credential regen).
- Both v0.3 features (PATs + Postgres rewrite-rules) ship together in each SDK release.

## [v0.2.0] — 2026-04-30

v0.2.0 stable cutoff. No surface changes vs `v0.2.0-rc.6`; this release flips ADRs 0007–0015 from Proposed to Accepted, snaps the four SDK families to `v0.2.0` (Python / Node / PHP / Java for `ids` / `identity` / `tenancy` / `authz`), and bumps the OpenAPI overlay version field from `0.2.0-rc.6` to `0.2.0`.

### Accepted ADRs
0007 (rewrite rules), 0008 (MFA), 0009 (invitation acceptance binding — backported v0.1.x), 0010 (WebAuthn RS256 + EdDSA), 0011 (org display_name + slug), 0012 (share tokens), 0013 (Postgres adapter transaction nesting), 0014 (user display_name), 0015 (`listUsers`).

### Cross-language SDK regression coverage
ADR 0013 savepoint cooperation is exercised by per-SDK adapter regression tests across PHP / Node / Python / Java: `PostgresIdentityStore` (createUser / credential creators shielded by `nested()`), `PostgresTenancyStore` (createOrg / createInvitation cooperation + savepoint rollback), `PostgresShareStore` (createShare / revokeShare savepoint cooperation), `PostgresTupleStore` (`INSERT … ON CONFLICT … DO NOTHING RETURNING` replaces catch-and-SELECT).

### Registry state at cut
- **Packagist**: `flametrench/{ids,identity,tenancy,authz}@v0.2.0` published.
- **npm**: `@flametrench/{ids,identity,tenancy,authz}@0.2.0` published via `pnpm publish --tag latest`; `latest` dist-tag moved from any pre-release to `0.2.0`.
- **PyPI**: blocked on `flametrench` org approval. Wheels are built locally; publish when unblocked.
- **Maven Central**: blocked on Sonatype Central Portal user-token regeneration. Bundles are built locally; publish when unblocked.

## [v0.2.0-rc.7-equivalent] — 2026-04-29 (cross-SDK ADR 0013 rollout)

No spec contract changes — all four SDK families now implement ADR 0013 (Postgres adapter transaction nesting). Per-package SDK bumps:

- `@flametrench/identity` to `v0.2.0-rc.7` (Node).
- `flametrench-identity` to `v0.2.0rc7` (Python).
- `dev.flametrench:identity` to `v0.2.0-rc.7` (Java).
- `flametrench-tenancy` to `v0.2.0rc6` (Python). `dev.flametrench:tenancy` to `v0.2.0-rc.6` (Java). Node tenancy unchanged at rc.5 — already cooperated correctly.
- `flametrench-authz` to `v0.2.0rc5` (Python). `dev.flametrench:authz` to `v0.2.0-rc.5` (Java). Node authz unchanged at rc.4 — already cooperated correctly.
- `PostgresTupleStore.createTuple` refactored across all four ecosystems to `INSERT ... ON CONFLICT (natural_key) DO NOTHING RETURNING`. The previous catch-and-SELECT pattern was incompatible with savepoint shielding because the follow-up SELECT would run inside a Postgres-aborted transaction. `DuplicateTupleError`/`DuplicateTupleException` contract preserved.

Closes [`flametrench/spec#11`](https://github.com/flametrench/spec/issues/11).

## [v0.2.0-rc.6] — 2026-04-28

### Added
- **ADR 0013** — Postgres adapter transaction nesting. Adapters detect an active outer transaction and use `SAVEPOINT/RELEASE` instead of `BEGIN/COMMIT`, enabling adopters to wrap multiple SDK calls in one atomic outer transaction (e.g. `DB::transaction(...)`). Savepoint name follows `ft_<method>_<random>` so pairing bugs surface as Postgres errors instead of silent half-commits. Closes [`flametrench/laravel#1`](https://github.com/flametrench/laravel/issues/1) reported by the `sitesource/admin` adopter (install-bootstrap atomicity). Cross-SDK rollout for Node/Python/Java tracked in [`spec#11`](https://github.com/flametrench/spec/issues/11).
- **ADR 0014** — User display name. Optional `display_name` field on the `User` entity (TEXT, nullable, no length cap, no normalization, no uniqueness). New `updateUser` operation with the same omitted-vs-null partial-update sentinel as `updateOrg`. `createUser` accepts the field at create time. Closes [`spec#9`](https://github.com/flametrench/spec/issues/9). Mirrors ADR 0011 for `Organization.name`.
- **ADR 0015** — `IdentityStore.listUsers`. Cursor-paginated user enumeration mirroring `listMembers` shape. Filters: case-insensitive substring against active credential identifiers (`query`), user status (`status`). Authorization gating lives at the host route — the SDK does not enforce. Closes [`spec#10`](https://github.com/flametrench/spec/issues/10).
- **Conformance fixtures**:
  - `identity/user-display-name.json` (8 tests) — round-trip, partial-update sentinel, Unicode round-trip without normalization, suspended-user-allowed, revoked-user-rejected, unknown-id NotFoundError.
  - `identity/list-users.json` (9 tests) — id-ordered enumeration, status filter, query case-insensitive substring, query skips revoked credentials, multi-page cursor walking, empty install, display_name pass-through.

### Postgres reference
- `usr.display_name TEXT NULL` column added (additive ALTER for v0.1 deployments upgrading).
- `PostgresTupleStore.createTuple` reference logic refactored: uses `INSERT ... ON CONFLICT (natural_key) DO NOTHING RETURNING` instead of catch-and-SELECT. The old pattern was incompatible with savepoint shielding because the follow-up SELECT runs inside a transaction Postgres has aborted (SQLSTATE 25P02). The new path preserves the `DuplicateTupleException` contract without raising a statement-level error. Adopters writing their own Postgres adapter SHOULD use the same pattern.

### OpenAPI
- New `GET /v1/users` endpoint with `cursor` / `limit` / `query` / `status` query params and `UserPage` response envelope.
- New `PUT /v1/users/{usr_id}` endpoint with `UpdateUserRequest` body.
- `User` schema gains optional `display_name`. `createUser` request body gains optional `display_name`.

### Bumped
- `tenancy-php` to `v0.2.0-rc.6` (ADR 0013 PHP impl).
- `identity-{node,php,python,java}` to `v0.2.0-rc.6` / `0.2.0rc6` (ADR 0013 PHP impl + ADR 0014 + ADR 0015).
- `authz-php` to `v0.2.0-rc.5` (ADR 0013 PHP impl in `PostgresTupleStore` and `PostgresShareStore`).
- Other SDK families pending — Node/Python/Java for ADR 0013 tracked in spec#11; tenancy and authz Node/Python/Java not yet shipped for ADR 0013.

## [v0.2.0-rc.5] — 2026-04-27

### Added
- New normative document [`docs/security.md`](docs/security.md) — unified threat model. Covers attacker classes, trust boundaries, per-primitive security claims, known gaps and explicit non-goals, and adopter responsibilities.
- New non-normative document [`docs/external-idps.md`](docs/external-idps.md) — coexistence patterns for adopters already on Auth0/Clerk/Cognito/Okta/WorkOS/Entra. Concrete Auth0 → Flametrench bridge example.

### Fixed (security posture)
- `verifyPassword` MUST consult `usr_mfa_policy` and surface `mfa_required = true` on the `VerifiedCredential` return when policy is active and the grace window has elapsed. The OpenAPI README has stated this since rc.1, but the four SDK families did not implement it through rc.4 — the policy table was decorative. Adopters configuring per-user MFA enforcement could be bypassed by applications that called `createSession` directly without consulting the policy. All four SDKs (Node / PHP / Python / Java) now implement the gate; the field is additive and defaults to `false`. Identity SDKs bumped to v0.2.0-rc.5.

### Bumped
- `identity-{node,php,python,java}` to v0.2.0-rc.5.
- `ids` and `authz` and `tenancy` SDKs unchanged.

## [v0.2.0-rc.4] — 2026-04-27

### Clarified
- `object_id` accepts wire-format prefixed IDs (`<prefix>_<32hex>`) at the Postgres adapter boundary across all four SDKs, in addition to bare 32-hex and canonical hyphenated UUIDs. ADR 0001 already states `object_type` is application-defined; this aligns the adapter implementations with that contract by routing prefixed forms through `decodeAny` rather than the strict `decode`. Closes [`spec#8`](https://github.com/flametrench/spec/issues/8) reported by the `sitesource/admin` adopter.
- No conformance-fixture changes. Read-side symmetry (encoding `object_id` back to its app-defined wire format on row mapping) is left as a deferred design discussion.

### Bumped
- `authz-{node,php,python,java}` to `v0.2.0-rc.4` / `0.2.0rc4`.
- `tenancy-{node,php,python,java}` to `v0.2.0-rc.5` / `0.2.0rc5`.
- `identity` and `ids` SDKs unchanged.

## [v0.2.0-rc.3] — 2026-04-27

### Added
- **ADR 0012** — share tokens for time-bounded resource access. New `shr_` ID prefix; new `shr` table in the reference Postgres schema; new `ShareStore` interface in the authz package across all four SDKs. Closes [`spec#7`](https://github.com/flametrench/spec/issues/7) reported by the `sitesource/admin` adopter (Phase 3.0a iter 1 file-manager shareable links). Token storage matches `ses` (SHA-256 → 32 bytes BYTEA, constant-time compare); `expires_at` capped at 365 days; optional `single_use` with transactional `consumed_at` on verify.
- New normative doc [`docs/shares.md`](docs/shares.md) covering when to use shares vs. tuples vs. sessions, the verification ordering, error precedence, and security considerations.

### Bumped
- `authz-{python,node,php,java}` to `v0.2.0-rc.3` / `0.2.0rc3` to ship the new `ShareStore`. `identity` and `tenancy` SDKs are unchanged at their respective rc.4 levels.

## [v0.2.0-rc.2] — 2026-04-26

### Added
- **ADR 0010** — WebAuthn RS256 + EdDSA. Extends the ADR 0008 verifier to dispatch on the COSE_Key's `alg` field. ES256 / RS256 (≥2048-bit) / EdDSA (Ed25519) all routed to their respective primitives. RS256 + EdDSA were previously "deferred to v0.3" in ADR 0008 — this ADR retires that deferral.
- **Conformance fixture** `identity/mfa/webauthn-assertion-algorithms.json` (6 tests). Pinned RSA + Ed25519 keypairs in `tools/generate_webauthn_alg_fixtures.py`.

### Bumped
- `identity-{python,node,php,java}` to `v0.2.0-rc.2`. `ids` and `authz` SDKs remain at `v0.2.0-rc.1` since they didn't change.

## [v0.2.0-rc.1] — 2026-04-25

### Added (v0.2 release-candidate)
- **ADR 0007** — authorization rewrite rules (subset of Zanzibar `userset_rewrite`: `this`, `computed_userset`, `tuple_to_userset`, union). Depth/fan-out caps 8/1024.
- **ADR 0008** — multi-factor authentication. New `mfa_` ID prefix; TOTP (RFC 6238), recovery codes, WebAuthn ES256 assertion verification; `usr_mfa_policy` per-user enforcement; `ses.mfa_verified_at` step-up freshness column.
- **Conformance fixtures**:
  - `authorization/rewrite-rules/{computed-userset,tuple-to-userset,empty-rules-equals-v01}.json` (9 tests)
  - `identity/mfa/totp-rfc6238.json` (18 RFC 6238 §B vectors)
  - `identity/mfa/recovery-code-format.json` (12 tests)
  - `identity/mfa/webauthn-assertion.json` (7 tests)
  - `identity/mfa/webauthn-counter-decrease-rejected.json` (4 tests)
- **Postgres reference**: `mfa` table, `usr_mfa_policy` table, `ses.mfa_verified_at` column.

## [v0.1.1] — 2026-04-25 (security)

### Fixed
- **ADR 0009** — invitation acceptance binding. `acceptInvitation` requires `accepting_identifier` byte-matching `invitation.identifier` when `as_usr_id` is supplied. Closes a privilege-escalation primitive reported in [`spec#5`](https://github.com/flametrench/spec/issues/5) where any authenticated user could accept an admin-targeted invitation. Backported into v0.1.x; tenancy SDKs tagged `v0.1.1`.

### Added
- **Conformance fixture** `tenancy/invitation-accept-binding.json` (4 tests).
- **OpenAPI**: `AcceptInvitationRequest` schema gains `accepting_identifier` field with sourcing requirement documented.

## [v0.1.0] — 2026-04-23

Initial spec.

### Surface
- **ADR 0001** — authorization model. Relational tuples; exact-match `check()`.
- **ADR 0002** — tenancy model. Flat orgs; multi-org memberships.
- **ADR 0003** — invitation state machine. Five-state lifecycle with atomic accept.
- **ADR 0004** — identity model. Opaque users; password / passkey / OIDC credentials; user-bound sessions.
- **ADR 0005** — revoke-and-re-add lifecycle pattern (cross-cutting).
- **ADR 0006** — legacy password migration.

### Capabilities
- IDs (`usr_`, `cred_`, `ses_`, `org_`, `mem_`, `inv_`, `tup_`).
- Identity (Argon2id-pinned passwords at OWASP floor; passkey + OIDC).
- Tenancy (orgs, memberships with sole-owner protection, invitations with pre-tuples).
- Authorization (relational tuples; six built-in relations).

### SDKs
Python / Node / PHP / Java first-party families; Laravel framework adapter.
