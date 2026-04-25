# Identity

Flametrench identity covers how a user is represented, how they authenticate, and how authenticated sessions are tracked.

Three entities make up identity in v0.1:

- **`usr_`** — a user: the human or service principal whose identity is being managed.
- **`cred_`** — a credential: one specific way the user can prove they are the user.
- **`ses_`** — a session: an authenticated link between a user and an application.

This chapter is normative. Decisions recorded here are requirements for conformance. Rationale and alternatives considered live in [ADR 0004 — Identity model](../decisions/0004-identity-model.md).

## Users

### Entity shape

A user is an **opaque identity**. The user entity carries:

- `id` — UUIDv7; rendered on the wire as `usr_<hex>`.
- `status` — one of `active`, `suspended`, `revoked`.
- `created_at` — timestamp of creation, timezone-aware.
- `updated_at` — timestamp of last modification, timezone-aware.

Implementations MUST NOT require additional fields on `usr_` for spec conformance. Identifiers (email, phone, handle, display name) are application-layer extensions.

### Lifecycle

```
active → suspended → active     (reinstate)
active → revoked                (terminal)
suspended → revoked             (terminal)
```

- **`active`** — user can authenticate and participate.
- **`suspended`** — user cannot authenticate; active sessions MUST be terminated when the transition happens. The user's memberships (`mem_`) are NOT affected by user-level suspension; if the intent is to suspend a specific membership, use `mem.status` instead.
- **`revoked`** — user is terminated. All sessions MUST be terminated. All active credentials MUST transition to `revoked`. The user row is preserved for audit; it is never deleted.

### Operations

Implementations MUST provide:

- `createUser() → usr_id` — returns a new `usr_` with `status = active`.
- `getUser(usr_id) → user` — returns the entity or a not-found error.
- `suspendUser(usr_id)` — transitions to `suspended` and terminates sessions.
- `reinstateUser(usr_id)` — transitions `suspended → active`.
- `revokeUser(usr_id)` — transitions to `revoked`; triggers the cascade (sessions terminated, credentials revoked).

### Identifiers

A user has no intrinsic identifier. Identifiers live on credentials. To find a user by email:

```
findCredentialByIdentifier(type = "password", identifier = "alice@example.com") → cred
cred.usr_id → the user
```

Applications MAY cache a denormalized email on their own `usr_` extensions. The spec does not define this.

## Credentials

### Entity shape

A credential carries:

- `id` — UUIDv7; `cred_<hex>`.
- `usr_id` — the user this credential authenticates.
- `type` — one of `password`, `passkey`, `oidc`.
- `identifier` — a human-meaningful handle; format depends on type (see below).
- `status` — one of `active`, `suspended`, `revoked`.
- `replaces` — nullable FK to the previous credential in a rotation chain.
- Type-specific payload (below).
- `created_at`, `updated_at`.

### Credential types in v0.1

#### Password

- `identifier`: login handle, typically an email.
- Payload: `password_hash` — an Argon2id PHC string.

**Hashing requirements.** Implementations MUST use Argon2id. The PHC-encoded hash MUST include parameters meeting or exceeding:

- Memory: 19 MiB (`m=19456`)
- Iterations: 2 (`t=2`)
- Parallelism: 1 (`p=1`)

These match the OWASP Password Storage Cheat Sheet floor as of 2026. Implementations SHOULD use stronger parameters when hardware supports them.

Implementations MUST NOT store password credentials using bcrypt, scrypt, PBKDF2, SHA-2, or any other algorithm.

#### Passkey

