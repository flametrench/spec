# 0016 — Personal access tokens (PATs) for non-interactive auth

**Status:** Proposed
**Date:** 2026-05-02
**Targets:** v0.3.0

## Context

Flametrench v0.2's identity primitives — `cred` (passwords, passkeys, OIDC, MFA factors) and `ses` (user-bound sessions with rotation-on-refresh) — all assume an **interactive** authentication ceremony. Some human types a password, taps a YubiKey, scans a TOTP code; a session is minted; the bearer of the session token is the authenticated user for the session's lifetime.

That model breaks for **non-interactive** use cases:

- **CLI tools** that the operator wants to authenticate once and reuse for weeks (`gh auth login`, `aws configure`, `stripe login`)
- **CI/CD pipelines** that need a long-lived credential to call the host's API from a build runner
- **Server-to-server integrations** between two systems both running Flametrench-built services
- **Automation scripts** owned by a human but running on a schedule

Today, every adopter that needs this either:

1. Reuses sessions, with awkwardly long TTLs and a UX that doesn't match how operators think about "API tokens"
2. Forces interactive auth in non-interactive contexts (browser-redirect flows from a CLI; wrong DX)
3. Cargo-cults OAuth client credentials (heavy ceremony for self-hosted single-tenant adopters)
4. Rolls their own per-app PAT type that doesn't conform to anything (the path `sitesource/cloud-cli` v0.2 is currently being pushed toward; the [filing issue](https://github.com/flametrench/spec/issues/14))

Every operator-facing API at scale ends up here. GitHub has classic + fine-grained PATs. GitLab has personal + project access tokens. AWS has IAM access keys. Stripe has live/test API keys. Slack has app tokens. Without a spec primitive, every Flametrench adopter rebuilds the same five-piece machine — secret generation, Argon2id storage, constant-time verification, prefix-routed bearer dispatch, audit-log discrimination — and at least one will get the security-critical pieces wrong.

## Decision

A new resource type `pat` (`pat_<32hex>` for the row id; bearer token format defined below) is added to the spec in v0.3 as a **third bearer-credential type** alongside `ses` (session bearer for interactive auth) and `shr` (share bearer for resource-scoped grants). The `pat` prefix moves from "reserved" to "active" in the ID prefix registry; the `pat` table joins `cred` / `ses` / `mfa` in the reference Postgres schema as part of the identity capability.

PATs are deliberately **not** modeled as a `cred` variant. They differ in lifecycle (no rotation, just revoke + re-issue), bearer model (the secret IS the auth — no session intermediary), audit semantics (`auth.kind = 'pat'`), and field shape (`scope` has no `cred` analog). Conflating would force discriminator branches in every store method and obscure the per-primitive mental model.

### Entity shape

```
PersonalAccessToken = {
  id:           pat_<32hex>          // wire; UUIDv7 underneath
  usr_id:       usr_<32hex>          // owner — the human who issued the token
  name:         string                // human label ("My laptop CLI", "GitHub Actions deploy")
  scope:        string[]              // adopter-defined; spec does not pin a vocabulary
  secret_hash:  bytea                 // Argon2id hash of the secret half of the token
  prefix:       string                // first 8 chars of pat_id, exposed in lists for UX
  expires_at:   timestamptz | null    // optional; bounded above by 365 days when set
  last_used_at: timestamptz | null    // updated atomically on successful verify
  revoked_at:   timestamptz | null    // soft-revoke; verification rejects immediately when set
  created_at:   timestamptz
  updated_at:   timestamptz
}
```

### Wire format (normative)

The bearer token is **two segments** separated by `_`:

```
pat_<id-payload>_<secret-payload>
```

Where:

- `<id-payload>` is the 32 lowercase hex characters of the `pat_id`'s UUIDv7 (matching the existing `pat_<32hex>` wire format for the row identifier — same encoding as `usr_`, `org_`, etc.)
- `<secret-payload>` is **at least** 32 random bytes (256 bits of entropy) base64url-encoded with no padding. Implementations MAY produce longer secrets.

