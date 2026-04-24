# Identity

Flametrench identity covers how a user is represented, how they authenticate, and how authenticated sessions are tracked.

Three entities make up identity in v0.1:

- **`usr_`** — a user: the human or service principal whose identity is being managed.
- **`cred_`** — a credential: one specific way the user can prove they are the user.
- **`ses_`** — a session: an authenticated link between a user and an application.

This chapter is normative. Decisions recorded here are requirements for conformance. Rationale and alternatives considered live in [ADR 0004 — Identity model](../decisions/0004-identity-model.md).

## Users

### Entity shape

A user is an **opaque identity**. The user entity carries:

- `id` — UUIDv7; rendered on the wire as `usr_<hex>`.
- `status` — one of `active`, `suspended`, `revoked`.
- `created_at` — timestamp of creation, timezone-aware.
- `updated_at` — timestamp of last modification, timezone-aware.

Implementations MUST NOT require additional fields on `usr_` for spec conformance. Identifiers (email, phone, handle, display name) are application-layer extensions.

### Lifecycle

```
active → suspended → active     (reinstate)
active → revoked                (terminal)
suspended → revoked             (terminal)
```

- **`active`** — user can authenticate and participate.
- **`suspended`** — user cannot authenticate; active sessions MUST be terminated when the transition happens. The user's memberships (`mem_`) are NOT affected by user-level suspension; if the intent is to suspend a specific membership, use `mem.status` instead.
- **`revoked`** — user is terminated. All sessions MUST be terminated. All active credentials MUST transition to `revoked`. The user row is preserved for audit; it is never deleted.

### Operations

Implementations MUST provide:

- `createUser() → usr_id` — returns a new `usr_` with `status = active`.
- `getUser(usr_id) → user` — returns the entity or a not-found error.
- `suspendUser(usr_id)` — transitions to `suspended` and terminates sessions.
- `reinstateUser(usr_id)` — transitions `suspended → active`.
- `revokeUser(usr_id)` — transitions to `revoked`; triggers the cascade (sessions terminated, credentials revoked).

### Identifiers

A user has no intrinsic identifier. Identifiers live on credentials. To find a user by email:

```
findCredentialByIdentifier(type = "password", identifier = "alice@example.com") → cred
cred.usr_id → the user
```

Applications MAY cache a denormalized email on their own `usr_` extensions. The spec does not define this.

## Credentials

### Entity shape

A credential carries:

- `id` — UUIDv7; `cred_<hex>`.
- `usr_id` — the user this credential authenticates.
- `type` — one of `password`, `passkey`, `oidc`.
- `identifier` — a human-meaningful handle; format depends on type (see below).
- `status` — one of `active`, `suspended`, `revoked`.
- `replaces` — nullable FK to the previous credential in a rotation chain.
- Type-specific payload (below).
- `created_at`, `updated_at`.

### Credential types in v0.1

#### Password

- `identifier`: login handle, typically an email.
- Payload: `password_hash` — an Argon2id PHC string.

**Hashing requirements.** Implementations MUST use Argon2id. The PHC-encoded hash MUST include parameters meeting or exceeding:

- Memory: 19 MiB (`m=19456`)
- Iterations: 2 (`t=2`)
- Parallelism: 1 (`p=1`)

These match the OWASP Password Storage Cheat Sheet floor as of 2026. Implementations SHOULD use stronger parameters when hardware supports them.

Implementations MUST NOT store password credentials using bcrypt, scrypt, PBKDF2, SHA-2, or any other algorithm.

#### Passkey

