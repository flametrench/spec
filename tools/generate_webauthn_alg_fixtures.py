#!/usr/bin/env python3
# Copyright 2026 NDC Digital, LLC
# SPDX-License-Identifier: Apache-2.0

"""Generate the webauthn-assertion-algorithms.json conformance fixture.

Tests the algorithm-dispatch path of webauthn_verify_assertion across
the three v0.2 algorithms (ADR 0010): ES256, RS256, EdDSA.

Fixed keypairs:
  - ES256: derived from the same scalar as webauthn-assertion.json.
  - RS256: generated once and pinned as a PEM-loaded keypair below.
  - EdDSA (Ed25519): generated once and pinned as a 32-byte raw seed.

The pinned PEM / seed values here are TEST DATA ONLY. They are
checked into the public spec repo and MUST NEVER be reused for
production keys. Keys are pinned (rather than re-generated each run)
so the fixture is byte-stable.
"""

from __future__ import annotations

import base64
import hashlib
import json
import struct
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa

# ─── Pinned key material ────────────────────────────────────────

# ES256 — same scalar as webauthn-assertion.json so adopters can
# correlate vectors across the two fixtures.
ES256_SCALAR = int(
    "C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721", 16
)

# RS256 — 2048-bit RSA private key (PKCS#8 PEM). Generated once via
# `openssl genrsa 2048` and pinned. Test data only.
RS256_PRIVATE_PEM = b"""-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCr4EqgFeuXVUi0
a/2uf7bEpNrjegHq6X8fa5Yr4tzWk2xL07rO3pEkgI5nyttGWEvaTAMabLbgfGBW
0S26x/9GSDAuIi32Qvyy9DnjjhTK2GXqFf0EWDBr4LGl07ARu/ncmPJ20L4sdgpG
3PRwUZ/d52zx9/4TMWZwcx/XK/KSEImIBw8AUTHIgp127cXczlAeRvROCjNaIpQO
u2UNLpJNqXYTbYvEwyWpiIuorFRYgHpIpEWfkfyZ7/UMBiYKQHbcDZhSJfhX3auh
aM3XdUZLr6+6ZooExdJiXnOqbMOupAjnsQBD28gRfmhPIYOxfr+J7M9wMY6iZSJW
c1LhesGNAgMBAAECggEADftpVA7ByLYbUR10OJjy/JofpL/qaNqVaPAxj4DoBRG0
TpKFy39E0J11Auxi/FzsUMYnE3l9bWjY1SnfqJFNYEGOSoElJY02AvXbbA+v0SpG
V4MclJj7BBpLlrP69Q+1HXUYy8HNUrnIj2gOqkDNpU7xaIQg4x1SmiUXau5MOwW4
vq9HH2XHxBkS+Fwc7IyG6kDXuSVkpgKzIFNvNQtKooJtQgjiqKE8IkUSTZwmCuTf
cXvbaxKXi+Uvi7ExwHPUu7YNKo3uXgYd52rJfUhM/7lR1VNYyILNptxC96hsmSqW
R6xEroD+rgGd4H0dDNcWo9AJYhlwJgZk9/1kUqTB6QKBgQDVsWFtPZLQgyJxmxgr
N1opA2Zrs23hw4lxEZ7DzM3Ya8ySkOUzUXj8IA0RRqzzTr7yas8fgaweVvi0NXFE
GlOW1m2c3fyxLkaw/XE+P54JZr23Skq0jxEJ7dcEAuVsAql8RcE5Qq6OCMdjLuPH
WMQvTuPLN4ENfJpj0DakQPBpFQKBgQDN54IKU2ygcYwWfHjdeXv5Kbvq5lotQoTu
S+rQfEiOjFposxljauVSRHe5px/ucmbSaox7xVySuiAhfBwKtXTQpXwWVJCx5R0p
qeyLoeLuvK71qnws26eYL5zIue2x6GpgSL4EuchUYioy8wiK8WzL4XuJR1r2O0Hz
jY/3DjEkmQKBgHANVDYRDHQT3zLNDc5Tdw58fu9Ipfy1KNPGVob7VJEAbcQJAHZ5
aURjlhaSBcyLZSr+gN9XgqZiGoV8ZIk+eMhmZhHUgVVzG5RhQUlP2JG7cw2yghvN
zTR0p8OttRl/B9pnRVu+MIO/7LWAd+YnELBx4JbF4wDsbpSaMJzOhIHFAoGAf67Q
NRcGhXfkJw2I5c4v0pLOtRujT+2wARWSxzZKyBrA9awaUkw3aIyMsdOxOWw31sO7
2gTJIzPIOPt9aCaeCcSU7kQCdk5dhziYNv5sex8GX9EYr7iGdRkRYGfrvich0BNL
wiJy1+EHyhBre726ebOZp8dX4NleTGm8nLdwQgECgYAGlVJopGZzXsgY8jY0IEJm
mUBgDo6AU42xawCQHc2zesqtWka0tGZt1XILMmt49gVgwvl1o6sKAGWULXWaGBjv
IcLnbiODfBqLIP78UJgEILqGSKXEZpYQaXYsrldGJXrqQWr2+km8cBDERWRPf7HE
8Wr0ynf5B6g8GITJFXBIHQ==
-----END PRIVATE KEY-----
"""

