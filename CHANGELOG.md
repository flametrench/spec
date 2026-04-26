# Changelog

All notable spec changes are recorded here. Adopter-facing migration guidance lives in [`docs/migrating-to-v0.2.md`](docs/migrating-to-v0.2.md). Per-SDK changelogs live in their respective repos; this file tracks the spec contract only.

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
