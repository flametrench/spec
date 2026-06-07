# ADR: Passkey login-credential assertion verification (`verifyPasskeyAssertion`)

> **DRAFT — number-less per `decisions/README.md`.** Assign the next free ADR number at PR-open time. Target: next identity wave (post-v0.4-publish). Status on merge: **Proposed** (normative once the targeted version releases).
> **Filed by:** SiteSource Admin (SDK-first pattern, cross-team request via PM). **Reviewers required:** Flametrench Security (WebAuthn/replay-sensitive), Flametrench QA (conformance vector).

## Status

Proposed (pending). Sequenced **after the v0.4 publish** — deferred hardening, not a live incident.

## Context

`flametrench/identity` owns WebAuthn assertion verification end-to-end since v0.2 ([ADR 0008](./0008-mfa.md), [ADR 0010](./0010-webauthn-rs256-eddsa.md)): the `webauthn_verify_assertion` primitive dispatches on the registration-time COSE `alg` (ES256/RS256/EdDSA), enforces **signature-counter monotonicity**, **RP ID validation**, and the **user-verified flag**, and is byte-identical across all five SDKs.

That primitive is currently wired only behind **`verifyMfa`** — i.e. against **MFA factors** (`mfa_` entities, keyed by `usrId`). **Passkey *login credentials*** (`cred_` entities of `type = passkey`, carrying `passkey_public_key` / `passkey_sign_count` / `passkey_rp_id` per `docs/identity.md#passkey`) are **create/rotate-only** in practice. `verifyCredential(type, identifier, proof) → usr_id | null` is specified as the login entry point for passkey assertions, but it is shaped for **session creation** (resolve *who* logged in by `(type, identifier)`), not for **re-authenticating a known, specific credential**.

