# Migrating from v0.2 to v0.3

This guide is for applications already running on a v0.2 Flametrench SDK that want to adopt v0.3.

**Status:** v0.3.0 is stable as of 2026-05-15. Adopt it on a non-production environment first, file issues at [`flametrench/spec`](https://github.com/flametrench/spec/issues), and roll forward to production once your acceptance tests pass.

The migration is **additive at the v0.2 wire surface**: every v0.2 call site keeps working unchanged. v0.3 adds two new capabilities (personal access tokens, Postgres-backed rewrite-rule evaluation), one schema relax (`tup.subject_type` check constraint), and an additive audit-log discriminator (`auth.kind`). The security audit completed during the v0.3 cycle also produced 22 in-code fixes that ship inside the SDK upgrade — no caller change required for any of them.

## At a glance

| Surface | v0.2 | v0.3 |
|---|---|---|
| ID prefixes | `usr_`, `cred_`, `ses_`, `org_`, `mem_`, `inv_`, `tup_`, `mfa_`, `shr_` | adds `pat_` |
| Authorization | exact-match `check()`; rewrite rules supported only on `InMemoryTupleStore` | `PostgresTupleStore.check()` accepts `rules` directly (ADR 0017) |
| Identity | password / passkey / OIDC + MFA via `cred` and `mfa` records | adds `pat` records — non-interactive bearer credentials for CLI / CI / service-to-service |
| Auth discriminator | implicit | `auth.kind ∈ {session, pat, share, system}` on audit/event records (additive) |
| Postgres reference | 10 tables | adds `pat` (with `secret_hash` Argon2id, `usr_id` FK, `scope TEXT[]`, `last_used_at`, `revoked_at`, three indexes, `pat_touch` trigger) |
| `tup.subject_type` constraint | enum (`usr`, `org`, `mem`, etc.) | relaxed to regex `^[a-z]{2,6}$` (admits `pat_` and adopter-defined subject types — required for ADR 0017 rule eval) |
| OpenAPI | `flametrench-v0.2-additions.yaml` | adds `flametrench-v0.3-additions.yaml` (composes additively) |

Nothing in v0.2 changes shape. The only required adopter action is the [schema migration in §4](#4-required-relax-tupsubject_type-check-constraint).

## 1. Optional: Personal access tokens (ADR 0016)

[ADR 0016](../decisions/0016-personal-access-tokens.md) introduces a `pat_` primitive for non-interactive bearer credentials — CLI tools, CI pipelines, service-to-service integrations.

**Wire format:** `pat_<32-hex-id>_<base64url-secret>` (Stripe-style id-then-secret). The token is shown once at creation; only its Argon2id hash is stored.

**SDK surface (operations).** `createPat`, `getPat`, `listPatsForUser`, `revokePat`, `verifyPatToken`. Verification is SDK-only — there is intentionally no public `/v1/pats/verify` route (mirrors the share-token precedent).

```python
# Create a PAT for an authenticated user. The plaintext token is returned ONCE.
pat, token = identity_store.create_pat(
    usr_id=authed_usr_id,
    name="ci-deploys",
    scope=["deploy:read", "deploy:write"],  # opaque to SDK; adopter-interpreted
    expires_at=now + timedelta(days=90),
)
# token == "pat_a1b2c3...d4e5f6_K3pVcyBz...EWQ"
# Hand `token` to the user; store the pat record only (pat.id, pat.name, scope, expires_at).
```

```python
# Verify an incoming bearer.
try:
    pat = identity_store.verify_pat_token(bearer_token)  # returns Pat or raises
    auth_kind = "pat"
    usr_id = pat.usr_id
    scope = pat.scope
except InvalidPatTokenError:
    raise Unauthorized()
```

**⚠️ Adopter responsibility (H7 in the v0.3 audit).** `createPat`, `getPat`, `listPatsForUser`, `revokePat` are NOT route-gated by the SDK. The adopter MUST enforce that only the owning `usr` (or an org admin with appropriate authorization) can call these. The doc comments on each method state this; the spec at `docs/identity.md#personal-access-tokens-v03` formalizes it. Treat PAT routes the way you'd treat password-change routes.

**Audit discriminator.** The new `auth.kind` field on audit/event records lets you distinguish `pat` bearers from `session`, `share`, and `system` bearers at log time. It's additive — existing audit consumers continue to work; opt-in to filter on the field.

**Bearer prefix routing.** Your HTTP middleware should prefix-route the bearer:

```
"pat_" prefix    → identity_store.verify_pat_token(bearer)
"shr_" prefix    → share_store.verify_share_token(bearer)
otherwise        → identity_store.verify_session(bearer)
```

The conformance fixture `identity/pat/bearer-prefix-routing.json` pins the classifier semantics across all four SDKs.

## 2. Optional: Postgres rewrite-rule evaluation (ADR 0017)

v0.2's `PostgresTupleStore.check()` was exact-match-only — adopters who needed rule-based authorization with Postgres durability had to load the relevant tuple subset into an `InMemoryTupleStore` at request time.

[ADR 0017](../decisions/0017-postgres-rewrite-rule-evaluation.md) retires that workaround. `PostgresTupleStore.check()` now accepts the same `rules` option as `InMemoryTupleStore` and evaluates via iterative async expansion: one indexed `SELECT` per direct lookup / `tuple_to_userset` enumeration, recursive over `computed_userset`. Cycle detection, depth + fan-out bounds (8 / 1024), and short-circuit semantics from ADR 0007 are unchanged.

```python
# Was (v0.2): rules supported only on in-memory store
store = InMemoryTupleStore(rules={...})

# Is (v0.3): same rules option, now on Postgres
store = PostgresTupleStore(pool=pool, rules={
    "project": {
        "viewer": [
            This(),
            ComputedUserset(relation="editor"),
            TupleToUserset(
                tupleset_relation="parent_org",
                computed_userset_relation="member",
            ),
        ],
    },
})
```

**Node-only API change.** `evaluate()` (the internal rewrite-rule evaluator) becomes async-capable: `DirectLookup` and `ListByObject` callbacks return `Promise<...>`. `InMemoryTupleStore` wraps in `Promise.resolve(...)`; `PostgresTupleStore` issues real async queries. PHP / Python / Java keep synchronous callbacks (no language async coroutine bridge in v0.3).

**Read consistency under writers (accepted limitation).** Rule eval issues N queries against the tuple table. Without serialization, a concurrent writer can produce a torn read across hops. The v0.3 fix-path is the ADR 0013 caller-owned-connection mode with `REPEATABLE READ`:

```python
# Pin one Postgres connection across the entire check; isolate at REPEATABLE READ.
with pool.connection() as conn:
    conn.execute("BEGIN ISOLATION LEVEL REPEATABLE READ;")
    store_pinned = PostgresTupleStore(connection=conn, rules=rules)
    allowed = store_pinned.check("usr", usr_id, "viewer", "project", proj_id)
    conn.execute("COMMIT;")
```

Standalone `PostgresTupleStore(pool=...)` construction still works; it just doesn't serialize across the recursion. The audit doc (M1) and ADR 0017 both document the trade-off.

## 3. Optional: `auth.kind` audit discriminator

v0.3 adds `auth.kind ∈ {session, pat, share, system}` to the audit/event record envelope. The discriminator is set by your HTTP middleware after bearer-prefix routing and emitted on every audit log entry. Existing audit consumers that ignore the field continue to work; downstream filters can opt-in.

The four SDKs export the discriminator as `AuthKind` (TypeScript / Java enum) or `AUTH_KIND` (Python / PHP union of literal strings) — F3 in the v0.3 audit. Centralize the dispatch in your auth middleware:

```typescript
import { AuthKind, classifyBearer } from "@flametrench/identity";

const kind: AuthKind = classifyBearer(bearer);  // "pat" | "share" | "session"
// kind === "system" is set by your background-job / cron-job code paths
auditLog.emit({ ...record, auth: { kind, subject_id } });
```

## 4. Required: Relax `tup.subject_type` check constraint

ADR 0017's rule-eval (especially `tuple_to_userset` hops onto adopter-defined subject types like `pat`) and the new `pat_` primitive itself require the `tup.subject_type` column to accept any short lowercase prefix, not just the v0.1/v0.2 enum.

```sql
-- Run before deploying any v0.3 SDK that writes pat-subject tuples.
ALTER TABLE tup DROP CONSTRAINT tup_subject_type_check;
ALTER TABLE tup ADD CONSTRAINT tup_subject_type_check
    CHECK (subject_type ~ '^[a-z]{2,6}$');
```

The new regex admits v0.1/v0.2's subject types (`usr`, `org`, `mem`) and the v0.3 additions (`pat`) plus any adopter-defined prefix that fits the spec's wire-format rule.

**⚠️ Adopter footgun (F6 in the v0.3 audit).** The relaxed constraint means `tuple_to_userset` rules enumerate every tuple matching the named relation, regardless of subject type. If you have both `(org_X, parent_org, proj_Y)` and `(aud_Z, parent_org, proj_Y)` tuples, a `tuple_to_userset(parent_org → org.viewer)` rule will recurse into both — the `aud_Z` hop misses harmlessly but the wasted round-trip is real. Keep subject-type discipline at write time: only insert tuples whose subject_type matches the rule's intended hop type. v0.4+ may add a typed `tuple_to_userset(parent_org @ org → org.viewer)` syntax that pins the expected hop subject_type at rule definition time.

## 5. Add the `pat` table

If you're adopting personal access tokens, add the `pat` table from the v0.3 reference schema:

```sql
CREATE TABLE pat (
    id           UUID PRIMARY KEY,
    usr_id       UUID NOT NULL REFERENCES usr(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    secret_hash  TEXT NOT NULL,           -- Argon2id PHC string
    scope        TEXT[] NOT NULL DEFAULT '{}',
    expires_at   TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    revoked_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX pat_usr_id_idx           ON pat(usr_id);
CREATE INDEX pat_active_idx           ON pat(usr_id) WHERE revoked_at IS NULL;
CREATE INDEX pat_expires_at_idx       ON pat(expires_at) WHERE revoked_at IS NULL;

CREATE TRIGGER pat_touch BEFORE UPDATE ON pat
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
```

Full DDL is in [`reference/postgres.sql`](../reference/postgres.sql). The optional RLS policy companion in `postgres-rls.sql` includes a `pat` table policy.

## 6. SDK bumps

```
# PHP
composer require flametrench/ids:^0.3.0 \
                 flametrench/identity:^0.3.0 \
                 flametrench/tenancy:^0.3.0 \
                 flametrench/authz:^0.3.0

# Node
pnpm add @flametrench/ids@^0.3.0 \
         @flametrench/identity@^0.3.0 \
         @flametrench/tenancy@^0.3.0 \
         @flametrench/authz@^0.3.0

# Python (once PyPI org approval lands)
pip install 'flametrench-ids>=0.3.0' \
            'flametrench-identity>=0.3.0' \
            'flametrench-tenancy>=0.3.0' \
            'flametrench-authz>=0.3.0'

# Java (once Maven Central credential regen lands)
# <dependency>
#   <groupId>dev.flametrench</groupId>
#   <artifactId>{ids,identity,tenancy,authz}</artifactId>
#   <version>0.3.0</version>
# </dependency>
```

`tenancy` bumps to 0.3.0 across all families with no surface changes — the version is moving in lockstep with the SDK matrix.

## 7. Security audit changes you inherit

Every adopter inherits the 22 in-code fixes from the [v0.3 security audit](security-audit-v0.3.md) without action. The high-leverage ones to be aware of:

- **C1** — PHP `authz-php`'s `checkAny` validated relations against the regex pattern before binding; any relation containing `","` previously could smuggle additional matches past the natural-key check. Patched in `authz-php@2a25e30`.
- **H2** — PAT verification on a missing-row path now runs a dummy Argon2id verify before raising, closing a token-presence timing oracle. Conformance-pinned across all four SDKs.
- **H3** — `pat.last_used_at` updates are conditional on `revoked_at IS NULL` — a revoked PAT no longer touches the timestamp.
- **M1** — `PostgresTupleStore.check()` rule eval pins a single Postgres connection across the recursion in Node / Java; PHP / Python are pinned by construction.
- **M9** — `subjectIdToUuid()` now takes `subjectType` and asserts the prefix; mismatches previously coerced silently.

Full per-finding remediation table at [`docs/security-audit-v0.3.md`](security-audit-v0.3.md).

## 8. Conformance fixtures

Two new fixtures land in v0.3:

- `identity/pat/token-format.json` — 11 tests pinning the `pat_<32hex>_<base64url>` wire-format structural validation.
- `identity/pat/bearer-prefix-routing.json` — 6 tests pinning the `auth.kind ∈ {pat, share, session}` classifier and the no-cross-routing invariant.

Plus an updated `identity/argon2id.json` that pins the dummy PHC hash used by the H2 timing-oracle fix.

If your SDK consumes the conformance suite, re-run after upgrading — the v0.3 fixtures are in the `index.json` manifest.

## 9. What's still deferred to v0.4+

Two v0.3 audit findings are explicit v0.4 deferrals (rationale in the audit doc remediation table):

- **L4** — `classifyBearer` `customPrefixes` extension hook. Adopters who want a custom prefix (e.g. `api_…`) today must fork the dispatcher; v0.4 will accept an optional `customPrefixes` parameter.
- **F2** — branded `UsrId` / `OrgId` value-object types in PHP and Python. Node has TypeScript branded types; Java has typed records. The PHP / Python uplift touches every method signature in identity / authz / tenancy — too large for the v0.3 ship.

Pre-existing v0.3-deferred items from v0.2:
- Group subjects in tuples (parent-child inheritance via subject sets) — see [ADR 0007](../decisions/0007-authorization-rewrite-rules.md).
- Intersection and exclusion in rewrite rules.

Open issues with adopter signal will land in v0.4 (no date committed). Track at `flametrench/spec`.

## Common upgrade questions

**Do I have to relax the `tup.subject_type` constraint if I'm not using PATs?**
Yes if you write any `pat`-subject tuples or use `tuple_to_userset` rules that recurse onto adopter-defined subject types. No if you're a pure v0.2 user who's just bumping SDK versions for the security audit fixes — but the migration is forward-compatible and recommended.

**Will my v0.2 audit log consumers break on the new `auth.kind` field?**
No. It's additive on the envelope; consumers that ignore unknown fields continue to work. v0.2 records had an implicit-session `auth.kind` — v0.3 makes it explicit.

**Does `PostgresTupleStore({ pool, rules })` work without pinning a connection?**
Yes — but rule eval issues N queries and a concurrent writer can produce a torn read across hops. For consistency-critical paths use the caller-owned-connection mode with `REPEATABLE READ` (§2 above). The trade-off is documented in ADR 0017.

**Are PyPI and Maven Central published?**
Not yet — same external blocks that held v0.2.0 (PyPI org approval pending; Maven Central credential regen pending). Python and Java SDKs are tagged at v0.3.0 with wheels / bundles built locally; they publish when the blockers clear. Verify each registry directly before quoting state: `pip index versions flametrench-ids` / `mvn dependency:get -Dartifact=dev.flametrench:ids:0.3.0`.
