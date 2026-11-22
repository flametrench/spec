# 0030 — Session-bound MFA freshness (amends ADR 0008)

**Status:** Accepted
**Date:** 2026-11-22
**Deciders:** Flametrench stewards
**Supersedes (in part):** ADR 0008 §"Session lifecycle changes" (the `createSession({ requireMfaWithin })` sentence, and the "spec floor" wording). `docs/identity.md` §"Sessions and MFA freshness" and §Sessions/Operations are updated to match.

## Context

ADR 0008 pins **what** MFA freshness is:
- a session carries `mfa_verified_at`;
- sensitive operations gate on `session.mfa_verified_at IS NOT NULL AND now() - session.mfa_verified_at < window`;
- `refreshSession` does **not** carry it forward.

**It never defines how a verification reaches a session.**
- `verifyMfa(usrId, proof)` "does NOT issue a session", and the flow `verifyPassword → verifyMfa → createSession` is "three steps the application sequences".
- `createSession(usr_id, cred_id, ttl)` has no MFA input.
- The one hook the ADR names, `createSession({ …, requireMfaWithin })`, has no defined meaning. A brand-new session has no MFA history, so its natural reading is "this **user** verified MFA within N seconds". That is **user-bound** freshness: a stolen session would inherit MFA the victim performed in another session. It's the design the session-bound `mfa_verified_at` field exists to prevent.

Without a defined path, adopters building step-up themselves are pushed toward the unsafe user-bound design. This amendment's constraints: freshness is bound to the session id, reset on refresh, and verification and stamping are atomic.

## Decision

### 1. `mfa_verified_at` is written only by operations that verify a proof *for a specific session*, atomically

Two operations bind an MFA verification to a session. **They are the only ways `ses.mfa_verified_at` is ever set:**

- **`createSession(usr_id, cred_id, ttl, *, mfa_proof?) → Session, token`**. When `mfa_proof` is supplied, the SDK verifies it against `usr_id`'s active factors (the same semantics as `verifyMfa`, including replay protection, the WebAuthn counter and recovery-slot consumption). It creates the session with `mfa_verified_at = now()`, **in one transaction**. If verification fails, no session is created, and the error is the same one `verifyMfa` would raise. Without `mfa_proof`, the session is created with `mfa_verified_at = NULL`, as today.
- **`verifyMfaForSession(ses_id, mfa_proof) → { session, token }`** (step-up). In one transaction, the SDK MUST:
  1. lock the session row (`SELECT … FOR UPDATE`);
  2. require it to be active: not revoked, not expired, and its user `active` (`docs/identity.md` §Lifecycle);
  3. verify `mfa_proof` against **the session's own `usr_id`**;
  4. **rotate the session:** create a **new** session and token for that user with `mfa_verified_at = now()`, and revoke the old session (§6).

  If any step fails, no state changes. The proof is always checked against the user who owns the session, never against a caller-supplied user id.

**The proof is passed in, not a verification result.** An `MfaVerifyResult` is an ordinary value that application code could construct or reuse. Taking the raw proof keeps "verified" and "stamped on this session" one atomic step that the SDK controls.

`verifyMfa(usr_id, proof)` stays as a stand-alone check, for example to confirm a factor before a sensitive, session-less operation. **It never touches any session.** Its result's `mfaVerifiedAt` is the time of that verification and is **not** stamped anywhere. SDK doc comments that say otherwise MUST be corrected.

### 2. Freshness is checked at use time, on the session: `requireMfaWithin` moves from `createSession` to session verification

- The `createSession({ …, requireMfaWithin })` option is **removed**. It has no coherent meaning on a new session.
- **`verifySessionToken(token, *, require_mfa_within?: seconds) → Session`**. When `require_mfa_within` is supplied, the SDK MUST raise **`MfaStepUpRequiredError`** unless `session.mfa_verified_at IS NOT NULL AND now() - session.mfa_verified_at < require_mfa_within`. The check reads the session row's own `mfa_verified_at`. Nothing user-level counts.
- **Window bound:** ADR 0008's "spec floor for the MFA verification window is 30 minutes … Applications MAY tighten this" is pinned as a **maximum**:
  - `require_mfa_within` MUST be in `(0, 1800]` seconds; a larger or non-positive value raises `InvalidFormatError`;
  - adopters MAY pass shorter windows.