# EdDSA — Ed25519 32-byte private seed (hex). The corresponding public
# key is derived deterministically.
EDDSA_PRIVATE_SEED_HEX = (
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
)

RP_ID = "flametrench.test"
ORIGIN = "https://flametrench.test"
CHALLENGE = b"flametrench-webauthn-challenge-v0.2"

REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = REPO_ROOT / "conformance" / "fixtures" / "identity" / "mfa"


# ─── COSE_Key encoders ──────────────────────────────────────────


def cose_es256(x: bytes, y: bytes) -> bytes:
    """COSE_Key for ES256 / P-256 — already validated by ADR 0008."""
    return (
        b"\xa5"
        + b"\x01\x02"
        + b"\x03\x26"
        + b"\x20\x01"
        + b"\x21\x58\x20" + x
        + b"\x22\x58\x20" + y
    )


def cose_rs256(n: bytes, e: bytes) -> bytes:
    """COSE_Key for RS256 / RSA per RFC 8230.

    Map(4):
       1 (kty): 3            (RSA)
       3 (alg): -257         (RS256)
      -1 (n):   bytes(...)   (modulus, big-endian, leading zero stripped)
      -2 (e):   bytes(...)   (public exponent, typically 65537 = 010001)
    """
    n_stripped = n.lstrip(b"\x00") or b"\x00"
    e_stripped = e.lstrip(b"\x00") or b"\x00"
    return (
        b"\xa4"  # map(4)
        + b"\x01\x03"  # kty=3
        + b"\x03\x39\x01\x00"  # alg=-257 (negative int, 2-byte payload: 0x0100=256, -1-256=-257)
        + cbor_neg_int_label(-1) + cbor_byte_string(n_stripped)
        + cbor_neg_int_label(-2) + cbor_byte_string(e_stripped)
    )


def cose_eddsa(x: bytes) -> bytes:
    """COSE_Key for EdDSA / Ed25519 per RFC 8037.

    Map(4):
       1 (kty): 1     (OKP)
       3 (alg): -8    (EdDSA)
      -1 (crv): 6     (Ed25519)
      -2 (x):   bytes(32)  (raw public key)
    """
    if len(x) != 32:
        raise ValueError(f"Ed25519 public key must be 32 bytes, got {len(x)}")
    return (
        b"\xa4"  # map(4)
        + b"\x01\x01"  # kty=1
        + b"\x03\x27"  # alg=-8 (negative int, info=7 → -1-7=-8)
        + b"\x20\x06"  # crv=6 (-1 → 0x20; 6 inline)
        + b"\x21\x58\x20" + x  # x: bytes(32)
    )


