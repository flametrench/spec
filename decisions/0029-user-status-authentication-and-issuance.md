# 0029 — User status gates authentication and issuance, at verify and issue time

**Status:** Accepted
**Date:** 2026-11-22
**Deciders:** Flametrench stewards
**Clarifies:** `docs/identity.md` §Lifecycle (`suspended`: "user cannot authenticate"). **Adds:** the issuance rule for suspended users. **Pins:** refusal error names. **Resolves:** `docs/shares.md` §createShare's suspended-creator SHOULD.

## Context

**Most of this is already accepted text:**
- `docs/identity.md` §Lifecycle says a `suspended` user "cannot authenticate", and that `revoked` is terminal.
- ADR 0004 defines suspension as reversible.
- ADR 0016 requires `createPat` for a non-revoked user, and requires PATs to auto-revoke with their owner.
- `docs/shares.md` requires a non-revoked `created_by`.

This ADR adds only what accepted text lacks:
1. **The rule as one RFC 2119 MUST**, covering every operation that authenticates. Today it's plain prose on one status definition.
2. **Issuance to a *suspended* user.** `docs/identity.md` covers authenticating, not minting things that authenticate later. ADR 0016 and `shares.md` cover *revoked* only; `shares.md` makes suspended a SHOULD.
3. **Error names** for each refusal. Accepted text says *that* these are refused but rarely *with what*. The conformance fixtures currently carry these names marked PROVISIONAL, and this ADR pins them.

## Decision

### The rule (normative)

> **No operation that authenticates a principal, and no operation that issues something that will later authenticate one, may succeed for a user whose `status` is not `active`.**

- The rule is evaluated **at verify and issue time, against the user's current status.**
  - Suspension is reversible (ADR 0004), so it can't be enforced only by cascading revocation.
  - A reinstated user's existing, unexpired PATs and credentials work again.
- **Revocation still cascades as already specified.** A revoked user's sessions are terminated, credentials revoked and PATs auto-revoked. The verify-time check is defence in depth, not a replacement.

### Operations covered, and the pinned refusal errors

| Operation | Non-`active` user → | Why this error |
|---|---|---|
| `verifyPassword` | `InvalidCredentialError` | The existing named failure of `verifyPassword`, conflated so it's no status oracle. **The status check MUST NOT short-circuit the Argon2id verify:** check status only after a successful verify, or run the verify regardless. An early return for a non-active user is a timing oracle (CWE-208) that reveals the account's status to anyone who knows the identifier. |
| `createSession`, including with `mfa_proof` | `PreconditionError` | A state precondition on issuance. Existing SDK precedent (Node, Python, PHP, Java). **Check order is normative:** user status is checked **before** credential status, so a non-active user always gets `PreconditionError`, even when the credential was revoked by the user-revocation cascade. |
| `refreshSession` | `PreconditionError` | Issuance of a new session. |
| `verifySessionToken` | `InvalidTokenError` | Sessions of suspended or revoked users MUST already be terminated on the transition. This is the verify-time backstop, conflated with any other invalid token. |
| `verifyMfa` | `InvalidCredentialError` | An authentication path, so it's conflated with proof failure (a distinct error would be a status oracle). Status is evaluated **after** proof verification but inside the same transaction, so a refusal rolls back any recovery-slot, TOTP-step or counter consumption. |
| `verifyMfaForSession` | (per ADR 0030) | Already refused by its active-session and active-user requirement. |
| `verifyPatToken` (owner **suspended**) | `InvalidPatTokenError` | Conflated. Its position in the step order is set below. |
| `verifyPatToken` (owner **revoked**) | `PatRevokedError` if the PAT row is revoked; **`InvalidPatTokenError`** if the row isn't | The row is normally revoked with its owner (ADR 0016). The verify-time check MUST refuse **any non-active owner whatever the PAT row's own state**, which covers rows whose owner was revoked before the cascade was implemented. |
| `createPat` | `PreconditionError` | ADR 0016 already covers revoked; this adds suspended. Existing SDK precedent (PHP). |
| `createShare` (`created_by`) | `PreconditionError` | `shares.md` already covers revoked; **suspended moves from SHOULD to MUST.** Existing precedent (Node/Python/PHP/Java Postgres). |

