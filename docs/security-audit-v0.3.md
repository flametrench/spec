# Security audit — v0.3 pre-release

**Audit date:** 2026-05-01
**Spec version under audit:** 0.3.0 (in development)
**Method:** code review across 4 parallel auditors (crypto, persistence, authorization, dependencies). Not in scope: dynamic analysis, fuzzing, deployment-layer (TLS / CSP / rate limits / WAF), pen-test.

This document is the canonical record of every finding from the v0.3 pre-release security audit. Each finding has a stable identifier (e.g. `C1`, `H3`, `M7`) used in commit messages, PR titles, and follow-up audits.

## Status legend

| Symbol | Meaning |
|---|---|
| 🟥 **Open** | Not yet remediated. |
| 🟧 **In progress** | Remediation in flight; PR open or commit pushed but not merged. |
| 🟩 **Fixed** | Patched and merged on the relevant branches; verified by re-test or 2nd-pass audit. |
| 📝 **Docs-only** | The implementation is correct per the spec; the gap was a documentation / language-loudness issue and has been addressed there. |
| ⏭ **Won't fix** | Considered and rejected with explicit rationale (recorded in the finding). |

## Severity legend

- **Critical** — block ship. Authorization bypass, secret leak, or data integrity loss possible from low-privilege input.
- **High** — fix before next stable. Spec-contract violation, unbounded resource use, or adopter-defaulted attack surface.
- **Medium** — track for follow-up. Defense-in-depth gap, race window with limited impact, or cross-SDK parity drift.
- **Low / informational** — code quality, refactor opportunities, or cosmetic.
- **Footgun (F)** — spec / docs gap that an adopter would predictably get wrong. Not a bug in the SDK; a loudness gap in the contract.

---

## Critical (block ship)

### C1 — PHP `PostgresTupleStore::checkAny` builds Postgres array literal by string concat → relation injection / authz bypass
🟩 Fixed · authz-php

**File:** `authz-php/src/PostgresTupleStore.php:340-376`

**Code:**
```php
$stmt->execute([
    $subjectType,
    self::subjectIdToUuid($subjectId),
    '{' . implode(',', array_map(fn(string $r) => '"' . $r . '"', $relations)) . '}',
    $objectType,
    self::objectIdToUuid($objectId),
]);
```

**Impact:** A relation containing `","` becomes a literal break in the array text — a single-element list with embedded `","` is parsed by Postgres as a two-element array. An attacker passing `relations: ['viewer","admin']` matches BOTH `viewer` AND `admin` tuples — granting privileges never checked. Quote / backslash chars can also smuggle elements or DoS the array parser.

**Why other SDKs are clean:** Node uses `pg`'s native array binding, Python passes a `list` to psycopg, Java uses `conn.createArrayOf("text", …)`. Only PHP synthesizes the array literal.

**Remediation:** validate every element against the existing `Patterns::RELATION_NAME` (`^[a-z_]{2,32}$`) before binding, OR rewrite to parameterized `relation IN (?, ?, ?)` with `count($relations)` placeholders.

### C2 — Hearth `/customer/comment` accepts any `viewer` share for writes (share `relation` field never checked)
🟩 Fixed · hearth + spec ShareStore guidance

**File:** `hearth/backends/node/src/customer.ts:233,263` (read + write paths)

**Impact:** The Hearth customer flow mints a share with `relation: 'viewer'` (line 210) and uses it to authorize both reading the ticket AND posting comments / reopening tickets / triggering admin email notifications. The write handler at line 263 calls `request.verifiedShare!` and checks `objectType` (line 264) but never checks `relation`. A `viewer` share authorizes writes.

**Why this is a Critical not a Hearth-only fix:** Hearth is the canonical adopter reference. The pattern is silently incorrect — the relation field exists but doing nothing with it appears intentional from the code shape. Adopters copying this design will either (a) under-authorize, granting writes from read-only shares, or (b) add a `writer` relation later and forget existing `viewer` shares would still pass. The SDK itself has no affordance forcing the relation check.

