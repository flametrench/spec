# 0006 — Legacy password migration: host-side verify-then-rotate

**Status:** Accepted
**Date:** 2026-04-25

## Context

Flametrench v0.1 pins password credentials to Argon2id at the OWASP-floor parameters (see [ADR 0004](./0004-identity-model.md) and `docs/identity.md`). This is the right floor for new credentials and is what the conformance suite enforces across every SDK.

The pin leaves a real adoption question unanswered: **how does an existing application migrate to Flametrench when its current password store uses a different algorithm?** Bcrypt is the dominant case (Laravel default, Django default until 4.x, Rails `has_secure_password`); PBKDF2 and scrypt appear less often but with the same shape. Plaintext is unrecoverable, so a one-shot bulk re-hash to Argon2id is impossible.

The natural migration path is **rehash-on-next-login**: the user submits plaintext, the server verifies against the legacy hash, and on success the credential is rotated to a fresh Argon2id row. This pattern is well-known (Django's `force_login` migration, Devise's pepper migration). The question for Flametrench is whether the SDK should ship the legacy verifier(s) or whether legacy verification stays a host-app concern.

This ADR records that decision so all SDKs (current and future) implement the migration story identically, and so first-time adopters have a normative answer to point at.

## Decision

### A `cred_` row of `type='password'` always holds an Argon2id hash

The credential-type contract from ADR 0004 is unchanged. Specifically:

- Implementations MUST NOT store password credentials using bcrypt, scrypt, PBKDF2, SHA-2, or any other algorithm. (This restatement is normative.)
- No new `Status` value is introduced for "legacy / pending rotation". The existing `active / suspended / revoked` set is sufficient.
- No new credential `type` is introduced for legacy hashes.
- A `cred_` row exists only once a conforming Argon2id hash exists.

Legacy hashes therefore live **outside** the Flametrench namespace — in the host application's pre-existing column (typically `users.password_hash` in Laravel, `auth_user.password` in Django, etc.). Flametrench's storage layer never sees a non-Argon2id payload.

### Verify-with-legacy-then-rotate is the normative migration pattern

A host application MAY migrate from a legacy password store to Flametrench by following this sequence at login time:

1. The host's login route receives the user's identifier and plaintext.
2. The host calls `verifyPassword(identifier, plaintext)` on its `IdentityStore`. If a Flametrench password credential already exists for that identifier (the user has already migrated), this succeeds and the flow is complete.
3. On `InvalidCredentialError`, the host falls back to its **own** legacy verifier — application code calling `password_verify($plaintext, $legacyHash)` (PHP), `bcrypt.compare(plaintext, legacyHash)` (Node), or equivalent — against the row in its existing user table.
4. On legacy-verify success, in a single database transaction the host:
   1. Calls `createPasswordCredential($usrId, $identifier, $plaintext)` on the `IdentityStore`. This mints a fresh Argon2id `cred_` row at the spec floor.
   2. Deletes (or nulls) the legacy `password_hash` column on the host's user row.
5. From this point forward, step 2 succeeds for that user; the legacy path is never re-entered.

After every active user has logged in once — or after a host-defined deadline — the host drops the legacy column entirely.

### The legacy verifier is a host concern in v0.1

Flametrench v0.1 SDKs do not ship a built-in bcrypt / PBKDF2 / scrypt verifier, and `verifyPassword` does not expose a "fall through to a legacy verifier" hook. The host owns the legacy hash lookup AND the legacy verification call.

Rationale for keeping the verifier out of v0.1:

- **Conformance simplicity.** Every SDK already ships exactly one password algorithm (Argon2id). Adding a configurable matrix of legacy verifiers expands the conformance surface and ties SDK release cadence to legacy-algorithm CVE response. Hosts already have these dependencies installed in their stacks (Laravel ships bcrypt; Django ships PBKDF2); there is no install-cost saving.
- **Identifier-lookup ownership.** The legacy hash is keyed on the host's existing user table, not on Flametrench's `cred_` table. A built-in verifier would force the host to either duplicate the legacy hash into a new column the SDK can read (silly) or expose a callback the SDK invokes to fetch it (a host-side hook by another name).
- **Premature commitment.** Different applications have different transition policies (force-reset email, OIDC fallback, opt-in user notification). Picking one in the SDK now would over-fit the first migrator's needs.

### A pluggable `LegacyPasswordVerifier` is deferred to v0.2+

If real demand for an in-SDK migration helper materializes from multiple adopters with consistent requirements, v0.2+ MAY add an opt-in `LegacyPasswordVerifier` interface that `verifyPassword` consults on `cred_` miss. The interface would be host-implemented (the SDK provides no built-in algorithms) and would invoke the rotation flow on success.

