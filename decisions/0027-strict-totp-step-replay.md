# 0027 — Strict TOTP step replay: reject any code at or before the last accepted step (amends ADR 0008)

**Status:** Accepted
**Date:** 2026-11-22
**Deciders:** Flametrench stewards
**Supersedes (in part):** ADR 0008 §"Verification flow", the TOTP dedup sentence ("rejects code reuse via a per-(usr_id, code, time-step) deduplication index")

## Context

ADR 0008 requires TOTP code reuse to be rejected, via a per-(usr_id, code, time-step) deduplication index. The reference schema records, per factor, only the **last accepted** time-step (`mfa.totp_last_accepted_step`).

Rejecting only a step **equal** to the last accepted one doesn't meet ADR 0008. With the ±1 drift window, a consumed code(N) can be replayed at step N+1 after code(N+1) was accepted. With a single column, the only rule that meets the accepted text is to reject any step **at or before** the last accepted one. That rule also rejects *never-used* older codes that are still inside the drift window, which is the stricter design adopted here. This ADR makes that design normative on its own, separately from the session-bound MFA amendment (ADR 0030).

## Decision

1. For each TOTP factor, the SDK records the time-step counter (`floor(unix_time / period)`) of the most recently **accepted** code, in `mfa.totp_last_accepted_step`. Enrollment confirmation counts as an acceptance.
2. A presented code is rejected with **`ReplayedTotpError`** if the step it matches is **less than or equal to** the recorded step. This covers a replay of the same code and an older code still inside the ±1 drift window.
   - If a presented code matches **more than one** step inside the window (an RFC 6238 collision, about 1 in 10⁶), the SDK MUST use the **highest** matched step, both for this comparison and for the value it records. That removes a cross-SDK ambiguity.
3. The comparison and the update of `totp_last_accepted_step` MUST happen in **one transaction under a row lock on the factor** (`SELECT … FOR UPDATE`, or the in-memory equivalent), so two concurrent verifications of one code can't both succeed.
4. This replaces the per-(usr_id, code, time-step) index as the mandated mechanism. An implementation MAY keep extra state, but MUST reject everything this rule rejects.

### The replay error (normative)

5. **`ReplayedTotpError` MUST be a subtype of `InvalidCredentialError`** in every SDK family, so a caller that handles an invalid credential handles a replay the same way in every language. In Go, `errors.Is(err, ErrInvalidCredential)` MUST be true for a replay, and so MUST `errors.Is(err, ErrReplayedTotp)`.
6. **Its code is `unauthorized.totp_replayed`**, following the existing `unauthorized.<noun>_<state>` pattern. SDKs that previously used another code string for this error change to this one.
7. **Conformance harnesses MUST match an expected error exactly.** A fixture's `expected.error` names the most specific error, and a harness passes only when the raised error's type is that one, not one of its supertypes or subtypes. Without this rule, once (5) holds, a test expecting a plain `InvalidCredentialError` would also pass on a replay, and the replay vectors would stop telling the two apart.

### Reference schema

8. `reference/postgres.sql` gains the nullable `mfa.totp_last_accepted_step BIGINT` column, which is NULL for non-TOTP factors, plus the additive migration `reference/migrations/0001-mfa-totp-last-accepted-step.sql`. NULL means "no code accepted yet under replay tracking", so no backfill is needed.

## Consequences

**Positive:**
- The accepted replay requirement becomes implementable with a single column.
- The rule is O(1), with no index to clean up.
- Replays raise the same error type and code in every SDK family.

**Negative:**
- A user who enters an older still-valid code after a newer one has been accepted is rejected and must wait for the next step. That's accepted as the cost of strict replay protection.
- **Migration residual:** a code accepted by a pre-upgrade SDK within its window can't be recognised by the upgraded SDK, for at most one step.
- **Release notes:** SDKs that previously used a different code string, or didn't make the error a subtype of `InvalidCredentialError`, change behaviour for callers that match on either.

**Conformance:** `identity/mfa/totp-replay-rejected.json` asserts the same-step replay and a consumed code replayed in the next step. A follow-up adds the **older never-used code** vector: accept code(N+1), then present an unused code(N) inside the window → `ReplayedTotpError`.

## Rejected alternatives

- **Equal-step only.** Rejected: it lets consumed codes replay across the drift window, which doesn't meet ADR 0008.
- **Track every accepted step in the window** (a multi-value column or index). Rejected: it needs more schema, for the sole benefit of accepting never-used older codes. The single column with the stricter rule is preferred.
- **Leave the replay error's hierarchy unpinned.** Rejected: callers would handle a replay differently by language. ADR 0009 is the precedent for pinning an error hierarchy.

## References

- ADR 0008 §"Verification flow", §Conformance; ADR 0009 (error hierarchy precedent).
- `reference/postgres.sql` (`mfa.totp_last_accepted_step`); `reference/migrations/0001-mfa-totp-last-accepted-step.sql`.
- `conformance/README.md` (fixture `expected` semantics).
