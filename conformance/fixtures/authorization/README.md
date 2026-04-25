# Authorization fixtures

Conformance fixtures for the authorization capability (`docs/authorization.md`). Every test embeds a `given_tuples[]` precondition array — the tuple store the SDK should be in before applying the operation under test. Harnesses MUST seed those tuples before running the assertion.

## v0.1 — runnable today

| File                | Operation       | Tests | What it locks down |
| ------------------- | --------------- | ----: | ------------------ |
| `check.json`        | `check`         |     8 | Exact-match semantics — and explicit `no-derivation` cases (admin ≠ editor, editor ≠ viewer, org membership ≠ project access). v0.1 has no role implication or parent-child inheritance; this fixture catches any SDK that accidentally adds it. |
| `check-any.json`    | `check_any`     |     4 | Set-form `check` returns true if ANY supplied relation matches; empty relations array MUST raise `EmptyRelationSetError` rather than silently returning false. |
| `uniqueness.json`   | `create_tuple`  |     2 | The 5-key natural key `(subject_type, subject_id, relation, object_type, object_id)` is unique. Duplicate creation raises `DuplicateTupleError`; tuples differing only in relation may coexist. |
| `format.json`       | `create_tuple`  |     5 | Relation regex `^[a-z_]{2,32}$` and object-type regex `^[a-z]{2,6}$` enforced at create time. Violations raise `InvalidFormatError`; underscores in custom relations are accepted. |

## v0.1 — deferred

These will land alongside the SDK features they exercise. Stub them out as `runnable_today: false` in `conformance/index.json` if you add them before the SDK code:

- **`cascade-on-subject-revoke.json`** — `cascadeRevokeSubject(subject)` deletes all tuples for the subject in one transaction. Requires the bulk-revoke API.
- **`enumeration-pagination.json`** — `listTuplesByObject` cursor pagination. Requires the enumeration API and stable UUIDv7 sort.
- **`invalid-subject-id-rejected.json`** — `createTuple` rejects `subject_id = Max UUID` per `docs/ids.md` rule 5. Cross-cuts ID validation; landing this requires the authz layer to call into the ID validator.

## Fixture format

Inputs are operation-shaped:

```jsonc
{
  "given_tuples": [{ /* 5-key tuple */ }],   // store state before the op
  "create": { /* tuple to create */ },        // for create_tuple ops
  "check":  { /* check input */ }             // for check / check_any ops
}
```

Outputs are either `{ "result": ... }` for the happy path or `{ "error": "ErrorName" }` for the failure path. Errors are spec error names; SDKs map them to language-native types.

See `spec/docs/authorization.md` for the normative behavior these fixtures exercise.