**Remediation:**
1. Hearth: mint two relations (`viewer` for read, `commenter` for write); enforce `verified.relation === 'commenter'` on `/customer/comment`.
2. Spec: `docs/shares.md` and `ShareStore.verifyShareToken` doc-comments add a normative MUST-loud callout: "the adopter MUST verify `verified.relation` matches the action being authorized; the SDK does not gate by intent."

### C3 — Hearth `/install` route is unauthenticated and TOCTOU-racy
🟩 Fixed · hearth

**File:** `hearth/backends/node/src/install.ts:77-115`

**Code:**
```ts
if (await isInstalled(ctx.pool)) {        // L77 — check
  return reply.code(409).send(...);
}
const client = await ctx.pool.connect();
try {
  await client.query('BEGIN');             // L85 — txn starts AFTER check
  // ... insert inst row + sysadmin
}
```

**Impact:** Two concurrent installer requests both pass the L77 gate before either's BEGIN runs. Both create `inst` rows + sysadmins. The system ends up with two installer principals.

**Remediation:** wrap in a Postgres advisory lock (`SELECT pg_advisory_xact_lock(<constant>)` first thing inside the BEGIN) OR `INSERT INTO inst ... WHERE NOT EXISTS (SELECT 1 FROM inst)` and re-check `rowCount === 1`.

---

## High (fix before next stable)

### H1 — PAT `expires_at` 365-day cap is normative MUST but enforced in zero SDKs
🟩 Fixed · all 4 SDKs + conformance fixture

**Files:** `node-repo/packages/identity/src/in-memory.ts:1145`, `identity-php/src/InMemoryIdentityStore.php:1213`, `identity-python/src/flametrench_identity/in_memory.py:1279`, `identity-java/src/main/java/dev/flametrench/identity/InMemoryIdentityStore.java:1019` (and the matching Postgres impls).

**Impact:** ADR 0016 §"Constraints" pins `expires_at` ≤ `created_at + 365 days`. All 4 SDKs only check "strictly future." Adopters can mint century-long PATs and the SDK silently accepts them — defeating the spec's bound on token lifetime.

**Remediation:** add the 365-day check to all 4 `createPat` impls + add a conformance fixture (`pat.create.expires-at-too-far`) so cross-SDK parity is mechanical.

### H2 — Argon2id verify skipped on missing-row PAT lookup → row-existence timing oracle
🟩 Fixed · all 4 SDKs

**Files:** `identity-{php,python,java}/.../*.{php,py,java}`, `node-repo/packages/identity/src/{in-memory,postgres}.ts`. Most clear-cut in Python:
```python
# postgres.py:920-935 (sketch)
row = cur.fetchone()
if row is None:
    raise InvalidPatTokenError()       # ← short-circuits without Argon2
# ... else: PasswordHashing.verify(row[0], secret_segment)
```

**Impact:** The conflated `InvalidPatTokenError` exists specifically to prevent timing attacks distinguishing "no such pat_id" from "wrong secret" (ADR 0016 §"Verification semantics"). All 4 SDKs short-circuit on missing row WITHOUT performing Argon2id. The Argon2id verify takes ~50-150ms; the missing-row path is a fast indexed SELECT (~ms). An attacker can probe `pat_id` existence by submitting any-secret tokens and timing the response.

**Remediation:** at store init, precompute a dummy PHC hash of a constant string; on missing-row, perform `PasswordHashing.verify(dummy_hash, secret_segment)` before throwing. The verify result is discarded; the cost matches the row-exists path.

### H3 — `verifyPatToken` revoke check + `last_used_at` UPDATE not transactional in any SDK
🟩 Fixed · all 4 SDK Postgres impls

**Files:** `identity-php/src/PostgresIdentityStore.php:2003-2039`, `identity-python/.../postgres.py:1628-1690`, `node-repo/packages/identity/src/postgres.ts:1746-1803`, `identity-java/.../PostgresIdentityStore.java:2012-2090`.

