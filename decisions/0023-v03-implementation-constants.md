# 0023 — v0.3 implementation constants (cross-SDK parity)

**Status:** Accepted
**Date:** 2026-06-06
**Deciders:** Flametrench stewards
**Filed by:** surfaced by the Go SDK (v0.3 reference implementation)

## Context

v0.3 is being implemented across all five SDK families in parallel. The Go SDK — the reference implementation — audited its own code against the ADRs and found **seven constants/algorithms that an implementer must choose but that were not pinned in one normative place.** Each is a silent cross-SDK divergence risk: families that pick different values produce *different behavior*, not clean errors (a different bucket, a different parse, a detectable timing difference), and the divergence is invisible until two SDKs disagree in production.

Four of the seven were already normative but **scattered** across ADRs and capability docs (easy for a code-first implementer to miss). Three were genuine gaps, now pinned in `docs/security.md` (the security-control prose). This ADR does **not** edit any frozen ADR (per the never-edit-accepted-ADRs rule); it is the **single consolidated source of truth** the SDK families build to, citing each value's authoritative home and its enforcing conformance fixture.

All values are the Go reference implementation's, confirmed spec-faithful by the spec owner.

## Decision

The following constants are normative for v0.3. An implementation that uses a different value is non-conformant.

### PAT constants (ADR 0016 surface)

| # | Constant | Normative value | Authoritative home |
|---|---|---|---|
| 1 | **PAT token parse** | Validate `^pat_[0-9a-f]{32}_[A-Za-z0-9_-]+$`, then ID = chars `[4:36]`, secret = chars `[37:]` — i.e. split on the **second** `_`. MUST NOT split on the first or last `_` (the base64url secret alphabet includes `_`). | ADR 0016 §"Verification" step 2; `docs/security.md` §`pat_`; `docs/ids.md` |
| 2 | **Dummy PHC hash** (H2 timing-oracle defense) | The exact literal below; every SDK MUST use *this* string (a self-generated hash has a different verify time → CWE-208 oracle). Covers both the missing-row path and the structurally-valid-but-non-UUIDv7-id path. | `docs/security.md` §`pat_`; `conformance/fixtures/identity/argon2id.json` (executable source) |
| 3 | **Max PAT secret length** (H6 DoS cap) | MUST reject secret segments longer than **256** characters with a cheap length check **before** Argon2id dispatch. (Real secrets are 43 chars.) | `docs/security.md` §`pat_` |
| 4 | **`auth.kind` wire values** | Exactly these four lowercase strings: `"session"`, `"pat"`, `"share"`, `"system"`. Byte-identical across SDKs. | ADR 0016 §"Audit log integration"; ADR 0019 §"`auth.kind` and `system`" |
| 5 | **Bearer dispatch order** | `pat_` → `verifyPatToken`, `shr_` → `verifyShareToken`, otherwise → `verifySessionToken` (opaque v0.2 sessions have no prefix). Fixed and **append-only**: new prefixed types are appended, never inserted ahead of `pat_`/`shr_`. | ADR 0016 §"Routing on the wire"; `docs/security.md` §`pat_` |

**Constant 2 — the dummy PHC hash literal:**
```
$argon2id$v=19$m=19456,t=2,p=1$779z4UHkLWR4w0TEo9gcHg$Gz0+nGnpokhsKi1cPlx8i74FBN1Nq0OURZ3xso1AHMU
```
(verifies against plaintext `correcthorsebatterystaple` at the spec-floor params `m=19456, t=2, p=1`.)

### Authorization constants (ADR 0007 / ADR 0001 surface)

| # | Constant | Normative value | Authoritative home |
|---|---|---|---|
| 6 | **Rewrite-rule bounds** | `max_depth` spec floor = **8**; `max_fan_out` (per `tuple_to_userset` step) spec floor = **1024**. Exceeding either raises `EvaluationLimitExceededError`. | ADR 0007 §"algorithm" (spec floor 8 / 1024); `docs/authorization.md` `max_depth`/`max_fan_out` |
| 7 | **Tuple field regexes** | `relation`: `^[a-z_]{2,32}$`. `subject_type` / `object_type`: `^[a-z]{2,6}$`. | `docs/authorization.md` §"Entity shape" + §custom relations; ADR 0001 (relation); F6 note (`subject_type` post-0017 relaxation) |

## Conformance enforcement

The corpus is the parity guarantee, so each constant should be fixture-enforced. Current status:

| # | Enforcing fixture | Status |
|---|---|---|
| 1 | `identity/pat/token-format.json` | ⚠️ format covered; **add** a "secret containing `_`/`-` parses at the second `_`" case (the specific divergence) |
| 2 | `identity/argon2id.json` | ✅ enforced |
| 3 | `identity/pat/token-format.json` | ❌ **gap** — add a ">256-char secret rejected before Argon2id" case |
| 4 | (audit fixtures, `fixtures/audit/`) | ⏳ pending SiteSource's v0.4 audit batch (asserts the `auth.kind` values) |
| 5 | `identity/pat/bearer-prefix-routing.json` | ✅ enforced (`pat_`/`shr_`/session + no-cross-routing) |
| 6 | `authorization/rewrite-rules/` | ❌ **gap** — no depth/fan-out-bound fixture; add `depth-limit-exceeded.json` / `fan-out-exceeded.json` |
| 7 | `authorization/format.json` | ✅ enforced (relation + object_type regexes) |

The three gaps (#1 strengthen, #3 add, #6 add) are tracked with QA & Conformance (suite owner) to land alongside this ADR; #4 lands with the audit fixture batch.

## Consequences

**Positive:** one citable source of truth for the four families still implementing v0.3; divergence on any of the seven becomes a conformance failure once the gap fixtures land, not a production surprise.

**Negative:** a consolidated table can drift from its authoritative homes if a value is ever changed in one place but not here. Mitigated: this ADR cites the authoritative home for each, which remains canonical; this table is a convenience index, and any future change to a value supersedes via a new ADR (the homes are frozen ADRs / living normative docs).

## Rejected alternatives

- **Edit ADRs 0016/0017 to add the table.** Rejected — accepted ADRs are frozen (never edited). A new consolidating ADR is the convention-respecting way to make a cross-cutting set explicit.
- **Pin values *only* in the scattered homes.** Rejected — that's the status quo that caused the miss; the four parallel implementers need one place.
- **Change any value from Go's reference.** Rejected — all seven Go reference values were confirmed spec-faithful; changing them would itself create divergence with the already-shipped Go SDK.

## References

- ADR 0016 (PATs), ADR 0007 (rewrite rules), ADR 0001 (authorization), ADR 0019 (audit / `auth.kind`).
- `docs/security.md` §`pat_` (constants 1/2/3/5), `docs/authorization.md` (constants 6/7).
- `conformance/fixtures/identity/{argon2id,pat/*}.json`, `conformance/fixtures/authorization/format.json`.
