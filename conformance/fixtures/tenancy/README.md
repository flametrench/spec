# Tenancy fixtures

Conformance fixtures for the tenancy capability (`docs/tenancy.md`). Tenancy operations chain together (create_org → add_member → change_role → assert tuple state), so these fixtures use the **state-machine test format** — `users[]` declarations + ordered `steps[]` with capture/substitution — rather than the single-step `input`/`expected` shape used by the ids and authz fixtures.

The state-machine format is documented in `spec/conformance/fixture.schema.json`. Each test:

1. Declares named users; the harness pre-allocates a fresh `usr_` ID for each name.
2. Lists ordered steps. Each step calls one operation; the result MAY be captured by name for later substitution via `{name}` references.
3. A step with `expected.error` MUST throw the named error and the test ends. Steps without `expected` MUST succeed.

State assertions use harness-recognized pseudo-ops:

- **`assert_subject_relations`** — `(subject_type, subject_id, relations: [string])`. Asserts the set of active relations the subject holds matches `relations` exactly. Order-independent.
- **`assert_equal`** — `(actual, expected)`. Generic equality assertion for captured scalars.

These pseudo-ops are not part of the SDK's public surface; they live in the conformance harness.

## v0.1 — runnable today

| File                       | Operation              | Tests | What it locks down |
| -------------------------- | ---------------------- | ----: | ------------------ |
| `self-leave.json`          | `self_leave`           |     3 | Sole-owner protection: a lone owner cannot self-leave without `transferTo`. With `transferTo` the SDK promotes-then-revokes atomically. Non-owners self-leave unconditionally. |
| `change-role.json`         | `change_role`          |     3 | Sole-owner demotion is blocked. Role changes are revoke-and-re-add: the old `mem_` transitions to revoked, a new `mem_` is inserted with `replaces = old.id`, and the `(usr, role, org)` tuple swaps atomically. |
| `transfer-ownership.json`  | `transfer_ownership`   |     2 | Atomic owner swap: target promoted before donor demoted, intermediate states never observable. Self-transfer rejected. |
| `admin-remove.json`        | `admin_remove`         |     4 | Role hierarchy: admin removes member ✓, admin removes peer admin ✓ (equal rank permitted), admin removes owner ✗ (use `transferOwnership`), non-admin invokes admin_remove ✗. |
| `invitation-accept.json`   | `accept_invitation`    |     3 | Atomic acceptance: pre-tuples materialize as real `tup_` rows keyed on the accepting user, alongside the membership tuple, in one transaction. Re-accepting a terminal invitation raises `InvitationNotPendingError`. |

## Harness implementation status

The state-machine fixture format is consumed today by:

- `flametrench-tenancy` (Python) — full harness, all 15 tests run.

Pending follow-up SDKs (file an issue if you need one prioritized):

- `@flametrench/tenancy` (Node) — the snake_case fixture keys need a camelCase adapter; otherwise the harness shape is identical to Python.
- `flametrench/tenancy` (PHP) — same camelCase adaptation needed.
- `flametrench/tenancy:java` — same, plus a Map-of-record builder for fixture inputs.

The single-step fixtures (ids, authz, identity) are runnable across all four SDKs already; only the new state-machine corpus is currently Python-only.

## Fixture format reference

```jsonc
{
  "id": "self_leave.sole_owner.requires_transfer",
  "description": "...",
  "users": ["alice"],          // pre-allocated usr_ IDs, referenced as {alice}
  "steps": [
    {
      "op": "create_org",
      "input": { "creator": "{alice}" },
      "captures": { "owner_mem_id": "owner_membership.id" }
    },
    {
      "op": "self_leave",
      "input": { "mem_id": "{owner_mem_id}" },
      "expected": { "error": "SoleOwnerError" }
    }
  ]
}
```

See `spec/docs/tenancy.md` for the normative behavior these fixtures exercise.