- `Session` (the returned entity, in every SDK) gains **`mfa_verified_at: timestamp | null`**, mapped from `ses.mfa_verified_at`, which the reference schema already defines. Adopters MAY also gate on the field directly with the ADR 0008 predicate.

### 3. Refresh resets freshness (unchanged, now enforceable)

`refreshSession(ses_id)` creates the new session with **`mfa_verified_at = NULL`** (ADR 0008 as written). A refreshed session that needs MFA must step up with `verifyMfaForSession`. Freshness is never amortized across refreshes.

### 4. Nothing is consumed on refusal (normative)

For `createSession(…, mfa_proof)` and `verifyMfaForSession`, the SDK MUST:
- check the user, credential and session preconditions **before** consuming the proof;
- perform every side effect of verifying it **in the same transaction as the session write**: recovery-slot consumption, the TOTP step record, the WebAuthn counter update.

A refusal at any step rolls all of them back, so a failed session creation never burns a recovery code or a TOTP step. In-memory stores MUST behave the same way, with no partial mutation on any error path.

### 5. The session id comes from the request (adopter duty)

Adopters MUST pass `verifyMfaForSession` the id of **the session authenticating the current request**, never a client-supplied session id. On its own that isn't exploitable, because the proof must still belong to the session's owner. It keeps the binding meaningful and auditable.

### 6. Step-up rotates the session token

Raising the privilege of the **existing** token would let a copy of that token already held by someone else (the stolen-session case this design targets) become MFA-fresh when its owner steps up, for up to 30 minutes. So step-up **rotates the session** (OWASP Session Management; CWE-384 class): `verifyMfaForSession` returns a **new** session and token with `mfa_verified_at = now()`, and revokes the old session, in the same transaction. The return type is `{ session, token }`. The pre-step-up token no longer verifies.

## Consequences

**Positive:**
- MFA freshness is bound to the session id, reset on refresh, and verified and stamped atomically.
- A stolen session can't inherit MFA performed elsewhere, and a copied token doesn't become fresh when its owner steps up.
- The ADR's undefined `requireMfaWithin` is replaced by a check with a defined meaning.
- A failed session creation or step-up never burns a recovery code or a TOTP step.

**Negative:**
- **New surface in five SDK families:**
  - the `mfa_proof` input on `createSession`;
  - `verifyMfaForSession`, returning a rotated session and token;
  - the `require_mfa_within` option on `verifySessionToken`;
  - `MfaStepUpRequiredError`;
  - `Session.mfa_verified_at`.
- **Behaviour change:** callers passing `requireMfaWithin` to `createSession` must move to `verifySessionToken`. Release notes MUST say so.
- **Adopters must replace the client's token after step-up,** because the old one is revoked.

**Conformance (a follow-up; not written here):**
- `identity/mfa/session-bound-freshness.json`:
  - stepping up session A does **not** make session B fresh;
  - `refreshSession` resets freshness;
  - `require_mfa_within` is enforced, with a known positive inside the window and a denial past it;
  - `createSession` with a bad `mfa_proof` creates no session;
  - a step-up on a revoked or expired session is refused;
  - a proof for a different user is never accepted for this session;
  - a refused `createSession(…, mfa_proof)` leaves the recovery code unconsumed, so the same code then succeeds (a known positive that proves nothing was burned);
  - the pre-step-up token no longer verifies after step-up.

## Rejected alternatives

- **Keep `createSession({ requireMfaWithin })` with user-level meaning.** Rejected: that's user-bound freshness, the exact weakness this amendment removes.
- **`createSession` accepts a `verifyMfa` result.** Rejected: results are forgeable or reusable values, so verification and stamping stop being one atomic SDK step.
- **Only the step-up operation, with no `mfa_proof` on `createSession`.** Rejected: users with required MFA (`usr_mfa_policy`) would briefly hold a session with no MFA, and adopters would have to gate every route. Verifying at creation keeps "no session before MFA" possible.
- **Step-up keeps the existing token.** Rejected: a copy of the token held by someone else would become MFA-fresh when its owner steps up. Rotation costs one return-type change and removes that residual.

## References

- ADR 0008 §"Verification flow", §"Session lifecycle changes"; `docs/identity.md` §Sessions, §"Sessions and MFA freshness", §Lifecycle.
- ADR 0027 (strict TOTP step replay, the replay protection `mfa_proof` verification uses).
- Reference schema: `ses.mfa_verified_at` (existing).
