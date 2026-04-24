# 0003 — Invitation state machine

**Status:** Accepted
**Date:** 2026-04-23

## Context

Invitations are the primary path for new users to join an organization. The abstraction has surprising variance across real products: some treat them as simple "email with a link"; others as multi-step flows with delivery tracking, click-tracking, 2FA enrollment, and so on.

Flametrench v0.1 must define an invitation state machine precise enough that every conforming implementation behaves identically, while leaving delivery mechanics (email, Slack, SMS) as application concerns.

## Decision

Invitations are modeled as first-class entities (`inv_`) with a fixed five-state lifecycle. The spec defines the state machine; the spec does NOT define delivery, notification, or tracking.

### States and transitions

```
                 ┌─── accepted
 pending ────────┼─── declined
                 ├─── revoked
                 └─── expired
```

`pending` is the only non-terminal state. The other four are terminal and immutable — once an invitation leaves `pending`, its status never changes again.

### Actors per transition

| Transition | Actor | `inv.terminal_by` |
|---|---|---|
| `pending → accepted` | Invitee | The invitee's newly-created or resolved `usr_id` |
| `pending → declined` | Invitee | The invitee's `usr_id` if known, or NULL (anonymous decline) |
| `pending → revoked` | Admin of the org | The admin's `usr_id` |
| `pending → expired` | System (TTL elapsed) | NULL |

`inv.terminal_at` is set to the transition timestamp; `inv.terminal_by` as above.

### Expiration

`inv.expires_at` is required at creation. The invitation is considered `expired` at query time if `status = 'pending' AND now() > expires_at`. Implementations MAY lazily transition `pending` invitations past their TTL to explicit `expired` status; implementations MUST treat expired invitations as non-acceptable.

### Scope of an invitation

An invitation carries:

- `org_id` — the organization being joined.
- `role` — the role the invitee will receive in the org on accept.
- `pre_tuples` (JSONB, possibly empty) — resource-scoped authorization grants to materialize at accept time.

`pre_tuples` is an array of objects shaped `{ "relation", "object_type", "object_id" }`. The subject of each pre-tuple is implicit: the `usr_id` of the accepting user.

This is how Carol-the-contractor (guest of Acme, viewer of `project_42`) is modeled in a single invitation.

### Acceptance is atomic

The `acceptInvitation(inv_id, ...)` operation MUST execute all of the following in a single transaction:

1. Resolve the invitee's `usr_id`. If the invitee already has an account, use it; otherwise create a new `usr_`.
2. Insert a new `mem_` with `usr_id`, `org_id = inv.org_id`, `role = inv.role`, `invited_by = inv.invited_by`, `status = active`.
3. Insert the corresponding `tup_` for the membership.
4. For each entry in `inv.pre_tuples`, insert a `tup_` with `subject = usr_id` and the specified `(relation, object_type, object_id)`.
5. Transition the invitation: `status = accepted`, `terminal_at = now()`, `terminal_by = usr_id`, `invited_user_id = usr_id`.

If any step fails, the entire transaction rolls back; the invitation remains `pending` and no partial state is persisted.

### Decline, revoke, expire are single-field transitions

None of the terminal non-accept transitions touch `mem_` or `tup_`. An invitation that was never accepted never affected the authorization or tenancy graphs.

### Re-invitation

If an invitation expires or is declined, a new invitation MAY be created for the same `(org_id, identifier)` pair. The spec imposes no cooldown; applications decide.

If an invitation was accepted and the resulting membership is later revoked, a new invitation MAY be created for the same identifier. The original invitation remains in its terminal state; the new invitation is a separate `inv_` entity.

### Out of scope for v0.1

The spec does NOT define:

- Email delivery, deep-link construction, SMS fallbacks.
- "Delivered" / "viewed" / "clicked" sub-states. These belong to email providers or application telemetry, not identity infrastructure.
- Invitation cooldown or rate limiting.
- Invitation renewal (extending `expires_at`). Implementations MAY allow this but MUST represent it as an update to an existing `pending` invitation, not as a state transition.

## Consequences

- Every invitation event (create, accept, decline, revoke, expire) is a single state transition plus (for accept) a transactional materialization.
- Invitation audit is trivial: the `inv_` row is a complete record.
- Delivery tracking layers on top without touching the spec.

## Deferred to v0.2+

- Multi-party invitation flows (invitation requires approval by a second admin before activating).
- Automatic renewal / extension semantics.
- Invitation templates (parameterized pre-declared tuples).

## Rejected alternatives

- **Delivery sub-states** (sent, delivered, opened, accepted). Coupling identity infrastructure to email-provider primitives is fragile and out of scope.
- **Accept creates membership in a two-phase flow** (invitee accepts → admin approves → membership active). Legitimate product feature for some apps; belongs in the application layer via a `pending_approval` custom status on `mem_`.

## References

- [ADR 0002 — Tenancy model](./0002-tenancy-model.md).
- `spec/docs/tenancy.md`.
- `spec/reference/postgres.sql` — `inv` table DDL.
