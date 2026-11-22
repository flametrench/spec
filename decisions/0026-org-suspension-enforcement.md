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

**Errors and the wire.**
- **Taxonomy:** both are subclasses of the cross-capability `PreconditionError`, as ADR 0009's
  `precondition.*` errors are, so an existing `except PreconditionError` catches them. They are
  state preconditions, not input-format errors (ADR 0019 and 0024's split), and there is no new
  error family. Go exposes them through `IsPrecondition`, per ADR 0021's idiom mapping.
- **HTTP:**
  - **403,** with the `code` discriminator, for a caller who could already see the org (its
    authenticated members).
  - **The adopter's not-found (404)** for everyone else (§1, "No existence oracle").
  - **Why 403 and not 409:** the spec's other `precondition.*` codes use 409 because the caller
    can fix the conflict in the request. Here nothing in the request can fix it: the org is
    closed, so the caller is refused.

**Every org-scoped operation MUST pass `requireActiveOrg` for each org it touches.** It runs before
`check()` and before any effect. That holds for every kind of bearer: a session, a PAT, a share
token, or none.

- **What "org-scoped" means:** an operation is org-scoped when any object it reads or changes
  belongs to an org.
- **Exempt: operator work on the org itself.** These tenancy operations don't need the
  precondition when an admin or system caller makes them, gated the way ADR 0025 gates
  `listOrgs`:
  - `getOrg`, `updateOrg`, `suspendOrg`, `reinstateOrg`, `revokeOrg`, `listOrgs` and
    `requireActiveOrg`;
  - operator tooling that reads a suspended org's memberships, invitations or audit for support.

  Without this exemption, `reinstateOrg` would be impossible, and so would
  `openapi/flametrench-v0.2-additions.yaml`'s "Suspended orgs MAY be updated". **The exemption is
  for the operator, not for the org's members.** A route that exposes one of these operations to
  the org's own members or bearers (an owner renaming their org, say) is org-scoped and MUST pass
  the precondition, so a suspended org's owner can't act in it either.
- **Which org:** the org that owns the **target object**, as the application derives it (the same
  derivation as Pattern B), not only an org named in the path or the request. An operation that
  touches objects of several orgs passes the precondition for each one.
- **Share tokens and PATs:** a request that resolves to an object, such as a verified share
  (`verifyShareToken`) or a PAT acting on a resource, checks that **object's** org.
- **Not only requests:** queued jobs, scheduled tasks, webhook deliveries and event fan-out MUST
  pass `requireActiveOrg` **when they execute**, not only when they're created. Otherwise a job
  created before the suspension runs after it.
- **Long-running work:** a stream, a websocket or a long job MUST re-check before each org-scoped
  step, not only at its start. A cached result MUST NOT outlive one request, one job execution,
  or one step of a long-running one.
- **No existence oracle:** some callers would otherwise get a not-found for the object or org,
  such as a non-member or an unauthenticated caller. For them, the adopter MUST NOT expose
  `OrgSuspendedError` or `OrgRevokedError`, and MUST map both to that same not-found. The distinct
  codes are for callers who could already see that the org exists, such as its authenticated
  members.
  - **How the adopter decides:** when `requireActiveOrg` throws, the adopter chooses between 403
    and not-found through its normal visibility path, the same membership or `check()` it would
    use to decide not-found for that caller and object.
  - **What it must not do:** return 403 to every caller. That would turn the code into an
    org-status oracle for any object id.
- **The tenancy store refuses grant-creating changes in a suspended or revoked org (MUST).**
  - **The operations:** `addMember`, `createInvitation`, `acceptInvitation`, `changeRole`,
    `transferOwnership` and `reinstateMembership`.
  - **What they raise:** `OrgSuspendedError` or `OrgRevokedError` at the SDK level, before any
    write, whoever calls them, an operator included.
  - **Why the store and not only the call site:** each of these creates or moves an org grant, and
    the store already holds the org's status. So refusing there couples no capabilities, and it
    holds even at a call site that forgot the precondition.
  - **Still allowed:** removals (`selfLeave`, `adminRemove`, `suspendMembership`,
    `revokeInvitation` and `declineInvitation`), which only reduce access. A member-facing route to
    them is still org-scoped (above), so in practice an operator makes them.
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
- **`identity.md`'s MAY is unaffected.** It lets an application enforce org-bound sessions by
  gating each cross-org request with `check()` against the current org. An adopter that also
  keeps a session it binds to one org MAY terminate that session on suspension. The precondition
  still applies either way.
- **`identity.md` needs no change.** Its user-bound model is what this decision relies on.

### 3. Tokens: refused per request, not revoked (MUST)

- **PATs (ADR 0016) and share tokens (ADR 0012) are not revoked on suspension.** Each org-scoped
  use of them fails §1's precondition while the org is suspended.
- **Why not revoke:**
  - revoking is irreversible for both, since a PAT has no un-revoke and is re-issued, and so is a
    share. That contradicts the reinstate-without-re-provisioning rule;
  - a PAT also serves its user's other orgs.
- **Reinstating the org restores them** with no action. Their own expiry keeps running during the
  suspension.
- **Single-use shares presented during the suspension are consumed and refused.**
  `verifyShareToken` sets `consumed_at` on the first successful verify (`shares.md`, verify
  steps 5 and 7), and only after that does the adopter learn the share's object, and so its org.
  - So a single-use share presented while the org is suspended is consumed, the precondition then
    refuses the request, and reinstating does **not** restore that share.
  - This is the one effect allowed before the precondition. It changes only the token's own state
    and grants nothing.
  - A single-use share that isn't presented during the suspension stays unconsumed, and works after
    reinstating.
  - Reordering this would need a non-consuming resolve in `shares.md`. That is deferred (below),
    because this ADR doesn't change ADR 0012's verify contract.
- **A revoked org** fails the precondition permanently, so its tokens can never act in it again.
  Adopters MAY also revoke them for hygiene. This ADR doesn't require it.
- **`verifyShareToken` and `verifyPatToken` are unchanged.** They verify the token. The
  precondition runs on the object the token resolves to (§1).

### 4. What is normative

- **MUST, SDK-level (the conformance fixtures gate these):**
  - `requireActiveOrg` and its two errors, both `PreconditionError` subclasses;
  - the tenancy store refusing grant-creating changes in a suspended or revoked org (§1);
  - `suspendOrg` not terminating sessions or revoking PATs or shares;
  - the operator operations (§1) succeeding on a suspended org.
- **MUST, adopter obligations (no SDK fixture can gate these; like the `listOrgs` gate in
  `security.md`, the call site is the only control):**
  1. the precondition on every org-scoped operation, for each org it touches, using the target
     object's org;
  2. at execution time, for jobs, schedules, webhooks and fan-out, and before each step of
     long-running work;
  3. 403 to callers who could already see the org, and not-found to everyone else, decided
     through the normal visibility path;
  4. the precondition on member-facing routes to the operator operations;
  5. a cached result that doesn't outlive one request, job execution or step.
- **MAY:**
  - terminating org-bound sessions;
  - revoking a revoked org's tokens.
- **Unchanged:** `check()`, `verifyShareToken`, `verifyPatToken`, the org's memberships and tuples
  on suspension (both are kept), and the revoke transition.

## Consequences

- **Following the spec gives a total lockout per org.** No org-scoped operation runs in a suspended
  org, whoever the bearer is and whenever the work was queued.
- **Reinstating is instant and lossless,** except for a single-use share presented during the
  suspension, which stays consumed (§3). Members, grants, sessions, PATs and every other share
  work again on the next request.
- **Every org-scoped call site has one more line** (`requireActiveOrg`) and one more lookup, which
  an adopter MAY cache within §1's bound.
- **The cost moves to adopters:** an adopter that skips the precondition at one call site reopens
  the gap there. **Conformance can't catch a missing adopter check.** The fixtures test the SDK's
  `requireActiveOrg` and the store's refusals, not the adopter's call sites, the same as the
  `listOrgs` gate (`security.md`). The call site is the only control for §4's adopter
  obligations.

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
- **Tokens survive:** after `suspendOrg`, the member's PAT and a multi-use share on an object of
  that org verify. After `reinstateOrg` they still verify. The share's expiry is unchanged.
- **Single-use share during the suspension:** presented after `suspendOrg`, it verifies, which
  consumes it, and the request is refused by `requireActiveOrg`. After `reinstateOrg` it raises
  `ShareConsumedError`. A single-use share not presented during the suspension verifies after
  `reinstateOrg`.
- **Operator exemption:** `reinstateOrg` and `updateOrg` succeed on a suspended org from a
  system caller, without the precondition.
- **Errors:** `OrgSuspendedError` and `OrgRevokedError` are `PreconditionError`s.
- **Store refuses grant changes:** on a suspended org, each of `addMember`, `createInvitation`,
  `acceptInvitation`, `changeRole`, `transferOwnership` and `reinstateMembership` raises
  `OrgSuspendedError` and writes nothing. On a revoked org they raise `OrgRevokedError`. After
  `reinstateOrg`, `addMember` succeeds.

**Notes for whoever writes the fixtures:**
- Harnesses end a test at the first expected-error step. So "suspend → throws", "`check()` still
  true" and "reinstate → passes" are separate tests.
- `Expected` has only `error` and `error_matches`, so the fixtures assert the class names. The
  `code` values (`precondition.org_suspended`, `precondition.org_revoked`) can't be asserted until
  the format can.
- §4's adopter obligations, including execution time for jobs, have no fixture. A fixture of
  "`suspendOrg`, then `requireActiveOrg`" would pass while an adopter runs the job anyway. An
  adopter proves them in its own tests.

## Out of scope / Deferred

- **ADR 0002:73's "sessions scoped to the org terminated"** for `selfLeave`. It is the same
  contradiction with `identity.md` that §2 fixes. This ADR corrects the normative chapter
  (`tenancy.md`'s `selfLeave` and `adminRemove`), and `tenancy.md` governs. Amending ADR 0002's
  rationale text is left to a later edit.
- **User suspension.** It's covered by `identity.md` and isn't changed here.
- **Billing, and the reasons for suspending.**
- **A store-level object-to-org map** that would let `check()` enforce suspension. It's rejected
  below, and could only return as its own ADR.
- **Writing the conformance fixtures** above, which is a follow-up ticket.
- **A non-consuming share resolve** (for example, `verifyShareToken(token, consume: false)` plus
  an atomic `consumeShare`), so the precondition can run before a single-use share is consumed. It
  would amend ADR 0012 and `shares.md`.

## Alternatives considered

- **(a) `check()` MUST deny when the object's org isn't active.** Rejected. `check()` can't know an
  object's org, and rewrite rules derive grants through the org tuples that suspension keeps
  (Context). It would be complete only if the authorization store held every object's org.
- **Delete the org's role tuples on suspension, instead of a precondition.** Rejected as the
  enforcement point, because of **coverage**:
  - it can't reach direct object grants, share tokens or PATs, so a precondition would be needed
    anyway;
  - recreating the role tuples from the unchanged `active` `mem_` rows on reinstate would **not**
    be re-provisioning (membership suspend and reinstate already work that way). The previous
    draft's "re-provisioning" reason was wrong.
- **Terminate every member's sessions.** Rejected: sessions are user-bound, and this would lock
  members out of their other orgs (§2).
- **Revoke PATs and shares on suspension.** Rejected: it's irreversible, and it breaks lossless
  reinstate (§3) for every token, not only a single-use share presented during the suspension.

## References

- `docs/tenancy.md`: Organizations, Lifecycle.
- `docs/identity.md`: Sessions are user-bound.
- `docs/authorization.md`: the `check()` primitive; Pattern B; rewrite rules.
- [ADR 0012](./0012-share-tokens.md), [ADR 0016](./0016-personal-access-tokens.md),
  [ADR 0007](./0007-authorization-rewrite-rules.md).

## Filed by

`sitesource/admin`, after it found that a suspended org's users could still reach plugin code.
The admin-security co-sign is in the PR.
