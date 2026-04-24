# Tenancy fixtures (placeholder for v0.1.0)

Tenancy fixtures require an SDK with state — organizations, memberships, invitations, and the transactional guarantees around accepting an invitation. No current Flametrench SDK implements the tenancy layer, so no fixtures are yet runnable.

When the first tenancy SDK lands, the following fixtures will be added here:

- **`invitation-accept.json`** — given a pending invitation with `pre_tuples = [{ relation: "viewer", object_type: "project", object_id: "<uuid>" }]`, accepting MUST atomically (a) create the user if absent, (b) insert a `mem_` at the invitation's role, (c) materialize one `tup_` for the membership plus one for each pre-tuple, and (d) transition the invitation to `accepted`. Any failure in any step MUST roll back the entire transaction.
- **`sole-owner-transfer.json`** — an org with one owner: `selfLeave(owner_mem_id)` MUST fail without `transferTo`; with `transferTo` pointing at an active member, the call MUST atomically transfer ownership and revoke the leaver's membership.
- **`admin-remove-hierarchy.json`** — given `mem_alice (role=admin)` and `mem_bob (role=owner)`, `adminRemove(bob, initiator=alice)` MUST fail (admins cannot remove owners).
- **`role-change-replaces-chain.json`** — changing a membership's role MUST NOT mutate in place. The existing `mem_` MUST transition to `revoked`; a new `mem_` MUST be inserted with `replaces = old.id`; the tuple swap MUST be atomic.
- **`removed-by-attribution.json`** — a `mem_` revoked via `selfLeave` MUST have `removed_by = null`; one revoked via `adminRemove` MUST have `removed_by` set to the admin's `usr_id`.

See `spec/docs/tenancy.md` for the normative behavior the fixtures will exercise.
