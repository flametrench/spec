# Share Tokens

A **share** grants the bearer of an opaque short-TTL token resource-scoped access to a single `(object_type, object_id)` at a given relation. Shares are the v0.2 primitive for time-bounded, presentation-bearer access — file-manager shareable links, view-only invoice URLs, single-use export downloads, and similar flows.

This chapter is normative. Rationale, alternatives considered, and the "what this is NOT" framing live in [ADR 0012 — Share tokens](../decisions/0012-share-tokens.md).

## When to use shares vs. tuples vs. sessions

| You need… | Primitive | Why |
|---|---|---|
| Durable "alice can edit doc_42 forever" | `tup` | Tuples are persistent, principal-bound grants. |
| Bearer authenticates as a user, then permissions follow tuples | `ses` | Sessions establish identity; access is tuple-evaluated. |
| Bearer holds a token, gets read access to one resource for a window | `shr` | Shares grant resource-scoped access without identity. |
| Bearer holds a one-time token, gets access exactly once | `shr` with `single_use=true` | Single-use shares consume on first verify. |

Shares do **not** authenticate the bearer. A share-token holder is not a `usr_id`. Hosts that serve resources via verified shares MUST NOT promote share-bearers to authenticated principals (no session minting, no MFA enrollment, no profile edits). The verified handle returned by `verifyShareToken` is exactly enough information to render *one* resource at *one* relation; nothing more.

## Entity shape

- `id` — UUIDv7; wire format `shr_<hex>`.
- `object_type` — the prefix of the shared object. MUST match `^[a-z]{2,6}$`.
- `object_id` — the UUIDv7 of the shared object.
- `relation` — what the bearer of the token can do. MUST match `^[a-z_]{2,32}$`. The spec does not constrain to `viewer`-only, but adopters SHOULD restrict share issuance to read-style relations and reject share-bearer-only requests at write-style endpoints.
- `created_by` — the `usr_id` who minted the share.
- `expires_at` — required. MUST be in the future at create time. MUST be no more than 365 days from `created_at`. Adopters MAY enforce a tighter cap.
- `single_use` — boolean. Default `false`. When `true`, the share is consumed on first successful verify.
- `consumed_at` — nullable timestamp. Set transactionally on first verify when `single_use` is true.
- `revoked_at` — nullable timestamp. Soft-delete; revoked shares fail verify with `ShareRevokedError`.
- `created_at` — set on insert.

The token itself is **not** part of the entity. The plaintext bearer credential is returned ONCE on `createShare` and never persisted. Token storage is the SHA-256 of the bearer token, kept in `BYTEA` form.

## Operations

### `createShare`

```
createShare(object_type, object_id, relation, created_by, expires_in, single_use=false)
  → { share, token }
```

Mints a new share. `expires_in` is a relative duration (seconds, or language-idiomatic interval); the SDK computes `expires_at = now + expires_in`.

The returned `token` is the opaque base64url-encoded bearer credential, derived from at least 32 random bytes (256 bits of entropy). This is the **only** time the plaintext token is observable; the SDK persists only its SHA-256 hash.

#### Validation

- `created_by` MUST resolve to a non-revoked `usr_id`. Implementations SHOULD reject share creation by suspended users.
- `relation` MUST match `^[a-z_]{2,32}$`. Otherwise `InvalidFormatError("relation")`.
- `object_type` MUST match `^[a-z]{2,6}$`. Otherwise `InvalidFormatError("object_type")`.
- `expires_in` MUST be positive and MUST NOT exceed 365 days. Otherwise `PreconditionError`.

### `verifyShareToken`

```
verifyShareToken(token) → VerifiedShare { share_id, object_type, object_id, relation }
```

Resolves a presented bearer token to its (object, relation) tuple. The host then renders the resource according to `relation`.

#### Verification semantics (normative ordering)

1. Hash the input via SHA-256 → 32 bytes.
2. Look up the row by `token_hash`. If no row matches, raise `InvalidShareTokenError`.
3. Constant-time-compare the stored hash against the input hash. If mismatch, raise `InvalidShareTokenError`.
4. If `revoked_at` is non-null, raise `ShareRevokedError`.
5. If `single_use` is true and `consumed_at` is non-null, raise `ShareConsumedError`.
6. If `expires_at <= now`, raise `ShareExpiredError`.
7. If `single_use` is true: transactionally set `consumed_at = now`. The set MUST be atomic with the bearer-acceptance — concurrent verifies of a single-use token MUST yield exactly one success and exactly one `ShareConsumedError`.
8. Return the verified handle.

#### Error precedence

