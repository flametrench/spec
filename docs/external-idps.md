# Coexistence with external identity providers

This document is non-normative. It explains the integration patterns adopters use when their authentication is already handled by an external identity provider — Auth0, Clerk, Cognito, Okta, WorkOS, Microsoft Entra, Firebase Auth, Supabase Auth, or a homegrown service.

The short answer: **Flametrench does not compete with your IdP.** Identity is one of three Flametrench capabilities, and it is the only one most teams already have a vendor for. Tenancy and authorization — the parts every application rebuilds because no IdP solves them — are what Flametrench is for.

## What Flametrench actually does

Flametrench's surface splits cleanly:

| Capability | What it solves | IdP equivalent |
|---|---|---|
| **Identity** (`flametrench-identity`) | Users, credentials (Argon2id-pinned passwords / passkeys / OIDC), sessions with rotation, MFA factors. | Auth0, Clerk, Cognito, Okta, WorkOS, etc. |
| **Tenancy** (`flametrench-tenancy`) | Organizations, memberships, invitations with atomic acceptance, role lifecycle, sole-owner protection. | None (most IdPs offer "organizations" but their membership semantics are thin and don't cover invitation acceptance, revoke-and-re-add role changes, or the membership-as-tuple duality). |
| **Authorization** (`flametrench-authz`) | Relational tuples, exact-match `check()`, opt-in rewrite rules, share tokens. | None (an IdP issues a token; what that token *can do* in your application is your problem). |

If you're already using an IdP for authentication, **`flametrench-identity` is optional**. The `usr_` identifier becomes a foreign-key bridge between the IdP's user record and your application's tenancy + authz state. The other two packages are where the value lands.

## Two integration patterns

### Pattern A: External IdP for sign-in, Flametrench for tenancy + authz

This is the common case. Your existing IdP owns sign-in, sessions, MFA, and password reset. Flametrench owns the org/membership/permission layer.

```
External IdP             Your application                Flametrench
────────────             ────────────────                ───────────
sign-in                                                  
  │                                                     
  ├─→ ID token / JWT  ─→ verify token                   
  │                       │                             
  │                       ├─→ resolve external_id ──→  usr_ (lookup or upsert)
  │                       │                             
  │                       └─→ load org context  ─────→  PostgresTenancyStore
  │                                                     │
  │                       ─→ check permission  ───────→ PostgresTupleStore
  │                                                     ▼
  │                       ─→ render response  ←──────── allowed/denied
```

**The bridge**: the application maintains a `usr_<32hex>` for every external IdP user, keyed by the external user ID. The mapping lives in your app, not in the spec — the spec doesn't know about Auth0 user IDs or Clerk user IDs and shouldn't.

#### Concrete example: Auth0 → Flametrench bridge

Auth0 issues a JWT with a `sub` claim (e.g., `auth0|67890abc...`). Your application verifies the JWT, resolves the Auth0 `sub` to a Flametrench `usr_`, and uses that `usr_` for every tenancy and authz operation.

```ts
import { jwtVerify, createRemoteJWKSet } from "jose";
import { generate as genId } from "@flametrench/ids";

// Once at startup.
const jwks = createRemoteJWKSet(new URL(`https://${AUTH0_DOMAIN}/.well-known/jwks.json`));

// Maps an Auth0 sub to a Flametrench usr_. Stored in your app's DB.
async function resolveUsrFromAuth0Sub(auth0Sub: string): Promise<string> {
  const existing = await db.users.findOne({ external_id: auth0Sub });
  if (existing) return existing.usr_id;
  // First sign-in: mint a Flametrench usr_ and bind it.
  const usrId = genId("usr");
  await db.users.insert({ usr_id: usrId, external_id: auth0Sub });
  // Mirror into the usr table that flametrench-tenancy/authz FK to.
  await pool.query(`INSERT INTO usr (id, status) VALUES ($1, 'active')`, [
    decode(usrId).uuid,
  ]);
  return usrId;
}

// Per request.
async function authenticate(request: Request): Promise<{ usrId: string }> {
  const token = request.headers.get("authorization")?.replace("Bearer ", "");
  if (!token) throw new Error("missing token");
  const { payload } = await jwtVerify(token, jwks, {
    issuer: `https://${AUTH0_DOMAIN}/`,
    audience: AUTH0_AUDIENCE,
  });
  const usrId = await resolveUsrFromAuth0Sub(payload.sub as string);
  return { usrId };
}

// Use Flametrench from here.
async function handleListProjects(request: Request) {
  const { usrId } = await authenticate(request);
  // Find the user's orgs through tenancy.
  const orgs = await tenancyStore.listOrgsForUser(usrId);
  // Check permission on a specific project.
  const result = await authzStore.check({
    subjectType: "usr",
    subjectId: usrId,
    relation: "viewer",
    objectType: "proj",
    objectId: "proj_0190...",
  });
  // ...
}
```

The pattern is identical for **Clerk** (`sub` is the Clerk user ID), **Cognito** (`sub` is the Cognito user pool subject), **Okta** (`sub` is the Okta user ID), **WorkOS** (`sub` is the WorkOS user ID), and **homegrown JWTs** (whatever your `sub` claim contains).

#### What you skip when going this route

- `flametrench-identity` — you don't `createUser`, `createPasswordCredential`, `verifyPassword`, `createSession`, or any of the session/MFA APIs. Your IdP owns all of that.
- The `cred`, `ses`, and `mfa` tables in the reference Postgres schema. You can drop them from your migrations or leave them empty.
- The `passwordHashing` parameter floor — your IdP handles password storage.

#### What you still need

- **The `usr` table.** `flametrench-tenancy` and `flametrench-authz` foreign-key to `usr.id`. The minimum schema is `id UUID PRIMARY KEY, status TEXT NOT NULL CHECK (status IN ('active', 'suspended', 'revoked'))` — that's it. You upsert into it on first sign-in and update `status` when your IdP signals the user is deactivated.
- **An external-ID bridge table.** Your application's own table (`users` in the example above) that maps your IdP's user identifier to the Flametrench `usr_id`. The spec doesn't define this — it's load-bearing application state.

### Pattern B: Flametrench for everything

Flametrench's `identity` package is a complete IdP for the cases where you don't want an external one. Argon2id-pinned passwords, passkeys, OIDC inbound, sessions, MFA. This is the "we want one less SaaS bill" path.

You'd reach for this when:

- You're a B2B SaaS with sub-1000 paying customers and your IdP cost is meaningful.
- You need to control the password storage parameters yourself for regulatory reasons.
- You're building something that needs to run air-gapped or on-premises.
- You want every load-bearing system to be open-source code you can read.

The reference [`@flametrench/server`](https://github.com/flametrench/node/tree/main/packages/server) wires all four core packages into a Fastify app for this case.

## Hybrid: external IdP for human users, Flametrench for service accounts

Some applications need machine-to-machine credentials (API keys, service tokens) that don't fit external IdPs cleanly. You can use Pattern A for human users while keeping `flametrench-identity` around for service accounts:

- Human users sign in through Auth0/Clerk/etc. → Pattern A bridge.
- Service accounts get a `flametrench-identity` user with a single `cred` of type `password` (or a future API-key credential type).
- Both flow through the same `usr_` → tenancy + authz pipeline.

The two paths converge at `usr_id` and never need to talk to each other again.

## Anti-patterns

### Don't sync your IdP's user data into Flametrench

Flametrench `usr_` is intentionally opaque. It has `id` and `status` and nothing else — no email, no display name, no profile photo. Your IdP already stores that. Don't replicate it.

If your application needs the user's display name, query your IdP (or your application's own user table that bridges to it). Flametrench's job is the org/membership/permission graph, not the user profile.

### Don't authorize with the IdP's roles

External IdPs sometimes offer role-based access control (Auth0 RBAC, Clerk roles, etc.). It's tempting to set up roles there and skip Flametrench's authz layer.

Don't. IdP roles are coarse, application-agnostic, and live in the wrong place. Authorization decisions need to consider the org context, the resource, and per-resource grants — none of which the IdP knows about. Flametrench's tuple model is exactly the granularity an application's authz needs.

A reasonable compromise: use the IdP's roles for the broadest cuts (e.g., `staff` vs `customer` for support-tooling access) and let Flametrench handle everything else.

### Don't confuse IdP organizations with Flametrench organizations

Some IdPs (Auth0, Clerk, WorkOS) offer "organizations" as a feature. These are typically thin: they group users for SSO routing or email-domain-based assignment.

Flametrench `org_` is a richer concept — it owns memberships with role lifecycles, invitations with atomic acceptance, and is the join target for authorization tuples. The two should be considered separate; if your application has both, treat the IdP's organization as a sign-in/SSO grouping and Flametrench's `org_` as the application-domain organization.

If a one-to-one mapping is enforced, store the IdP organization ID in your app's bridge table next to the Flametrench `org_id`, similar to the user mapping above.

## Migration: from "auth + permissions in IdP" to "auth in IdP, permissions in Flametrench"

If you're starting from a system where roles and permissions are stored in your IdP (Auth0 RBAC, Clerk roles, custom claims), the migration to Flametrench's authz layer is:

1. **Mint a `usr_` for every IdP user**, keyed on the IdP's `sub`. Backfill in a one-shot script.
2. **For each existing role**, decide: is this role *truly* application-agnostic (e.g., `staff` for support tooling) or is it scoped to a tenant (e.g., `org-admin` for org X)?
   - Application-agnostic: leave it in the IdP as a custom claim.
   - Tenant-scoped: every existing assignment becomes a Flametrench tuple. Write a migration that walks the IdP's role assignments and inserts the equivalent `tup_` rows.
3. **Switch your authorization checks** from "read role from token" to "call `check()` on the Flametrench tuple store." The change is local to your authz middleware.
4. **Once the dual-write phase passes verification**, stop writing role data into the IdP. Continue using the IdP for sign-in only.

This is an additive migration: at no point does your existing authorization stop working. The Flametrench tuples are the new source of truth; the IdP stays as the identity provider it always was.

## Where to look next

- [`docs/identity.md`](identity.md) — what `flametrench-identity` does (skip if you're going Pattern A).
- [`docs/tenancy.md`](tenancy.md) — the org/membership/invitation contract.
- [`docs/authorization.md`](authorization.md) — the tuple model and `check()` semantics.
- [`reference/postgres.sql`](../reference/postgres.sql) — the data model. The `usr` table is the only one Pattern A adopters touch.
- [`@flametrench/nextjs`](https://github.com/flametrench/node/tree/main/packages/nextjs) — App Router adapter that demonstrates Pattern A wiring with cookie-backed bridge sessions.