- `identifier`: the WebAuthn credential ID, base64url-encoded.
- Payload:
  - `passkey_public_key` — raw public key bytes.
  - `passkey_sign_count` — WebAuthn signature counter; incremented on each successful assertion.
  - `passkey_rp_id` — the relying party ID (typically the application's eTLD+1).

#### OIDC

- `identifier`: the issuer-assigned subject or email claim; application choice.
- Payload:
  - `oidc_issuer` — the OIDC issuer URL.
  - `oidc_subject` — the value of the `sub` claim.

The pair `(oidc_issuer, oidc_subject)` uniquely identifies the user at the external identity provider.

### At most one active credential per (type, identifier)

A user MAY have many credentials, but the pair `(type, identifier)` MUST be unique across **active** credentials. Historical revoked credentials with the same `(type, identifier)` are permitted — this allows a password to be rotated and the email to be reused under the new credential.

### Lifecycle

```
active → suspended → active     (reinstate)
active → revoked                (terminal)
suspended → revoked             (terminal)
```

`suspended` is for short-lived blocks (e.g., temporary lockout during a password reset). `revoked` is terminal.

Credential rotation — password change, passkey re-registration, OIDC re-link — follows the **revoke-and-re-add** pattern defined in [ADR 0005](../decisions/0005-revoke-and-re-add.md):

1. The existing credential transitions to `status = revoked`.
2. A new credential is inserted with `replaces = old.id`.
3. All sessions (`ses_`) that were established by the rotated credential MUST be terminated (`revoked_at = now()`).

All three happen in one transaction.

### Operations

- `createCredential(usr_id, type, identifier, payload) → cred_id`.
- `rotateCredential(cred_id, new_payload) → new_cred_id` — implements the revoke-and-re-add sequence above.
- `suspendCredential(cred_id)`, `reinstateCredential(cred_id)`, `revokeCredential(cred_id)`.
- `verifyCredential(type, identifier, proof) → usr_id | null` — verifies a proof (password, WebAuthn assertion, OIDC ID token) and returns the authenticated user. Entry point for session creation.

## Sessions

### Entity shape

A session is an authenticated session of a user:

- `id` — UUIDv7; `ses_<hex>`.
- `usr_id` — the authenticated user.
- `cred_id` — the credential that established this session.
- `created_at` — timestamp of creation.
- `expires_at` — timestamp after which the session is considered expired.
- `revoked_at` — nullable; if set, the session is revoked.

The spec does NOT require IP address, user agent, device fingerprint, or geolocation. These are useful for security telemetry but carry PII and jurisdictional concerns; applications MAY add them as extension fields.

### Sessions are user-bound

A session is bound to a `usr_`, not to an `org_`. A user with memberships in multiple orgs uses the same session across all of them; "active org" is a client-side context attribute.

Applications with stricter compliance requirements (e.g., zero-trust banking) MAY enforce org-bound sessions at the application layer by gating each cross-org request with `check()` against the current org. The spec does not mandate this.

### Rotation on refresh

Refreshing a session MUST create a new `ses_` with a new `id` and mark the previous session `revoked_at = now()`. **In-place refresh** — keeping the same `id` and extending `expires_at` — is NOT spec-conformant.

The new session's `cred_id` SHOULD be the same as the previous session's unless the refresh involves re-authentication with a different credential.

### Session ID versus session token

**The session's `id` is not a secret.** It appears in logs, admin panels, and audit queries. An SDK MUST NOT expose `ses.id` as a bearer credential.

The session's **token** is a separate piece of state derived from `id` plus implementation-specific signing or lookup. Typical patterns:

- **Signed token** (JWT or equivalent) — carries `ses.id` as a claim, signed by the auth service; verification is stateless, requires no database lookup.
- **Opaque token** — random bearer string indexed against a server-side session table; verification requires a lookup on every request.

Implementations MUST ensure the token's authenticity is verifiable server-side on every authenticated request. The spec does not mandate JWT; both patterns are conformant.

### Termination

A session terminates when any of the following occur:

- `expires_at` passes.
- `revokeSession(ses_id)` is called — sets `revoked_at = now()`.
- The underlying credential is rotated or revoked (cascades to all sessions bound to it).
- The user is suspended or revoked (cascades to all their sessions).

### Operations

- `createSession(usr_id, cred_id, ttl) → ses_id, token`.
- `refreshSession(ses_id) → new_ses_id, new_token`.
- `revokeSession(ses_id)`.
- `listSessions(usr_id) → [session]`.

## Multi-factor authentication (deferred)

Flametrench v0.1 does NOT specify MFA. See [ADR 0004](../decisions/0004-identity-model.md) for rationale.

Applications that need MFA in v0.1 can layer it on:

- Maintain multiple credentials per user (e.g., one password credential and one passkey credential).
- Require verification of a second credential before calling `createSession`.
- The resulting session's `cred_id` records the primary credential that established it.

v0.2 will introduce first-class MFA with credential chains, grace windows, and recovery codes.

## Conformance fixtures

The following fixtures are REQUIRED for identity interoperability across conforming implementations:

### Argon2id hash format

A password credential created with the input password `"correcthorsebatterystaple"` and parameters `m=19456, t=2, p=1` and the fixed salt `c29tZXNhbHQxMjM` (base64: "somesalt123") MUST produce a hash that verifies under any other compliant Argon2id verifier.

### OIDC subject resolution

Given an OIDC credential with `issuer = "https://accounts.google.com"` and `subject = "1234567890"`, `findCredentialByIdentifier` with the matching `(issuer, subject)` pair MUST return this credential. Issuer URL normalization follows RFC 3986: trailing-slash equivalence is permitted, but case normalization of the host is required.

More conformance fixtures will be added in `spec/conformance/` as implementations surface specific interoperability questions.
