# Tenancy

Flametrench tenancy covers how organizations are structured, how users join them, how membership role changes are recorded, and how memberships are removed.

Three entities comprise tenancy in v0.1:

- **`org_`** — an organization: a unit of tenancy. A company, a team, a workspace.
- **`mem_`** — a membership: a user's participation in an org, carrying a role and lifecycle metadata.
- **`inv_`** — an invitation: a pending offer for a user to join an org.

This chapter is normative. Rationale lives in [ADR 0002 — Tenancy model](../decisions/0002-tenancy-model.md) and [ADR 0003 — Invitation state machine](../decisions/0003-invitation-state-machine.md).

## Organizations

### Entity shape

- `id` — UUIDv7; `org_<hex>`.
- `status` — one of `active`, `suspended`, `revoked`.
- `created_at`, `updated_at`.

Organizations are opaque: no name, no slug, no billing plan in the spec. Those are application concerns. Applications MAY extend with their own columns; the spec does not define extensions.

### Flat hierarchy

v0.1 supports only flat orgs: an `org_` has no parent org. Modeling divisions or sub-teams is done either outside the spec (application-level structure) or in v0.2+ when rewrite rules land and cross-org inheritance becomes safe to derive.

### Lifecycle

Tri-state, matching users:

- **`active`** — org is live.
- **`suspended`** — org access is paused. All active sessions scoped to the org MUST be terminated when the transition happens. Memberships remain in their current status — reinstating the org re-activates the authorization grants without requiring re-provisioning members.
- **`revoked`** — org is terminated. All active memberships MUST be transitioned to `revoked`. The `org_` row is preserved for audit.

### Operations

- `createOrg() → org_id, owner_mem_id` — creates the org AND the creator's owner membership in one transaction. Both IDs are returned.
- `getOrg(org_id) → org`.
- `suspendOrg(org_id)`, `reinstateOrg(org_id)`, `revokeOrg(org_id)`.

## Memberships

### Entity shape

- `id` — UUIDv7; `mem_<hex>`.
- `usr_id` — the member.
- `org_id` — the organization.
- `role` — one of `owner`, `admin`, `member`, `guest`, `viewer`, `editor`.
- `status` — one of `active`, `suspended`, `revoked`.
- `replaces` — nullable FK to the previous membership in the rotation chain.
- `invited_by` — FK to the user who initiated the invitation; NULL for org-creator bootstrap.
- `removed_by` — FK to the user who removed this membership; NULL for self-leave.
- `created_at`, `updated_at`.

### Multi-organization membership

A `usr_` MAY hold memberships in any number of `org_`s simultaneously. The constraint `UNIQUE(usr_id, org_id) WHERE status = active` prohibits duplicate active memberships for the same pair.

### Membership-as-tuple duality

Every active membership is represented as BOTH:

- A `mem_` row (tenancy metadata).
- A `tup_` row (the authorization fact): `(subject_type = usr, subject_id = usr_id, relation = role, object_type = org, object_id = org_id)`.

The two rows are created, modified, and removed in the same transaction. When `mem.status` transitions to `suspended` or `revoked`, the corresponding `tup_` row MUST be deleted. When `mem.status` transitions to `active` (initial creation or reinstate), the `tup_` row MUST be created.

Tenancy queries use `mem_` for lifecycle history; authorization queries use `tup_` for current grants.

### Role change: revoke-and-re-add

Role changes MUST NOT be performed as in-place updates to `mem.role`. Instead:

1. The existing `mem_` transitions to `status = revoked`.
2. A new `mem_` is inserted with `replaces = old.id` and the new role.
3. The `tup_` row for the old role is deleted.
4. A new `tup_` row for the new role is inserted.

All four steps happen in one transaction.

Walking the `replaces` chain yields the full role history with monotonic timestamps. The root of the chain (`replaces IS NULL`) carries the original join date; the head carries the current state.

### Status transitions

```
active → suspended → active     (paused and reinstated; tup_ deleted then recreated)
active → revoked                (terminal)
suspended → revoked             (terminal)
```

### Sole-owner invariant

For any organization with at least one active membership, at least one active membership MUST have `role = owner`. This invariant is enforced procedurally in the leave and remove operations — NOT by a SQL constraint.

### Self-leave

A member MAY remove their own membership. The operation:

- Takes no authorization check: the subject is always authorized over their own membership.
- If the subject is the **sole active owner** of the org, the call MUST include a `transferTo: usr_…` parameter targeting another active member. Otherwise the operation MUST return an error. The ownership transfer and the leave happen in one transaction — ownership is never in a "pending" state.

Effect:

- `mem.status = revoked`.
- `mem.removed_by = NULL` (null distinguishes self-initiated).
- Corresponding `tup_` row deleted.
- Sessions scoped to this org (if any) terminated at the SDK layer.

### Admin-remove

An admin MAY remove another member. The operation:

- Authorization check: `check(admin, [owner, admin], org)`.
- Precondition: `admin.role ≥ target.role` in the admin hierarchy `owner > admin > member > guest`. Admins MUST NOT remove owners. Owner removal is possible ONLY via an ownership-transfer operation, never via direct `adminRemove`.
- `viewer` and `editor` are object-scoped relations; they do not participate in the admin hierarchy for removal purposes.

Effect:

- `mem.status = revoked`.
- `mem.removed_by = admin.usr_id` (non-null value distinguishes admin-initiated).
- Corresponding `tup_` row deleted.
- Sessions scoped to this org terminated.

The telltale field for audit attribution is `removed_by`: null for self-leave, non-null for admin-remove.

### Operations

