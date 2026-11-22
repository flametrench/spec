# Tenancy

Flametrench tenancy covers how organizations are structured, how users join them, how membership role changes are recorded, and how memberships are removed.

Three entities comprise tenancy:

- **`org_`** — an organization: a unit of tenancy. A company, a team, a workspace.
- **`mem_`** — a membership: a user's participation in an org, carrying a role and lifecycle metadata.
- **`inv_`** — an invitation: a pending offer for a user to join an org.

This chapter is normative. Rationale lives in [ADR 0002 — Tenancy model](../decisions/0002-tenancy-model.md) and [ADR 0003 — Invitation state machine](../decisions/0003-invitation-state-machine.md).

## Organizations

### Entity shape

- `id` — UUIDv7; `org_<hex>`.
- `status` — one of `active`, `suspended`, `revoked`.
- `name` — optional display name (v0.2; per [ADR 0011](../decisions/0011-org-display-name-slug.md)). SHOULD be set when the org has a human-meaningful identity.
- `slug` — optional URL handle (v0.2). When set, MUST match `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` (DNS-label-style: 1–63 lowercase ASCII chars or digits or hyphens, no leading/trailing hyphen). Globally unique within a deployment when set; NULL allowed.
- `created_at`, `updated_at`.

`name` has no uniqueness constraint and no length cap pinned at the spec level. `slug` rename is allowed; the old slug becomes free immediately and the spec does NOT track slug history. Adopters that need redirect-from-old-slug semantics implement them at the routing layer.

### Flat hierarchy

Orgs are flat: an `org_` has no parent org. Modeling divisions or sub-teams is done either outside the spec (application-level structure) or via v0.2 rewrite rules ([ADR 0007](../decisions/0007-authorization-rewrite-rules.md)) where cross-org inheritance becomes safe to derive declaratively. Nested orgs as a first-class primitive remain deferred.

### Lifecycle

Tri-state, matching users:

- **`active`** — org is live.
- **`suspended`** — org access is paused. Every org-scoped operation in the org MUST fail the org-active precondition (below). User-bound sessions, PATs and share tokens are NOT terminated or revoked; each use is refused per request ([ADR 0026](../decisions/0026-org-suspension-enforcement.md)). Memberships remain in their current status. Their role tuples are removed on suspend and re-created from the `active` memberships on reinstate (ADR 0026 §1a), so reinstating the org re-activates the authorization grants without requiring re-provisioning members.
- **`revoked`** — org is terminated. All active memberships MUST be transitioned to `revoked`. The `org_` row is preserved for audit.

### Operations

- `createOrg(creator, *, name?, slug?) → {org, owner_membership}` — creates the org AND the creator's owner membership in one transaction. `name` and `slug` are optional v0.2 fields per ADR 0011; supplying a slug that collides with another org raises `OrgSlugConflictError` (`code: conflict.org_slug`).
- `getOrg(org_id) → org`.
- `updateOrg(org_id, *, name?, slug?) → org` — partial update of v0.2 metadata fields. An omitted parameter means "don't change"; an explicit null means "set to null." Slug uniqueness violations raise `OrgSlugConflictError`. Updating a revoked org raises `AlreadyTerminalError`.
- `suspendOrg(org_id)`, `reinstateOrg(org_id)`, `revokeOrg(org_id)`.
- `requireActiveOrg(org_id) → org` — the org-active precondition (ADR 0026). Returns the org when `active`; raises `OrgSuspendedError` (`code: precondition.org_suspended`), `OrgRevokedError` (`code: precondition.org_revoked`), or the not-found error `getOrg` raises. Both errors are `PreconditionError` subclasses; on the wire they are 403 to a caller who could already see the org and the adopter's not-found (404) to anyone else.
- `listOrgs(*, cursor?, limit = 50, query?, status?) → Page<Organization>` — paginated cross-org enumeration (ADR 0025). `query` is a case-insensitive substring over `name`/`slug`; `status` filters `active|suspended|revoked` (omitted = all). Ordered by `id` ASC. **This is the one cross-tenant read in tenancy — the adopter MUST gate the call site to an admin/system caller** (a missing gate is a cross-tenant org-enumeration leak); server-side callers with no subject (e.g. a per-org background fan-out) are inherently system-level and satisfy the bar but MUST NOT be exposed on a tenant-scoped route. A missing gate discloses the **entire customer roster** (id/status/name/slug/timestamps — a searchable tenant directory + churn/billing + growth signal), not merely an enumeration count. **Revoked orgs remain enumerable:** `status='revoked'` returns full metadata — `revoke` is a lifecycle state, not erasure, so adopters with deletion/data-protection (e.g. GDPR) obligations MUST purge separately. See ADR 0025 §Authorization + ADR 0019 (the cross-tenant non-inference invariant `listOrgs` is the single explicit exception to).

