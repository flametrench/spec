# Migrating from v0.1 to v0.2

This guide is for applications already running on a v0.1 Flametrench SDK that want to adopt v0.2.

**Status:** v0.2 is at `v0.2.0-rc.2`. Adopt it on a non-production environment first, file issues at [`flametrench/spec`](https://github.com/flametrench/spec/issues), and roll forward to production once v0.2 final ships.

The migration is **additive**: nothing in v0.1 changes shape. Every v0.1 call site keeps working unchanged. The only required change is the [security patch in ADR 0009](#1-mandatory-adr-0009-invitation-acceptance-binding) — already backported to v0.1.x — and that change is enforced by the SDK regardless of whether you adopt the rest of v0.2.

## At a glance

| Surface | v0.1 | v0.2 |
|---|---|---|
| ID prefixes | `usr_`, `cred_`, `ses_`, `org_`, `mem_`, `inv_`, `tup_` | adds `mfa_` |
| Authorization | exact-match `check()` over tuples | adds optional `rules` parameter on store construction (rewrite rules) |
| Identity | password / passkey / OIDC credentials | adds MFA factor records (TOTP, WebAuthn, recovery) + `usr_mfa_policy` |
| WebAuthn (in MFA) | — | ES256 + RS256 + EdDSA assertion verification |
| `acceptInvitation` | accepted any `as_usr_id` (security gap) | requires `accepting_identifier` byte-matching `invitation.identifier` |
| Postgres reference | 7 tables | adds `mfa`, `usr_mfa_policy`, plus `ses.mfa_verified_at` column |
| Postgres RLS | absent | optional `postgres-rls.sql` companion |
| OpenAPI | `flametrench-v0.1.yaml` | `flametrench-v0.2-additions.yaml` (composes additively) |

## 1. Mandatory: ADR 0009 invitation acceptance binding

Every v0.1.1 / v0.2 SDK rejects `acceptInvitation` calls that supply `as_usr_id` without `accepting_identifier`. This closes a privilege-escalation primitive reported in [`spec#5`](https://github.com/flametrench/spec/issues/5).

**Code change.** Wherever your application calls `acceptInvitation`, add `accepting_identifier`:

```python
# Before
store.accept_invitation(inv_id, as_usr_id=authed_usr_id)

# After
store.accept_invitation(
    inv_id,
    as_usr_id=authed_usr_id,
    accepting_identifier=identity_store.canonical_identifier(authed_usr_id),
)
```

**Sourcing requirement (normative).** `accepting_identifier` MUST come from the authenticated session — typically the canonical email/handle attached to the bearer token's `usr_id`. It MUST NOT come from the request body without an authenticity check. The SDK enforces byte-equality; the host's auth layer enforces source authenticity. See `docs/tenancy.md#identifier-binding-normative`.

**Mint-new-user path** (`as_usr_id = null`) is unchanged: the SDK creates a fresh `usr_` and the host wires the corresponding credential separately.

## 2. Optional: Authorization rewrite rules

[ADR 0007](../decisions/0007-authorization-rewrite-rules.md) introduces rewrite rules — a subset of Zanzibar's `userset_rewrite`. Without registering rules, `check()` behavior is byte-identical to v0.1.

Register rules at store construction time:

```python
from flametrench_authz import (
    InMemoryTupleStore,
    This,
    ComputedUserset,
    TupleToUserset,
)

store = InMemoryTupleStore(
    rules={
        # When checking 'project.viewer', also include anyone who's an
        # editor on the project, OR a member of the project's parent org.
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
    },
)
```

The depth and fan-out caps are 8 and 1024 respectively; deeper or wider rule graphs raise `EvaluationLimitExceededError`. Rules are SDK/application configuration, not row-level data — store them in code or in an app-managed config table.

## 3. Optional: MFA

[ADR 0008](../decisions/0008-mfa.md) and [ADR 0010](../decisions/0010-webauthn-rs256-eddsa.md) add three first-class factor types. The SDK ships:

- TOTP compute / verify (RFC 6238) and helpers (`generateTotpSecret`, `totpOtpauthUri`).
- WebAuthn assertion verifier with COSE-alg dispatch (ES256 / RS256 / EdDSA).
- Recovery-code generator and format predicate.
- A `UserMfaPolicy` record with `isActiveNow(now)`.

The session-mint flow becomes three calls:

```python
result = identity_store.verify_password(identifier, candidate)
# If usr_mfa_policy.required and grace elapsed, route the user to the
# MFA challenge instead of minting a session immediately. After the user
# presents a factor proof:
mfa_ok = identity_store.verify_mfa(usr_id, proof)  # SDK responsibility
if mfa_ok:
    session = identity_store.create_session(usr_id, cred_id)
```

The SDK provides the verification primitives (`totp_verify`, `webauthn_verify_assertion`, `is_valid_recovery_code` + the consumed-flag bookkeeping). The store layer composes them into `verify_mfa` per your application's flow.

**Wire surface.** New endpoints in `openapi/flametrench-v0.2-additions.yaml`:

- `GET/POST /users/{usr_id}/mfa-factors` — list / enroll
- `POST /mfa-factors/{mfa_id}/confirm` — confirm pending TOTP/WebAuthn
- `POST /mfa-factors/{mfa_id}/revoke`
- `POST /users/{usr_id}/mfa/verify`
- `GET/PUT /users/{usr_id}/mfa-policy`

Bundle the v0.1 + v0.2 OpenAPI files into a single served spec via `npx @redocly/cli bundle openapi/flametrench-v0.1.yaml openapi/flametrench-v0.2-additions.yaml`.

## 4. Optional: Postgres schema additions

The reference schema gains two tables and one column. Apply the additive DDL block at the bottom of `reference/postgres.sql` to a v0.1 database:

```sql
-- Run only the v0.2 section of postgres.sql, OR re-run the full file
-- against a fresh database. Existing v0.1 rows are not touched.
```

The new tables:

- **`mfa`** — per-user factor records. Type-discriminated via CHECK; partial-unique-active for at most one TOTP and one recovery set per user; multiple WebAuthn factors permitted.
- **`usr_mfa_policy`** — per-user enforcement, 1:1 with `usr`. Absent row means MFA not required.
- **`ses.mfa_verified_at`** — nullable timestamp for step-up auth freshness.

## 5. Optional: Postgres RLS

`reference/postgres-rls.sql` is a new optional companion. Apply AFTER `postgres.sql`. Installs per-table policies that read two session GUCs:

- `flametrench.current_usr_id` — UUID of the authenticated user
- `flametrench.actor_role` — `'tenant'` (subject to RLS) or `'admin'` (bypass)

The application sets the GUCs at the start of each request from its authentication context. RLS then enforces isolation across `usr`, `cred`, `ses`, `org`, `mem`, `inv`, `tup`, `mfa`, `usr_mfa_policy` regardless of whether the application's own checks are bug-free. See the file's "Operational notes" section for the dedicated-role pattern (`flametrench_app NOINHERIT NOSUPERUSER`).

## Conformance fixture changes

If you run the conformance suite against your own implementation, the fixture corpus grew from 17 (v0.1) to 24 (v0.2). New files:

- `authorization/rewrite-rules/computed-userset.json` (3 tests)
- `authorization/rewrite-rules/tuple-to-userset.json` (3 tests)
- `authorization/rewrite-rules/empty-rules-equals-v01.json` (3 tests)
- `identity/mfa/totp-rfc6238.json` (18 RFC 6238 §B vectors)
- `identity/mfa/recovery-code-format.json` (12 tests)
- `identity/mfa/webauthn-assertion.json` (7 tests against an ES256 keypair)
- `identity/mfa/webauthn-counter-decrease-rejected.json` (4 tests for spec §6.1.1)
- `identity/mfa/webauthn-assertion-algorithms.json` (6 tests for ADR 0010 dispatch)
- `tenancy/invitation-accept-binding.json` (4 tests for ADR 0009)

The existing `tenancy/invitation-accept.json` was updated to pass `accepting_identifier` alongside `as_usr_id`; pre-fix SDKs see it fail closed with `IdentifierBindingRequiredError`, which is the desired behavior.

## Rollback

If something goes wrong:

1. **SDK level**: pin to the previous tag (`v0.1.0` or `v0.1.1` for tenancy). Your code that doesn't pass `accepting_identifier` will return to the v0.1 (vulnerable) behavior — **only acceptable as a brief diagnostic step**.
2. **Database level**: the v0.2 additions are additive. Drop `mfa`, `usr_mfa_policy`, and the `mfa_verified_at` column to revert to v0.1 schema. Rolling back RLS is `ALTER TABLE … DISABLE ROW LEVEL SECURITY` on each affected table.
3. **OpenAPI level**: serve only `flametrench-v0.1.yaml`. Adopters who have wired up MFA endpoints will see 404s — communicate the rollback before doing it.

## Reporting issues

[`flametrench/spec`](https://github.com/flametrench/spec/issues) is the right place for spec-level questions; per-SDK questions go to the relevant SDK repository. Tag spec issues with the affected ADR number where possible.