Until then, v0.1 hosts adopt the pattern in Decision §2 directly. Spec versioning is independent of the host's migration timeline; an app that completes its bcrypt migration on v0.1 incurs no upgrade obligation when v0.2 ships the interface.

## Consequences

**Positive:**
- Cross-SDK parity stays narrow. The conformance suite continues to enforce one password algorithm; no SDK has to ship a verifier matrix to read its own data.
- Hosts adopt incrementally without a flag day. Migration completes user-by-user on natural login traffic.
- The migration pattern is the same across PHP, Node, Python, and Java because all four SDKs only see the post-rotation `cred_` row.
- No `cred_` row ever holds a non-conformant hash. Audit and conformance logs are clean.

**Negative:**
- Hosts write the legacy-verify branch in their login code rather than configuring it on the SDK. This is roughly 10–20 lines per host but it's host-language idiomatic.
- Users who never log in during the migration window keep their legacy hash forever (or get force-reset). The SDK doesn't help with this; it's a host policy decision (mass-email a reset link, set a deadline, etc.).
- The "is this user migrated yet?" question requires the host to either (a) keep the legacy column nullable and check it on each login, or (b) use the existence of a Flametrench `cred_` as the source of truth and only consult legacy on `verifyPassword` failure. Pattern (b) is recommended and is what `docs/identity.md#migration-from-legacy-password-stores` documents.

## Deferred

- **Built-in `LegacyPasswordVerifier` interface in the SDK.** Revisit when ≥2 adopters request it AND we have a concrete proposal for the lookup-callback shape. v0.2+ candidate.
- **Bulk-rotate tooling.** A migration that issues forced password resets to all unmigrated users after a deadline. Out of scope for the spec; appropriate as host-side tooling or a future `flametrench/migration` library.
- **Migration support for non-password credentials.** Legacy passkey or OIDC stores that need adapter shims. No demand observed; file an issue if you hit one.

## Rejected alternatives

### Allow bcrypt inside `cred_` rows during a migration window

Rejected. This would require every conforming SDK to ship a bcrypt verifier — adding bcrypt becomes a transitive dependency for all four current SDKs and any future one. The conformance suite's Argon2id parity test would no longer cover the full read path; a separate bcrypt parity test would have to join it. The migration window is a per-host concern that should not bleed into the SDK conformance contract. The cost of the host-side pattern (10–20 lines per host) is much smaller than the cost of expanding the SDK contract.

### Add a `Status::Legacy` (or `Status::PendingRotation`) value

Rejected. Status describes the lifecycle of a credential, not the algorithm of its hash. A bcrypt-holding row that's "active enough to verify against" but "not active enough to be conformant" is a contradiction the existing three-state lifecycle was designed to avoid. Per ADR 0004, `suspended` is for short-lived blocks (lockout during reset), not for migration backlog spanning months.

### Add a fourth credential `type` for legacy hashes (e.g., `password_legacy`)

Rejected. The credential type is a discriminator on what kind of authentication factor the user is presenting (password, passkey, OIDC), not on what hash algorithm an implementation happens to use internally. A `password_legacy` type would also need to be passed through every operation that takes a `CredentialType`, and would require explicit deferral handling in the conformance suite. Cleaner to keep legacy hashes outside Flametrench's type system entirely.

### Force-reset email instead of verify-then-rotate

Rejected as the *normative* path, not as an option. A host MAY choose to email all users a reset link and ignore legacy hashes entirely; this is policy. But the spec must sanction the more common pattern (silent rehash on first login) because requiring a force-reset for adoption is a much bigger ask of first-time integrators.

### Ship the legacy verifier in v0.1 as a built-in plugin

Rejected for v0.1. See "The legacy verifier is a host concern" above. Revisitable in v0.2.

## References

- [ADR 0004 — Identity model](./0004-identity-model.md) — Argon2id pinning rationale.
- [ADR 0005 — Revoke-and-re-add](./0005-revoke-and-re-add.md) — credential rotation lifecycle that the rotation step in §2.4 follows.
- [`docs/identity.md#migration-from-legacy-password-stores`](../docs/identity.md#migration-from-legacy-password-stores) — normative migration section with a worked PHP/Laravel example.
- [Issue #1 — Migration story for existing apps with bcrypt(password) on a users table](https://github.com/flametrench/spec/issues/1) — the question that prompted this ADR.
- OWASP Password Storage Cheat Sheet — Argon2id parameter floor reference.
