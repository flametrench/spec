# Flametrench Conformance Suite

The normative test corpus every Flametrench-conformant implementation MUST satisfy (subject to conformance level — see below).

The suite is **language-agnostic**: fixtures are JSON data files. Each SDK provides its own thin harness that loads the fixtures and exercises them against its implementation. The fixtures themselves are the single source of truth — duplicating them in SDKs is how conformance regressions get detected before they ship.

## How this is structured

```
spec/conformance/
├── README.md                      ← this document
├── fixture.schema.json            ← JSON Schema for fixture files
├── index.schema.json              ← JSON Schema for the index
├── index.json                     ← manifest: every fixture file, with metadata
└── fixtures/
    ├── ids/                       ← ID format (fully runnable today)
    │   ├── encode.json
    │   ├── decode.json
    │   ├── decode-reject.json
    │   ├── is-valid.json
    │   └── type-of.json
    ├── identity/                  ← identity fixtures (v0.1 + v0.2 + v0.3)
    │   ├── argon2id.json                  ← v0.1: PHC verify
    │   ├── list-users.json                ← v0.2 (ADR 0015): cursor-paginated enumeration
    │   ├── user-display-name.json         ← v0.2 (ADR 0014): display_name + updateUser
    │   ├── mfa/                           ← v0.2 (ADR 0008 / ADR 0010): factor + verify
    │   │   ├── totp-rfc6238.json
    │   │   ├── recovery-code-format.json
    │   │   ├── webauthn-assertion.json
    │   │   ├── webauthn-counter-decrease-rejected.json
    │   │   └── webauthn-assertion-algorithms.json   ← v0.3: ES256 + RS256 + EdDSA
    │   └── pat/                           ← v0.3 (ADR 0016): personal access tokens
    │       ├── token-format.json
    │       └── bearer-prefix-routing.json
    ├── authorization/
    │   └── rewrite-rules/                 ← v0.2 (ADR 0007): subset of Zanzibar userset_rewrite
    │       └── empty-rules-equals-v01.json
    └── tenancy/                   ← placeholder; future SDK layers
        └── README.md
```

Each fixture file conforms to [`fixture.schema.json`](./fixture.schema.json); the [`index.json`](./index.json) manifest conforms to [`index.schema.json`](./index.schema.json). CI validates both on every spec repo push.

## Conformance levels

Every fixture file declares its `conformance_level`, using [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) keywords:

| Level | Meaning | Failure consequence |
|---|---|---|
| `MUST` | Behavior that is load-bearing to interoperability. | An implementation that fails any `MUST` fixture is **not conformant** and MUST NOT claim to be. |
| `SHOULD` | Behavior that is strongly recommended but allows justified exceptions. | A failure produces a warning; the implementation SHOULD document why. |
| `MAY` | Behavior that is aspirational or implementation-hint. | Informational only. Failures do not affect conformance. |

An implementation documents its conformance posture by maintaining a `CONFORMANCE.md` in its own repository listing which fixture files it passes, which it skips (with reasons), and at what spec version.

## Fixture file shape

A fixture file is one capability × one operation × one or more vectors. Example:

```json
{
  "$schema": "../../fixture.schema.json",
  "spec_version": "0.1.0",
  "capability": "ids",
  "operation": "encode",
  "conformance_level": "MUST",
  "spec_section": "docs/ids.md#encoding-rules",
  "description": "Canonical hyphenated UUIDs encode to the self-describing wire format.",
  "tests": [
    {
      "id": "encode.canonical.usr",
      "description": "Basic canonical UUID encodes correctly for the usr prefix.",
      "input": {
        "type": "usr",
        "uuid": "0190f2a8-1b3c-7abc-8123-456789abcdef"
      },
      "expected": {
        "result": "usr_0190f2a81b3c7abc8123456789abcdef"
      }
    }
  ]
}
```

