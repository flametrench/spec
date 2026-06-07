# 0024 — Share `expires_in` bound violations raise `InvalidFormatError`, not `PreconditionError`

**Status:** Proposed
**Date:** 2026-06-06
**Deciders:** Flametrench stewards
**Supersedes (in part):** the error-type clause of [`docs/shares.md`](../docs/shares.md) §`createShare`/Validation (ADR 0012 primitive)

## Context

`docs/shares.md` §`createShare`/Validation states:

> `expires_in` MUST be positive and MUST NOT exceed 365 days. Otherwise **`PreconditionError`**.

Every shipped first-party SDK disagrees with that error type. For both bound violations (`expires_in <= 0` and `expires_in > 365 days`) all four authz SDKs raise **`InvalidFormatError`** with field discriminator `expires_in_seconds`:

| SDK | Site | Raises |
|---|---|---|
| Python | `authz-python/src/flametrench_authz/shares.py:169–178` | `InvalidFormatError(field="expires_in_seconds")` |
| PHP | `authz-php/src/InMemoryShareStore.php:80–83` | `InvalidFormatException("expiresInSeconds")` |
| Java | `authz-java/.../InMemoryShareStore.java:99–102` | `InvalidFormatError` |
| Node | `node/packages/authz/src/in-memory-shares.ts:96–98`, `postgres.ts:510–512` | `InvalidFormatError` |

No SDK raises `PreconditionError` for this case. `PreconditionError` *does* exist in every SDK and is used deliberately — but for **state preconditions**, not input bounds: e.g. `created_by` does not exist / is not an active user (`authz-python/.../postgres.py:491,496`; Node `postgres.ts:526,532`). The line in `shares.md` is the lone reference to `PreconditionError` for an input-range check, and it is unimplemented by the entire reference set.

This is a spec-prose error discovered during the `shares.mdx` documentation review (`flametrench/www` PR #5): the doc could not faithfully describe both the spec and the observed SDK behavior because they conflict.

## Decision

**Reconcile the spec to the unanimous shipped behavior.** `docs/shares.md` is amended so that `expires_in` bound violations raise **`InvalidFormatError`** with field `expires_in_seconds`, matching all four SDKs.

The rationale is not merely "majority wins" — the SDKs encode a coherent and defensible distinction that the original prose violated:

- **`InvalidFormatError`** — the supplied *arguments* are malformed or out of their allowed range. Determinable from the inputs alone, no system state consulted. In `createShare` this already covers `relation` (regex), `object_type` (regex), and `expires_in <= 0`. `expires_in > 365 days` is the same class — a value-range check on a passed argument — so it belongs here.
- **`PreconditionError`** — a precondition against *system state* fails (the referenced `created_by` user is missing or suspended). Requires a lookup; not knowable from the arguments alone.

`expires_in > 365 days` is an argument-range violation, not a state precondition. `InvalidFormatError` is the internally-consistent classification, and it is what every SDK ships. The original `PreconditionError` clause was an inconsistency in the prose, not a contract any implementation honored.

### Normative change

`docs/shares.md` §`createShare`/Validation:

- **Before:** "`expires_in` MUST be positive and MUST NOT exceed 365 days. Otherwise `PreconditionError`."
- **After:** "`expires_in` MUST be positive and MUST NOT exceed 365 days. Otherwise `InvalidFormatError(\"expires_in_seconds\")`."

No other normative text changes. The 365-day ceiling, positivity requirement, and all verify-side semantics are untouched.

## Consequences

**Positive:**
- The spec now matches shipped reality; `shares.mdx` (and any adopter reading either) gets one true answer.
- Error taxonomy is coherent: input-shape/range → `InvalidFormatError`; state precondition → `PreconditionError`. No carve-out for the TTL bound.
- **Zero code churn.** No SDK changes — this ratifies what Python/PHP/Java/Node already do. No adopter who catches `InvalidFormatError` is affected; no one was catching `PreconditionError` here because no SDK ever threw it.

**Negative:**
- A published (v0.2) capability doc's stated error type changes. Mitigated: the change moves the *spec* toward the *implementations*, so no running code or conformance fixture changes, and the prior text was never observable behavior.

**Neutral / follow-on:**
- **Shares has no conformance fixtures at all** (`conformance/fixtures/` has no `shares/` tree). A `createShare` validation fixture asserting `InvalidFormatError` for `expires_in > 365d` and `<= 0` would lock this in cross-SDK. Tracked separately with QA-Conformance as part of closing the v0.2 shares coverage gap; not blocking this ADR.

## Rejected alternatives

- **Change all four SDKs to raise `PreconditionError`.** Rejected: it's a breaking behavior change across four shipped libraries to match a single prose line that no implementation ever honored, and it would make the TTL bound the *only* input-range check that isn't an `InvalidFormatError` — the less consistent taxonomy. Higher blast radius, worse design.
- **Leave the spec as-is and document the SDK behavior as a "known deviation."** Rejected: enshrines a permanent spec/impl contradiction and forces every SDK to carry a deviation note for behavior that is actually the correct, consistent choice.

## References

- [ADR 0012 — Share tokens](./0012-share-tokens.md) (the primitive this refines)
- [`docs/shares.md`](../docs/shares.md) §`createShare`
- `flametrench/www` PR #5 (`shares.mdx`) — where the discrepancy surfaced
- SDK sites: `authz-python/.../shares.py:169–178`, `authz-php/src/InMemoryShareStore.php:80–83`, `authz-java/.../InMemoryShareStore.java:99–102`, `node/packages/authz/src/in-memory-shares.ts:96–98`