**Impact:** `revokePat` racing between the verify SELECT and the `last_used_at` UPDATE writes the timestamp onto an already-revoked row. Not privilege escalation (verify already returned), but inflates the audit timeline of revoked PATs and complicates incident response.

**Remediation:** change all four UPDATE statements to:
```sql
UPDATE pat SET last_used_at = ? WHERE id = ? AND revoked_at IS NULL
```

### H4 — PAT `name` length cap inconsistent across SDKs; PHP byte-counts vs others code-unit-count
🟩 Fixed · spec + identity-php

**Files:** `spec/decisions/0016-personal-access-tokens.md:134` (says 1-100), `spec/docs/identity.md:472` (says ≤120), all SDK impls (enforce 1-120).

**Impact:** Spec disagrees with itself. PHP uses `strlen()` (bytes); Node/Python/Java use code-unit length. A 60-character Japanese name is 180 bytes in UTF-8 — rejected by PHP, accepted by all others. Cross-SDK conformance break.

**Remediation:** pick 120 as the canonical value (matches existing SDK enforcement); update ADR 0016 §"Entity shape"; change `identity-php` to `mb_strlen($name, 'UTF-8')`.

### H5 — `buildBearerAuthHook` (Node @flametrench/server) silently downgrades to v0.2 session-only — no PAT branch
🟩 Fixed · node-repo/packages/server

**File:** `node-repo/packages/server/src/auth.ts:26,42`

**Impact:** Adopters wiring `buildBearerAuthHook` get `InvalidTokenError` on every PAT bearer because the hook only routes to `verifySessionToken`. The new `resolveBearer` helper exists but the bearer-auth hook doesn't use it. Also `startsWith("Bearer ")` is case-sensitive (RFC 6750 says case-insensitive — `bearer`, `BEARER` should also match).

**Remediation:** rewrite `buildBearerAuthHook` to use `resolveBearer` internally (accept `{ identityStore, shareStore? }` config); lowercase the prefix check.

### H6 — PAT secret-segment length unbounded → Argon2 DoS amplification on known PAT id
🟩 Fixed · all 4 SDKs

**Files:** all SDK `verifyPatToken` impls — they check `secret.length > 0` but no upper bound.

**Impact:** An attacker who knows a real `pat_<id>_` prefix (from leaked logs / shoulder-surf of an admin UI / the test fixtures) can submit multi-MB secrets per request to force expensive Argon2id hashing (~100ms each at the spec floor). One attacker, one terminal, the worker pool is saturated.

**Remediation:** reject secrets exceeding (say) 256 chars cheaply before dispatching to Argon2id. The natural base64url length of 32 bytes is 43 chars; 256 leaves a generous margin while bounding the attack.

### H7 — PAT `getPat` / `listPatsForUser` / `revokePat` zero SDK-side authz, single-sentence doc warning
🟩 Fixed · all 4 SDKs + spec

**Files:** docstrings on `IdentityStore.getPat` / `listPatsForUser` / `revokePat` in all 4 SDKs; `spec/docs/identity.md:478` (one sentence).

