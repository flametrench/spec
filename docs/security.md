# Security model

This document describes what Flametrench defends against, what it leaves to adopters, and what is explicitly out of scope. It is normative for every Flametrench-conforming SDK and HTTP server.

## Scope

Flametrench specifies the **identity, tenancy, and authorization** primitives that sit underneath an application — and the security properties of those primitives. It does NOT specify network security, deployment topology, secret storage, rate limiting, anomaly detection, or audit logging. Those remain adopter responsibilities; this document calls them out explicitly so adopters know what they own.

The spec assumes:

- **TLS is terminated upstream.** All wire-level protection (transport secrecy, integrity, authentication of the server to the client) is the adopter's responsibility. Flametrench treats every byte that crosses the HTTP boundary as if an attacker could read it (which they can, on plaintext channels).
- **The application server is trusted.** A compromised application server can issue any tuple, mint any session, accept any invitation. Flametrench's defenses operate inside the trust boundary, not against compromise of the trust boundary itself.
- **The database is trusted at rest.** Storage-level encryption, backup encryption, and DB credential rotation are adopter responsibilities. Flametrench's storage shape is designed so that exfiltration of a single column (e.g., `cred.argon2id_hash`) doesn't compromise the corresponding plaintext, but exfiltration of the whole database does compromise tenancy state and session validity.

## Attacker classes

Each Flametrench primitive's security claim is stated in terms of these classes. An adopter's threat model may add more, but every Flametrench primitive defends against at least these.