def cbor_neg_int_label(n: int) -> bytes:
    """Encode a small negative integer (-1 .. -23) as a single CBOR byte."""
    if not (-24 <= n <= -1):
        raise ValueError(f"This helper only handles -1..-23, got {n}")
    return bytes([0x20 | (-1 - n)])


def cbor_byte_string(b: bytes) -> bytes:
    """CBOR byte-string with the smallest valid length encoding."""
    length = len(b)
    if length < 24:
        return bytes([0x40 | length]) + b
    if length < 256:
        return bytes([0x58, length]) + b
    if length < 65536:
        return bytes([0x59, (length >> 8) & 0xFF, length & 0xFF]) + b
    raise ValueError(f"byte-string too long for this helper: {length}")


# ─── Helpers ────────────────────────────────────────────────────


def b64url(buf: bytes) -> str:
    return base64.urlsafe_b64encode(buf).rstrip(b"=").decode("ascii")


def make_auth_data(rp_id: str, flags: int, sign_count: int) -> bytes:
    rp_hash = hashlib.sha256(rp_id.encode("utf-8")).digest()
    return rp_hash + bytes([flags]) + struct.pack(">I", sign_count)


def make_client_data(challenge: bytes, origin: str) -> bytes:
    payload = {"type": "webauthn.get", "challenge": b64url(challenge), "origin": origin}
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")


# ─── Per-algorithm assertion synthesis ──────────────────────────


def synth_es256_signature(scalar: int, signed: bytes) -> bytes:
    private = ec.derive_private_key(scalar, ec.SECP256R1())
    return private.sign(signed, ec.ECDSA(hashes.SHA256()))


def synth_rs256_signature(pem: bytes, signed: bytes) -> bytes:
    private = serialization.load_pem_private_key(pem, password=None)
    return private.sign(
        signed,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )


def synth_eddsa_signature(seed_hex: str, signed: bytes) -> bytes:
    private = ed25519.Ed25519PrivateKey.from_private_bytes(bytes.fromhex(seed_hex))
    return private.sign(signed)


# ─── Pubkey extraction ──────────────────────────────────────────


def es256_cose() -> bytes:
    private = ec.derive_private_key(ES256_SCALAR, ec.SECP256R1())
    pub = private.public_key().public_numbers()
    return cose_es256(pub.x.to_bytes(32, "big"), pub.y.to_bytes(32, "big"))


