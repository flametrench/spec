# Migrating from v0.1 to v0.2

This guide is for applications already running on a v0.1 Flametrench SDK that want to adopt v0.2.

**Status:** v0.2.0 is stable. Adopt it on a non-production environment first, file issues at [`flametrench/spec`](https://github.com/flametrench/spec/issues), and roll forward to production once your acceptance tests pass.

The migration is **additive**: nothing in v0.1 changes shape. Every v0.1 call site keeps working unchanged. The only required change is the [security patch in ADR 0009](#1-mandatory-adr-0009-invitation-acceptance-binding) — already backported to v0.1.x — and that change is enforced by the SDK regardless of whether you adopt the rest of v0.2.

## At a glance

| Surface | v0.1 | v0.2 |
|---|---|---|
| ID prefixes | `usr_`, `cred_`, `ses_`, `org_`, `mem_`, `inv_`, `tup_` | adds `mfa_`, `shr_` |
| Authorization | exact-match `check()` over tuples | adds optional `rules` parameter on store construction (rewrite rules) |
| Share tokens | absent | new `ShareStore` for capability-style URL sharing (ADR 0012) |
| Identity | password / passkey / OIDC credentials | adds MFA factor records (TOTP, WebAuthn, recovery) + `usr_mfa_policy` |
| User entity | `id`, `status`, timestamps | adds optional `display_name` (ADR 0014) + `updateUser` partial-update |
| User enumeration | absent | new `listUsers` cursor-paginated with credential-identifier filter (ADR 0015) |
| WebAuthn (in MFA) | — | ES256 + RS256 + EdDSA assertion verification |
| `acceptInvitation` | accepted any `as_usr_id` (security gap) | requires `accepting_identifier` byte-matching `invitation.identifier` |
| Postgres reference | 7 tables | adds `mfa`, `usr_mfa_policy`, `shr`, plus `ses.mfa_verified_at` and `usr.display_name` columns |
| Postgres adapters | in-memory only | `PostgresIdentityStore`, `PostgresTenancyStore`, `PostgresTupleStore`, `PostgresShareStore` cooperate with caller-owned outer transactions via savepoints (ADR 0013) |
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

## 5. Optional: Postgres adapter transaction nesting (ADR 0013)

If your application has its own outer transactions and wants the SDK's Postgres adapter writes to participate in them — commit-or-rollback together — construct the adapter with a caller-owned connection instead of a pool/DataSource. The adapter detects this and pivots from BEGIN/COMMIT to SAVEPOINT/RELEASE so a constraint violation in one SDK call rolls back its own work without poisoning the outer transaction.

```python
# Standalone (the v0.1 / default path is unchanged)
store = PostgresTupleStore(pool=pool)

# Caller-owned (new in v0.2)
async with pool.connection() as conn, conn.transaction():
    nested = PostgresTupleStore(connection=conn)
    await nested.create_tuple(...)
    await nested.create_tuple(...)
    # If the second create_tuple raises DuplicateTupleError, the savepoint
    # rolls back; the outer txn stays usable for further work.
```

Same contract per language idiom — Node distinguishes Pool vs PoolClient by the presence of a `release` method; PHP uses PDO's `inTransaction()`; Java accepts a `Connection` constructor in addition to `DataSource`. See ADR 0013 for the full pattern.

## 6. Optional: Share tokens (ADR 0012)

The new `ShareStore` mints opaque tokens (`shr_<32 hex>` ID, separate 256-bit base64url token) that grant a single relation on a single object until expiry. Tokens are SHA-256-hashed at rest; only the holder of the token can verify against the store. Tokens are capped at 1 year and may be marked single-use.

```python
result = share_store.create_share(
    object_type="proj", object_id=project_id,
    relation="viewer", created_by=alice_id,
    expires_in_seconds=86400,
    single_use=False,
)
# `result.token` is the value to embed in a share URL — show it once;
# the SDK only stores its hash.
verified = share_store.verify_share_token(result.token)  # → VerifiedShare
```

Spec error precedence: `consumed > revoked > expired > active`. Suspended/revoked users cannot mint shares (`creator_not_active`).

## 7. Optional: User display name + updateUser (ADR 0014)

`User` records carry an optional `display_name` (max 200 chars, NFC-normalized). New `update_user` operation supports partial updates — pass `UNSET` (or the language equivalent) to leave a field unchanged, or `None`/`null` to clear it.

```python
identity_store.update_user(usr_id, display_name="Alice Liddell")
# Or clear it:
identity_store.update_user(usr_id, display_name=None)
```

## 8. Optional: User enumeration (ADR 0015)

`list_users` returns a cursor-paginated page filtered by credential-identifier substring (case-insensitive) and/or `status`. Inactive users (suspended/revoked) are included unless `status` is supplied.

```python
page = identity_store.list_users(
    identifier_query="alice@",  # matches any credential identifier
    status="active",
    cursor=None, limit=50,
)
# page.data: list[User]; page.next_cursor: str | None
```

## 9. Optional: Postgres RLS

`reference/postgres-rls.sql` is a new optional companion. Apply AFTER `postgres.sql`. Installs per-table policies that read two session GUCs:

- `flametrench.current_usr_id` — UUID of the authenticated user
- `flametrench.actor_role` — `'tenant'` (subject to RLS) or `'admin'` (bypass)

The application sets the GUCs at the start of each request from its authentication context. RLS then enforces isolation across `usr`, `cred`, `ses`, `org`, `mem`, `inv`, `tup`, `mfa`, `usr_mfa_policy` regardless of whether the application's own checks are bug-free. See the file's "Operational notes" section for the dedicated-role pattern (`flametrench_app NOINHERIT NOSUPERUSER`).

## Conformance fixture changes

If you run the conformance suite against your own implementation, the fixture corpus grew from 17 (v0.1) to 27 (v0.2). New files:

- `authorization/rewrite-rules/computed-userset.json` (3 tests)
- `authorization/rewrite-rules/tuple-to-userset.json` (3 tests)
- `authorization/rewrite-rules/empty-rules-equals-v01.json` (3 tests)
- `identity/mfa/totp-rfc6238.json` (18 RFC 6238 §B vectors)
- `identity/mfa/recovery-code-format.json` (12 tests)
- `identity/mfa/webauthn-assertion.json` (7 tests against an ES256 keypair)
- `identity/mfa/webauthn-counter-decrease-rejected.json` (4 tests for spec §6.1.1)
- `identity/mfa/webauthn-assertion-algorithms.json` (6 tests for ADR 0010 dispatch)
- `tenancy/invitation-accept-binding.json` (4 tests for ADR 0009)
- `identity/user-display-name.json` (ADR 0014: optional display_name + updateUser partial-update)
- `identity/list-users.json` (ADR 0015: cursor-paginated user enumeration)

The existing `tenancy/invitation-accept.json` was updated to pass `accepting_identifier` alongside `as_usr_id`; pre-fix SDKs see it fail closed with `IdentifierBindingRequiredError`, which is the desired behavior.

ADR 0013 (Postgres adapter transaction nesting) is enforced at the SDK level rather than via fixtures — every Postgres adapter has regression tests demonstrating savepoint cooperation under a caller-owned outer transaction.

## Rollback

If something goes wrong:

1. **SDK level**: pin to the previous tag (`v0.1.0` or `v0.1.1` for tenancy). Your code that doesn't pass `accepting_identifier` will return to the v0.1 (vulnerable) behavior — **only acceptable as a brief diagnostic step**.
2. **Database level**: the v0.2 additions are additive. Drop `mfa`, `usr_mfa_policy`, and the `mfa_verified_at` column to revert to v0.1 schema. Rolling back RLS is `ALTER TABLE … DISABLE ROW LEVEL SECURITY` on each affected table.
3. **OpenAPI level**: serve only `flametrench-v0.1.yaml`. Adopters who have wired up MFA endpoints will see 404s — communicate the rollback before doing it.

## Reporting issues

[`flametrench/spec`](https://github.com/flametrench/spec/issues) is the right place for spec-level questions; per-SDK questions go to the relevant SDK repository. Tag spec issues with the affected ADR number where possible.