- `addMember(org_id, usr_id, role, invited_by) → mem_id` — creates an active membership and corresponding `tup_`.
- `changeRole(mem_id, new_role) → new_mem_id` — revoke-and-re-add.
- `suspendMembership(mem_id)`, `reinstateMembership(mem_id)`.
- `selfLeave(mem_id, transferTo?)` — takes an optional transfer target required when leaver is sole owner.
- `adminRemove(mem_id, admin_usr_id)` — subject to authorization check and hierarchy precondition.
- `transferOwnership(org_id, from_mem_id, to_mem_id)` — the only way to transition ownership.
- `listMembers(org_id, cursor, limit) → [mem]` — paginated; MUST be gated by `check(subject, list_members, org)` or equivalent application policy at the call site.

## Invitations

### Entity shape

- `id` — UUIDv7; `inv_<hex>`.
- `org_id` — the org being joined.
- `identifier` — the invitee's email (or handle).
- `role` — the role the invitee will receive on accept.
- `status` — one of `pending`, `accepted`, `declined`, `revoked`, `expired`.
- `pre_tuples` — JSONB array of resource-scoped grants to materialize on accept.
- `invited_by` — FK to the inviting user.
- `invited_user_id` — resolved `usr_id` at accept time.
- `created_at`, `expires_at`, `terminal_at`, `terminal_by`.

### State machine

Full definition in [ADR 0003](../decisions/0003-invitation-state-machine.md). Summary:

```
pending → accepted       (invitee accepts)
pending → declined       (invitee declines)
pending → revoked        (admin cancels)
pending → expired        (TTL elapsed)
```

Non-pending states are terminal and immutable.

### Pre-declared tuples

`pre_tuples` is an array of objects shaped:

```json
{
  "relation":    "viewer",
  "object_type": "project",
  "object_id":   "0190f2a8-..."
}
```

On accept, each becomes a `tup_` row with the accepting user as subject.

This is how Carol-the-contractor (guest of Acme, viewer of `project_42`) is modeled in a single invitation.

### Atomic acceptance

The `acceptInvitation(inv_id, ...)` operation MUST execute in a single transaction:

1. Resolve or create `usr_id` for the invitee. If the invitee already has an account matching the invitation identifier, use it; otherwise create a new `usr_`.
2. Insert `mem_` for `(usr_id, org_id, role = inv.role)`.
3. Insert the corresponding `tup_` for the membership.
4. Expand `pre_tuples` into additional `tup_` rows.
5. Transition `inv.status = accepted`, set `terminal_at`, `terminal_by = usr_id`, `invited_user_id = usr_id`.

Any failure rolls back the entire transaction. The invitation remains `pending` and no partial state is persisted.

### Identifier binding (normative)

When an existing-user `as_usr_id` is supplied to `acceptInvitation`, callers MUST also supply `accepting_identifier`. The SDK byte-compares `accepting_identifier == invitation.identifier`; mismatch raises `IdentifierMismatchError` (`code: precondition.identifier_mismatch`) and the transaction is not started. Omitting the parameter when `as_usr_id` is supplied raises `IdentifierBindingRequiredError` (`code: precondition.identifier_binding_required`) — the SDK fails closed rather than allow the implicit pre-v0.1.x behavior. See [ADR 0009](../decisions/0009-invitation-accept-binding.md) for the rationale.

The host application MUST source `accepting_identifier` from the authenticated session context — typically the canonical email or handle attached to the bearer token's `usr_id`. The host MUST NOT source it from the request body without an authenticity check that ties the body field to the authenticated subject. The SDK enforces the byte-equality; the host's auth layer enforces the source authenticity. Neither layer alone is sufficient.

The mint-new-user path (`as_usr_id = null`) does not require `accepting_identifier`: the SDK creates a fresh `usr_` and the host wires the corresponding credential separately, with `cred.identifier = invitation.identifier`. The binding is enforced post-hoc when that credential is created at the Identity layer.

### Operations

- `createInvitation(org_id, identifier, role, pre_tuples?, expires_at) → inv_id`.
- `acceptInvitation(inv_id, as_usr_id?, accepting_identifier?)` — if the invitee already has an account, pass their `usr_id` AND `accepting_identifier` (the canonical identifier for that account, sourced from the host's auth context). If `as_usr_id` is null, the operation creates a fresh user; `accepting_identifier` may be omitted.
- `declineInvitation(inv_id, as_usr_id?)`.
- `revokeInvitation(inv_id, admin_usr_id)` — subject to admin authorization on the target org.
- `getInvitation(inv_id) → inv`.
- `listInvitations(org_id, status?) → [inv]`.

## Conformance fixtures

- **Sole-owner transfer.** Creating an org via `createOrg()`, then calling `selfLeave(owner_mem_id)` WITHOUT `transferTo` MUST return an error. Calling with a valid `transferTo` pointing at another active member MUST atomically transfer ownership and revoke the leaver's membership; the recipient's membership MUST be at role=owner after the call.

- **Admin role hierarchy on remove.** Given `mem_alice (role=admin)` and `mem_bob (role=owner)` in the same org, `adminRemove(bob, initiator=alice)` MUST return an error. Given `mem_alice (role=admin)` and `mem_bob (role=member)`, `adminRemove(bob, initiator=alice)` MUST succeed.

- **Pre-tuple expansion.** An invitation with `pre_tuples = [{"relation":"viewer", "object_type":"project", "object_id":"<uuid>"}]`, when accepted, MUST result in exactly one additional `tup_` row beyond the membership tuple, with the specified relation and object and subject=accepting user.

- **`removed_by` attribution.** A membership revoked via `selfLeave` MUST have `removed_by = NULL`. A membership revoked via `adminRemove` MUST have `removed_by` set to the admin's `usr_id`.

More fixtures will be added in `spec/conformance/` as implementations surface specific questions.
