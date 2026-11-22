# 0026 — Org suspension: a tuple pause plus a request precondition, and what it does to sessions and tokens

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

**Why `check()` can't be the whole enforcement point.**
- **Objects are opaque to authorization.** A tuple's object is `(object_type, object_id)`, and the
  authorization capability has no map from an object to its org. Pattern B ("check org-level
  membership" via `project.parent_org`) is the application deriving the org, not the store.
- **Rewrite rules make it worse.** They derive grants on child objects through org tuples, which
  today's suspension leaves in place. A `check()` that denied only on `object_type = org`
  would still grant `viewer` on every project that inherits from that org.
- **The cost of closing it there:** making `check()` complete would mean the authorization store
  learns every object's org. That would merge the tenancy and authorization capabilities, which
  the spec keeps separate.

## Decision

### 0. Two layers (owner's decision)

Org suspension is enforced in two layers. Both are MUST:
- **The tuple pause (§1a).** It runs inside the tenancy store, so `check()` denies every
  membership-derived and rewrite-derived grant in a suspended org, even at a call site that forgot
  the precondition. This is the fail-closed layer.
- **The precondition (§1).** It covers what the tuple pause can't reach: direct object grants,
  share tokens, PATs, and work with no `check()` at all.

Neither layer alone is complete. Context explains why `check()` can't see an object's org, and the
pause can't reach grants that aren't membership role tuples.

### 1. The precondition: `requireActiveOrg` (MUST)

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
  - **What they raise:** `OrgSuspendedError` on a suspended org, and `OrgRevokedError` on a revoked
    one unless an existing error already applies. They raise at the SDK level, before any write,
    whoever calls them, an operator included.
  - **Why the store and not only the call site:** each of these creates or moves an org grant, and
    the store already holds the org's status. So refusing there couples no capabilities, and it
    holds even at a call site that forgot the precondition.
  - **Still allowed:** removals (`selfLeave`, `adminRemove`, `suspendMembership`,
    `revokeInvitation` and `declineInvitation`), which only reduce access. A member-facing route to
    them is still org-scoped (above), so in practice an operator makes them.
  - **Except `selfLeave` with `transferTo`:** a sole owner's leave performs an ownership transfer,
    so it is refused like `transferOwnership`, with `OrgSuspendedError` and no write. To leave, the
    operator reinstates the org first. A `selfLeave` that needs no transfer is still allowed.
- **`check()` the operation is unchanged.** With §1a's pause, it denies membership-derived grants in
  a suspended org. It can still return `true` for a direct object grant in that org, which is why
  §1 is needed too. `check()` answers "does this grant exist", and `requireActiveOrg` answers "is
  this org open". An org-scoped operation needs both.

**What this implies for the rejected option (a):** `check()` alone is never the whole lockout. Every
adopter call site that authorizes an org-scoped operation has two steps: the precondition, then
`check()`. A call site that skips the precondition still gets §1a's denial for membership-derived
grants, but not for direct grants, shares or PATs.

### 1a. The tuple pause (MUST)

- **`suspendOrg`:** in the same transaction as the status change, it deletes the membership role
  tuple `(usr, <role>, org, <org_id>)` of every `active` membership of the org. The `mem_` rows
  stay `active` and unchanged.
- **`reinstateOrg`:** in the same transaction, it re-creates that tuple for every membership that
  is `active` at reinstate time, from its unchanged `mem_` row (`relation = mem.role`). Suspended
  and revoked memberships get no tuple, whether they were suspended before or during the org's
  suspension. The re-created tuples are new `tup_` rows, and nothing in the spec references a
  membership tuple's id. This is the same as membership reinstate, and nothing is re-provisioned.
- **Invariant:** while an org is `suspended`, none of its membership role tuples exist.
- **Removals during the suspension find no tuple.** `selfLeave`, `adminRemove`,
  `suspendMembership` and `revokeOrg` on a suspended org update the `mem_` row as usual. Deleting a
  membership role tuple that isn't there is a no-op, never an error.
- **`reinstateOrg`'s tuple re-creation creates no duplicate tuple.** It creates a membership's role
  tuple only when an identical `(usr, mem.role, org, org_id)` tuple doesn't already exist. This
  ADR adds no lifecycle rule for calling `reinstateOrg` on an org that is already `active`. That
  stays whatever the lifecycle already says.
- **Orgs suspended before a store adopts this ADR** still have their membership role tuples. The
  store's upgrade MUST reconcile them before it serves `check()` under this ADR. For each org whose
  status is `suspended`, it deletes the role tuples of that org's `active` memberships, in one
  migration step, the same deletion `suspendOrg` makes. After that, `reinstateOrg` restores them as
  usual.
- **Atomicity:** a store operation that would create a membership role tuple reads the org's status
  and writes the tuple atomically with respect to `suspendOrg`, for example by locking the org row.
  Otherwise a concurrent `addMember` could leave a tuple behind.
- **What `check()` then does:** with no tuples changed beyond these, `check(member, role, org)` is
  `false` while the org is suspended, and so is every grant a rewrite rule derives through those
  org tuples. Both are `true` again after reinstating.
- **What it doesn't touch:** direct object tuples (for example an invitation's `pre_tuples`,
  `editor` on a project) and tuples of other subjects stay in place. The precondition covers them.
- **The membership-as-tuple duality has one exception:** while its org is suspended, an `active`
  membership has no `tup_` row. `tenancy.md` says so.
- **Adopters MUST write org membership role tuples (the `owner`, `admin`, `member` and `guest`
  relations on `org`) only through tenancy operations,** never with a direct authz `createTuple`.
  This states the premise ADR 0002's duality already relies on. A direct write would survive the pause, or re-grant during it.
  This is an adopter obligation (§4).
