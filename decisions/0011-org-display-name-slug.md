# 0011 — Organization display name + slug

**Status:** Accepted
**Date:** 2026-04-26

## Context

The v0.1 `Organization` entity is intentionally minimal: `{id, status, created_at, updated_at}`. This was a stability choice — every additional field is a field every conforming implementation has to support, every conforming admin tool has to respect, and every cross-version migration has to handle. v0.1 punted on display semantics by design.

The first PHP adopter (sitesource/admin) reported the cost in [`spec#6`](https://github.com/flametrench/spec/issues/6): every adopter ends up needing at least a human-readable name (for admin UIs, invitation emails, audit logs) and a URL slug (for routing, subdomain mapping). Today they invent host-side `org_metadata` extension tables, which is fine for one adopter but blocks two outcomes the spec exists to support:

1. **Cross-tool interoperability.** A future cross-language admin reporter, audit exporter, or migration utility can't agree on where to read "the org's display name" without learning each adopter's bespoke metadata shape.
2. **SDK-level invitation mailers / notifications.** The SDK can't render `"Welcome to {orgName}!"` in a stock invitation email without bridging back through host-side data.

The reporter offered three options in spec preference order: add structured fields directly, add a generic `metadata` JSONB column, or defer to host extension tables. This ADR adopts option 1 with two refinements.

## Decision

The `Organization` entity gains two optional fields in v0.2:

```
Organization = {
  id, status, created_at, updated_at,    // v0.1 — unchanged
  name: string | null,                   // v0.2 — optional display name
  slug: string | null,                   // v0.2 — optional URL handle
}
```

### `name`

- Type: nullable `TEXT`. No length cap pinned at the spec level — adopters who want to enforce one (e.g. 255 chars to match a CSV import column) MAY do so at the application layer.
- The spec says **SHOULD set when the org has a human-meaningful identity.** Adopters that always want it MAY enforce required-on-name at the application layer; the spec stays permissive so programmatic / CI-provisioned / test-fixture orgs don't need placeholder names.
- No uniqueness constraint. Two orgs may share a name.
- May be updated freely via `updateOrg`.

### `slug`

- Type: nullable `TEXT`. When set, MUST match the regex `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` — DNS-label-ish: 1–63 lowercase ASCII characters or digits or hyphens, no leading/trailing hyphen.
- Globally unique within a deployment **when set**. NULLs are not unique-constrained (Postgres default), so multiple internal orgs without slugs coexist.
- May be updated freely. Renaming a slug frees the old one immediately. The spec does NOT track slug history — adopters who need redirect-from-old-slug semantics implement them at the application or routing layer.
- Reserved values (e.g. `admin`, `api`, `www`) are NOT spec-reserved; deployments that need to block them do so at the application layer.

### New operation: `updateOrg`

```
updateOrg(org_id, *, name?, slug?) → Organization
```

Partial update. The semantics across all four SDK languages:

- An **omitted** parameter means "don't change this field."
- An explicit **`null`** means "set this field to NULL."

The Python sentinel idiom uses `_UNSET` vs `None`; the TypeScript idiom uses `undefined` vs `null`; the PHP idiom uses a separate boolean indicator or named-param convention; the Java idiom uses `Optional<String>` (or two overloads). Each SDK documents its own idiom; the spec mandates the semantic, not the calling convention.

`updateOrg` raises:

- `OrgSlugConflictError` (`code: conflict.org_slug`) on slug uniqueness violation.
- `NotFoundError` if the org does not exist.
- `AlreadyTerminalError` if the org is in a terminal state (revoked).

### `createOrg` extension

```
createOrg(creator, *, name?, slug?) → CreateOrgResult
```

Both new args optional. `OrgSlugConflictError` raised if the supplied slug collides with an existing org's slug.

## Consequences

- **Backwards compatibility.** Pure addition; no v0.1 caller breaks. Pre-v0.2 stores that round-trip an `Organization` payload without `name` or `slug` continue to work — the fields default to `null`.
- **Postgres reference.** Two new nullable columns + a partial unique index on slug + a CHECK constraint enforcing the slug pattern. The DDL block lands in the v0.2 additive section of `postgres.sql`.
- **OpenAPI.** `Organization` schema gains the two optional fields; `flametrench-v0.2-additions.yaml` declares the new `PUT /orgs/{org_id}` endpoint with the `UpdateOrgRequest` body.
- **Conformance.** New fixture `tenancy/org-name-slug.json` covers round-trip, slug uniqueness, slug pattern validation, and the partial-update sentinel-vs-null distinction.
- **`tup_check` semantics unchanged.** Authorization is unaffected; `tup` rows still reference `org.id`, never `org.slug`.
- **RLS policies unchanged.** `org` visibility is governed by membership in the org, which the new fields don't influence.

## Alternatives considered

### Generic `metadata` JSONB column

Adds an opaque object to `Organization` and lets adopters put whatever they want there. Rejected because:

1. It defers the cross-tool interoperability question rather than answering it. Two adopters using a generic metadata bag can disagree on whether the display name lives at `metadata.name`, `metadata.display_name`, `metadata.title`, etc.
2. JSONB columns become junk drawers. Without a schema, the only way to read them safely is to know the writer's conventions — which is exactly the problem we're trying to fix.
3. Doesn't give the SDK enough structure to drive built-in features (invitation mailer, admin tooling).

### Host-side extension tables only

The status quo. Rejected because the first adopter is already feeling the cost; subsequent adopters will hit it identically. Spec stays minimal but the cost is paid in N places.

### Required `name`

The reporter's original option 1. Rejected because it forces programmatic / CI / test-fixture flows to invent placeholder names. The spec stays permissive; adopters who want it required enforce at the application layer.

### Slug history table

Tracks every slug an org has ever held to support automatic redirects from old slugs. Rejected for the spec because:

1. Most adopters either don't rename slugs frequently or handle redirects at the routing layer (Cloudflare rules, Next.js redirects, nginx rewrites).
2. Adopters who need it can implement a sibling table keyed by `(old_slug, new_org_id, retired_at)` — the spec doesn't have to bless one shape.

### Display name + handle on `usr`

Same shape, deferred to a separate ADR. Display name on a user pulls in PII / privacy concerns (whether to expose handle to other org members, whether display name is per-tenant or global) that deserve their own design pass rather than a quick add. Tracked in a future spec issue.

## References

- Spec issue [`flametrench/spec#6`](https://github.com/flametrench/spec/issues/6) — original report and reproduction.
- [`decisions/0002-tenancy-model.md`](./0002-tenancy-model.md) — the original org-as-minimal-entity decision this ADR amends.
- [`docs/tenancy.md`](../docs/tenancy.md) — gains a normative paragraph on name + slug semantics.
- [DNS RFC 1035 §2.3.1](https://datatracker.ietf.org/doc/html/rfc1035#section-2.3.1) — origin of the 1–63 char DNS-label pattern adopted for slug.