| Class | Description | Defended against by |
|---|---|---|
| **Network attacker** | Passive sniffer or active MitM on the HTTP wire. | Out of scope (TLS is the adopter's responsibility) — but Flametrench's bearer tokens and share tokens are designed to be revocable on disclosure (see below). |
| **Anonymous user** | Has not authenticated. | All write operations require an authenticated `usr_` (or a valid share token for share-mediated reads). |
| **Authenticated user (any tenant)** | Holds a valid session for some `usr_id`, but no membership in the target org. | `flametrench-tenancy` enforces membership for org operations; `flametrench-authz` requires an explicit `tup_` for any object-level grant. |
| **Authenticated tenant member** | Holds a valid session AND a `mem_` in the target org. Attempts to escalate within the org. | Sole-owner protection on every demotion path; role hierarchy on `adminRemove` (admins cannot remove peers or higher); revoke-and-re-add on role changes leaves a `replaces` chain for forensics. |
| **Leaked password** | Has a user's password but no MFA enrollment. | `usr_mfa_policy` with `required = true` blocks session creation regardless of password validity (v0.2; ADR 0008). Without MFA enrollment by the user, the password alone is sufficient to sign in — adopter responsibility to enforce MFA enrollment before allowing sensitive operations. |
| **Leaked session token** | Has a 32-byte bearer token. | Tokens are revocable (`revokeSession`); session refresh rotates the token (old token immediately invalid); session expiry caps the validity window; `verifySessionToken` constant-time compares against the SHA-256 hash, so a partial token leak doesn't enable timing attacks. |
| **Leaked share token** | Has a `shr_` bearer token. | Single-use shares are atomically consumed on first verify (concurrent verifies of the same single-use token race-correctly to exactly one success); revocation is immediate (`revokeShare`); 365-day spec ceiling on `expires_at`; tokens are SHA-256 hashed at rest. |
| **Misuse-of-invitation** | Has been targeted by someone else's invitation and tries to accept it as themselves. | ADR 0009 acceptance binding: when an existing `usr_id` is supplied to `acceptInvitation`, the caller MUST also supply `accepting_identifier` matching `invitation.identifier` byte-for-byte. Closes a privilege-escalation primitive reported as `spec#5`. |
| **Compromised passkey authenticator** | Cloned WebAuthn authenticator (sign-counter manipulation). | WebAuthn assertion verification enforces `signCount` monotonicity per W3C spec §6.1.1 cloned-authenticator detection. Counter decrease invalidates the assertion and SHOULD trigger credential revocation in the adopter's policy. |
| **Compromised application server** | Adversary has code execution inside the application process. | **Out of scope.** Flametrench's defenses operate inside this trust boundary. An adopter requiring defense against application compromise needs additional layers (e.g., per-tenant DB roles + RLS, hardware-backed signing, dedicated identity service). |
| **Compromised database (read-only exfil)** | Adversary obtained a copy of the production database but cannot write. | Argon2id hashes resist offline cracking at the OWASP floor; recovery codes are also Argon2id-hashed; share tokens and session tokens stored only as SHA-256 hashes; passkey public keys and OIDC subjects are not sensitive (public key cryptography). Tenancy state IS readable: org membership graph and authorization tuples leak unencrypted. Database-level encryption is the adopter's defense for the membership/tuple graph. |
| **Compromised database (read-write)** | Adversary can write rows. | **Out of scope.** Equivalent to compromising the application. RLS as an optional companion (see `reference/postgres-rls.sql`) limits blast radius to the connected DB role. |

## Trust boundaries

Numbered from outside-in:

1. **Browser ↔ application server.** TLS-protected (adopter's responsibility). Anything traversing this boundary is treated as adversary-controlled at the spec layer.
2. **Application server ↔ Flametrench SDK.** Function calls in-process. Flametrench SDKs assume the calling code is honest about its inputs (e.g., a `subjectId` passed to `check()` is assumed to belong to the actual authenticated user, not a victim). Adopters MUST validate session ownership before passing a `usr_id` into the authz layer.
3. **Flametrench SDK ↔ store.** The store interface is pluggable (in-memory or Postgres-backed). All SQL queries in the Postgres-backed stores are parameterized; no string concatenation into SQL.
4. **Store ↔ database.** Database-level — adopter terminates this boundary with their DB credentials, network policy, and (optionally) RLS.

## Primitive-level security claims

### `usr_` — User

- **Opaque.** The `usr` row in the reference schema has only `id` and `status`. No PII (no email, no display name, no phone). Adopters that need PII layer it on in their own table and bridge by `usr_id`.
- **Status-gated.** A `usr` with `status = 'suspended'` or `'revoked'` cannot be the subject of session creation, credential creation, MFA enrollment, or share-token minting.
- **Cascade semantics are explicit.** Revoking a user revokes all credentials, terminates all sessions, and revokes all MFA factors atomically. The reference schema enforces FK cascades; the SDK enforces the application-layer cascade for non-FK relationships.

### `cred_` — Credential

- **Argon2id is pinned.** Password credentials use parameters at or above the OWASP floor (`m=19456, t=2, p=1`). Implementations MUST NOT use bcrypt, scrypt, PBKDF2, or any non-Argon2id verifier ([ADR 0006](../decisions/0006-argon2id-parameters.md)).
- **Cross-language byte parity.** A PHC hash produced by any of the four SDKs verifies identically in all four. The conformance suite enforces this with shared test vectors.
- **No legacy-verifier hook.** The spec does not provide a pluggable "verify against the old bcrypt hash" path. Adopters migrating from a legacy hasher use verify-then-rotate at sign-in time (read your old hash, verify, then write a new Argon2id credential and revoke the old one).
- **Sensitive material is never returned.** `getCredential` returns the public credential shape; password hashes, passkey public-key bytes (technically not sensitive but consistently omitted), and OIDC issuer/subject pairs are accessed through verification-bound APIs only.

### `ses_` — Session

- **Bearer token ≠ session id.** The session ID is a tracking handle (appears in audit logs, admin views). The bearer token is 32 cryptographically-random bytes, base64url-encoded, returned exactly once from `createSession` / `refreshSession`.
- **Hash-at-rest.** Only the SHA-256 hash of the token is persisted. The plaintext token never appears in the database. `verifySessionToken` does a constant-time compare against the hash.
- **Rotation on refresh.** `refreshSession` mints a new session id, new token, and revokes the old session atomically. The previous token is invalid the instant `refreshSession` returns. In-place refresh is non-conformant.
- **Cascade on credential change.** Rotating a credential (e.g., password change) terminates every session bound to that credential. Suspending or revoking a credential terminates its sessions.

### `mfa_` — MFA factor (v0.2)

- **TOTP secrets are stored as raw bytes** in `mfa.totp_secret BYTEA`. They cannot be Argon2id-hashed because TOTP verification requires the symmetric secret to compute the expected code. Implementations SHOULD encrypt this column at rest using application-layer encryption (`pgcrypto.pgp_sym_encrypt` with an app-held key, or an external KMS). The SDK does not enforce this — column-level encryption is the adopter's responsibility, called out explicitly here so it isn't missed. The plaintext secret is returned exactly once at enrollment for QR provisioning; subsequent `verifyMfa` calls only see the code, not the secret.
- **Recovery codes are single-use AND Argon2id-hashed.** A consumed code is marked consumed atomically (`UPDATE … WHERE consumed = false RETURNING …`); concurrent attempts to consume the same code race correctly to one success.
- **WebAuthn assertion verification enforces signCount monotonicity.** A counter that decreases between assertions is treated as cloned-authenticator evidence and the assertion fails.
- **Per-user policy with grace window.** `usr_mfa_policy` carries a `grace_until` timestamp. After the grace window, `verifyPassword` returns `VerifiedCredential` with `mfa_required = true` (additive field; `false` when no policy is active or when the grace window hasn't elapsed). The application MUST call `verifyMfa` before `createSession` when `mfa_required` is true. Adopters who do not configure a policy see `mfa_required = false` always, with no behavioral change. The SDK does not block `createSession` itself when `mfa_required` is true — that gate is the application's responsibility, since the policy decision (e.g., "warn for grace, hard-fail after") varies by deployment.

### `org_` / `mem_` / `inv_` — Tenancy

- **Sole-owner protection is mechanical.** Every code path that could leave an org with zero active owners (`changeRole` on the only owner, `suspendMembership` on the only owner, `selfLeave` of the only owner without `transferOwnership`) raises `SoleOwnerError` before mutating state. The conformance suite has an explicit fixture for each path.
- **Role hierarchy on `adminRemove`.** An admin can remove members and other admins-of-lower-rank, but cannot remove an owner; only `transferOwnership` can demote an owner. Conformance fixtures cover the rank table.
- **Revoke-and-re-add audit trail.** Role changes are not in-place: the existing `mem_` is revoked and a new one is created with `replaces` set to the old `mem_id`. "Who promoted Bob?" has a deterministic answer keyed off the `replaces` chain.
- **Atomic invitation acceptance.** `acceptInvitation` performs (a) user creation if needed, (b) membership insertion, (c) owner-role tuple creation, AND (d) pre-tuple expansion in a single transaction. Partial application is impossible; concurrent acceptance attempts race correctly to one success.
- **ADR 0009 acceptance binding.** When `as_usr_id` is supplied, `accepting_identifier` MUST be supplied AND MUST byte-match `invitation.identifier`. Closes a privilege-escalation primitive where any authenticated user could accept any invitation. Backported into v0.1.x; non-conformant SDKs are explicitly rejected.

### `pat_` — Personal access token (v0.3)

- **Argon2id hash at the cred-password parameter floor.** PAT secrets are never persisted in plaintext; the server retains an Argon2id hash (m=19456, t=2, p=1) of the secret segment ([ADR 0016](../decisions/0016-personal-access-tokens.md)). Plaintext is returned exactly once at mint time.
- **Bearer wire format `pat_<32hex>_<base64url>`.** The leading `pat_` prefix is normative and lets `resolveBearer` dispatch by scheme without first-row probing — a malformed bearer is rejected on length/charset alone, before any DB read.
- **Constant-time secret verification.** Implementations MUST run Argon2id verify even when the row lookup misses (using a fixed dummy PHC hash) so that "row missing" and "wrong secret" take the same wall time. ADR 0016 §"Verification semantics" pins the dummy hash for cross-SDK conformance.
- **365-day spec ceiling on `expires_at`.** `createPat(expires_at=…)` over 31,536,000 seconds in the future raises `InvalidFormatError`. There is no escape hatch; longer-lived automation rotates a PAT.
- **`last_used_at` updates are revoke-aware.** The verify path's `UPDATE pat SET last_used_at = ? WHERE id = ? AND revoked_at IS NULL` MUST gate on the not-revoked predicate so a token revoked between row read and write does not silently re-arm. Implementations MAY coalesce `last_used_at` writes within a configurable window (60s default) to avoid a write-per-request hot path.
- **Lifecycle errors precede the secret check — explicit trade-off.** ADR 0016's 8-step order surfaces `PatRevokedError` and `PatExpiredError` BEFORE the Argon2id verify. This means anyone holding a stolen `pat_id` (e.g. from log scrape) can probe `active vs revoked vs expired vs not-exist` without the secret. The spec accepts this leak: the existence of a PAT id is not itself sensitive (it appears in audit logs and dashboards by design), and fail-fast on terminal state is a more useful signal for adopter logging and incident response than the marginal leak it costs. The secret is the only thing that grants access.
- **Adopter MUST gate PAT management routes.** `createPat`, `getPat`, `listPatsForUser`, `revokePat` enforce no authorization at the SDK layer. Without route-layer gating an authenticated user can mint, read, or revoke any other user's PAT. Mirrors the spec-wide "SDK does not gate; adopter does" pattern.

### `tup_` / `shr_` — Authorization

- **Default exact-match.** `check()` returns true iff a tuple with the exact 5-tuple natural key exists. No relation implication. No parent-child inheritance. No group expansion. Adopters opt into rewrite rules ([ADR 0007](../decisions/0007-authorization-rewrite-rules.md)) explicitly when they want hierarchies.
- **Rewrite-rule depth and fan-out caps.** Even with rules registered, evaluation depth is capped at 8 and fan-out at 1024 per the ADR. A pathological rule set raises `RewriteEvaluationLimitError` instead of unbounded compute.
- **Share-token verification ordering is normative.** revoked > consumed > expired > success. This ordering matters: a share that is BOTH revoked and consumed surfaces as `ShareRevokedError`, not `ShareConsumedError`. Stable error precedence makes adopter logging and incident response deterministic.
- **Single-use shares race correctly.** Concurrent verifies of a single-use token result in exactly one success and N-1 `ShareConsumedError` — enforced by `UPDATE … WHERE consumed_at IS NULL RETURNING …`.
- **365-day spec ceiling on share lifetime.** `createShare(expires_in_seconds=…)` over 31,536,000 raises `InvalidFormatError`. There is no escape hatch; longer-lived access requires session-based authentication.

## Known gaps and explicit non-goals

Flametrench's narrow scope means the spec deliberately does NOT define:

- **Rate limiting.** No primitive limits sign-in attempts, password-reset requests, or MFA verifications. Adopters MUST implement rate limiting at the HTTP layer (or a more sophisticated tier) — Flametrench provides no defense against brute-force or credential-stuffing.
- **Anomaly / bot detection.** No "this sign-in looks suspicious" signal. CAPTCHAs, device fingerprinting, IP reputation — all out of scope.
- **Audit logging.** v0.2 does not specify an audit primitive. The `aud_` prefix is reserved for v0.3+. Tenancy operations expose enough metadata (`replaces` chain, `removedBy`, `terminalBy`, `terminalAt`) for adopters to log durably; adopters wire that to their preferred audit backend.
- **Password reset flow.** The spec defines credential rotation (`rotatePasswordCredential`) and session cascade. The end-to-end "user requests reset → email link → set new password" UX is the adopter's design — Flametrench provides the primitives, not the flow.
- **Email / SMS delivery.** Invitation delivery (the `inv.identifier` is just an opaque string from the spec's perspective), MFA enrollment links, password reset links — Flametrench does not send any of these. Adopter integrates their own delivery service.
- **Encryption at rest.** Beyond the per-column protections described above (Argon2id for passwords/recovery codes, SHA-256 for session/share tokens), Flametrench does not specify table-level or column-level encryption. The `mem`, `tup`, `inv`, and `org` tables hold readable data; adopters needing defense against DB exfiltration enable storage-level encryption.
- **DoS protection.** Beyond the rewrite-rule depth/fan-out caps, no primitive defends against DoS. A flood of `verifySessionToken` calls will exercise Argon2id (no — only password verification does Argon2id; session verification is just SHA-256). Still, adopters MUST front the application with infrastructure-level DoS defenses.
- **Supply-chain integrity.** SLSA / Sigstore / SBOM — not in scope. Adopters verify their dependencies through their own supply-chain controls. Flametrench publishes SDKs to npm / Packagist / PyPI / Maven Central with maintainer-signed releases (PGP for Java; npm 2FA for Node; etc.) but does not specify supply-chain claims for adopters.

## Adopter responsibilities

To maintain Flametrench's security posture in a real deployment, adopters MUST:

1. **Terminate TLS** at the network ingress. Flametrench's bearer tokens are not protected on the wire by the SDK; the wire is the adopter's domain.
2. **Rate-limit auth endpoints.** Sign-in, password-reset request, MFA verify, invitation accept — all of these become brute-force surfaces if not rate-limited.
3. **Validate session ownership before passing a `usr_id` to the authz layer.** The SDK trusts that the calling code is being honest about which user is making the request. A bug here turns into an authorization bypass.
4. **Encrypt the database at rest** if the membership/tuple graph is sensitive. Flametrench's per-column protections defend credentials; the rest of the data model is plaintext.
5. **Rotate database credentials** on schedule. Flametrench has no opinion about how, but assumes rotation happens.
6. **Wire audit logging.** Flametrench operations expose enough metadata; adopters connect that to their audit backend.
7. **Enforce MFA enrollment** before allowing sensitive operations. Flametrench gates session creation on policy when enrolled, but does not force enrollment — that's a business decision.
8. **Validate IdP tokens** if using external-IdP integration (see `external-idps.md`). Audience matching, issuer matching, signature verification with refresh — adopter's domain.

## Disclosure

Security issues should be reported to `nate@site-source.com`. We aim to acknowledge within 48 hours. Public disclosure timeline is negotiable but defaults to 90 days from acknowledgement.

Past security-relevant issues:

- [`spec#5`](https://github.com/flametrench/spec/issues/5) — invitation acceptance privilege escalation. Reporter: sitesource/admin (adoption surface). Patched in v0.1.x via [ADR 0009](../decisions/0009-invitation-accept-binding.md).
- [`spec#8`](https://github.com/flametrench/spec/issues/8) — wire-format `object_id` rejected by strict decode in Postgres adapters (correctness, not security; included for transparency). Patched in v0.2.0-rc.4.
