# 0025 — TenancyStore.listOrgs

**Status:** Proposed
**Date:** 2026-06-07

## Context

`TenancyStore` exposes targeted reads — `getOrg(org_id)`, `getMembership(mem_id)`, `listMembers(org_id, …)`, `listInvitations(org_id, …)`, `listTuplesForSubject(…)` — plus the org lifecycle ops (`createOrg`, `suspendOrg`/`reinstateOrg`/`revokeOrg`, membership ops). It has **no cross-org enumeration primitive**: there is no spec-blessed way to ask "all orgs on this install" without dropping below the SDK to direct SQL (`DB::table('org')`).

This is the same portability-breaking pattern that motivated the now-shipped `IdentityStore.listUsers` ([ADR 0015](./0015-list-users.md), `spec#10`). It is filed as [`spec#25`](https://github.com/flametrench/spec/issues/25) by `sitesource/cloud`, whose multi-tenant scheduled-task fan-out (cloud ADR 0046) must enumerate **active** orgs on each scheduler fire and act once per org. Without this primitive the adopter has two bad options: raw-query the `org` table (bypassing the `suspendOrg`/`revokeOrg` lifecycle — risking fan-out to dead tenants) or maintain a synced cache.

**A note on the dangling reference.** ADR 0015 (listUsers, Accepted) repeatedly cites `TenancyStore.listOrgs(cursor, limit, query?)` as an *existing* precedent ("Tenancy already has the shape needed", "mirroring the precedent set by `TenancyStore.listOrgs(query)`"). That reference was aspirational — `listOrgs` was never landed in `docs/tenancy.md`, given a conformance fixture, or implemented in the SDKs. This ADR **lands the primitive ADR 0015 already assumed**, resolving the dangling reference and inverting the modelling: `listOrgs` now mirrors the shipped `listUsers` verbatim.

## Decision

A new operation lands on `TenancyStore` in v0.4:

```
listOrgs(*, cursor?, limit = 50, query?, status?) → Page<Organization>
```

Signature-identical to `IdentityStore.listUsers` (ADR 0015) except it has no per-tenant scoping (it *is* the cross-tenant read) and `query` filters org `name`/`slug` rather than credential identifiers.

### Parameters

- **`cursor`** — opaque pagination token from a previous page. Encoding is implementation-defined; the conformance contract is "the cursor returned by page N yields page N+1." Cursors are UUIDv7-monotonic per the existing pagination convention shared with `listUsers`, `listMembers`, `listSessions`, `listInvitations`, `listTuples*`.
- **`limit`** — integer, default 50, MUST be in `[1, 200]`; out-of-range values are clamped at the server boundary (implementations MAY return `400 PreconditionError` at deployment discretion).
- **`query`** — optional case-insensitive substring filter over the org's `name` and `slug` (ADR 0011 fields). An org matches if `query` is a case-insensitive substring of `name` OR `slug`. Orgs with both `name` and `slug` null never match a non-empty `query`. Simple substring only (mirrors `listUsers`' identifier filter); full-text search is out of scope. When omitted, no name/slug filter applies.
- **`status`** — optional `'active' | 'suspended' | 'revoked'` filter. When omitted, all statuses are returned. This is the parameter cloud ADR 0046's fan-out depends on: it passes `status='active'` so suspended/revoked tenants are never invoked. Mirrors the `status` filter on `listUsers`/`listMembers`.

All parameters except `cursor` are keyword-only / object-keyed per each SDK's idiom (Python kwargs, TypeScript options object, PHP named args, Java overload set), matching the existing paginated-read conventions.

### Return shape

```
Page<Organization> = {
  data: Organization[]          // current page, ordered by id ASC (UUIDv7 — chronological)
  page: { next_cursor: string | null }
}
```

The `Organization` entity is the canonical shape (`id`, `status`, `name?`, `slug?` per ADR 0011, `created_at`, `updated_at`). No additional view-model fields — symmetric with `listUsers` returning the canonical `User`.

### Ordering

Orgs are returned ordered by `id` ASC (UUIDv7 ≈ creation-time), matching every other paginated read. Implementations MUST be consistent: the same call with the same cursor MUST return the same page (modulo concurrent inserts).

### Authorization

`listOrgs` enumerates the **entire org table — it is the one cross-tenant read in tenancy.** Like `listUsers`/`listMembers`, the spec does not mandate authorization at the SDK layer; **the adopter MUST gate the call site to an admin/system caller.** A missing gate here is a *cross-tenant* org-enumeration leak (strictly worse than a single-tenant leak), so the gating obligation is emphasized:

