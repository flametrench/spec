# Identity fixtures (placeholder for v0.1.0)

No identity fixtures are runnable yet because no Flametrench SDK has published an identity layer: the current `@flametrench/ids` and `flametrench/ids` packages cover only the wire-format identifier spec.

When the first identity SDK lands, the following fixtures will be added here:

- **`argon2id.json`** — a known-good PHC-encoded Argon2id hash of a fixed password with spec-floor parameters. `verifyPassword("correcthorsebatterystaple", <phc-hash>)` MUST return `true` on any conforming implementation. `verifyPassword("wrong", <phc-hash>)` MUST return `false`.
- **`password-hash-floor.json`** — a hash with parameters below the spec floor (e.g. `m=4096,t=1,p=1`); a conformant policy check MUST reject such a hash as non-conformant.
- **`oidc-issuer-normalization.json`** — given OIDC credentials with superficially different issuer URLs (trailing slash, mixed host case) but semantically the same issuer, `findCredentialByIdentifier` MUST return the same credential.
- **`session-rotation.json`** — given an active session, `refreshSession` MUST produce a new session with a different `id`, mark the original `revoked_at`, and preserve `usr_id` / `cred_id` linkage.

See `spec/docs/identity.md` for the normative behavior the fixtures will exercise.