def rs256_cose() -> bytes:
    private = serialization.load_pem_private_key(RS256_PRIVATE_PEM, password=None)
    pub = private.public_key().public_numbers()
    n_bytes = pub.n.to_bytes((pub.n.bit_length() + 7) // 8, "big")
    e_bytes = pub.e.to_bytes((pub.e.bit_length() + 7) // 8, "big")
    return cose_rs256(n_bytes, e_bytes)


def eddsa_cose() -> bytes:
    private = ed25519.Ed25519PrivateKey.from_private_bytes(
        bytes.fromhex(EDDSA_PRIVATE_SEED_HEX)
    )
    pub_bytes = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return cose_eddsa(pub_bytes)


# ─── Small RSA key for the key-too-small test ───────────────────


def small_rsa_cose() -> bytes:
    """A 1024-bit RSA key — below the v0.2 floor; MUST be rejected."""
    # Generated once via `openssl genrsa 1024`. Test data only.
    pem = b"""-----BEGIN PRIVATE KEY-----
MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBALLbuP48T/ufQsG5
4q8ufRpbnvnYf45ZhqOVelUCduqDzofNo2cZnzikGYAuWf/P+OzJmK/2+0KOV+4z
L88ZuhZQJ9Dnug0qIDGAbnBehA3uWUMdl0TXE0rymkxNJXU9gGQcA8uDmatU2f8O
gDvRBIu322b5j47APrcmBgHYTTLvAgMBAAECgYAOCHtNR0InRemg9Yq5n/Yk2Udx
5vCrJI8RyqqcfOMDp2/O6+2EK1h4wzdU/U4GajTnrzGRrNkt8akogU+g+i3FbMiT
hGOZlpfXewPZ1La0FduIsK1AeUNL5ukCNI+kxLQXUq3+dfEv/wBUVHGoPr/YOblm
x00JxiNmPrWjC0/PgQJBAOGWMbAbNbnHS9JH45pKAjg7PYQV+xeHTLCeyEP7Ax0U
7rJqtMmQRjYbPQOVgfcmiuVyROxiwdoFT2II7XC3v2ECQQDK+MODVtoeIQiWYtk1
tl8f+z5x4NHv80qFDHywWt8KkhdgxSR4iSYuXJz2mtW2BEo6YfBUelBGprdq+hrU
X6RPAkA5KdUXeh2oIP9unrbnHv/m/eP9t5A0Cx3814+J4m6MjQRbg7yiIwQXq9lP
MjCHz2V89PLQL8pNk/Dkt7xrRrShAkAygCaVHRzz9iAe2sVUeeW9HVPyHY/eddgK
toqnjlSEWsj6SNLEMsuPKXfcW7XkrbiSQh/7xNsIWR61vTjDsnA9AkBlKb6HyGXq
NTJpideeUxrGmOQaC7CYq+4aq3rl3Zv8ZMgbktxu8oRcJAQoimQU49W9A8xT3rTO
8P9LLQQROFAI
-----END PRIVATE KEY-----
"""
    private = serialization.load_pem_private_key(pem, password=None)
    pub = private.public_key().public_numbers()
    n_bytes = pub.n.to_bytes((pub.n.bit_length() + 7) // 8, "big")
    e_bytes = pub.e.to_bytes((pub.e.bit_length() + 7) // 8, "big")
    return cose_rs256(n_bytes, e_bytes), pem


# ─── Build the fixture ──────────────────────────────────────────


def build_test(
    test_id: str,
    description: str,
    cose_pub_hex: str,
    auth_data_hex: str,
    client_data_hex: str,
    signature_hex: str,
    expected: dict,
) -> dict:
    return {
        "id": test_id,
        "description": description,
        "input": {
            "authenticator_data_hex": auth_data_hex,
            "client_data_json_hex": client_data_hex,
            "signature_hex": signature_hex,
            "cose_public_key_hex": cose_pub_hex,
            "require_user_verified": True,
            "require_user_present": True,
        },
        "expected": {"result": expected},
    }


def main() -> None:
    flags = 0x05  # UP=1, UV=1
    sign_count = 7
    auth = make_auth_data(RP_ID, flags, sign_count)
    client = make_client_data(CHALLENGE, ORIGIN)
    signed = auth + hashlib.sha256(client).digest()

    es256_sig = synth_es256_signature(ES256_SCALAR, signed)
    rs256_sig = synth_rs256_signature(RS256_PRIVATE_PEM, signed)
    eddsa_sig = synth_eddsa_signature(EDDSA_PRIVATE_SEED_HEX, signed)

    es256_pub = es256_cose()
    rs256_pub = rs256_cose()
    eddsa_pub = eddsa_cose()
    small_rsa_pub, _ = small_rsa_cose()

    # Tampered signatures (last byte flipped).
    rs256_bad = bytes(rs256_sig[:-1] + bytes([rs256_sig[-1] ^ 0x01]))
    eddsa_bad = bytes(eddsa_sig[:-1] + bytes([eddsa_sig[-1] ^ 0x01]))

    fixture = {
        "$schema": "../../../fixture.schema.json",
        "spec_version": "0.2.0",
        "capability": "identity",
        "operation": "webauthn_verify_assertion",
        "conformance_level": "MUST",
        "spec_section": "decisions/0010-webauthn-rs256-eddsa.md",
        "description": (
            "WebAuthn assertion verification across the three v0.2 algorithms "
            "(ADR 0010): ES256, RS256, EdDSA. The SDK MUST detect the algorithm "
            "from the COSE_Key's `alg` field and dispatch to the matching "
            "primitive. Each algorithm has a happy-path test and a "
            "signature-tampered test. RS256 also gates against keys smaller "
            "than 2048-bit. The shared authenticatorData and clientDataJSON "
            "are reused across rows; only the COSE pubkey, signature, and "
            "algorithm dispatch differ."
        ),
        "shared": {
            "stored_rp_id": RP_ID,
            "expected_origin": ORIGIN,
            "expected_challenge_hex": CHALLENGE.hex(),
            "stored_sign_count": 0,
            "authenticator_data_hex": auth.hex(),
            "client_data_json_hex": client.hex(),
        },
        "tests": [
            {
                "id": "webauthn.alg.es256.valid",
                "description": (
                    "Sanity: ES256 dispatch still works after the v0.2 "
                    "algorithm-dispatch refactor. Identical to the existing "
                    "webauthn-assertion.json happy path but with sign_count=7."
                ),
                "input": {
                    "cose_public_key_hex": es256_pub.hex(),
                    "signature_hex": es256_sig.hex(),
                },
                "expected": {"result": {"ok": True, "new_sign_count": sign_count}},
            },
            {
                "id": "webauthn.alg.rs256.valid",
                "description": (
                    "RS256 (RSASSA-PKCS1-v1_5 + SHA-256) over a 2048-bit key. "
                    "The SDK MUST parse the COSE_Key's RSA shape (kty=3, alg=-257, "
                    "-1=n, -2=e), construct a public key, and verify the raw "
                    "RSA signature."
                ),
                "input": {
                    "cose_public_key_hex": rs256_pub.hex(),
                    "signature_hex": rs256_sig.hex(),
                },
                "expected": {"result": {"ok": True, "new_sign_count": sign_count}},
            },
            {
                "id": "webauthn.alg.rs256.signature_invalid",
                "description": (
                    "RS256 with a single byte of the signature flipped MUST "
                    "be rejected with reason=signature_invalid."
                ),
                "input": {
                    "cose_public_key_hex": rs256_pub.hex(),
                    "signature_hex": rs256_bad.hex(),
                },
                "expected": {"result": {"ok": False, "reason": "signature_invalid"}},
            },
            {
                "id": "webauthn.alg.rs256.key_too_small",
                "description": (
                    "RS256 with a 1024-bit RSA modulus MUST be rejected with "
                    "reason=unsupported_key. WebAuthn §5.8.5 floors RSA at "
                    "2048 bits; weaker keys are a non-conformant authenticator."
                ),
                "input": {
                    "cose_public_key_hex": small_rsa_pub.hex(),
                    "signature_hex": rs256_sig.hex(),
                },
                "expected": {"result": {"ok": False, "reason": "unsupported_key"}},
            },
            {
                "id": "webauthn.alg.eddsa.valid",
                "description": (
                    "EdDSA (Ed25519) assertion. The SDK MUST parse the COSE_Key's "
                    "OKP shape (kty=1, alg=-8, -1=6 for Ed25519, -2=x) and verify "
                    "the 64-byte signature against the message authData || "
                    "sha256(clientDataJSON)."
                ),
                "input": {
                    "cose_public_key_hex": eddsa_pub.hex(),
                    "signature_hex": eddsa_sig.hex(),
                },
                "expected": {"result": {"ok": True, "new_sign_count": sign_count}},
            },
            {
                "id": "webauthn.alg.eddsa.signature_invalid",
                "description": (
                    "EdDSA with a single byte of the signature flipped MUST be "
                    "rejected with reason=signature_invalid."
                ),
                "input": {
                    "cose_public_key_hex": eddsa_pub.hex(),
                    "signature_hex": eddsa_bad.hex(),
                },
                "expected": {"result": {"ok": False, "reason": "signature_invalid"}},
            },
        ],
    }

    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    out_path = FIXTURE_DIR / "webauthn-assertion-algorithms.json"
    out_path.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
