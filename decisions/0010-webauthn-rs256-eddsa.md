# 0010 — WebAuthn RS256 + EdDSA

**Status:** Accepted
**Date:** 2026-04-26

## Context

[ADR 0008](./0008-mfa.md) defined WebAuthn assertion verification with ES256 only. ES256 covers every modern platform authenticator (Touch ID, Face ID, Windows Hello, every YubiKey shipped in the last six years), so v0.2's release-candidate is functionally complete for the 95th-percentile adopter.

The remaining 5% — and a steadily growing share of older / cheaper hardware tokens, plus Android Safety-Net attestation, plus some passkey providers that auto-provision RSA keys — relies on RS256 (RSA-PKCS#1 v1.5 + SHA-256) or EdDSA (Ed25519). ADR 0008 explicitly deferred these to v0.3; this ADR retires that deferral.

## Decision

`webauthn_verify_assertion` MUST accept ES256, RS256, and EdDSA assertions byte-identically across all four SDKs. The SDK detects the algorithm from the COSE_Key's `alg` field and dispatches to the matching primitive:

| COSE `alg` | Algorithm | COSE `kty` | Notes |
|---|---|---|---|
| `-7` | ES256 (ECDSA P-256 + SHA-256) | `2` (EC2), `crv: 1` | Already shipped in v0.2.0-rc.1 |
| `-257` | RS256 (RSASSA-PKCS1-v1_5 + SHA-256) | `3` (RSA), `n` + `e` | New in this ADR |
| `-8` | EdDSA (Ed25519) | `1` (OKP), `crv: 6`, `x` | New in this ADR |

The `alg` value is taken from the registration-time COSE_Key only. The assertion does not re-declare the algorithm; the SDK uses whatever the credential was registered with. This matches the WebAuthn spec and prevents algorithm-substitution attacks (an attacker cannot present an EdDSA signature against a key that was registered as RS256).

### COSE_Key shapes (per RFC 8152)

**RS256:**
```
{
   1 (kty): 3,        # RSA
   3 (alg): -257,     # RS256
  -1 (n):   <bigint, raw bytes, leading zero stripped>,
  -2 (e):   <bigint, usually 65537 = 0x010001>,
}
```

**EdDSA / Ed25519:**
```
{
   1 (kty): 1,        # OKP
   3 (alg): -8,       # EdDSA
  -1 (crv): 6,        # Ed25519
  -2 (x):   <32 raw bytes>,
}
```

The CBOR decoder added in the v0.2.0-rc.1 push already handles both shapes; only the algorithm dispatch in `_parse_cose_*` and the verifier itself need to grow.

### Signature format on the wire

- ES256: DER-encoded ECDSA `SEQUENCE { INTEGER r, INTEGER s }`. (Already handled.)
- RS256: raw RSA signature, length = key modulus length (typically 256 bytes for 2048-bit RSA, 384 for 3072-bit, 512 for 4096-bit).
- EdDSA: 64 raw bytes (Ed25519 fixed signature length).

The SDK accepts whatever length the algorithm prescribes; it does not pad or truncate.

### Key-size policy

- **RS256**: minimum 2048-bit modulus. Anything smaller MUST be rejected with `WebAuthnUnsupportedKeyError(reason=key_too_small)`. The 2048-bit floor matches WebAuthn spec §5.8.5 ("Authenticator algorithm requirements") and NIST SP 800-131A.
- **EdDSA**: only Ed25519 (`crv: 6`). Ed448 (`crv: 7`) MAY be added in a future ADR; this one does not commit.

## Consequences

- **No new error reasons** beyond the existing `signature_invalid`, `unsupported_key`, `malformed`. The new key-size floor reuses `unsupported_key` with a distinct message.
- **Library reliance:** Python uses `cryptography`, Node uses `node:crypto`, PHP uses `ext/openssl` (EdDSA requires PHP 8.1+ openssl with libsodium fallback), Java uses `java.security` (EdDSA requires JDK 15+, all four target JDKs are 17+ so this is met). Per ADR 0008, the spec permits using vetted libraries for primitives; Flametrench owns the verification flow.
- **Conformance fixtures grow:** the existing `webauthn-assertion.json` adds 6 more tests (3 algorithms × valid + signature-invalid). The existing `webauthn-counter-decrease-rejected.json` is algorithm-agnostic and does not change.
- **Spec version:** this ADR ships under v0.2 — it lands in the rc cycle as v0.2.0-rc.2 if accepted before final. Adopters who already integrated rc.1 against ES256 keep working without changes.

## Alternatives considered

### Defer to v0.3

The original ADR 0008 plan. Rejected on second look because:

1. The implementation cost is small (~150 LOC per SDK; the CBOR decoder, flag enforcement, counter check, and JSON parsing are all reusable).
2. The fixture cost is small (6 new test vectors, deterministic generation).
3. Adopters with mixed authenticator inventories (e.g. enterprise rollouts inheriting older hardware tokens) would otherwise have to fall back to a non-Flametrench library for those credentials — defeating the cross-SDK parity claim.
4. Adding the algorithms in the v0.2 rc cycle is cheaper than deferring to v0.3 because the harness is already in place; coming back to it in 6 months means re-loading the context.

### Detect algorithm from the assertion rather than the COSE_Key

Some libraries let the assertion declare its own algorithm. Rejected because it permits algorithm-substitution attacks: an attacker who exfiltrates an RS256 signature can attempt to present it as ES256 (with appropriate transformations) and have the verifier guess wrong. The COSE_Key is registered server-side and trusted; the assertion is presented client-side and is not.

## References

- [W3C WebAuthn Level 2 §5.8.5](https://www.w3.org/TR/webauthn-2/#sctn-alg-identifier) — algorithm identifier registry.
- [RFC 8152 §13](https://datatracker.ietf.org/doc/html/rfc8152#section-13) — COSE algorithm registry; `alg` values authoritative.
- [RFC 8230 §4](https://datatracker.ietf.org/doc/html/rfc8230#section-4) — RSA COSE_Key shape.
- [RFC 8037 §2](https://datatracker.ietf.org/doc/html/rfc8037#section-2) — OKP / Ed25519 COSE_Key shape.
- [`decisions/0008-mfa.md`](./0008-mfa.md) — parent ADR; this one supersedes its "RS256/EdDSA deferred" line.
