# 0026 — Org suspension: who enforces it, and what it does to sessions and tokens

**Status:** Proposed
**Date:** 2026-11-22

## Context

`tenancy.md` says a `suspended` org's "access is paused", and an implementer can't follow it as
written. It has three gaps.

1. **Nothing denies.** Suspending an org leaves its memberships in their current status and keeps
   their `tup_` rows, so that reinstating needs no re-provisioning (`tenancy.md`, Lifecycle).
   `check()` reads tuples only (`authorization.md`), so it keeps returning `true` for every member
   of a suspended org. No normative rule says which layer turns "paused" into a denial.
   `sitesource/admin` found this in practice: a suspended org's users could still reach plugin
   code.
2. **The session rule contradicts identity.** `tenancy.md` says "All active sessions scoped to the
   org MUST be terminated". But sessions are bound to a user, not an org: "A user with memberships
   in multiple orgs uses the same session across all of them" (`identity.md`, Sessions are
   user-bound). No session is "scoped to the org" for that rule to end, and ending the user's
   sessions would log them out of every other org.
3. **Tokens aren't covered.** Personal access tokens ([ADR 0016](./0016-personal-access-tokens.md))
   are user-bound, with an adopter-defined `scope` that may name an org. Share tokens
   ([ADR 0012](./0012-share-tokens.md)) are bound to one object, which belongs to some org. The
   spec doesn't say what happens to either while the org is suspended.

**Why `check()` can't be the enforcement point.**
- **Objects are opaque to authorization.** A tuple's object is `(object_type, object_id)`, and the
  authorization capability has no map from an object to its org. Pattern B ("check org-level
  membership" via `project.parent_org`) is the application deriving the org, not the store.
- **Rewrite rules make it worse.** They derive grants on child objects through org tuples that
  suspension deliberately leaves in place. A `check()` that denied only on `object_type = org`
  would still grant `viewer` on every project that inherits from that org.
- **The cost of closing it there:** making `check()` complete would mean the authorization store
  learns every object's org. That would merge the tenancy and authorization capabilities, which
  the spec keeps separate.

## Decision

### 1. The enforcement point: a normative org-active precondition (MUST)

A new tenancy operation:

```
requireActiveOrg(org_id) → Organization
  // throws OrgSuspendedError (code: precondition.org_suspended)
  //        OrgRevokedError   (code: precondition.org_revoked)
  //        the not-found error getOrg raises, for an unknown org
```

**Every org-scoped operation MUST pass `requireActiveOrg` for each org it touches.** It runs before
`check()` and before any effect. That holds for every kind of bearer: a session, a PAT, a share
token, or none.

- **What "org-scoped" means:** an operation is org-scoped when any object it reads or changes
  belongs to an org.
- **Which org:** the org that owns the **target object**, as the application derives it (the same
  derivation as Pattern B), not only an org named in the path or the request. An operation that
  touches objects of several orgs passes the precondition for each one.
- **Share tokens and PATs:** a request that resolves to an object, such as a verified share
  (`verifyShareToken`) or a PAT acting on a resource, checks that **object's** org.
- **Not only requests:** queued jobs, scheduled tasks, webhook deliveries and event fan-out MUST
  pass `requireActiveOrg` **when they execute**, not only when they're created. Otherwise a job
  created before the suspension runs after it.
- **No existence oracle:** some callers would otherwise get a not-found for the object or org,
  such as a non-member or an unauthenticated caller. For them, the adopter MUST NOT expose
  `OrgSuspendedError` or `OrgRevokedError`, and MUST map both to that same not-found. The distinct
  codes are for callers who could already see that the org exists, such as its authenticated
  members.
- **`check()` is unchanged.** A `check()` that returns `true` for a member of a suspended org is
  conformant. `check()` answers "does this grant exist", and `requireActiveOrg` answers "is this
  org open". An org-scoped operation needs both.

**What this implies for the rejected option (a):** with (b), `check()` alone is never the lockout.
Every adopter call site that authorizes an org-scoped operation has two steps: the precondition,
then `check()`. Skipping the precondition is a conformance failure, just as skipping `check()` is.

### 2. Sessions: enforced per request, not terminated (MUST)

- **Replacing `tenancy.md`'s sentence:** "All active sessions scoped to the org MUST be terminated
  when the transition happens" is replaced. Suspending an org MUST NOT terminate the members'
  sessions, which are user-bound. Each org-scoped operation those sessions attempt fails §1's
  precondition instead.
- **Why:** sessions serve the user's other orgs, and ending them would lock the user out of orgs
  that aren't suspended. Enforcing per request gives the same denial in the suspended org, and
  takes effect from the next request.
- **Adopters that bind sessions to an org** (the MAY in `identity.md`) MAY also terminate those
  sessions on suspension. The precondition still applies.
- **`identity.md` needs no change.** Its user-bound model is what this decision relies on.

### 3. Tokens: refused per request, not revoked (MUST)

- **PATs (ADR 0016) and share tokens (ADR 0012) are not revoked on suspension.** Each org-scoped
  use of them fails §1's precondition while the org is suspended.
- **Why not revoke:**
  - revoking is irreversible for both, since a PAT has no un-revoke and is re-issued, and so is a
    share. That contradicts the reinstate-without-re-provisioning rule;
  - a PAT also serves its user's other orgs.
- **Reinstating the org restores them** with no action. Their own expiry keeps running during the
  suspension, and a single-use share that wasn't consumed stays unconsumed.
- **A revoked org** fails the precondition permanently, so its tokens can never act in it again.
  Adopters MAY also revoke them for hygiene. This ADR doesn't require it.
- **`verifyShareToken` and `verifyPatToken` are unchanged.** They verify the token. The
  precondition runs on the object the token resolves to (§1).

### 4. What is normative

- **MUST:**
  - `requireActiveOrg` and its two errors;
  - the precondition on every org-scoped operation, for each org it touches, at execution time,
    including jobs, schedules, webhooks and fan-out;
  - not-found mapping for callers who couldn't already see the org;
  - not terminating user-bound sessions;
  - not revoking PATs or shares on suspension.
- **MAY:**
  - terminating org-bound sessions;
  - revoking a revoked org's tokens.
- **Unchanged:** `check()`, `verifyShareToken`, `verifyPatToken`, membership and tuple handling on
  suspension, and the revoke transition.

## Consequences

- **Following the spec gives a total lockout per org.** No org-scoped operation runs in a suspended
  org, whoever the bearer is and whenever the work was queued.
- **Reinstating is instant and lossless.** Members, grants, sessions, PATs and shares all work again
  on the next request.
- **Every org-scoped call site has one more line** (`requireActiveOrg`) and one more lookup, which
  an adopter MAY cache per request. A cache MUST NOT outlive the request or the job execution.
- **The cost moves to adopters:** an adopter that skips the precondition at one call site reopens
  the gap there. The conformance tests below make that visible.

## Conformance tests to add (a follow-up ticket; not written here)

- **Suspended member denied:** an org with an active `mem_` and its `tup_`. After `suspendOrg`:
  - `requireActiveOrg` throws `OrgSuspendedError`;
  - `check(member, role, org)` still returns `true`.
- **Reinstate restores:** after `reinstateOrg`, `requireActiveOrg` returns the org, with no
  membership or tuple re-created.
- **Revoked:** after `revokeOrg`, `requireActiveOrg` throws `OrgRevokedError`.
- **Unknown org:** throws the same not-found error as `getOrg`.
- **Sessions survive:** after `suspendOrg`, the member's session is not revoked (`revoked_at` is
  null), and so is a session of a user who belongs only to that org.