Example: `pat_019ddc5fa1b27c4e9f3a64b8e2c1d705_kJ8XVqW3pYf7N2bL9Q-D5FxR8aTcM1eZ`

This shape — **id-then-secret**, separable by the second underscore — gives the verifier an indexed lookup path (`SELECT ... FROM pat WHERE id = $1`) instead of an O(N) hash scan. Stripe's `sk_live_<id>_<secret>` shape is the prior art; GitHub's classic `ghp_<opaque>` shape forces a hash-prefix index, which we avoid by putting the id in the token.

The `prefix` field surfaced in list views shows the first 8 chars of the `pat_id` (e.g. `pat_019ddc5f`). It is **not** a slice of the secret; the secret is one-time-displayed at issuance and never persisted in plaintext.

### Routing on the wire

A server receiving `Authorization: Bearer <token>` distinguishes credential types by **prefix inspection**:

| Token starts with | Verify via |
|---|---|
| `pat_` | `IdentityStore.verifyPatToken(token)` |
| anything else | `IdentityStore.verifySessionToken(token)` (existing v0.2 behavior) |

Existing v0.2 session tokens are opaque base64url with no prefix; this routing is additive and does not change the format of session tokens. Adopters with existing v0.2 deployments do not need to re-mint sessions when they upgrade to v0.3; the PAT path is purely new code.

### SDK surface

A new `PatStore` interface (or extension of `IdentityStore` — see Open Questions) ships in the **identity** package across all four SDK families. Operations:

```
createPat(input: { usrId, name, scope, expiresAt? }) → { pat, token }
  // token is the opaque bearer credential (`pat_<id>_<secret>`); only visible here.
  // Persists Argon2id(secret) under matching params to cred-password hashing (ADR 0004).

verifyPatToken(token) → VerifiedPat { patId, usrId, scope, prefix }
  // Throws InvalidPatTokenError, PatExpiredError, PatRevokedError.
  // Atomically updates last_used_at on success.

getPat(patId) → PersonalAccessToken
listPatsForUser(usrId, *, cursor, limit) → Page<PersonalAccessToken>
revokePat(patId) → PersonalAccessToken
```

### Verification semantics (normative)

`verifyPatToken(token)` MUST, in order:

1. Validate the wire format. Token MUST match `^pat_[0-9a-f]{32}_[A-Za-z0-9_-]{43,}$`. If not, raise `InvalidPatTokenError`.
2. Split on the second underscore to extract `<id-payload>` and `<secret-payload>`.
3. Look up the row by `id = decode("pat", <id-payload>)`. If not found, raise `InvalidPatTokenError`. (Conflate "no such PAT" with "wrong secret" to avoid a timing-side-channel oracle distinguishing the two.)
4. If `revoked_at` is non-null, raise `PatRevokedError`.
5. If `expires_at` is non-null and `<= now`, raise `PatExpiredError`.
6. Argon2id-verify `<secret-payload>` against `secret_hash`. If mismatch, raise `InvalidPatTokenError`. (The Argon2id verify is constant-time by construction.)
7. Atomically update `last_used_at = now` and return the verified handle.

The `last_used_at` update is best-effort — it MAY be skipped under high-load conditions where the write would dominate the verify path. Adopters that need exact "last seen" semantics (e.g. for compliance) configure their store to enforce the write; adopters that don't can opt-out.

### Audit log integration

PAT-authenticated requests carry a discriminator on the audit-log row that the `aud` primitive (forthcoming, ADR-0017 working set) consumes:

```
{
  actor_usr_id: <PAT owner>,
  auth: {
    kind: "pat",          // vs "session" | "share" | "system"
    pat_id: pat_<id>,     // for "rotate this token after a leak" workflows
  },
  ...
}
```

This is a **canonical discriminator vocabulary** for the spec — `auth.kind ∈ {session, pat, share, system}` — that adopters MUST emit and audit-log consumers MAY rely on. The discriminator is sufficient for "show me everything authenticated via this specific PAT" queries without needing per-adopter conventions.

### Constraints (normative)