- A host-application **system/sysadmin** route (e.g. an admin org-management UI gated by `check(subject, system_admin, system_<install_id>)` or equivalent) MAY call `listOrgs`. End-user / org-scoped routes MUST NOT.
- A **server-side** caller with no request/subject (e.g. cloud ADR 0046's scheduler fan-out) is inherently system-level and satisfies the bar — but MUST NOT be reachable through any tenant-scoped surface.

The spec does not introduce a tuple relation for "list orgs"; the gate lives at the host call site.

### Wire surface (OpenAPI)

A new `GET /v1/orgs` operation lands in **`openapi/flametrench-v0.4-additions.yaml`** (the first v0.4 wire-surface addition) with `cursor` / `limit` / `query` / `status` query parameters and an `OrgPage` response schema mirroring the existing `MembershipPage` / `UserPage` shapes (an `OrgStatus` enum `active|suspended|revoked` accompanies it). This also **defines the `OrgPage` schema** that `UserPage` / `MembershipPage` descriptions already reference — a second dangling reference resolved alongside the `listOrgs` one.

## Consequences

- **Backwards compatibility.** Pure addition; no v0.1+ caller breaks; no changes to existing operations.
- **Postgres reference.** The `org` table's `id` PK gives the natural covered scan: order by `id ASC`, seek via `id > cursor`. The `query` filter is `(name ILIKE '%'||$q||'%' OR slug ILIKE '%'||$q||'%')`; the existing `org (slug)` unique index assists the slug arm, `pg_trgm` is NOT required for the floor. `status` is an indexed equality.
- **Conformance.** New fixture `tenancy/list-orgs.json` covers basic id-ordered enumeration, `status` filter (active / suspended / revoked), `query` substring over name+slug (incl. case-insensitivity), multi-page cursor round-trip, and the empty-install case — structurally mirroring `identity/list-users.json`.
- **Resolves the ADR 0015 dangling reference.** `listOrgs` is now real; 0015's references resolve to this ADR.

## Alternatives considered

- **Skip the primitive; document direct SQL.** The status quo `spec#25` reports. Rejected for ADR 0015's reasons: violates adopters' canonical-conformance commitments, couples adopter code to the `org` schema, and — uniquely here — bypasses the `suspend`/`revoke` lifecycle so a fan-out can hit dead tenants.
- **`status`-less signature (the ADR 0015 dangling-reference form `listOrgs(cursor, limit, query?)`).** Rejected: the concrete adopter need (cloud 0046) is precisely "active orgs only." Including `status` matches `listUsers` and avoids every fan-out adopter re-filtering host-side.
- **Cardinality estimate (`total`) on the page envelope.** Rejected — no other paginated read exposes it; uniformity over a special case (same call as ADR 0015).
- **Streaming iterable instead of cursor `Page<T>`.** Rejected — uniformity with every other paginated read; streaming layers over the cursor adopter-side if needed.

## Out of scope / Deferred

- **`countOrgs`** — cardinality-only primitive. Deferred until a concrete ask; cursor-walking is the workaround.
- **Sorting modes other than `id ASC`** — out of scope (matches ADR 0015).
- **Full-text / tri-gram search on name/slug** — Postgres-specific; adopters run their own index host-side.
- **Per-attribute filters beyond `status` + `query`** (e.g. created-after) — out of scope; add via a future ADR if demand surfaces.

## References

- [`spec#25`](https://github.com/flametrench/spec/issues/25) — the report from `sitesource/cloud` (multi-tenant scheduler fan-out, cloud ADR 0046).
- [ADR 0015](./0015-list-users.md) — `IdentityStore.listUsers`; this ADR mirrors it verbatim and resolves its dangling `listOrgs` reference.
- [ADR 0011](./0011-org-display-name-slug.md) — `name`/`slug` fields the `query` filter searches.
- `TenancyStore.listMembers(org_id, …)` — the closest existing parallel; `listOrgs` mirrors it minus the org_id scoping.

## Filed by

`sitesource/cloud` multi-tenant scheduled-task fan-out (cloud ADR 0046), via `flametrench/spec#25`. Authoring (spec text + `tenancy.md` + conformance fixtures) contributed by `sitesource-cloud-spec` to offload the v0.4 wave. Tag: `feedback:sitesource-cloud`.
