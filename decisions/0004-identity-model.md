# 0004 — Identity model: opaque users, layered credentials

**Status:** Accepted
**Date:** 2026-04-23

## Context

Identity in Flametrench spans three entities: users, credentials, and sessions. Each has its own design axis, and they interact:

- **Users.** Do they carry identifiers (email) directly, or are identifiers a property of credentials? How opaque is the entity?
- **Credentials.** What types are in v0.1? What's the normative stance on password hashing?
- **Sessions.** Are they user-bound or org-bound? Rotated or refreshed in place? What's the relationship between the session identifier and the bearer token?

User shape constrains credential shape constrains session shape.

## Decision

### Scope: "Standard"

Three scope levels were considered:

- **Minimal** — `usr_` only; credentials and sessions are application concerns.
- **Standard** — `usr_` + `cred_` + `ses_` with lifecycle; password + passkey + OIDC.
- **Rich** — Standard + MFA + magic link + SAML + device tracking.

**Standard is v0.1 scope.** Minimal leaves real gaps in a project that positions itself as "identity, tenancy, authorization" — a user can't actually authenticate. Rich is scope creep; each of MFA, SAML, and magic link has enough nuance to be its own v0.2+ decision.

### Users are opaque

A `usr_` row carries:

- `id` (UUIDv7)
- `status` (`active` / `suspended` / `revoked`)
- `created_at`, `updated_at`

No email, no name, no phone. Identifiers live on credential rows. A user can exist without any email — service accounts, migration imports, users who only authenticate via SSO — and binding a single "primary identifier" to the user entity creates awkward migration paths when that identifier changes.

Applications that want to pin a display name or primary contact to the user entity MAY do so as an application-level extension; the spec does not define those fields.

User lifecycle mirrors tenancy: `active → suspended → active` (reinstate) or `active/suspended → revoked` (terminal). Revocation does NOT delete the row; it preserves audit. User rows never get a `replaces` chain — users don't fork the way memberships do.

### Credentials: password, passkey, OIDC

A credential (`cred_`) is one specific way a user can prove identity. One user has N credentials. v0.1 defines three types:

| Type | Identifier | Payload |
|---|---|---|
| `password` | Email or handle | PHC-encoded Argon2id hash |
| `passkey` | WebAuthn credential ID | Public key, signature counter, RP ID |
| `oidc` | Issuer-assigned subject or email | Issuer URL + subject claim |

Explicitly deferred to v0.2+: SAML (enterprise scope), magic link (effectively a single-use OIDC-shaped cred), SMS/TOTP (MFA territory).

### Password hashing is pinned

Every conforming implementation MUST store password credentials as **Argon2id** in PHC string format with minimum parameters:

- Memory: ≥ 19 MiB (`m=19456`)
- Iterations: ≥ 2 (`t=2`)
- Parallelism: ≥ 1 (`p=1`)

These floors track the OWASP Password Storage Cheat Sheet as of 2026. Implementations SHOULD use stronger parameters when hardware supports them. The PHC format preserves algorithm and parameters with the hash; forward-compatible upgrades are straightforward.

Password hashing is where inconsistent choices cause real breaches. The spec MUST NOT permit a conforming implementation to ship bcrypt, scrypt, or PBKDF2. Argon2id is the consensus modern choice, and the spec pins it.

### Credentials rotate

Password change, passkey re-registration, OIDC re-link:

1. Existing `cred_` transitions to `status = revoked`.
2. New `cred_` inserted with `replaces = previous.id`.
3. All `ses_` sessions referencing the rotated credential MUST be terminated (`revoked_at = now()`).

The session-termination cascade is enforced at the SDK layer; the schema does not embed a trigger because application-layer transactions handle atomicity.

### Sessions are user-bound

A session (`ses_`) represents one authenticated session of one user:

- `id` (UUIDv7)
- `usr_id` — whose session
- `cred_id` — which credential established this session
- `created_at`, `expires_at`, `revoked_at` (nullable)

No IP address, user agent, or device fingerprint in the spec. Those are useful for security telemetry but they're PII with different retention and compliance implications. Applications may store them; the spec neither requires nor forbids.

**Sessions are user-bound, not org-bound.** Switching the active organization is a context change, not a session change. Applications needing org-bound sessions (e.g., strict compliance environments) MAY enforce that as application policy — the spec does not pick.

### Session rotation on refresh

Refreshing a session MUST create a NEW `ses_` row (new ID, new token) and mark the previous one `revoked_at = now()`. In-place refresh (same ID, extended `expires_at`) is NOT spec-conformant.

Rationale is the same as credential and membership rotation: every distinct session state has a unique ID, and audit trail is intrinsic rather than bolt-on.

### Session ID vs. session token

**The session's `id` is an identifier, not a secret.** It appears in logs, admin panels, audit queries. It MUST NOT be exposed as a bearer credential.

The session's **token** — the bearer value the client carries — is separate. Typical patterns:

- **Signed token (JWT or equivalent):** carries `ses.id` as a claim; verification is stateless.
- **Opaque token:** random bearer string indexed against a server-side table; verification requires lookup.

Implementations MUST ensure the token's authenticity is verifiable server-side on every authenticated request. The spec does NOT mandate JWT; both patterns are conformant.

### MFA is deferred

v0.1 does not model multi-factor authentication. Reasons:

- MFA adds real complexity: credential chains, grace periods, recovery codes, factor ordering, remember-this-device flags. Half-right is worse than absent.
- The primitives v0.1 does define (multiple credentials per user, session-to-credential linkage, credential rotation) are forward-compatible with the expected v0.2 MFA model.
- Applications needing MFA in v0.1 can layer it on: verify a second `cred_` before calling `session.create()`; the resulting session's `cred_id` points at the primary credential that established it.

## Consequences

- Conforming implementations can plug in any Argon2id password backend and any OIDC provider without spec adjustments.
- Rotation-on-change means every identity-state transition leaves a trail; no "silent state mutation" in identity any more than in tenancy or authz.
- User entities stay opaque; applications choose their own profile-extension strategies.

## Deferred to v0.2+

- MFA as first-class with factor chains and grace windows.
- Magic-link credentials.
- SAML / enterprise SSO.
- Passkey device attestation beyond basic registration.

## Rejected alternatives

- **`usr_` carries an email field.** Simple for the common case but assumes email, breaks for service accounts, and complicates email changes.
- **In-place session refresh.** Faster (no insert) but destroys the audit story.
- **Org-bound sessions.** Necessary for some zero-trust scenarios but imposes cost on the common multi-org case; leave to application policy.
- **Algorithm-agnostic hashing.** Letting implementations pick virtually guarantees inter-SDK mismatches and latent security holes.

## References

- [ADR 0005 — Revoke-and-re-add lifecycle pattern](./0005-revoke-and-re-add.md).
- `spec/docs/identity.md`.
- `spec/reference/postgres.sql` — `usr`, `cred`, `ses` tables.
- OWASP Password Storage Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html>