- `scope` is a string array; spec does not pin a vocabulary. Adopters define their own (`cloud:read`, `org:admin`, etc.). Empty array is allowed and means "no permissions" — useful as a placeholder during issuance ceremonies.
- `expires_at` MUST be in the future at create time when set, MUST be no more than 365 days from `created_at` when set. Implementations MAY enforce a tighter cap. `null` means "never expires" — adopters concerned about long-lived secrets MAY refuse to issue null-expiry PATs at the application layer.
- `name` MUST be 1–100 characters. Adopters MUST NOT use it for authorization decisions; it's display-only.
- `usr_id` MUST refer to a non-revoked `usr`. PATs auto-revoke when their owner is revoked (cascade in `cascadeRevokeSubject`).
- The secret MUST be at least 32 random bytes (256 bits of entropy). Implementations MAY produce longer secrets.
- Secret storage MUST use Argon2id with parameters at or above the `cred`-password floor (ADR 0004 references). Constant-time comparison is enforced by Argon2id verify.
- The SDK MUST NOT log, return, or persist the plaintext token after `createPat` returns.

### What this is NOT

- **Not a session.** PATs do not establish a `ses` row, do not have a session lifetime, do not refresh. The bearer of a PAT is the owner `usr_id` for the duration of any single request, full stop.
- **Not a `cred`.** `cred` is for interactive ceremonies (password/passkey/OIDC) where the user proves they hold a secret in real-time. PATs are non-interactive long-lived bearers.
- **Not a share token.** `shr` grants resource-scoped access without identity binding. PATs grant the holder full agency-as-the-owner, scoped only by `scope`.
- **Not an OAuth access token.** No issuer, no audience, no JWT structure, no rotation, no refresh tokens. PATs are opaque secrets the operator manages directly. Adopters that need OAuth can layer it on top using PATs as the underlying credential.
- **Not a system-to-system identity.** `auth.kind = 'system'` (forthcoming via the audit ADR) covers automation that has no human owner. PATs always have an owning `usr_id`.

## Migration

This is purely additive. v0.2 deployments upgrade to v0.3 by:

1. Apply the `pat` table DDL to their database (the v0.3 spec patch to `reference/postgres.sql`).
2. Update their bearer-routing to inspect `pat_` prefix before falling through to `verifySessionToken`.
3. Wire the issuance UI / artisan command / CLI subcommand at the application layer.

No `cred`, `ses`, `mfa`, or other table is modified. Existing v0.2 session tokens stay valid and continue routing through the session path.

## Compatibility

- ID prefix `pat` is added to the v0.3 active registry. v0.2 implementations MUST NOT mint PATs.
- The `pat` table is new; no existing tables are altered.
- The identity package gains a new `PatStore` (or `IdentityStore` extension); existing interfaces are unchanged.
- A v0.3 deployment that does not use PATs MAY skip applying the `pat` DDL.
- Bearer routing is additive: in v0.2 every bearer token went through `verifySessionToken`; in v0.3 the `pat_`-prefixed bearer tokens go through `verifyPatToken` and everything else continues through the session path. Existing session tokens (which never start with `pat_`) keep working unchanged.

## Why a separate primitive instead of `cred` variant

Considered: extending the existing `cred` table with `kind: 'pat'` and reusing the `cred` lifecycle.

Rejected because:

- **Lifecycle differs.** `cred` rotation (revoke-and-re-add per ADR 0005) is centered on key-material refresh while preserving identity binding. PATs don't rotate — they revoke, and the operator issues a new one at a different `pat_id`. Forcing `cred`'s `replaces` chain on PATs is conceptually wrong.
- **Bearer model differs.** `cred` proves a user can produce a secret in an interactive ceremony, then `createSession` mints a `ses` whose token is the bearer for the next ~hours. PATs skip the session entirely — the secret IS the bearer, indefinitely. A unified store would have to discriminate at every operation.
- **Field shape differs.** `cred` has `identifier` (email / username); PATs don't. PATs have `scope` and `last_used_at`; `cred` doesn't. A unified shape carries optional fields that are always-required for one variant and always-null for the other — a code smell.
- **Audit semantics differ.** Already covered above. `auth.kind` distinguishes; conflating them in storage doesn't change that.