The errors above are listed in normative precedence order. An expired-AND-revoked share raises `ShareRevokedError` (revoke wins; the share has been positively repudiated). An expired-AND-consumed single-use share raises `ShareConsumedError`. The intent: the most-specific failure reason wins, so adopter audit logs disambiguate "the token was repudiated" from "nobody got there in time."

### `getShare`

```
getShare(share_id) → Share
```

Read-only fetch by id. No state transitions; safe to call from any context including audit / admin views. Throws `ShareNotFoundError` for unknown ids.

### `revokeShare`

```
revokeShare(share_id) → Share
```

Sets `revoked_at = now` if the share is not already revoked. Idempotent — calling twice on the same id is not an error; the second call returns the share with the original `revoked_at`. Future verify calls fail with `ShareRevokedError`.

### `listSharesForObject`

```
listSharesForObject(object_type, object_id, *, cursor, limit) → Page<Share>
```

Enumerates all shares (active, expired, consumed, revoked) for a given resource. Ordered by `id` ascending. Used for admin UIs ("show all share links for this file") and for bulk-revoke iteration.

## Authz integration

`check(usr, relation, object)` and `checkAny(...)` are unaffected — they continue to consult `tup` exclusively.

The host-side pattern for "render this resource if the token is valid" is:

```
verified = shareStore.verifyShareToken(presented_token)
// → render the resource indicated by verified.{object_type, object_id} at relation verified.relation
```

The verified handle does **not** pass through `check`. The share verify *is* the authorization decision for that bearer at that resource. If a host wants a share-bearer to also acquire normal authenticated permissions (e.g. "this share lets you in, AND if you log in you also get edit access"), that's two distinct flows: verify the share to render the read view, and run the normal session+tuple check separately for the edit surface.

## Storage notes

The reference Postgres schema at [`spec/reference/postgres.sql`](../reference/postgres.sql) places `shr` alongside `tup` in the authorization capability section. Three indexes ship in the reference DDL:

- A partial-unique index on `token_hash` excluding consumed/revoked rows — the verify hot path.
- A composite index on `(object_type, object_id)` — the `listSharesForObject` path.
- A partial index on `expires_at` — operational sweep / cleanup of expired shares.

Adopters who do not use shares MAY skip applying the `shr` DDL; the rest of the v0.2 schema stays byte-identical.

## What shares are NOT

- **Not a session.** Bearer of a share token does not become an authenticated principal. No MFA enrollment, no profile edit, no `usr_id`-bound surfaces.
- **Not a tuple.** Shares are time-bounded and principal-less. A tuple grants `(usr_alice, viewer, doc_42)` durably to alice; a share grants `viewer on doc_42` for whoever holds the token, until expiry.
- **Not an invitation.** Invitations create memberships when accepted (and require [ADR 0009](../decisions/0009-invitation-accept-binding.md) identifier binding). Shares grant resource access without identity binding.
- **Not a JWT.** Opaque tokens (matching `ses.token_hash`) avoid rotation/algorithm-agility hazards and give simpler audit + revocation. The token is server-resolved against `token_hash`; revocation is a single column update.

## Security considerations

- **Token entropy** — at least 32 random bytes (256 bits). The reference SDKs generate from `crypto.randomBytes(32)` / `secrets.token_bytes(32)` / `random_bytes(32)` / `SecureRandom.nextBytes(32)`. Implementations MAY use longer tokens.
- **Constant-time compare** — every `verifyShareToken` MUST compare the stored hash against the input hash via constant-time comparison after the index lookup, even though the partial-unique index excludes consumed/revoked rows. The defense-in-depth is cheap (one fixed-time compare on the hot path) and prevents timing oracles if the index ever fails to fire.
- **Logging** — implementations MUST NOT log the plaintext token. The `share_id` and `token_hash` are safe to log; the bearer credential is not.
- **PII in `object_id`** — share rows carry only the resource UUID, not any payload. Adopter-side concerns about what's behind the resource are unchanged from the existing tuple model.
- **Race on single-use** — the spec mandates atomic `consumed_at` set within the verify transaction. Implementations MUST NOT use a check-then-set pattern; use `UPDATE ... WHERE consumed_at IS NULL RETURNING ...` or equivalent.
- **Lifetime ceiling** — the 365-day spec ceiling exists to prevent share tokens from devolving into de-facto durable credentials. Adopters with stricter requirements (short-TTL exports, minutes-not-days links) SHOULD enforce a tighter cap at the application layer.

## Filed by

The share-token primitive landed in v0.2 in response to [`spec#7`](https://github.com/flametrench/spec/issues/7) from the `sitesource/admin` adopter. See [ADR 0012](../decisions/0012-share-tokens.md) for the full rationale.
