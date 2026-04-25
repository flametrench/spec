# Identity fixtures

Conformance fixtures for the identity capability (`docs/identity.md`). Today these focus on the cross-language Argon2id parity test — the most important interop check in the suite, because any real identity SDK MUST verify hashes produced by any other.

## v0.1 — runnable today

| File             | Operation         | Tests | What it locks down |
| ---------------- | ----------------- | ----: | ------------------ |
| `argon2id.json`  | `verify_password` |     3 | A real PHC-encoded Argon2id hash produced at the spec floor (`m=19456, t=2, p=1`) MUST verify against its plaintext on every conforming SDK, MUST reject any other plaintext, and MUST reject the empty string. This is THE cross-SDK parity test for password hashing. |

The fixture hash:

```
$argon2id$v=19$m=19456,t=2,p=1$779z4UHkLWR4w0TEo9gcHg$Gz0+nGnpokhsKi1cPlx8i74FBN1Nq0OURZ3xso1AHMU
```

was produced with the Node `argon2` package at the spec floor (m=19456 KiB, t=2, p=1, 16-byte salt, 32-byte tag). It should verify identically under PHP `sodium_crypto_pwhash_str_verify`, Python `argon2-cffi`, Java `de.mkammerer.argon2`, and any other libsodium- or reference-Argon2-derived implementation.

## v0.1 — deferred

These will land alongside the identity SDKs that implement them:

- **`password-hash-floor.json`** — a hash below the spec floor (e.g. `m=4096, t=1, p=1`) MUST be flagged by a policy check as non-conformant.
- **`oidc-issuer-normalization.json`** — `findCredentialByIdentifier` normalizes OIDC issuer URLs (trailing slash, host case) so superficially different inputs resolve to the same credential.
- **`session-rotation.json`** — `refreshSession` produces a new session id, marks the original `revoked_at`, and preserves `usr_id` / `cred_id` linkage.

## Fixture format

Inputs and outputs are operation-shaped:

```jsonc
{
  "input":    { "phc_hash": "...", "candidate_password": "..." },
  "expected": { "result": true | false }
}
```

See `spec/docs/identity.md#hashing-requirements` for the normative behavior.