A test's `expected` has exactly one of `result` (asserts success with that value) or `error` (asserts the operation throws the named error type). `error_matches` is an optional substring the error's message MUST contain; use sparingly — over-specifying message text makes fixtures fragile across SDKs.

## How to write a harness

Any conformant SDK includes a conformance harness. The harness:

1. Loads the `index.json` manifest.
2. For each entry with `runnable_today: true` (or omitted), loads the fixture file.
3. For each test, invokes the corresponding SDK operation with `input` and asserts against `expected`.
4. Reports pass/fail per test.

A reference harness implementation lives in each first-party SDK:

- **PHP:** [`flametrench/ids-php/tests/ConformanceTest.php`](https://github.com/flametrench/ids-php/blob/main/tests/ConformanceTest.php)
- **Node:** [`flametrench/node/packages/ids/test/conformance.test.ts`](https://github.com/flametrench/node/blob/main/packages/ids/test/conformance.test.ts)

## Fixture vendoring and drift detection

Each SDK vendors a snapshot of the fixtures into its own tree (under `tests/conformance/fixtures/` or equivalent). This keeps SDK test runs self-contained — no network, no git submodules — while the CI drift-check workflow in each SDK verifies the vendored snapshot is byte-identical to the upstream spec repo. Any drift fails CI, forcing the SDK to re-vendor on the next PR.

## Contributing a fixture

1. Pick the capability and operation.
2. Add test vectors to the appropriate file, or create a new file.
3. Every test MUST have a unique `id`, a one-line `description`, concrete `input`, and `expected`.
4. Run the schema validation locally:
   ```bash
   # With ajv-cli
   npx -y ajv-cli@5 validate -s fixture.schema.json -d "fixtures/**/*.json" --strict=false
   ```
5. Open a PR. CI re-runs the validation and runs every SDK's conformance suite against the new fixtures; the PR can only merge when both SDKs pass or explicitly skip with a reason.

## What's NOT yet covered

v0.1 fixtures cover:

- **`ids`** — fully. Every operation has encode/decode/reject/validate vectors.
- **`identity`** — partial. `argon2id.json` validates password hash verification against a known vector; other operations (session rotation, credential rotation) require SDK state and are deferred until an SDK implements the identity layer.
- **`tenancy`** — nothing yet. Invitation state machine, role changes, self-leave vs admin-remove all need SDK state machinery. Placeholder in `fixtures/tenancy/README.md` tracks what will land.
- **`authorization`** — nothing yet. `check()` fixtures need a tuple store to seed. Placeholder in `fixtures/authorization/README.md`.

As SDK layers for identity/tenancy/authz ship, corresponding fixture files will land here. The fixture format is designed to extend cleanly — new capabilities add directories; new operations add files; existing fixtures don't churn.

## Why this is better than "just write more tests in each SDK"

- **One source of truth.** If PHP and Node both test `encode("usr", "0190f2a8-...")`, that's one fixture row in this repo, not duplicated inline constants that can drift.
- **Language-agnostic additions.** A Go, Rust, or Python SDK in the future consumes the same fixtures. No porting.
- **Spec-linked.** Every fixture file includes `spec_section`; if the spec changes, a grep through `spec_section` references finds the fixtures that need review.
- **Conformance-level aware.** Not every behavior is equally load-bearing. MUST/SHOULD/MAY separates what's critical from what's nice-to-have.
- **Machine-graded.** Harnesses output JSON reports; a conformance dashboard or badge system can consume them without parsing language-specific test output.
- **Designed for third-party validation.** Any third-party Flametrench implementation can prove conformance by publishing its harness results; the test corpus is external and unbiased.

## Versioning

Each fixture file declares a `spec_version`. When the spec breaks compatibility, affected fixtures update and the spec version bumps. SDKs declare the spec version they target; mismatches are CI-detectable.

The suite follows the spec's versioning — there is no separate "conformance suite version." The fixtures are part of the spec.

## License

All fixtures are Apache License 2.0, same as the rest of the specification. Third-party implementations may use them freely to test conformance.