Share **verification** (`verifyShareToken`) authenticates no user principal; share tokens grant bearer access without one (ADR 0012). The creator's later status doesn't retroactively affect an issued share, because revocation of shares is its own operation. That's unchanged and out of scope here.

### Where the owner-status check sits in `verifyPatToken`

ADR 0016 fixes the order: format → look up the row → revoked → expired → Argon2id secret check. The owner-status check MUST run **after the secret check, as step 6½, and before the `last_used_at` update.**

- Only a holder of the **full, valid token** learns that its owner is suspended (as `InvalidPatTokenError`, indistinguishable from a wrong secret). Someone holding only the non-secret token id (the prefix) learns nothing new.
- Refused tokens don't record a misleading `last_used_at`.
- Cost: suspended owners' tokens pay the Argon2id verify, as every token already does.

## Consequences

**Positive:**
- One rule, checked at use time, covering every authentication and issuance path.
- Suspension becomes a real, reversible off switch.
- The fixtures' provisional error names become pinned text.

**Negative:**
- **Behaviour changes**, for SDKs that didn't already enforce them:
  - suspended users stop authenticating by any path;
  - suspended users can no longer mint PATs or shares;
  - callers that create shares for suspended users (a SHOULD before) start failing.

  Release notes MUST list these changes.

**Users already non-active when an SDK adopts this ADR (release notes, not spec text):**
- An owner revoked before the PAT cascade was implemented may still have **unrevoked PAT rows**. The verify-time check above covers them.
- A session issued to a user after their suspension is covered by `verifySessionToken`'s status check.
- **Recommended one-time clean-up**, stated in the release notes: revoke the PATs and sessions of every currently non-active user.

**Shares are not revoked by user revocation.** Existing shares created by a user who is later revoked or suspended keep working until they expire or are revoked (ADR 0012 bearer semantics). This ADR gates share *creation* only. Adopters who need a user's shares gone on offboarding MUST revoke them explicitly.

**Conformance:** `identity/user-status-gates.json` and `authorization/shares/created-by-status.json` assert the accepted-text arms. A follow-up un-marks their PROVISIONAL error names and adds:
- suspended-user `createPat`/`createShare` refusals;
- `refreshSession`, `verifySessionToken` and `verifyMfa` arms;
- a reinstate-and-succeed arm for each.

## Rejected alternatives

- **Enforce suspension by revoking tokens and sessions on suspend.** Rejected: suspension is reversible, and revoking would make reinstate a re-provisioning event (ADR 0004).
- **A distinct `UserNotActiveError` for every operation.** Rejected: on the authentication paths (`verifyPassword`, `verifyMfa`, `verifySessionToken`, `verifyPatToken`) it would be a status oracle, so those conflate with their existing failure error. `PreconditionError` is used only on **issuance** (`createSession`, `refreshSession`, `createPat`, `createShare`), where the caller is already authenticated or is system code. It's no oracle for an outsider there, and it matches the house split (a state precondition, not an input-format error).
- **The owner-status check before the secret check (step 4½) in `verifyPatToken`.** Rejected: it is cheaper, but a prefix holder would learn that the owner is suspended, extending ADR 0016's documented revoked/expired disclosure to user status.

## References

- `docs/identity.md` §Lifecycle, §Sessions, §"Personal access tokens"; ADR 0004 (reversible suspension); ADR 0016 §Constraints, §"Verification semantics"; ADR 0012 / `docs/shares.md` §createShare.
- Fixtures: `identity/user-status-gates.json`, `authorization/shares/created-by-status.json`.
