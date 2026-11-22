# 0028 — `revokeInvitation` authorization is enforced by the SDK; a separate system revocation path

**Status:** Accepted
**Date:** 2026-11-22
**Deciders:** Flametrench stewards
**Supersedes (in part):** the `revokeInvitation` line of `docs/tenancy.md` §"Invitations/Operations"; adds a row to ADR 0003 §"Actors per transition"

## Context

- `docs/tenancy.md` lists `revokeInvitation(inv_id, admin_usr_id)` as "subject to admin authorization on the target org".
- ADR 0003 §"Actors per transition" makes the actor for `pending → revoked` the "Admin of the org", with `terminal_by` = the admin's `usr_id`.
- **The text doesn't say which layer performs the check.** If no layer does, any caller holding an `inv_id` can revoke that invitation in any org, and is then recorded in `terminal_by` as the revoking admin.

**Precedent settles which layer is responsible.** `adminRemove(mem_id, admin_usr_id)`, which the same doc describes as "subject to authorization check", enforces its admin argument **inside the SDK** in all five families. Each looks up the caller's **active membership** in the target org and requires role `owner` or `admin`, raising `ForbiddenError` otherwise (fixture `admin_remove.member_attempts_remove.forbidden`). An `admin_usr_id` parameter exists to be checked.

Adopters also have legitimate automated revocations with no human admin: clean-up jobs, and cascades from their own workflows. If the SDK enforces the check and offers no system path, those adopters will pass a fake admin id to get past it, which defeats the check at the call site.

## Decision

### User path: `revokeInvitation(inv_id, admin_usr_id)`

1. The SDK MUST verify that `admin_usr_id` holds an **`active` membership** (membership status, which is what `adminRemove` checks) **in the invitation's own org** (`inv.org_id`), with role **`owner` or `admin`**. This is the same active-membership check `adminRemove` performs. Being an admin of **any other** org does not satisfy it.
2. **Order and atomicity (normative):** in one transaction the SDK MUST:
   1. load and lock the invitation row;
   2. authorize `admin_usr_id` against `inv.org_id`, **locking the acting membership row** (`SELECT … FOR SHARE`, or the in-memory equivalent), so a concurrent demotion or removal can't land between the check and the write;
   3. check that the invitation is `pending`;
   4. write the transition.

   Authorization comes **before** the `pending` check, so an unauthorized caller gets `ForbiddenError` whatever the invitation's state and can't use `InvitationNotPendingError` to learn it.

   **Accepted residual:** loading the invitation before authorizing means an unknown `inv_id` raises `NotFoundError` where a real one raises `ForbiddenError`, so an unauthorized caller can tell whether an id exists. That's accepted because invitation ids are UUIDv7 wire ids with at least 62 random bits (74 when the generator randomizes `rand_a`), so they can't be guessed. Authorizing against `inv.org_id` needs the row, so the order can't be reversed. Don't "fix" this by authorizing first.
3. **On authorization failure** the SDK raises **`ForbiddenError`**, and the invitation is unchanged.
4. **On success** the invitation transitions `pending → revoked`, with `terminal_at = now` and **`terminal_by = admin_usr_id`**. `terminal_by` only ever records an actor the SDK has verified.
5. For an **authorized** caller, a non-`pending` invitation raises `InvitationNotPendingError` (unchanged).

### System path: `revokeInvitationAsSystem(inv_id)`

6. It revokes a `pending` invitation with **no** actor: `terminal_at = now`, **`terminal_by = NULL`**. It performs no SDK authorization check.
7. **Adopters MUST gate the call site to server-side system or automation callers. It MUST NOT be reachable from any user-facing or tenant-scoped route.**
   - This is the same call-site gate pattern as `listUsers`/`listOrgs` (`docs/security.md`, the system-wide / cross-tenant enumeration reads entry).
   - The SDK can't enforce the gate, and **conformance can't catch a missing one**. The route-layer gate is the only control.
8. **It's a distinct operation, not a nullable `admin_usr_id`,** so that a route forwarding a missing or anonymous caller id (`null`) can never silently take the unchecked path, and so that every unchecked revocation is explicit and searchable in adopter code.
9. **Audit can tell the cases apart without a `reason` argument:** a system revoke is `status = revoked` with `terminal_by` NULL, and TTL expiry is `status = expired`.
10. **TTL expiry is unchanged:** `pending → expired`, performed by the system, with `terminal_by = NULL`, evaluated at query time or lazily transitioned (ADR 0003 §Expiration). Expired invitations need no revoke call.

### ADR 0003 §"Actors per transition": added row

| Transition | Actor | `inv.terminal_by` |
|---|---|---|
| `pending → revoked` (system) | System (`revokeInvitationAsSystem`) | NULL |

## Conformance

`tenancy/revoke-invitation-authz.json` asserts the user path:

- a **non-admin member** of the invitation's org calls `revokeInvitation` → `ForbiddenError`;
- an **admin of a different org** calls it → `ForbiddenError`;
- a caller who is **admin of org A but only a plain member of the invitation's org B** → `ForbiddenError` (this pins "the invitation's own org", not "any org the caller administers");
- an **owner** of the invitation's org calls it → revoked, `terminal_by` = owner (the known positive);
- an **admin** of the invitation's org calls it → revoked, `terminal_by` = admin;
- an admin whose **membership** in the invitation's org is **suspended** → `ForbiddenError` (only an active membership counts; the suspended *user* case is already stopped at authentication).

A follow-up adds the system-path vector: `revokeInvitationAsSystem` → revoked, `terminal_by` = NULL. The fixture format ends a test at the first expected error, so "the invitation is unchanged after a refusal" is normative but not yet fixture-expressible.

## Consequences

**Positive:**
- `terminal_by` can no longer be forged.
- Makes the ADR 0003 actor table true.

**Negative:**
- **A behaviour change:** `revokeInvitation` raises `ForbiddenError` for non-admins in SDKs that didn't check before. Release notes MUST say so, and MUST point automated callers at `revokeInvitationAsSystem`.
- One new operation across five SDK families.

## Rejected alternatives

- **The call site owns the check** (SDK unchanged). Rejected: it breaks the `adminRemove` precedent, and it leaves `terminal_by` writable by anyone holding an `inv_id`.
- **A nullable `admin_usr_id` means system.** Rejected: a route forwarding a missing caller id would become an unchecked revoke.
- **Only an `expireInvitation`-style operation.** Rejected as the sole path: automated revocation isn't always expiry, for example cascades from adopter workflows. `revokeInvitationAsSystem` covers both cases.

## References

- ADR 0003 (invitation state machine); ADR 0002 / `docs/tenancy.md` §"Admin-remove" (the precedent); `docs/tenancy.md` §"Invitations/Operations"; `docs/security.md` (the call-site gate pattern).
