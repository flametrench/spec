# Authorization fixtures (placeholder for v0.1.0)

Authorization fixtures need a tuple store to seed before a `check()` can be meaningful. No Flametrench SDK has published the authorization layer yet; fixtures are deferred until that work lands.

When the first authz SDK lands, the following fixtures will be added here:

- **`check-exact-match.json`** — given `tup_(alice, editor, project_42)` and no other tuples for that subject/object pair, `check(alice, editor, project_42)` MUST return `true`; `check(alice, viewer, project_42)` MUST return `false`.
- **`check-set-form.json`** — given the same tuple, `check(alice, [viewer, editor], project_42)` MUST return `true`. The empty set MUST produce a validation error, not silently return `false`.
- **`check-no-derivation.json`** — given `tup_(alice, admin, org_acme)` as the only tuple, `check(alice, editor, org_acme)` MUST return `false`. v0.1 does NOT imply `editor` from `admin`. This fixture exists specifically to catch SDKs that accidentally introduce derivation.
- **`uniqueness.json`** — attempting to create two tuples with identical `(subject_type, subject_id, relation, object_type, object_id)` natural keys MUST either reject the second call with an error OR be idempotent (returning the existing tuple's id). Implementations MUST NOT persist duplicate rows.
- **`cascade-on-subject-revoke.json`** — given N tuples with the same subject, `cascadeRevokeSubject(subject)` MUST delete all N in one transaction.
- **`enumeration-pagination.json`** — `listTuplesByObject` with a small `limit` MUST return a cursor; following the cursor MUST yield the remaining results in UUIDv7-sorted order with no duplicates or skips.
- **`invalid-subject-id-rejected.json`** — a `createTuple` call with `subject_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"` (Max UUID) MUST fail per `docs/ids.md` rule 5; the fixture enforces that authz doesn't bypass ID validation.

See `spec/docs/authorization.md` for the normative behavior the fixtures will exercise.
