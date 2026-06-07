# ADR: Passkey login-credential assertion verification (`verifyPasskeyAssertion`)

> **DRAFT — number-less per `decisions/README.md`.** Assign the next free ADR number at PR-open time. Target: next identity wave (post-v0.4-publish). Status on merge: **Proposed** (normative once the targeted version releases).
> **Filed by:** SiteSource Admin (SDK-first pattern, cross-team request via PM). **Reviewers:** Flametrench Security — **conditional sign-off received (2026-06-07), rulings folded below**; Flametrench QA (conformance vector) at PR-open.

## Status

Proposed (pending). Sequenced **after the v0.4 publish** — deferred hardening, not a live incident.

## Context

`flametrench/identity` owns WebAuthn assertion verification end-to-end since v0.2 ([ADR 0008](./0008-mfa.md), [ADR 0010](./0010-webauthn-rs256-eddsa.md)): the `webauthn_verify_assertion` primitive dispatches on the registration-time COSE `alg` (ES256/RS256/EdDSA), enforces **signature-counter monotonicity**, **RP ID validation**, and the **user-verified flag**, and is byte-identical across all five SDKs.

That primitive is currently wired only behind **`verifyMfa`** — i.e. against **MFA factors** (`mfa_` entities, keyed by `usrId`). **Passkey *login credentials*** (`cred_` entities of `type = passkey`, carrying `passkey_public_key` / `passkey_sign_count` / `passkey_rp_id` per `docs/identity.md#passkey`) are **create/rotate-only** in practice. `verifyCredential(type, identifier, proof) → usr_id | null` is specified as the login entry point for passkey assertions, but it is shaped for **session creation** (resolve *who* logged in by `(type, identifier)`), not for **re-authenticating a known, specific credential**.

