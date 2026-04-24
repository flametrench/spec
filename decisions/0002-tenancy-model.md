# 0002 — Tenancy model: flat organizations, membership-as-tuple

**Status:** Accepted
**Date:** 2026-04-23

## Context

Tenancy in Flametrench covers organizations, memberships, and the operations that modify them. Invitations are a separate decision ([ADR 0003](./0003-invitation-state-machine.md)) because the invitation state machine has enough independent design complexity to warrant its own record.

The core tensions for v0.1:

1. Do we support nested organizations (sub-orgs, divisions, team-of-teams)?
2. Can one user belong to multiple organizations simultaneously?
3. How do memberships interact with the authorization primitive from ADR 0001?
4. How are role changes modeled?
5. What procedures govern leaving or removing members, and how is "the last owner can't just walk away" enforced?

## Decision

### Flat organizations in v0.1

An `org_` has no `parent_org_id`. Every org is a root. Applications that model divisions or sub-teams do so either via cross-org structure or via custom object types (`team_`, `div_`) outside the spec.

Nested orgs are deferred to v0.2+ because they only become coherent alongside rewrite rules (ADR 0001): without derivation, "members of parent org are implicit members of child" cannot be encoded, and explicit materialization across a hierarchy is an anti-pattern.

### Multi-organization membership

A `usr_` MAY belong to any number of `org_`s simultaneously. Memberships are enumerable per user via `listMemberships(usr_id)`. This matches the expectation of every major modern SaaS (Slack, Linear, GitHub, Notion).

Within a single `(usr_id, org_id)` pair, at most one `mem_` may be active at a time. Historical revoked memberships accumulate without limit and form the audit trail.

### Membership as dual entity and tuple

Every active membership is represented as BOTH:

1. A `mem_` row carrying tenancy metadata: `role`, `status`, `invited_by`, `removed_by`, `created_at`, `replaces` (chain pointer), `updated_at`.
2. A `tup_` row carrying the authorization fact: `(subject=usr_id, relation=role, object=org_id)`.

The two are created, modified, and deleted in the same transaction. When `mem.status` transitions to `suspended` or `revoked`, the corresponding `tup_` row is deleted. Reinstatement creates a new `tup_` row.

Tenancy operations query `mem_` for lifecycle (when Alice joined, who invited her, whether she's suspended). Authorization operations query `tup_` for effective grants. The two cannot diverge because they are maintained atomically.

### Membership status

```
active → suspended → active (reinstate)
active → revoked (terminal)
suspended → revoked (terminal)
```

- **`active`** — membership is live. `tup_` exists.
- **`suspended`** — membership is paused. `tup_` deleted. `mem_` entity preserved for rapid reinstate and audit.
- **`revoked`** — membership terminated. `tup_` deleted. `mem_` frozen; terminal.

### Role change via revoke-and-re-add

Role changes MUST NOT mutate `mem.role` in place. Instead:

1. The existing `mem_` transitions to `status=revoked`.
2. A new `mem_` is inserted with `replaces = previous.id` and the new role.
3. The `tup_` row for the old role is deleted.
4. A new `tup_` row for the new role is inserted.

All four steps happen in one transaction. Walking the `replaces` chain yields the full role history; the root of the chain carries the original join date; the head carries the current state.

See [ADR 0005](./0005-revoke-and-re-add.md) for the rationale behind this pattern.

### Self-leave and admin-remove are distinct operations

**Self-leave** — a member removes their own membership.

- Preconditions: none, UNLESS the subject is the sole `owner` of the org, in which case the call MUST atomically include a `transferTo: usr_…` parameter. The ownership transfer is not a separate stateful step; it is encoded in the leave call. Attempting to self-leave as sole owner without a transfer target is rejected.
- Effect: `mem.status = revoked`, `mem.removed_by = NULL` (null distinguishes self-initiated from admin-initiated), `tup_` deleted, sessions scoped to the org terminated at the SDK layer.

**Admin-remove** — an admin removes another member.

- Authorization check: `check(admin, [owner, admin], org)`.
- Precondition: `admin.role ≥ target.role` in the admin hierarchy `owner > admin > member > guest`. Admins MUST NOT remove owners; only other owners may, and only via ownership transfer (never direct `remove_member`).
- Effect: `mem.status = revoked`, `mem.removed_by = admin.usr_id`, `tup_` deleted, sessions terminated.

The telltale for audit attribution is `removed_by`: null for self-leave, non-null for admin-remove.

### Sole-owner invariant

Every organization with any active membership MUST have at least one active membership with `role = owner`. This invariant is enforced procedurally in `selfLeave` and `adminRemove`: the operation MUST reject if executing it would leave the org ownerless.

Ownership transfer is the only path for the last owner to leave. Expressing the invariant as a SQL CHECK requires deferred triggers that complicate bulk operations (backup restoration, org-creation-by-import). Procedural enforcement at the SDK layer is the chosen discipline.

## Consequences

**Positive:**

- Membership semantics are one sentence: a tuple plus metadata.
- Role changes preserve complete history without a shadow audit table.
- Offboarding is a single SDK call with well-defined cascade semantics.

**Negative:**

- Role changes write two rows (`mem_` insert + `tup_` re-insertion) and one update (`mem_` status) instead of one update. Higher write volume, but strictly traceable.
- "Every member who has ever been an admin of any org" requires scanning revoked `mem_` rows.

## Deferred to v0.2+

- Nested organizations.
- Org-level role hierarchies (declarative "admin implies editor" within an org).
- Bulk membership operations with cascade previews.
- Time-bounded memberships ("Alice is a viewer of Acme until Jan 31").

## Rejected alternatives

- **Mutating `mem.role` in place.** Simpler wire but requires a separate audit table to recover history; invites "silent role edits" that zero-trust postures cannot tolerate.
- **Ownership transfer as a separate pending state.** Adds a `transfer_pending` status, complicates authz checks, and creates "zombie org" cases when transfers aren't completed. Atomic encoding is cleaner.

## References

- [ADR 0001 — Authorization model](./0001-authorization-model.md).
- [ADR 0003 — Invitation state machine](./0003-invitation-state-machine.md).
- [ADR 0005 — Revoke-and-re-add lifecycle pattern](./0005-revoke-and-re-add.md).
- `spec/docs/tenancy.md` — normative prose.
- `spec/reference/postgres.sql` — reference DDL.
