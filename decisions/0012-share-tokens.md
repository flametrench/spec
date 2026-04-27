# 0012 — Share tokens for time-bounded resource access

**Status:** Proposed (v0.2)
**Date:** 2026-04-27

## Context

Flametrench v0.1 has three primitives for "is this principal allowed to do X to Y?":

- **Tuples (`tup`)** — durable, identified-principal grants. The bearer of `(usr_alice, viewer, doc_42)` is alice, and the row sticks around until explicitly deleted.
- **Sessions (`ses`)** — bearer-token credentials for a *user*. Holding a session token authenticates the bearer as a specific `usr_id`; what they can do is then determined by tuples.
- **Memberships (`mem`)** — durable per-(user, org) role grants, dual-represented via tuples.

None of these answer the question every adopter eventually asks: **"How do I grant the bearer of this short-lived opaque string read access to exactly this one resource — without making them an authenticated principal?"**

Concrete use cases hitting this gap:

- **File-manager shareable links** ("send this link to a contractor; they can view this PDF for the next 10 minutes"). This is the canonical case raised by [`spec#7`](https://github.com/flametrench/spec/issues/7) from the `sitesource/admin` adopter, blocking iter 2 of their in-core file manager.
- **"View-only invoice" links** in commerce / billing flows.
- **Single-use export links** (CSV / report exports that a recipient consumes once).
- **Temporary handoffs to external systems** (signed callbacks / webhooks scoped to one resource).

Today, every adopter that needs this invents the same five-piece machine independently:

1. A keyed store mapping opaque token → `(object_type, object_id, relation, expires_at)`.
2. SHA-256 hashing on the way in, constant-time comparison on the way out (matching the same posture as `ses.token_hash`).
3. A revocation path. Tuples can be revoked individually; ad-hoc share tokens currently cannot without bespoke endpoints.
4. A verification API that returns "yes, this token is good — here is the implied relation on the implied object."
5. Wire-format ID prefix + collision protection.

Doing this once in the SDK is one-time implementation cost; doing it per-adopter fragments the security model and makes audit logs incoherent across ecosystems.

## Decision

A new resource type `share` (`shr_<hex>`) is added to the spec in v0.2 as a **complement to**, not a replacement for, tuples and sessions. The `shr` prefix moves from "reserved" to "active" in the ID prefix registry; the `shr` table joins `tup` in the reference Postgres schema as part of the authorization capability.

### Entity shape

```
Share = {
  id:           shr_<hex>          // wire; UUIDv7 underneath
  object_type:  string              // matches Patterns::TYPE_PREFIX (^[a-z]{2,6}$)
  object_id:    UUIDv7              // the resource being shared
  relation:     string              // matches Patterns::RELATION_NAME (^[a-z_]{2,32}$)
  created_by:   usr_<hex>           // who minted the share
  expires_at:   timestamptz         // required; bounded above by 1 year
  single_use:   boolean             // if true, consumed on first verify
  consumed_at:  timestamptz | null  // set on consume when single_use
  revoked_at:   timestamptz | null  // soft-delete timestamp
  created_at:   timestamptz
}
```

Token storage matches `ses`: SHA-256 of the bearer token, persisted as 32 raw bytes (`BYTEA`). The plaintext token is returned ONCE on `createShare` and never persisted.

### SDK surface

A new `ShareStore` interface ships in the **authz** package across all four SDK families, alongside the existing `TupleStore`. Operations:

```
createShare(input) → { share, token }
  // token is the opaque bearer credential; only visible here.

verifyShareToken(token) → VerifiedShare { share_id, object_type, object_id, relation }
  // throws InvalidShareTokenError, ShareExpiredError, ShareRevokedError, ShareConsumedError.
  // For single_use shares, transactionally sets consumed_at on success.

getShare(share_id) → Share
revokeShare(share_id) → Share
listSharesForObject(object_type, object_id, *, cursor, limit) → Page<Share>
```

### Verification semantics (normative)

`verifyShareToken(token)` MUST, in order:

1. Hash the input via SHA-256 → 32 bytes.
2. Look up the row by `token_hash`. If not found, raise `InvalidShareTokenError`.
3. Constant-time-compare the stored hash against the input hash. If mismatch, raise `InvalidShareTokenError`.
4. If `revoked_at` is non-null, raise `ShareRevokedError`.
5. If `single_use` is true and `consumed_at` is non-null, raise `ShareConsumedError`.
6. If `expires_at <= now`, raise `ShareExpiredError`.
7. If `single_use` is true, transactionally set `consumed_at = now` and return the verified handle. The `consumed_at`-set must be atomic with the bearer-acceptance — a race between two concurrent verifies of a single-use token MUST result in exactly one success and exactly one `ShareConsumedError`.

### Authz integration

`check(usr, relation, object)` and `checkAny(...)` are unaffected — they continue to consult `tup` exclusively. The share primitive is a complement, not a replacement.

The host-side pattern for "render this resource if the token is valid" is:

```
verified = shareStore.verifyShareToken(presented_token)
// → render the resource indicated by verified.{object_type, object_id} at relation verified.relation
```

Hosts MUST NOT promote share-token bearers to authenticated principals. A share token grants resource-scoped read-style access for the bearer; it does NOT establish a `ses`, does NOT mint a `cred`, does NOT confer membership. Application surfaces that require an authenticated `usr_id` (account settings, profile edit, MFA enrollment) MUST reject share-token-only requests.

### Constraints (normative)

- `expires_at` MUST be in the future at create time.
- `expires_at` MUST be no more than 365 days from `created_at`. Implementations MAY enforce a tighter cap (e.g. 24h for sensitive object types); the spec ceiling is one year.
- `created_by` MUST be a non-revoked `usr_id`.
- `relation` MUST match `Patterns::RELATION_NAME`.
- `object_type` MUST match `Patterns::TYPE_PREFIX`.
- The SDK MUST NOT log, return, or persist the plaintext token after `createShare` returns.
- The token MUST be at least 32 random bytes (256 bits of entropy), base64url-encoded. Implementations MAY produce longer tokens.
- Token storage MUST use SHA-256 → 32 bytes BYTEA. Constant-time comparison MUST be used on verify.

### What this is NOT

- **Not a session.** Bearer of a share token does not become an authenticated principal. The host serves the resource based on the verified relation; no other API surface treats the bearer as authenticated.
- **Not a tuple.** Tuples are durable, principal-bound grants. Shares are time-bounded, single-resource, principal-less.
- **Not an invitation.** Invitations create memberships when accepted (and require ADR 0009 identifier binding for existing-user accept). Shares grant resource access without identity binding.
- **Not a JWT or signed token.** Opaque tokens (matching `ses.token_hash`) avoid rotation/algorithm-agility hazards and give simpler audit + revocation semantics.
- **Not a capability for write-style operations.** The proposal allows any `relation` (the spec doesn't constrain to `viewer`-only), but adopters SHOULD restrict share-token issuance to read-style relations and reject share-bearer-only requests at write-style endpoints. The spec leaves this as a host-side policy decision rather than a forced restriction.

## Why a single-use option

The proposer flagged the use case in the issue: single-use export links and one-time-handoff scenarios. Adding `single_use` adds one column and one transactional update on verify; omitting it would force adopters to rebuild it externally. The cost of the column is small enough to land it now.

## Why not put this in identity

`ses` and `shr` share the token-storage posture (SHA-256 BYTEA, constant-time compare, plaintext-once) but answer different questions:

- `ses` answers "who is the authenticated principal?" — identity.
- `shr` answers "what resource-relation does the bearer of this token have?" — authorization.

The verification result of `verifyShareToken` is an authorization fact (relation on object), not an identity fact. Placing the store in the authz package keeps the per-capability mental model clean: identity for principals, tenancy for orgs/memberships, authz for grants (durable + ephemeral).

## Migration

This is purely additive. Adopters with existing per-app share-token tables can:

1. Create the `shr` table alongside their existing one.
2. Continue serving live tokens from their existing table.
3. Migrate to mint new tokens via `ShareStore.createShare`.
4. Drop the legacy table once historical tokens have aged out (or do a one-time backfill into `shr` if they need to preserve the historical surface).

No tuple, session, or membership semantics change.

## Compatibility

- ID prefix `shr` is added to the v0.2 active registry. v0.1 implementations MUST NOT mint share tokens.
- The `shr` table is new; no existing v0.1 tables are altered.
- The authz package gains a new optional `ShareStore`; the existing `TupleStore` interface and behavior are unchanged.
- A v0.2 deployment that does not use shares MAY skip applying the `shr` DDL; the rest of the schema stays byte-identical to v0.1+v0.2 baseline.

## Open questions (deferred)

- **Cross-SDK conformance fixtures** for share lifecycle. Will land in a follow-up; the per-SDK in-memory test suites cover the same surface for v0.2 final.
- **OpenAPI `flametrench-v0.2-additions.yaml`** — the HTTP shape (`POST /v1/shares`, `GET /v1/shares/{id}`, `POST /v1/shares/verify`) lands in a follow-up. The SDK store interface is the normative surface for v0.2; HTTP-layer concerns are scope-creep for this ADR.
- **Bulk revocation** (e.g. "revoke all shares minted by usr_X for object_Y"). Adopters can iterate `listSharesForObject` and `revokeShare` for v0.2; if a hot-path emerges, a `cascadeRevokeShares` helper can land in v0.3 with the same shape as `cascadeRevokeSubject` on the tuple store.

## Filed by

`sitesource/admin` Phase 3.0a iter 1 (`spec#7`). Tag: `feedback:sitesource-admin`.