- **Tokens survive:** after `suspendOrg`, the member's PAT and a share on an object of that org
  verify. After `reinstateOrg` they still verify. The share's expiry is unchanged.
- **Execution time, not enqueue time:** a job created while the org is active, and executed after
  `suspendOrg`, is refused by `requireActiveOrg` when it executes.

## Out of scope / Deferred

- **User suspension.** It's covered by `identity.md` and isn't changed here.
- **Billing, and the reasons for suspending.**
- **A store-level object-to-org map** that would let `check()` enforce suspension. It's rejected
  below, and could only return as its own ADR.
- **Writing the conformance fixtures** above, which is a follow-up ticket.

## Alternatives considered

- **(a) `check()` MUST deny when the object's org isn't active.** Rejected. `check()` can't know an
  object's org, and rewrite rules derive grants through the org tuples that suspension keeps
  (Context). It would be complete only if the authorization store held every object's org.
- **Delete the tuples on org suspension**, as membership suspension does. Rejected: reinstating
  would then need re-provisioning, which `tenancy.md` rules out.
- **Terminate every member's sessions.** Rejected: sessions are user-bound, and this would lock
  members out of their other orgs (§2).
- **Revoke PATs and shares on suspension.** Rejected: it's irreversible, and it breaks lossless
  reinstate (§3).

## References

- `docs/tenancy.md`: Organizations, Lifecycle.
- `docs/identity.md`: Sessions are user-bound.
- `docs/authorization.md`: the `check()` primitive; Pattern B; rewrite rules.
- [ADR 0012](./0012-share-tokens.md), [ADR 0016](./0016-personal-access-tokens.md),
  [ADR 0007](./0007-authorization-rewrite-rules.md).

## Filed by

`sitesource/admin` (ticket 17tvpau6ddx), from admin's suspended-org finding (17tvpau6db9). The
admin-security co-sign is in the PR.