- `identifier`: the WebAuthn credential ID, base64url-encoded.
- Payload:
  - `passkey_public_key` — raw public key bytes.
  - `passkey_sign_count` — WebAuthn signature counter; incremented on each successful assertion.
  - `passkey_rp_id` — the relying party ID (typically the application's eTLD+1).

#### OIDC

- `identifier`: the issuer-assigned subject or email claim; application choice.
- Payload:
  - `oidc_issuer` — the OIDC issuer URL.
  - `oidc_subject` — the value of the `sub` claim.

The pair `(oidc_issuer, oidc_subject)` uniquely identifies the user at the external identity provider.

### At most one active credential per (type, identifier)

A user MAY have many credentials, but the pair `(type, identifier)` MUST be unique across **active** credentials. Historical revoked credentials with the same `(type, identifier)` are permitted — this allows a password to be rotated and the email to be reused under the new credential.

### Lifecycle

```
active → suspended → active     (reinstate)
active → revoked                (terminal)
suspended → revoked             (terminal)
```

`suspended` is for short-lived blocks (e.g., temporary lockout during a password reset). `revoked` is terminal.

Credential rotation — password change, passkey re-registration, OIDC re-link — follows the **revoke-and-re-add** pattern defined in [ADR 0005](../decisions/0005-revoke-and-re-add.md):

1. The existing credential transitions to `status = revoked`.
2. A new credential is inserted with `replaces = old.id`.
3. All sessions (`ses_`) that were established by the rotated credential MUST be terminated (`revoked_at = now()`).

All three happen in one transaction.

### Operations

- `createCredential(usr_id, type, identifier, payload) → cred_id`.
- `rotateCredential(cred_id, new_payload) → new_cred_id` — implements the revoke-and-re-add sequence above.
- `suspendCredential(cred_id)`, `reinstateCredential(cred_id)`, `revokeCredential(cred_id)`.
- `verifyCredential(type, identifier, proof) → usr_id | null` — verifies a proof (password, WebAuthn assertion, OIDC ID token) and returns the authenticated user. Entry point for session creation.

## Sessions

### Entity shape

A session is an authenticated session of a user:

- `id` — UUIDv7; `ses_<hex>`.
- `usr_id` — the authenticated user.
- `cred_id` — the credential that established this session.
- `created_at` — timestamp of creation.
- `expires_at` — timestamp after which the session is considered expired.
- `revoked_at` — nullable; if set, the session is revoked.

The spec does NOT require IP address, user agent, device fingerprint, or geolocation. These are useful for security telemetry but carry PII and jurisdictional concerns; applications MAY add them as extension fields.

### Sessions are user-bound

A session is bound to a `usr_`, not to an `org_`. A user with memberships in multiple orgs uses the same session across all of them; "active org" is a client-side context attribute.

Applications with stricter compliance requirements (e.g., zero-trust banking) MAY enforce org-bound sessions at the application layer by gating each cross-org request with `check()` against the current org. The spec does not mandate this.

### Rotation on refresh

Refreshing a session MUST create a new `ses_` with a new `id` and mark the previous session `revoked_at = now()`. **In-place refresh** — keeping the same `id` and extending `expires_at` — is NOT spec-conformant.

The new session's `cred_id` SHOULD be the same as the previous session's unless the refresh involves re-authentication with a different credential.

### Session ID versus session token

**The session's `id` is not a secret.** It appears in logs, admin panels, and audit queries. An SDK MUST NOT expose `ses.id` as a bearer credential.

The session's **token** is a separate piece of state derived from `id` plus implementation-specific signing or lookup. Typical patterns:

- **Signed token** (JWT or equivalent) — carries `ses.id` as a claim, signed by the auth service; verification is stateless, requires no database lookup.
- **Opaque token** — random bearer string indexed against a server-side session table; verification requires a lookup on every request.

Implementations MUST ensure the token's authenticity is verifiable server-side on every authenticated request. The spec does not mandate JWT; both patterns are conformant.

### Termination

A session terminates when any of the following occur:

- `expires_at` passes.
- `revokeSession(ses_id)` is called — sets `revoked_at = now()`.
- The underlying credential is rotated or revoked (cascades to all sessions bound to it).
- The user is suspended or revoked (cascades to all their sessions).

### Operations

- `createSession(usr_id, cred_id, ttl) → ses_id, token`.
- `refreshSession(ses_id) → new_ses_id, new_token`.
- `revokeSession(ses_id)`.
- `listSessions(usr_id) → [session]`.

## Migration from legacy password stores

This section is normative. It defines how an application with an existing password store (bcrypt, PBKDF2, scrypt, or any algorithm other than Argon2id at the spec floor) MUST adopt Flametrench without violating the credential-type contract.

Rationale and alternatives considered live in [ADR 0006 — Legacy password migration](../decisions/0006-legacy-password-migration.md).

### What is and is not conformant

A `cred_` row of `type='password'` MUST hold an Argon2id PHC hash meeting the parameters in §"Hashing requirements". This is restated for emphasis: a `cred_` row holding a bcrypt, PBKDF2, scrypt, SHA-2, or any other non-Argon2id payload is **non-conformant**, regardless of how recently the host application started its migration. There is no transitional `Status` value or credential `type` that legitimizes a non-Argon2id hash.

It follows that during a migration, legacy password hashes live **outside** Flametrench's namespace — typically in the host application's pre-existing `users.password_hash` (Laravel), `auth_user.password` (Django), or equivalent column.

### The verify-then-rotate pattern

Conforming implementations MAY adopt the following migration pattern at login time. Hosts SHOULD adopt it; alternatives such as forced password reset are permitted but coarser.

1. The host receives the user's identifier and plaintext password from the login request.
2. The host calls `verifyPassword(identifier, plaintext)`. If a Flametrench password credential already exists for that identifier (i.e., the user has migrated), this succeeds and the migration is complete for that user.
3. On `InvalidCredentialError` from step 2, the host falls back to its own legacy verifier — application code calling the legacy library directly — against its existing user-table row.
4. On legacy-verify success, the host MUST atomically:
   1. Call `createPasswordCredential(usrId, identifier, plaintext)` on the IdentityStore. This mints a fresh Argon2id `cred_` row at the spec floor.
   2. Delete (or null) the legacy `password_hash` column on the host's user row.

   Both writes happen in a single database transaction. If either fails, both roll back and the user retries on next login.

5. From this point forward, step 2 succeeds for that user; the legacy path is never re-entered.

After every active user has logged in once — or after a host-defined deadline — the host drops the legacy column. Users who do not log in during the migration window remain on the legacy hash; the host's migration policy (force-reset email, deadline-based account lock, OIDC fallback) is out of scope for this spec.

### Worked example: Laravel + `flametrench/identity`

The example assumes:

- A pre-existing `users` table with a `password_hash` column holding bcrypt strings.
- A `usr_id` column on the same `users` table linking to a Flametrench `usr_` row that was already imported during initial adoption.
- The Flametrench identity store wired into the Laravel container.

```php
<?php

use Flametrench\Identity\IdentityStore;
use Flametrench\Identity\Exceptions\InvalidCredentialException;
use Illuminate\Support\Facades\DB;

final class LoginController
{
    public function __construct(
        private readonly IdentityStore $identity,
    ) {}

    public function __invoke(LoginRequest $request): JsonResponse
    {
        $identifier = $request->input('email');
        $plaintext = $request->input('password');

        // 1. Try the Flametrench credential first. If the user has migrated,
        // this is the entire login flow.
        try {
            $verified = $this->identity->verifyPassword($identifier, $plaintext);
            return $this->establishSession($verified->usrId, $verified->credId);
        } catch (InvalidCredentialException) {
            // Fall through to legacy verification.
        }

        // 2. Legacy lookup. Application-owned, NOT a Flametrench API.
        $legacyRow = DB::table('users')
            ->where('email', $identifier)
            ->whereNotNull('password_hash')
            ->first();

        if ($legacyRow === null || !password_verify($plaintext, $legacyRow->password_hash)) {
            // Same generic error the SDK would have raised. Don't disclose
            // which arm failed.
            return response()->json(['error' => 'invalid_credential'], 401);
        }

        // 3. Atomic rotation: mint the Argon2id cred_, drop the legacy hash.
        $migratedCred = DB::transaction(function () use ($legacyRow, $identifier, $plaintext) {
            $cred = $this->identity->createPasswordCredential(
                usrId: $legacyRow->usr_id,
                identifier: $identifier,
                password: $plaintext,
            );
            DB::table('users')
                ->where('id', $legacyRow->id)
                ->update(['password_hash' => null]);
            return $cred;
        });

        // 4. Same session-establishment path the migrated arm took.
        return $this->establishSession($legacyRow->usr_id, $migratedCred->id);
    }

    private function establishSession(string $usrId, string $credId): JsonResponse
    {
        $sessionWithToken = $this->identity->createSession($usrId, $credId, ttlSeconds: 3600);
        return response()->json([
            'token' => $sessionWithToken->token,
            'expires_at' => $sessionWithToken->session->expiresAt->format(DATE_RFC3339),
        ]);
    }
}
```

The same pattern applies to other host languages and frameworks; the key invariants are:

- The legacy verifier call (`password_verify` here) is host code, not an SDK call.
- The legacy fallback runs ONLY on `InvalidCredentialException` from `verifyPassword`, never preemptively.
- The credential mint and the legacy-column delete are in one transaction.
- After rotation, the legacy verifier is unreachable for that user; the SDK's `verifyPassword` is the single source of truth.

### Bulk migration is out of scope for v0.1

The spec deliberately does not define a one-shot bulk re-hash tool, because plaintext is unrecoverable and any "bulk migrate" path requires either forcing all users to reset their passwords or keeping legacy verifiers permanently. Hosts choose their policy.

### What the SDK will and will not do for migrations

In v0.1, Flametrench SDKs MUST NOT:

- Ship a built-in bcrypt, PBKDF2, scrypt, or any non-Argon2id verifier.
- Expose a hook that lets `verifyPassword` consult host-provided legacy verifiers automatically.
- Accept a non-Argon2id PHC string into `createPasswordCredential` even with explicit override flags.

A pluggable `LegacyPasswordVerifier` interface MAY be introduced in v0.2+ if multiple adopters request it with consistent requirements. Hosts adopting v0.1 today are not blocked by its absence; the verify-then-rotate pattern above is correct and complete.



Flametrench v0.1 does NOT specify MFA. See [ADR 0004](../decisions/0004-identity-model.md) for rationale.

Applications that need MFA in v0.1 can layer it on:

- Maintain multiple credentials per user (e.g., one password credential and one passkey credential).
- Require verification of a second credential before calling `createSession`.
- The resulting session's `cred_id` records the primary credential that established it.

v0.2 will introduce first-class MFA with credential chains, grace windows, and recovery codes.

## Conformance fixtures

The following fixtures are REQUIRED for identity interoperability across conforming implementations:

### Argon2id hash format

A password credential created with the input password `"correcthorsebatterystaple"` and parameters `m=19456, t=2, p=1` and the fixed salt `c29tZXNhbHQxMjM` (base64: "somesalt123") MUST produce a hash that verifies under any other compliant Argon2id verifier.

### OIDC subject resolution

Given an OIDC credential with `issuer = "https://accounts.google.com"` and `subject = "1234567890"`, `findCredentialByIdentifier` with the matching `(issuer, subject)` pair MUST return this credential. Issuer URL normalization follows RFC 3986: trailing-slash equivalence is permitted, but case normalization of the host is required.

More conformance fixtures will be added in `spec/conformance/` as implementations surface specific interoperability questions.