**Impact:** The SDK does not gate these by caller — by design (per ADR 0016, the gating is the adopter's responsibility). But the warning is a single line buried mid-document. An adopter writing `app.post('/pats/:id/revoke', ({id}) => store.revokePat(id))` lets any authenticated user revoke any user's PAT.

**Remediation:** add `@security Adopter MUST gate that the caller is the owner OR a sysadmin acting on the user's behalf. The SDK does not enforce.` to every PAT method docstring across all 4 SDKs. `identity.md` adds a louder callout box.

---

## Medium (track for follow-up)

### M1 — Rule-eval direct lookups acquire a fresh pool connection per hop
🟩 Fixed · authz Postgres adapters (Node, Python, Java)

Each `directLookup` / `listByObject` calls `pool.query(...)` independently — deep `tuple_to_userset` chains under load fan pool checkouts across one request. Worse, read-skew is possible: a tuple deleted mid-evaluation produces a partially-consistent answer. **Fix:** acquire one `PoolClient` for the whole `evaluate()` call and pass it through. Document read-skew as a v0.3 limitation in ADR 0017.

### M2 / M10 — PAT verifier leaks status via `PatRevokedError` / `PatExpiredError` BEFORE the secret check
📝 Spec-documented · all 4 SDKs (or 📝 docs-only)

The 8-step ordering (revoked > expired > invalid_secret) is sanctioned by ADR 0016, but lifecycle errors are thrown before the Argon2id verify — anyone with a leaked `pat_id` can probe `active vs revoked vs expired vs not-exist` without the secret. **Fix options:** (a) swap order, secret-check first (defeats the spec's "fail-fast on terminal state" intent and changes audit signal); (b) document the leak explicitly in `security.md` threat model. Recommend (b) — the existence of a `pat_id` in logs is not itself secret; the secret is.

### M3 — PHP `PostgresShareStore::createShare` uses `nested()` not `tx()` → standalone race window
🟩 Fixed · authz-php

**File:** `authz-php/src/PostgresShareStore.php:233-296`. Standalone (no outer txn), `nested()` runs the closure unwrapped — the SELECT user-status check + INSERT are not atomic. A revoke racing between them mints a share for a no-longer-active user. **Fix:** swap to `tx()` OR add `FOR UPDATE` to the SELECT.

### M4 — PHP `verifyPatToken` accepts uppercase hex in id segment
🟩 Fixed · identity-php

`ctype_xdigit($idHex)` is case-insensitive. The conformance fixture `pat.token-format.rejects-uppercase-hex` MUST reject `pat_0190F2A8…`. PHP diverges silently (lookup misses since stored ids are lowercase, so it conflates to InvalidPatTokenException — but the contract is violated). **Fix:** `preg_match('/^[0-9a-f]{32}$/', $idHex)`.

### M5 — Conformance fixtures only consumed by the Node harness
🟩 Fixed · identity-{php,python,java}

`token-format.json` and `bearer-prefix-routing.json` exist as JSON but no PHP / Python / Java test loads them. The cross-SDK guarantee they exist for is untested in 3 of 4 SDKs. **Fix:** add a conformance test loader to each SDK family (small file each).

### M6 — Hearth PHP onboard duplicate-credential detection is exception-message string-matching
🟩 Fixed · hearth

**File:** `hearth/backends/php/app/Http/Controllers/OnboardController.php:63`. `str_contains($e->getMessage(), 'duplicate key') && str_contains($e->getMessage(), 'identifier')` will silently break under Postgres locale changes / driver wrapping. **Fix:** catch the typed `DuplicateCredentialException` from the SDK.

### M7 — Java rewrite-rule cycle stack `new HashSet<>(stack)` per recursion → O(N) hashing per call
🟩 Fixed · authz-java

**File:** `authz-java/src/main/java/dev/flametrench/authz/RewriteRulesEvaluator.java:135`. Combined with depth=8 and fan-out=1024, an adversarial-but-spec-legal rule does ~8K hash copies per `check()`. Not a security DoS in itself but worth bounding. **Fix:** pass a single mutable `Deque<String>` and `addLast` / `removeLast` around the recursive call.

### M8 — `resolveBearer` (Node) lacks parallel guard for missing PAT verifier
🟩 Fixed · node-repo/packages/server

**File:** `node-repo/packages/server/src/resolve-bearer.ts:67`. TypeScript catches a missing `verifyPatToken` at compile time, but the codepath has no runtime check parallel to the share branch's `TokenFormatUnrecognizedError`. PHP/Python/Java callers writing similar middleware won't get the same compile-time guarantee. **Fix:** add a `pat_` arm that throws `TokenFormatUnrecognizedError` if `identityStore.verifyPatToken == null`.

### M9 — Subject-prefix bypass via `decodeAny` is reachable
🟩 Fixed · authz Postgres adapters (all 4 SDKs)

**File:** `authz-php/src/PostgresTupleStore.php:163-169` (and equivalents). `subjectIdToUuid` accepts ANY `^[a-z]{2,6}_<32hex>$` prefix, then strips the prefix and binds the bare UUID. ADR 0017 sanctions this for `tuple_to_userset` hops, but it creates a footgun: an adopter that trusts `subjectType` from one source and `subjectId` from another loses the cross-check. **Fix:** when `subjectId` carries a prefix, assert `prefix === subjectType` before stripping; throw `InvalidFormatException` on mismatch.

---

## Low / informational

### L1 — Savepoint name 32 bits of randomness
🟩 Fixed · ADR 0013 + 4-SDK savepoint helpers

`random_bytes(4)` (PHP), `randomBytes(4)` (Node) — birthday collision at ~65k savepoints in the same connection. Real workloads stay well below this. **Fix:** document the bound in ADR 0013, OR bump to 8 bytes (16 hex chars in the savepoint name) at zero perf cost.

### L2 — PHP `nested()` `debug_backtrace`-derived savepoint names attribute to private helpers
🟩 Fixed · authz-php / identity-php

When called via a private helper (e.g. `revokeOldOnRotation` → `nested()`), the savepoint name reflects the helper, not the public method (`ft_revokeOldOnRotation_…` instead of `ft_rotatePassword_…`). Cosmetic — reduces grep value in `pg_stat_activity`. **Fix:** walk one more frame when the immediate caller is in an internal whitelist.

### L3 — Node SDK regex duplication
🟩 Fixed · node-repo/packages/identity

`pat.ts:125-128` exports `isStructurallyValidPatToken` with the canonical regex; `in-memory.ts:1231-1247` and `postgres.ts:1746-1754` re-implement the same checks inline rather than calling the helper. **Fix:** call `isStructurallyValidPatToken` from both impls. Lower priority: refactor only.

### L4 — `classifyBearer` (Node) is not extensible
⏭ v0.4 deferral · node-repo/packages/server

Adopters who want to introduce a custom prefix (e.g. `api_…`) have to fork the dispatcher. **Fix (v0.4):** accept an optional `customPrefixes: Record<string, AuthKind>` parameter.

### L5 — `buildShareAuthHook` lowercases `'bearer'`; `buildBearerAuthHook` does not
🟩 Closes with H5 · node-repo/packages/server (rides along with H5)

Inconsistency in the existing v0.2 helper. Resolved as part of H5.

---

## Adopter footguns (spec / docs gaps)

### F1 — `share.relation` is never enforced by share-auth middleware
📝 Closes with C2 spec language.

### F2 — `subjectId` accepts wire-format AND bare hex; type signature is `string`
⏭ v0.4 deferral · spec + identity SDKs

Passing `"usr_X"` as `objectId` to `check()` silently fail-closes — no type error. Add nominal `OrgId` / `UsrId`-style branded types in PHP (via opaque value objects) and Python (via `NewType`). Node already has them.

### F3 — `auth.kind = 'system'` lives only in spec prose, no SDK enum constant
🟩 Fixed · all 4 SDKs

Adopters writing cron / scheduled jobs reach for `'pat'` or `'session'` because those exist as code values; `'system'` lives only in `identity.md`. **Fix:** add an `AuthKind` enum / union type to each SDK with `system` as a member.

### F4 — PAT `getPat` / `listPatsForUser` / `revokePat` need adopter-side gating
📝 Closes with H7.

### F5 — PAT `scope` is opaque `string[]`; SDK does not enforce — adopter's authz layer interprets
📝 Spec-documented (createPat scope docstring) · spec + identity SDK doc-comments

Adopters copy the "looks like the spec works out of the box" mental model from `relation` (which IS enforced by `check()`) and forget to gate `scope` themselves. **Fix:** stinger to `createPat` doc-comment in all 4 SDKs.

### F6 — Rewrite rule `tuple_to_userset` does not constrain expected `subject_type` of the hop
📝 Spec-documented (ADR 0017 + authorization.md) · ADR 0017 + docs/authorization.md

With the v0.3 `subject_type` relaxation, an adopter with both `(org_X, parent_org, proj_Y)` and `(aud_Z, parent_org, proj_Y)` recurses into BOTH. The "application contract still recommends `'usr'`" line in ADR 0017 is too quiet. **Fix:** add a louder warning section.

### F7 — Hearth onboard accepts password ≥ 8 chars (below NIST SP 800-63B 15+ for primary credentials)
🟩 Fixed · hearth

Adopter copy-paste sets the floor too low. **Fix:** raise Hearth's minimum to 12 (or 15 with a clear comment) and add a comment pointing at NIST SP 800-63B.

---

## Verified clean (no findings — useful baseline)

These are areas the audit specifically looked at and found correct. They form the v0.3 security-baseline assertion.

### Cryptography
- All 4 SDKs enforce Argon2id parameter floors (m=19456, t=2, p=1).
- Secret generation uses CSPRNG everywhere (`secrets.token_bytes` / `randomBytes` / `random_bytes` / `SecureRandom`); ≥256 bits of entropy on every secret token.
- SHA-256 token hashes stored as raw 32 BYTEA (not hex strings).
- Constant-time compares: `hash_equals` (PHP), `timingSafeEqual` (Node), `hmac.compare_digest` (Python), `MessageDigest.isEqual` (Java).
- WebAuthn per-algorithm dispatch correct (ES256 / RS256 / EdDSA); RSA-2048 floor enforced; counter regression rejected including the `0==0` no-counter-authenticator edge case.
- TOTP drift window clamped to [0..10]; constant-time digit comparison.
- Recovery codes: per-slot Argon2id; all 10 slots iterated regardless of match (no slot-position leak).

### Token verification semantics
- Share verify ordering correct in all 4 SDKs (revoked > consumed > expired > success).
- Single-use share consumption race-correct: `UPDATE … WHERE consumed_at IS NULL RETURNING …` inside `tx()` (real BEGIN/COMMIT, the only `tx()` not `nested()` site that matters here).
- PAT 8-step verification ordering implemented identically in all 4 SDKs.
- "Conflated `InvalidPatTokenError` for missing-row vs wrong-secret" — implemented modulo H2 (the timing-side leak the conflation was supposed to defend against — fixed in S5).

### Authorization
- All 4 SDK rewrite evaluators implement per-evaluation cycle stacks (not registration-time).
- Depth and fan-out bounds enforced identically (default 8 / 1024); same `EvaluationLimitExceededError` shape.
- `This` is always implicit via the step-1 directLookup short-circuit before rule expansion — a rule omitting `this` cannot bypass exact tuples.
- `cascadeRevokeSubject` properly scopes by both `subject_type` AND `subject_id` — the v0.3 schema relaxation does not enable subject confusion in the membership system.
- Tenancy hardcodes `subject_type='usr'` everywhere it touches `tup` — the relaxation is invisible to the membership flow.

### Persistence + concurrency
- All 4 SDKs use `ON CONFLICT DO NOTHING` for tuple insert (or savepoint shielding) so a 23505 doesn't poison an outer adopter transaction (ADR 0013-conformant).
- Cred rotation atomically terminates `cred_id`-bound sessions inside the same transaction with `FOR UPDATE` on the cred row.
- ADR 0009 `accepting_identifier` byte-equality across all 4 SDKs (no Unicode normalization, no lowercasing).
- Schema `CHECK (subject_type ~ '^[a-z]{2,6}$')` enforces the prefix shape at the DB layer — even if SDK validation is bypassed, malformed `subject_type` cannot land in `tup`.

### v0.3 specifics
- `resolveBearer` (Node) does NOT silently fall through PAT failures to the session resolver — `pat_` always routes to `verifyPatToken` and propagates its errors verbatim.
- Error messages never include the secret value.
- All v0.3 CHANGELOG entries follow the same `## [v0.3.0] — Unreleased[ (PyPI/Maven Central publish blocked)]` header style.
- No debug code (`console.log` / `var_dump` / `debugger` / `print()`) in any v0.3 source file.

### Dependencies
- `pnpm audit` clean across the Node monorepo (304 deps, 0/0/0/0 critical/high/medium/low).
- `composer audit` clean across all 5 PHP repos.
- Java `pom.xml` inspection: `postgresql 42.7.4`, `jackson-databind 2.18.2`, `junit-jupiter 5.11.4`, `argon2-jvm 2.11` — all current; no flagged CVEs.
- Python: `argon2-cffi 25.1.0`, `cryptography 47.0.0`, `psycopg 3.3.3` — all current. (`pip-audit` not pre-installed; relied on manual review.)

---

## Remediation tracking

Status updates land here as PRs merge. Format: `<finding-id> · <PR-link> · <date> · <status-symbol>`.

| Finding | PR | Date | Status |
|---|---|---|---|
| C1 | authz-php@2a25e30 | 2026-04-30 | 🟩 |
| C2 | hearth@4bc1426 + spec/Hearth/4-SDK ShareStore docstrings | 2026-04-30 | 🟩 |
| C3 | hearth@4bc1426 (Postgres advisory locks on /install) | 2026-04-30 | 🟩 |
| H1 | identity-{php,node,python,java}@v0.3.x (365-day cap) | 2026-04-30 | 🟩 |
| H2 | identity-{php,node,python,java}@v0.3.x (Argon2id on missing row) | 2026-04-30 | 🟩 |
| H3 | identity-{php,node,python,java}@v0.3.x (revoke-aware lastUsedAt) | 2026-04-30 | 🟩 |
| H4 | spec@485f43e + identity-php@a072407 (mb_strlen) | 2026-04-30 | 🟩 |
| H5 | node-repo@6283d32 + auth.test.ts | 2026-04-30 | 🟩 |
| H6 | identity-{php,node,python,java}@v0.3.x (256-char secret cap) | 2026-04-30 | 🟩 |
| H7 | spec@73e72ae + identity-{php,node,python,java}@v0.3.x | 2026-04-30 | 🟩 |
| M1 | node-repo@6693063 + authz-java@ea25f79 + spec ADR 0017 | 2026-05-01 | 🟩 |
| M2/M10 | spec@3e6c13e (security.md PAT verification ordering trade-off) | 2026-05-01 | 📝 |
| M3 | authz-php@67be6f7 (createShare → tx) | 2026-05-01 | 🟩 |
| M4 | identity-php@3b01dbd (lowercase-hex preg_match) | 2026-05-01 | 🟩 |
| M5 | identity-{php,python,java}@v0.3.x (PAT conformance harnesses) | 2026-05-01 | 🟩 |
| M6 | hearth@9e8b7c3 (typed DuplicateCredentialException) | 2026-05-01 | 🟩 |
| M7 | authz-java@e17e328 (in-place stack mutation) | 2026-05-01 | 🟩 |
| M8 | node-repo@0a0f5b5 (resolveBearer guard) | 2026-05-01 | 🟩 |
| M9 | authz-{php,node,python,java}@v0.3.x (subjectIdToUuid prefix-assert) | 2026-05-01 | 🟩 |
| L1 | authz-php + identity-php + node-repo (8-byte savepoint suffix) | 2026-05-01 | 🟩 |
| L2 | authz-{php,identity-php} (ReflectionMethod walk past private) | 2026-05-01 | 🟩 |
| L3 | node-repo (verifyPatToken delegates to isStructurallyValidPatToken) | 2026-05-01 | 🟩 |
| L4 | _v0.4 deferral_ — `customPrefixes` extension hook for `classifyBearer` | 2026-05-01 | ⏭ |
| L5 | resolved by H5 | 2026-04-30 | 🟩 |
| F1 | resolved by C2 | 2026-04-30 | 📝 |
| F2 | _v0.4 deferral_ — branded `OrgId`/`UsrId`-style types in PHP/Python | 2026-05-01 | ⏭ |
| F3 | identity-{php,node,python,java}@v0.3.x (AuthKind enum/union) | 2026-05-01 | 🟩 |
| F4 | resolved by H7 | 2026-04-30 | 📝 |
| F5 | identity-{php,node,python,java}@v0.3.x (createPat scope docstring) | 2026-05-01 | 📝 |
| F6 | spec@8a00bfd (ADR 0017 + authorization.md hop-subject_type warning) | 2026-05-01 | 📝 |
| F7 | hearth@411cd8d (Hearth password floor 8 → 12 chars) | 2026-05-01 | 🟩 |

**v0.4 deferrals.** Two findings (L4, F2) are deferred by design rather than left open. L4 (`classifyBearer` extensibility) is a feature request rather than a security gap — adopters who need a custom bearer prefix today can fork the dispatcher; v0.4 will accept an optional `customPrefixes` parameter. F2 (branded `UsrId` / `OrgId` types in PHP and Python) is a typing-API uplift the audit recommends but doesn't block ship — the runtime behavior (silent close-on-mismatched-id) is documented and recoverable, and a value-object pass through identity-php / authz-php / tenancy-php would touch every method signature; v0.4 will land it as a typed-API release alongside the LSP-friendly Python `NewType` aliases.

## Re-audit gate

The focused 2nd-pass review of the patched surface ran 2026-05-01. Findings:

- **C1 ✅** — patched `checkAny` validates every element of the relations array against `Patterns::RELATION_NAME` before binding; no SQL string concatenation remains in the file.
- **C2 ✅** — both Hearth backends enforce `verified.relation === 'commenter'` on write paths; agent-side self-share mints `commenter` not `viewer`. The fix also tightens the read path to require `commenter` (Hearth never mints viewer shares); adopters who later add viewer-only shares will need to update both branches together — documented inline.
- **C3 ❌→🟩** — re-audit caught a constant typo: PHP `InstallController.php`'s advisory-lock literal was `7521751562894049651`, NOT the canonical `0x6865617274686e73 = 7522525896799448691` that Node uses. The two backends were serializing against DIFFERENT lock keys. Fixed in `hearth@99973eb` (corrects the literal AND fixes the misleading "heartheng" comment in both backends — the correct ASCII unpacking is "hearthns").
- **H2 ✅** — verified across all 4 SDKs that BOTH the missing-row branch AND the structurally-valid-but-not-UUIDv7 (`wireToUuid` failure) branch perform `verifyPasswordHash(DUMMY_PHC_HASH, secret)` before raising. The second branch is easy to miss; all 4 SDKs got it right.
- **H3 ✅** — `UPDATE pat SET last_used_at = ? WHERE id = ? AND revoked_at IS NULL` confirmed in all 4 SDKs.
- **H6 ✅** — secret-length cap fires before Argon2id dispatch in all 4 SDKs; the L3 refactor (Node delegating structural check to `isStructurallyValidPatToken`) did NOT drop the H6 cap.
- **M1 ✅** — Node `withClient` and Java try-with-resources Connection both pin one connection across the rule-eval recursion and release on every return path; `directLookupOn` / `listByObjectOn` only ever reference the explicit param.
- **M3 ✅** — `PostgresShareStore::createShare` uses `tx(...)`, not `nested(...)`.
- **M9 ✅** — all 5 `subjectIdToUuid` callsites in PHP/Node/Python/Java pass `subjectType`. Java still has a 1-arg overload for backward compat but no internal caller uses it.
- **L2 ✅** — three identical PHP implementations of `callerName()` walk past private/protected frames via ReflectionMethod, handle Closure frames (no `function` key), handle top-level functions (no `class`), and fall back to `'tx'` if no public frame is found. No infinite-loop risk.

Net: 1 critical bug caught and fixed (C3 PHP advisory-lock constant); all 32 findings now have a final disposition.