The gap that motivates this ADR: there is no SDK method to verify a fresh WebAuthn assertion **against one specific, already-enrolled passkey login credential** and get a boolean re-auth result. SiteSource Admin needs exactly this to gate **passkey-rotation re-auth** (their admin#89): a WebAuthn step-up against the *existing* enrolled passkey immediately before `rotatePasskey()`, closing a **stolen-bearer-rebinds-passkey** account-takeover gap for password-less / passkey-only users (who have no password to re-prompt). Adopters MUST NOT reimplement WebAuthn crypto, so this belongs in the SDK.

## Decision

Add an `IdentityStore` operation, **owner-scoped** (the authenticated `usrId` is a parameter, mirroring the notify Option-2 ruling [ADR 0022] — secure-by-default, conformance-testable, and it makes the cross-user existence differential moot):

```
verifyPasskeyAssertion(usrId, credId, assertion, challenge) → bool
```

**Semantics:**
1. Load the `cred_` by `credId`. It MUST belong to `usrId` (`cred.usr_id == usrId`), be `type = passkey`, and `status = active`. A credential that does not exist **or is not owned by `usrId`** returns the same `NotFoundError` (non-disclosure — a caller cannot probe other users' credential ids; see Errors).
2. Run the existing `webauthn_verify_assertion` primitive ([ADR 0010](./0010-webauthn-rs256-eddsa.md)) against the credential's `passkey_public_key`, dispatching on its registration-time COSE `alg`, validating the assertion's RP ID against `passkey_rp_id`, the user-verified flag, and that the assertion was signed over `challenge`.
3. **Sign-count monotonicity / clone detection — via atomic compare-and-swap (CAS), NOT read-then-write.** On a successful crypto verify, the counter check and bump MUST be a single atomic CAS:
   ```sql
   UPDATE credential
      SET passkey_sign_count = :asserted
    WHERE id = :credId AND passkey_sign_count < :asserted
   ```
   then branch on rows-affected: **1 row → `true`**; **0 rows → `false`** (counter did not advance: a clone/replay signal, OR a concurrent submission of the same assertion already advanced it). A read-then-write here is a **TOCTOU replay hole** — two concurrent submissions of the *same* valid assertion both read `stored = N`, both see `asserted > N`, both succeed — same race class as the audit H3 `last_used_at` finding. Atomicity is **normative**. For **counter-less authenticators** (always report sign count 0, permitted by WebAuthn): verify-only, no bump, identical to the `verifyMfa` path — replay-safety for these rests entirely on challenge single-use (see Challenge lifecycle).
4. **Fail-closed, no oracle.** Any cryptographic/assertion/counter failure — bad signature, RP-ID mismatch, challenge mismatch, missing user-verified flag, counter non-advance — returns `false`. The boolean MUST NOT distinguish *which* check failed (no verification oracle). In particular, the ADR 0010 primitive's internal `WebAuthn*` exceptions (e.g. `WebAuthnUnsupportedKeyError`, malformed authenticator data) MUST be **caught and collapsed into `false`** — surfacing them here would itself be the which-check oracle (see Errors). Wall-clock timing of the failing check is **adopter-hardening, not a contract MUST** (consistent with [ADR 0019] / notify #59) — the contract kills the *error-code* oracle, which is the load-bearing part.

**This does NOT mint a credential, session, or factor**, does NOT perform the rotation, and does NOT stamp MFA freshness — it is a pure verification predicate the adopter chains before `rotatePasskey()`.

### Why a new method rather than overloading `verifyCredential` / `verifyMfa`
- `verifyCredential` returns `usr_id | null` (login: *who* authenticated, by `(type,identifier)`); `verifyPasskeyAssertion` is keyed by `(usrId, credId)` the caller already holds and returns **bool** (re-auth: *did this user's exact enrolled passkey just sign this challenge*). Different question, different shape.
- `verifyMfa` operates on `mfa_` factors. Passkey **login credentials** are `cred_` entities with a distinct lifecycle ([ADR 0005](./0005-revoke-and-re-add.md) rotation, `(type,identifier)` uniqueness). Reusing the verifier primitive while keeping the entity boundary intact upholds the `docs/identity.md` "factors are not credentials" invariant.

## Challenge lifecycle (the primary replay defense — normative adopter contract)

`verifyPasskeyAssertion` takes `challenge` as a parameter and only verifies the assertion was signed over it. It is **stateless with respect to challenge issuance** — it does **not** generate, store, single-use, or expire the challenge, and therefore **cannot enforce single-use itself.** Replay-safety therefore rests on the adopter, and this ADR makes that a **loud, normative adopter-MUST.** The `challenge` passed in MUST be:
- **server-generated** (never client-supplied),
- **cryptographically random, ≥16 bytes** (WebAuthn L2 §13.1),
- **single-use** — consumed/invalidated the moment it is handed to `verifyPasskeyAssertion`; a given challenge MUST NOT be accepted for a second verification,
- **time-bound** (short TTL).

**Threat-model note:** for **counter-less authenticators** the sign-count backstop does nothing, so **challenge single-use is the *only* replay defense** — an adopter who reuses or fails to invalidate a challenge has a replay hole the SDK cannot close. The ADR states this explicitly so adopters cannot read the sign-count rule as sufficient.

## Errors

Resolved with Security — **uniform taxonomy is mandatory here (not just consistent):** any `WebAuthn*`-family error on the verdict path would itself be the no-oracle violation, so the only errors are structural/state; the crypto verdict is always the fail-closed bool.
- `usrId` / `credId` malformed → `InvalidFormatError(field=…)`.
- `assertion` / `challenge` **structurally** malformed (decode only, not the crypto check) → `InvalidFormatError(field=…)`.
- `credId` not found **or not owned by `usrId`** → `NotFoundError` (single indistinguishable response — no cross-user existence/status probe; same posture as `getUser` and the notify Option-2 non-disclosure).
- Credential is owned + exists but is not an active passkey (`type != passkey` or `status != active`, incl. `suspended`) → `PreconditionError`. (Active-only re-auth, confirmed.)
- The ADR 0010 primitive's `WebAuthn*` exceptions are **wrapped/collapsed into the `false` verdict**, never surfaced.

## Conformance

A `fixtures/identity/passkey/verify-assertion.json` vector (synthetic assertions against known public keys, same approach as the WebAuthn MFA fixtures, `docs/identity.md#cross-sdk-parity-contract`). Minimum cases:
- **valid** assertion against the user's enrolled passkey → `true`, `passkey_sign_count` advanced to the asserted counter.
- **counter regression / equal** (asserted ≤ stored, counter-using authenticator) → `false`, counter **unchanged** (clone-detection; the CAS yields 0 rows).
- **RP-ID mismatch** / **challenge mismatch** / **missing UV flag** → each `false`, mutually indistinguishable (no oracle).
- **non-owned `credId`** (valid credential of *another* user) → `NotFoundError`, **byte-identical to unknown-credId** (owner-scoping non-disclosure).
- **wrong-type / revoked / suspended** owned credential → `PreconditionError`; **malformed usrId/credId** → `InvalidFormatError`.
- one valid vector per registered COSE `alg` (ES256/RS256/EdDSA) to prove the dispatch reuse.

(Challenge single-use is an *adopter*-side property — not directly SDK-conformance-testable — so the fixtures assert crypto + owner-scope + counter/CAS semantics; the challenge-lifecycle MUSTs live in the normative prose + adopter docs.) `runnable_today: false` until 5/5 SDKs implement (per-primitive flip discipline; flips per the re-vendor rule).

## Security rulings folded (2026-06-07 conditional sign-off)

1. **Atomic CAS** for the counter check+bump (replay TOCTOU) — pinned normative (Decision §3).
2. **No-oracle bool**, `WebAuthn*` collapsed, timing = adopter-hardening — folded (Decision §4, Errors).
3. **Step-up freshness: STANDALONE** — `verifyPasskeyAssertion` MUST NOT auto-stamp `session.mfa_verified_at`. It verifies a *credential*, not an MFA *factor*; auto-stamping would let a passkey re-auth silently satisfy an MFA-freshness gate for a user who also has a separate factor (a privilege/semantics leak). Whether a passkey re-auth counts as step-up is **adopter policy** — the adopter stamps `mfa_verified_at` itself on a `true` result if its policy says so. The two are distinct; conflating them is the adopter's explicit choice. (Folded as the no-stamp rule above.)
4. **Uniform error taxonomy required** (not optional) — folded (Errors).
5. **Active-only** — folded (Errors, `PreconditionError`).
6. **Challenge lifecycle** — the real replay surface; normative adopter-MUST added (dedicated section), with the counter-less reliance threat note.
7. **Owner-scoping** — adopted the `usrId` param (Security's lean; secure-by-default, conformance-testable, consistent with notify Option-2) over a credId-must-belong-to-caller adopter-MUST. Signature gains `usrId`; non-owned → uniform `NotFoundError`. Note for PM: this refines Admin's original `(credId, assertion, challenge)` sketch to `(usrId, credId, assertion, challenge)`.

## Consequences

- One new `IdentityStore` method, reusing the existing verifier primitive — a mini-primitive (single method, smaller than a v0.4 cap), fans out to all 5 SDKs after the ADR locks.
- Closes the passkey-only re-auth gap (admin#89's takeover surface) without adopters touching WebAuthn crypto; defense-in-depth via owner-scoping + non-disclosure; replay closed by atomic-CAS + the normative challenge contract.
- Keeps the `cred_` vs `mfa_` boundary intact; **no schema change** (the passkey credential already stores pubkey + counter + RP ID).