- **`revokeOrg`** is unchanged. It transitions memberships to `revoked`, which deletes their tuples
  if any are still present.

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
  - the tuple pause: `suspendOrg` deletes the org's membership role tuples, and `reinstateOrg`
    re-creates them for memberships still `active` (§1a);
  - the tenancy store refusing grant-creating changes in a suspended or revoked org, including a
    `selfLeave` with `transferTo` (§1);
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
  5. a cached result that doesn't outlive one request, job execution or step;
  6. writing org membership role tuples only through tenancy operations (§1a).
- **MAY:**
  - terminating org-bound sessions;
  - revoking a revoked org's tokens.
- **Unchanged:** the `check()` operation, `verifyShareToken`, `verifyPatToken`, the org's `mem_`
  rows on suspension (they stay `active`), and the revoke transition.

## Consequences

- **Following the spec gives a total lockout per org.** No org-scoped operation runs in a suspended
  org, whoever the bearer is and whenever the work was queued.
- **`suspendOrg` and `reinstateOrg` become O(active members) writes** in one transaction.
- **Behaviour change for existing stores:** suspending an org now changes what `check()` returns,
  and membership changes on a suspended org are refused.
- **A forgotten call site fails closed for membership grants.** Because of §1a, an adopter that
  skips the precondition still gets `check()` denying membership-derived and rewrite-derived
  grants. What stays open at such a call site is direct grants, shares and PATs.
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
  - `check(member, role, org)` returns `false`, and the `mem_` row is still `active`;
  - with a rewrite rule granting `viewer` on a project through the org, `check(member, viewer,
    project)` returns `false`;
  - a direct tuple `(member, editor, project)` still makes `check` return `true` (the precondition
    covers it).
- **Reinstate restores:** after `reinstateOrg`, `requireActiveOrg` returns the org,
  `check(member, role, org)` and the rewrite-derived `check` return `true`, and the `mem_` id is
  unchanged (no membership re-created).
- **Removed during suspension:** a member `selfLeave`s while the org is suspended, and it succeeds
  with no error (the absent tuple's delete is a no-op). After `reinstateOrg`, their membership is
  `revoked` and has no tuple.
- **No duplicate tuple:** reinstating an org where a member's role tuple already exists, for
  example one written before the suspension and not yet reconciled, leaves exactly one role tuple
  per `active` membership.
- **Upgrade reconciliation is not a conformance fixture.** The fixture format can't express a
  store's pre-ADR state or its upgrade step. The MUST stands, and each SDK proves it in its own
  migration tests: an org stored as `suspended` with its membership role tuples present has none
  after the upgrade step, and `check(member, role, org)` is `false` until `reinstateOrg`.
- **Suspended before:** a membership suspended before the org is suspended still has no tuple
  after `reinstateOrg`.
- **No write on refusal:** `addMember` on a suspended org raises `OrgSuspendedError` and creates
  neither a `mem_` nor a `tup_`.
- **Sole owner can't transfer while suspended:** a sole owner's `selfLeave(mem, transferTo)` raises
  `OrgSuspendedError` and writes nothing. After `reinstateOrg`, it succeeds.
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
- Harnesses end a test at the first expected-error step. So "suspend → throws", "`check()` false
  while suspended" and "reinstate → passes" are separate tests.
- `Expected` has only `error` and `error_matches`, so the fixtures assert the class names. The
  `code` values (`precondition.org_suspended`, `precondition.org_revoked`) can't be asserted until
  the format can.
- §4's adopter obligations, including execution time for jobs, have no fixture. A fixture of
  "`suspendOrg`, then `requireActiveOrg`" would pass while an adopter runs the job anyway. An
  adopter proves them in its own tests.

## Out of scope / Deferred

- **ADR 0002's text, in a separate edit.** `tenancy.md` governs, and this ADR corrects it. The edit
  is left out because this ADR's ticket is scoped to `tenancy.md` and `identity.md`. Two passages
  need it:
  - **ADR 0002:73,** "sessions scoped to the org terminated" for `selfLeave`. It is the same
    contradiction with `identity.md` that §2 fixes, and Flametrench Spec asked for the same
    one-line change there.
  - **ADR 0002:36-41,** the membership-as-tuple duality: "Every active membership is represented
    as BOTH…" and "The two cannot diverge". It needs §1a's exception: while the org is suspended,
    an active membership has no `tup_` row.
- **User suspension.** It's covered by `identity.md` and isn't changed here.
- **Billing, and the reasons for suspending.**
- **A store-level object-to-org map** that would let `check()` enforce suspension for direct
  grants too. It's rejected below, and could only return as its own ADR.
- **Writing the conformance fixtures** above, which is a follow-up ticket.
- **A non-consuming share resolve** (for example, `verifyShareToken(token, consume: false)` plus
  an atomic `consumeShare`), so the precondition can run before a single-use share is consumed. It
  would amend ADR 0012 and `shares.md`.

## Alternatives considered

- **(a) `check()` MUST deny when the object's org isn't active.** Rejected. `check()` can't know an
  object's org (Context). It would be complete only if the authorization store held every object's
  org. §1a gets the fail-closed part of (a) for membership grants without that coupling.
- **The tuple pause alone, with no precondition.** Rejected, because of **coverage**: it can't reach
  direct object grants, share tokens or PATs. (Re-creating role tuples from `active` `mem_` rows
  on reinstate is not re-provisioning. An earlier draft wrongly gave that as a reason to reject
  pausing tuples.)
- **The precondition alone, with no tuple pause.** Rejected by the owner: a forgotten call site
  would grant full access in a suspended org, and a missed call site is how the gap was found.
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