### Suspension enforcement (normative; ADR 0026)

Two layers, both MUST:

- **Tuple pause.** `suspendOrg` deletes the membership role tuple of every `active` membership of the org, in the same transaction; the `mem_` rows stay `active`. `reinstateOrg` re-creates the tuple for every membership `active` at reinstate time whose user is not `revoked` (`revokeUser` leaves `mem_` active, so a revoked user MUST NOT be re-granted). So `check()` denies membership-derived and rewrite-derived grants while the org is suspended. Direct object tuples are not touched. Deleting an absent membership tuple during the suspension (a removal) is a no-op; `reinstateOrg` creates no duplicate tuple; and a store upgrading to ADR 0026 MUST first delete the membership role tuples of orgs already `suspended` (proved in each SDK's migration tests, not by a fixture). Adopters MUST write org membership role tuples only through tenancy operations.
- **Precondition.** It covers direct object grants, shares, PATs and work with no `check()`:

- Every **org-scoped operation** (one that reads or changes any object belonging to an org) MUST pass `requireActiveOrg` for **each org it touches**, before `check()` and before any effect, whatever the bearer: session, PAT, share token or none.
- **Operator exemption:** `getOrg`, `updateOrg`, `suspendOrg`, `reinstateOrg`, `revokeOrg`, `listOrgs`, `requireActiveOrg` and operator support tooling need no precondition when an admin or system caller makes them, gated as `listOrgs` is (ADR 0025). A route exposing them to the org's own members or bearers is org-scoped and MUST pass it.
- The org is the one that owns the **target object**, as the application derives it (the same derivation as `authorization.md` Pattern B), not only an org named in the path. A request resolved through a verified share or a PAT checks that object's org.
- Queued jobs, scheduled tasks, webhook deliveries and event fan-out MUST pass it **when they execute**, not only when they are created.
- Where the adopter would answer the caller with not-found (a non-member, an unauthenticated caller), it MUST NOT expose `OrgSuspendedError` or `OrgRevokedError`, and MUST map both to that same not-found. The distinct codes are for callers who could already see the org.
- Suspension MUST NOT terminate user-bound sessions (`identity.md`) or revoke PATs or shares. Reinstating restores them with no action; their own expiry keeps running. An adopter that keeps a session it binds to one org MAY terminate that session.
- **Single-use shares:** `verifyShareToken` consumes a single-use share before its org is known, so one presented during the suspension is consumed and then refused, and reinstating does not restore it. This is the one effect allowed before the precondition.
- **Store-level refusal:** `addMember`, `createInvitation`, `acceptInvitation`, `changeRole`, `transferOwnership`, `reinstateMembership` and a `selfLeave` with `transferTo` MUST raise `OrgSuspendedError` / `OrgRevokedError` on a suspended or revoked org, before any write, whoever calls them. Other removals still work.
- Long-running work (a stream, a websocket, a long job) MUST re-check before each org-scoped step. An adopter MAY cache the result, but never beyond one request, one job execution, or one step of long-running work.
- When `requireActiveOrg` throws, the adopter chooses 403 or not-found through its normal visibility path; it MUST NOT return 403 to every caller.
- **Conformance cannot catch a missing adopter check** — like the `listOrgs` gate, the call site is the only control for these obligations.

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

Every active membership **of an active org** is represented as BOTH:

- A `mem_` row (tenancy metadata).
- A `tup_` row (the authorization fact): `(subject_type = usr, subject_id = usr_id, relation = role, object_type = org, object_id = org_id)`.

The two rows are created, modified, and removed in the same transaction. While the org is `suspended`, active memberships have no `tup_` row (ADR 0026 §1a). When `mem.status` transitions to `suspended` or `revoked`, the corresponding `tup_` row MUST be deleted. When `mem.status` transitions to `active` (initial creation or reinstate), the `tup_` row MUST be created.

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
- No session is terminated: sessions are user-bound (`identity.md`). Deleting the membership's tuple ends the user's org access from the next `check()`. Adopters with org-bound sessions MAY terminate those.

### Admin-remove

An admin MAY remove another member. The operation:

- Authorization check: `check(admin, [owner, admin], org)`.
- Precondition: `admin.role ≥ target.role` in the admin hierarchy `owner > admin > member > guest`. Admins MUST NOT remove owners. Owner removal is possible ONLY via an ownership-transfer operation, never via direct `adminRemove`.
- `viewer` and `editor` are object-scoped relations; they do not participate in the admin hierarchy for removal purposes.

Effect:

- `mem.status = revoked`.
- `mem.removed_by = admin.usr_id` (non-null value distinguishes admin-initiated).
- Corresponding `tup_` row deleted.
- No session is terminated: sessions are user-bound (`identity.md`). Deleting the membership's tuple ends the user's org access from the next `check()`. Adopters with org-bound sessions MAY terminate those.

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
- `revokeInvitation(inv_id, admin_usr_id)` — the SDK MUST verify, in the same transaction as the transition, that `admin_usr_id` holds an **active** membership **in the invitation's org** with role `owner` or `admin` (the same active-membership check as `adminRemove`), in one transaction: lock the invitation → authorize (locking the acting membership) → check `pending` → write. An unauthorized caller gets `ForbiddenError` whatever the invitation's state; no state change. On success `terminal_by = admin_usr_id`. (ADR 0028.)
- `revokeInvitationAsSystem(inv_id)` — system revocation with no actor: `terminal_by = NULL`, no SDK authorization check. **Adopters MUST gate the call site to server-side system/automation callers; it MUST NOT be reachable from any user-facing or tenant-scoped route** — the SDK cannot enforce this and conformance cannot catch a missing gate. (ADR 0028.)
- `getInvitation(inv_id) → inv`.
- `listInvitations(org_id, status?) → [inv]`.

## Conformance fixtures

- **Sole-owner transfer.** Creating an org via `createOrg()`, then calling `selfLeave(owner_mem_id)` WITHOUT `transferTo` MUST return an error. Calling with a valid `transferTo` pointing at another active member MUST atomically transfer ownership and revoke the leaver's membership; the recipient's membership MUST be at role=owner after the call.

- **Admin role hierarchy on remove.** Given `mem_alice (role=admin)` and `mem_bob (role=owner)` in the same org, `adminRemove(bob, initiator=alice)` MUST return an error. Given `mem_alice (role=admin)` and `mem_bob (role=member)`, `adminRemove(bob, initiator=alice)` MUST succeed.

- **Pre-tuple expansion.** An invitation with `pre_tuples = [{"relation":"viewer", "object_type":"project", "object_id":"<uuid>"}]`, when accepted, MUST result in exactly one additional `tup_` row beyond the membership tuple, with the specified relation and object and subject=accepting user.

- **`removed_by` attribution.** A membership revoked via `selfLeave` MUST have `removed_by = NULL`. A membership revoked via `adminRemove` MUST have `removed_by` set to the admin's `usr_id`.

- **Org suspension (ADR 0026; fixtures to be written).** After `suspendOrg`, `requireActiveOrg` MUST raise `OrgSuspendedError`, the member's `check(member, role, org)` MUST return `false` (and `true` again after `reinstateOrg`, with the same `mem_` id), their session is not revoked, and their PAT and the org's multi-use shares still verify; a single-use share presented during the suspension is consumed and refused. After `reinstateOrg` it MUST return the org with no membership re-created, and a member whose user was revoked MUST still get `false` from `check(usr, role, org)`. A sole owner's `selfLeave` with `transferTo` MUST raise `OrgSuspendedError` while the org is suspended. After `revokeOrg` it MUST raise `OrgRevokedError`. On a suspended org, `addMember`, `createInvitation`, `acceptInvitation`, `changeRole`, `transferOwnership` and `reinstateMembership` MUST raise `OrgSuspendedError` and write nothing. (Execution-time refusal of jobs is an adopter obligation with no fixture.)

More fixtures will be added in `spec/conformance/` as implementations surface specific questions.