The gap that motivates this ADR: there is no SDK method to verify a fresh WebAuthn assertion **against one specific, already-enrolled passkey login credential** and get a boolean re-auth result. SiteSource Admin needs exactly this to gate **passkey-rotation re-auth** (their admin#89): a WebAuthn step-up against the *existing* enrolled passkey immediately before `rotatePasskey()`, closing a **stolen-bearer-rebinds-passkey** account-takeover gap for password-less / passkey-only users (who have no password to re-prompt). Adopters MUST NOT reimplement WebAuthn crypto, so this belongs in the SDK.

## Decision

Add an `IdentityStore` operation:

```
verifyPasskeyAssertion(credId, assertion, challenge) → bool
```

**Semantics:**
1. Load the `cred_` by `credId`. It MUST be `type = passkey` and `status = active`; otherwise see Errors.
2. Run the existing `webauthn_verify_assertion` primitive (ADR 0010) against the credential's `passkey_public_key`, dispatching on its registration-time COSE `alg`, validating the assertion's RP ID against `passkey_rp_id`, the challenge against `challenge`, and the user-verified flag.
3. **Sign-count monotonicity / clone detection:** the assertion's authenticator sign count MUST be **strictly greater than** the stored `passkey_sign_count` (when the authenticator uses a non-zero counter). On success, persist the new `passkey_sign_count` (monotonic bump) in the same transaction as the boolean result. A non-increasing counter on a counter-using authenticator is a **clone/replay signal** → return `false`, do not bump. (Mirrors the verifyMfa WebAuthn counter rule so the two assertion paths cannot diverge.)
4. **Fail-closed, no oracle:** any cryptographic/assertion failure — bad signature, RP-ID mismatch, challenge mismatch, missing user-verified flag, counter regression — returns `false`. The boolean MUST NOT distinguish *which* check failed (no verification oracle), exactly as the existing assertion path is fail-closed.

**This does NOT mint a new credential, session, or factor**, and does NOT itself perform the rotation — it is a pure verification predicate the adopter chains before `rotatePasskey()` (and MAY use to stamp step-up freshness; see Open Questions).

### Why a new method rather than overloading `verifyCredential` / `verifyMfa`
- `verifyCredential` returns `usr_id | null` (login: *who* authenticated, by `(type,identifier)`); `verifyPasskeyAssertion` is keyed by a **specific `credId`** the caller already holds and returns **bool** (re-auth: *did this exact enrolled passkey just sign this challenge*). Different question, different shape.
- `verifyMfa` operates on `mfa_` factors keyed by `usrId`. Passkey **login credentials** are `cred_` entities — a distinct lifecycle ([ADR 0005](./0005-revoke-and-re-add.md) rotation, `(type,identifier)` uniqueness). Reusing the verifier primitive while keeping the entity boundary intact is the `docs/identity.md` "factors are not credentials" invariant.

## Errors

Open for Security/QA confirmation (see Open Questions) — proposed:
- `credId` malformed → `InvalidFormatError(field="credId")`.
- `assertion` / `challenge` structurally malformed (not the crypto check — structural decode only) → `InvalidFormatError(field=...)`. The crypto/assertion verdict is the boolean, never an exception (fail-closed, no oracle).
- `credId` not found → `NotFoundError` (generic; same non-disclosure posture as `getUser`).
- Credential exists but is not an active passkey (`type != passkey` or `status != active`) → `PreconditionError`.

**Cross-cutting taxonomy question:** the v0.2 WebAuthn layer uses primitive-specific classes (e.g. `WebAuthnUnsupportedKeyError(reason=...)`, ADR 0010), whereas the v0.4 taxonomy (ADRs 0019–0022) is uniform `InvalidFormatError` / `PreconditionError` with **no** primitive-specific classes. This method straddles both. The draft proposes the uniform classes for the *new* surface (structural input + state), with the assertion verdict staying a fail-closed boolean (so no WebAuthn-specific error is reachable on the hot path). **Security/QA to confirm** we don't want a `WebAuthn*`-family error here for parity with `verifyMfa`'s surface.

## Conformance

A `fixtures/identity/passkey/verify-assertion.json` vector (synthetic assertions against known public keys, same approach as the existing WebAuthn MFA fixtures, `docs/identity.md#cross-sdk-parity-contract`). Minimum cases:
- **valid** assertion against an enrolled passkey credential → `true`, `passkey_sign_count` bumped to the asserted counter.
- **counter regression** (asserted ≤ stored, non-zero authenticator) → `false`, counter **unchanged** (clone-detection).
- **RP-ID mismatch** / **challenge mismatch** / **missing UV flag** → each `false` (and indistinguishable — no oracle).
- **wrong-type / revoked credential** → `PreconditionError`; **unknown credId** → `NotFoundError`; **malformed credId** → `InvalidFormatError`.
- one vector per registered COSE `alg` (ES256/RS256/EdDSA) to prove the dispatch reuse.

`runnable_today: false` until 5/5 SDKs implement (the per-primitive flip discipline; flips to enforcing per the re-vendor rule).

## Open questions (for Security + PM)

1. **Step-up freshness integration.** Should a successful `verifyPasskeyAssertion` be allowed to stamp `session.mfa_verified_at` (the `docs/identity.md#sessions-and-mfa-freshness` step-up window), or is it strictly a standalone predicate the adopter wires? Leaning standalone (it verifies a *credential*, not an MFA *factor*) — but the rotation-re-auth use case is morally a step-up. **Security's call.**
2. **Error taxonomy** — uniform vs WebAuthn-family (above).
3. **Scope of "active".** Should re-auth be permitted against a `suspended` passkey (e.g. mid-reset)? Draft says no (active-only). Confirm.
4. **Counter-less authenticators.** For authenticators that always report sign count 0 (allowed by WebAuthn), the strict-greater rule is skipped (verify-only, no bump) — confirm this matches the existing verifyMfa behavior so the two paths stay identical.

## Consequences

- One new `IdentityStore` method, reusing the existing verifier primitive — a mini-primitive (single method, smaller than a v0.4 cap), fans out to all 5 SDKs after the ADR locks.
- Closes the passkey-only re-auth gap (admin#89's takeover surface) without adopters touching WebAuthn crypto.
- Keeps the `cred_` vs `mfa_` boundary intact; no schema change (the passkey credential already stores pubkey + counter + RP ID).
