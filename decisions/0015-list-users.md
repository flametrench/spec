# 0015 — IdentityStore.listUsers

**Status:** Accepted
**Date:** 2026-04-28

## Context

`IdentityStore` exposes targeted reads — `getUser(usr_id)`, `findCredentialByIdentifier(...)`, `listCredentialsForUser(usr_id)`, `listSessionsForUser(usr_id)` — and the user lifecycle ops (createUser, suspend/reinstate/revoke). It has no enumeration primitive: there is no spec-blessed way to ask "all users on this install" without dropping below the SDK layer to direct SQL.

The first PHP adopter (`sitesource/admin`) reported the cost in [`spec#10`](https://github.com/flametrench/spec/issues/10): their `GET /v1/system/users` sysadmin endpoint (Phase 2.0c — paginated user list with substring filter) is the only place in admin's V1 surface that bypasses a Flametrench SDK call. The controller drops to `DB::table('usr')->paginate()` directly with a docblock note explaining why.

Two costs of the workaround:

1. **It violates admin's own canonical-conformance ADR.** Admin's ADR 0002 commits the project to "every concern goes through the SDK." `SystemUsersController` is the documented exception; it stays an exception until the spec lands a list primitive.
2. **It couples adopter code to the schema.** Reaching into the upstream-managed `usr` table from adopter code means every column rename or addition forces every adopter to update their bypass query. ADR 0014's `display_name` is a concrete near-term example: `SELECT id, status, created_at, updated_at FROM usr` would silently miss the new column.

Tenancy already has the shape needed: `TenancyStore.listOrgs(cursor, limit, query?)` and `TenancyStore.listMembers(org_id, cursor, limit, role?)`. Identity needs the same.

## Decision

A new operation lands on `IdentityStore` in v0.2:

```
listUsers(*, cursor?, limit = 50, query?, status?) → Page<User>
```

### Parameters

- **`cursor`** — opaque pagination token returned from a previous page. Encoding is implementation-defined; the conformance contract is "given the cursor returned by page N, calling listUsers with that cursor yields page N+1." Cursors are UUIDv7-monotonic per the existing pagination convention shared with `listMembers`, `listOrgs`, `listSessions`, `listInvitations`, and `listTuples*`.
- **`limit`** — integer, default 50, MUST be in `[1, 200]`. Values outside that range are clamped at the server boundary; implementations MAY return `400 PreconditionError` instead at deployment discretion. Limit covers the page size; the wire format may return up to `limit` rows.
- **`query`** — optional case-insensitive substring filter over the credential identifier. When present:
  - Users with at least one credential whose `identifier` contains `query` (case-insensitive) MUST be included.
  - Match semantics is "any active credential identifier" — suspended and revoked credentials' identifiers do not contribute. (Adopters who want a wider match build it host-side; the spec stays narrow.)
  - The filter is intentionally a simple substring, mirroring the precedent set by `TenancyStore.listOrgs(query)`. Full-text search is out of scope.
  - When omitted, no identifier filter applies.
- **`status`** — optional `'active' | 'suspended' | 'revoked'` filter. When omitted, all statuses are returned. Mirrors the `status` filter on `listMembers`.

All parameters except `cursor` are keyword-only / object-keyed in each SDK's idiom (Python kwargs, TypeScript options object, PHP named args, Java overload set), matching the existing SDK calling conventions for paginated reads.

### Return shape

```
Page<User> = {
  data: User[]                  // current page of users, ordered by id ASC (UUIDv7 — chronological)
  page: { next_cursor: string | null }
}
```

The `User` entity is the canonical shape from [ADR 0004](./0004-identity-model.md), extended in [ADR 0014](./0014-user-display-name.md) with `display_name`. No additional view-model fields. Adopters that need to render a credential identifier in their list rows look it up via the existing `listCredentialsForUser(usr_id)` primitive, or use `display_name` (which #9 introduces precisely for this use case).

### Ordering

Users are returned ordered by `id` ASC. UUIDv7 makes this approximately creation-time-ordered, matching the convention of every other paginated read in the spec. Implementations MUST be consistent — repeating the same listUsers call with the same cursor MUST return the same page contents (modulo concurrent inserts).

### Authorization

`listUsers` enumerates the entire user table. Like `listMembers`, the spec does not mandate authorization at the SDK layer — adopters MUST gate the call site. Concretely: a sysadmin route at the host application level (admin's `GET /v1/system/users`, gated by `check(subject, system_admin, system_<install_id>)` or equivalent) calls `listUsers`. End-user routes do not.

The spec does not introduce a tuple relation for "list users" — the gate lives at the host route.

### Wire surface (OpenAPI)

A new `GET /v1/users` endpoint lands in `flametrench-v0.2-additions.yaml` with the same `cursor` / `limit` / `query` / `status` query parameters and a `UserPage` response schema mirroring the existing `MembershipPage` / `OrgPage` / `InvitationPage` shapes.

## Consequences

- **Backwards compatibility.** Pure addition; no v0.1 caller breaks. No changes to existing operations.
- **Postgres reference.** The `usr` table already has the natural index for this read — `id` is PK, ordering by `id ASC` and seeking via `id > cursor` is a covered index scan. The `query` filter joins to `cred` once: `EXISTS (SELECT 1 FROM cred WHERE cred.usr_id = usr.id AND cred.status = 'active' AND cred.identifier ILIKE '%' || $query || '%')`. The `cred (identifier, status)` index supports the `ILIKE` lookup; `pg_trgm` is NOT required for the spec floor (a simple `ILIKE %q%` is sufficient and matches the tenancy precedent).
- **OpenAPI.** New `GET /v1/users` operation; new `UserPage` schema. Adds to `flametrench-v0.2-additions.yaml` summary.
- **Conformance.** New fixture `identity/list-users.json` covers basic enumeration, status filter, query substring, pagination round-trip across multiple pages, and the empty-result case.
- **Cross-link to ADR 0014.** Once `display_name` lands (it does in the same v0.2 RC), `listUsers` MUST return the field on each row. The ADR 0014 fixture and the ADR 0015 fixture should share a deployment so adopters see both ship together.

## Alternatives considered

### Skip the list primitive; document direct SQL

The status quo. Rejected for the reasons in the Context: the workaround violates conformance contracts, couples adopter code to schema specifics, and breaks every time the schema evolves. ADR 0014 proves the breakage point — the existing bypass query would silently miss `display_name`.

### Include a primary-credential identifier hint on each row

The original spec#10 proposal suggested each `User` returned by `listUsers` should include the "active credential identifier" so adopters can render `"user@host"` in the list without an N+1 lookup. Rejected for v0.2 because:

1. **`display_name` covers the same use case.** Adopters that need a render string in a user list set `display_name`. ADR 0014 added it precisely for that purpose.
2. **Adding a derived field to `User` muddles the entity.** `User` is the canonical row from `usr`. Adding a virtual/computed `primary_credential_identifier` field that is only populated by `listUsers` (and `getUser`?) creates ambiguity: is it a stored column or a join? Adopters who serialize `User` to their own DTO and back would lose the field on round-trip.
3. **Adopters with a real N+1 problem can ship a batched lookup later.** A future `listActiveCredentialsForUsers(usr_ids[])` primitive solves the batch-fetch problem cleanly without touching the `User` entity.

If demand surfaces post-v0.2, the cleanest path is a separate read primitive rather than a virtual field on `User`.

### Cardinality estimate (`total`) on the page envelope

The spec#10 issue body proposed `total: int | null` as an "optional cardinality estimate." Rejected because no other paginated read in the spec exposes this — `listMembers`, `listOrgs`, `listSessions`, `listInvitations`, `listTuples*` all use the same cursor-only `PageMeta`. Adding `total` only to `UserPage` introduces an asymmetry without a clear reason. Adopters that want a count call a separate primitive (`countUsers` — not in scope here) or accept the cursor-walking cost on rare cardinality questions.

If demand surfaces for any paginated read to expose a count, the right fix is to extend `PageMeta` for all reads, not to special-case `UserPage`.

### Keyset pagination on `(created_at, id)` instead of `id` alone

UUIDv7 IDs are time-encoded, so ordering by `id` is approximately ordering by creation time without paying the cost of a composite cursor. Rejected the composite form for the same reason every other paginated read in the spec uses single-column `id` cursors — uniformity over a marginal optimization that doesn't matter at the spec's typical N (≤ 1M users per install).

### Full-text search on credential identifiers

`pg_trgm` indexes plus tri-gram matching would let adopters search for partial domain names ("@example") cheaply. Rejected because it adopts a Postgres-specific feature into the spec floor. Adopters who need it run their own tri-gram index host-side; the spec floor stays portable across reference adapters.

## Out of scope / Deferred

- **`countUsers`** — a cardinality-only primitive returning total row count. Deferred until a concrete adopter ask surfaces. Cursor-walking the list is the documented workaround.
- **Search on `display_name`** — the spec#10 query parameter searches credential identifiers, not display names. Adding `display_name` to the search vector means choosing a normalization strategy (NFC, case-folding, trimming) which the spec deliberately stays out of (per ADR 0014). Adopters who want display-name search apply their own normalization host-side.
- **Cross-tenant filtering** — listUsers returns all users in the install. Per-org filtering is `listMembers(org_id)` (which already exists), not `listUsers(org_id?)`. The spec keeps the user table install-global; tenancy concerns live on the tenancy side.
- **Sorting modes other than `id ASC`** — chronological-by-id is sufficient for sysadmin UIs. Custom-sort variants (by status, by creation desc, by display name) are out of scope.
- **Bulk credential-identifier batch fetch** (`listActiveCredentialsForUsers([usr_ids])`) — see Alternatives above. Open for a future ADR if N+1 lookup costs become real.

## References

- Spec issue [`flametrench/spec#10`](https://github.com/flametrench/spec/issues/10) — original report from `sitesource/admin`.
- [`decisions/0014-user-display-name.md`](./0014-user-display-name.md) — `display_name` covers the "render a string in the user list" use case the credential-hint proposal addresses; cross-linked here.
- [`decisions/0011-org-display-name-slug.md`](./0011-org-display-name-slug.md) — same shape on the tenancy side; the precedent `listOrgs(query)` mirrors.
- `TenancyStore.listMembers(org_id, cursor, limit, status?)` — the closest existing parallel; `listUsers` mirrors its signature except for the org_id (no per-org scoping for users).

## Filed by

`sitesource/admin` Phase 2.0c sysadmin user-management page, via `flametrench/spec#10`. Tag: `feedback:sitesource-admin`.