A separate primitive keeps each capability's mental model crisp: `cred` for interactive, `pat` for programmatic, `ses` for principal-lifetime, `shr` for resource-scoped.

## Why id-then-secret (Stripe pattern) instead of opaque (GitHub classic)

Considered: a single opaque token (`pat_<random>`) where the whole string is the secret and lookup is by hash.

Rejected because:

- **O(N) lookup without a hash-prefix index.** Every verify scans every row. At 100k PATs in a tenant, that's a 100ms+ verify per request. With a hash-prefix index, you regain O(log N) — but now you've added schema + maintenance complexity, and you've leaked a secret-derived prefix into the index.
- **Enumeration safety isn't compromised by id-in-token.** The `pat_id` alone is useless; you still need the secret to authenticate. GitHub's fine-grained PATs and Stripe both put a structured id in the token without security loss.
- **Visible-in-logs UX.** The `pat_id` portion appears in audit logs and "your active PATs" UI. Without id-in-token, the audit log can only reference the `pat_id` from a separate hash→id lookup, which means the audit row writer needs to do the lookup synchronously — slower critical path.

The cost is longer tokens (~80 chars vs ~40), which is irrelevant for non-interactive use.

## Migration path for `cloud-cli` (the filing adopter)

Once the spec ships and at least one SDK implements `PatStore`, `sitesource/cloud-cli` v0.2 unblocks:

1. `cloud-cli login` accepts a PAT pasted from the admin UI; stores it in the user's keychain.
2. Every `cloud:*` command sends `Authorization: Bearer pat_<id>_<secret>`.
3. The `sitesource/cloud` package's HTTP layer routes bearer tokens via prefix; PATs go through `verifyPatToken`, sessions go through the existing `verifySessionToken`. No change needed for browser-issued sessions.
4. Audit logs distinguish `auth.kind = 'pat'` from `'session'` for "who really did this — operator at a CLI vs operator in a browser tab" queries.

## Open questions (deferred to implementation, not blocking ADR acceptance)

- **`PatStore` as separate interface vs extension on `IdentityStore`.** The Postgres adapter pattern (ADR 0013) probably wants a separate `PatStore` to keep store interfaces single-purpose, but the in-memory reference store could be either. Will be resolved when the first SDK implements.
- **Scope vocabulary.** The spec deliberately does not pin one. If two or more adopters converge on the same vocabulary independently (e.g. `<resource>:<action>`), a future ADR can bless it as a recommendation. Premature prescription would force unnatural fits on adopters with different authorization models.
- **Rate limiting per-PAT.** Adopter-scope. Load patterns, abuse-prevention thresholds, and quota policies vary too much to spec.
- **OIDC bind for PAT issuance.** Adopters that already use OIDC SSO for interactive login MAY want to gate PAT issuance behind a recent OIDC re-auth (similar to GitHub's "sudo mode"). This is a session-freshness check at the application layer, not a primitive-level decision.
- **Bulk revocation.** `cascadeRevokeSubject` already cascades-revokes everything a `usr_id` holds; PATs ride this for free when the owner is revoked. A `cascadeRevokePatsByScope` or similar can land in v0.3.x if a hot path emerges.
- **OpenAPI shape for PAT routes.** `POST /v1/users/{usr_id}/pats`, `GET /v1/users/{usr_id}/pats`, `GET /v1/pats/{pat_id}`, `POST /v1/pats/{pat_id}/revoke`, `POST /v1/pats/verify`. Lands in `flametrench-v0.3-additions.yaml` alongside the other v0.3 primitives.
- **Conformance fixtures.** Will land alongside the first SDK implementation, matching the `shr` precedent.

## Filed by

`sitesource/cloud-cli` v0.2 ([`spec#14`](https://github.com/flametrench/spec/issues/14)). Tag: `feedback:sitesource-cloud-cli`.
