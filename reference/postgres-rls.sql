-- Flametrench reference Postgres Row-Level Security companion.
--
-- Apply AFTER postgres.sql. This file enables RLS on every entity
-- where row-level isolation is meaningful and installs policies that
-- read from per-request session GUCs ("session settings") to scope
-- visibility and writes by usr_id and/or org_id.
--
-- This file is REFERENCE material, not normative. The spec does not
-- mandate RLS — implementations MAY enforce isolation at the
-- application layer instead. RLS is the cheapest defense-in-depth for
-- multi-tenant deployments where a single Postgres role is shared
-- across requests.
--
-- Copyright 2026 NDC Digital, LLC
-- SPDX-License-Identifier: Apache-2.0

-- ===========================================================================
-- Session-context model
-- ===========================================================================
--
-- Flametrench's RLS model assumes the application sets two session
-- GUCs at the start of each request, BEFORE any query runs:
--
--   SET LOCAL flametrench.current_usr_id = '<usr_uuid>';
--   SET LOCAL flametrench.actor_role   = 'tenant';   -- or 'admin'
--
-- `flametrench.current_usr_id` is the authenticated user's UUID
-- (NOT the wire-format prefixed ID — RLS policies compare against
-- usr.id directly). It is read by every policy.
--
-- `flametrench.actor_role` is one of:
--   - 'tenant' — the default. Subject to all policies.
--   - 'admin'  — bypass policies. Reserved for first-party operations
--                (background jobs, migrations, the implementation's
--                own admin tools).
--
-- The application is responsible for setting these GUCs from the
-- request's authentication context. SET LOCAL scopes them to the
-- transaction; if your driver pools connections without per-request
-- transactions, use SET (without LOCAL) and reset at request end —
-- but be defensive against bleed-through. Connection-pooled drivers
-- without proper context isolation are the most common source of
-- RLS bypass bugs.
--
-- A NULL or unset GUC reads as the empty string; policies treat that
-- as "no user authenticated" and deny by default.

-- ===========================================================================
-- Helper functions
-- ===========================================================================
--
-- Centralize the GUC reads so policies stay readable. Marked STABLE
-- because they consult session state but produce identical results
-- within a transaction.

CREATE OR REPLACE FUNCTION flametrench_current_usr_id() RETURNS UUID
LANGUAGE SQL STABLE AS $$
    SELECT NULLIF(current_setting('flametrench.current_usr_id', true), '')::UUID;
$$;

CREATE OR REPLACE FUNCTION flametrench_is_admin() RETURNS BOOLEAN
LANGUAGE SQL STABLE AS $$
    SELECT current_setting('flametrench.actor_role', true) = 'admin';
$$;

-- Membership check: does the current user hold ANY active membership
-- in the given org? Used by org-scoped policies (mem, inv, tup-on-org).
-- Recurses into the existing tup table so mem-as-tuple stays the
-- single source of truth.

CREATE OR REPLACE FUNCTION flametrench_has_org_membership(p_org_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM mem
         WHERE mem.org_id = p_org_id
           AND mem.usr_id = flametrench_current_usr_id()
           AND mem.status = 'active'
    );
$$;

-- ===========================================================================
-- usr — opaque user identity
-- ===========================================================================
--
-- Visible only to:
--   - oneself (a user can read their own usr row)
--   - admins
--
-- Inserts/updates/deletes restricted to admin (user creation goes
-- through the application's identity flow which runs as admin during
-- the createUser transaction).

ALTER TABLE usr ENABLE ROW LEVEL SECURITY;

CREATE POLICY usr_admin_all ON usr FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY usr_self_read ON usr FOR SELECT
    USING (id = flametrench_current_usr_id());

-- ===========================================================================
-- cred — credentials
-- ===========================================================================
--
-- Sensitive: password hashes, passkey public keys, OIDC subjects. A
-- user sees only their own cred rows. Admins see all (rotation,
-- revocation, support flows).
--
-- Note: verifyPassword runs as admin to look up creds by identifier
-- before the user is authenticated. Use a separate connection or a
-- per-step admin escalation for that flow.

ALTER TABLE cred ENABLE ROW LEVEL SECURITY;

CREATE POLICY cred_admin_all ON cred FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY cred_self_read ON cred FOR SELECT
    USING (usr_id = flametrench_current_usr_id());

-- ===========================================================================
-- ses — sessions
-- ===========================================================================
--
-- A user sees their own sessions (the "active devices" UX). Admins
-- see all.
--
-- token_hash is sensitive; consider whether to expose it via a view
-- with the column nulled out. The spec assumes the server only ever
-- returns ses.id + metadata to clients, never token_hash.

ALTER TABLE ses ENABLE ROW LEVEL SECURITY;

CREATE POLICY ses_admin_all ON ses FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY ses_self_read ON ses FOR SELECT
    USING (usr_id = flametrench_current_usr_id());

CREATE POLICY ses_self_revoke ON ses FOR UPDATE
    USING (usr_id = flametrench_current_usr_id())
    WITH CHECK (usr_id = flametrench_current_usr_id());

-- ===========================================================================
-- org — organizations
-- ===========================================================================
--
-- A user sees only orgs they have an active membership in. Admins see
-- all. Org creation goes through the application's createOrg path
-- which runs as admin (or escalates briefly).

ALTER TABLE org ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_admin_all ON org FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY org_member_read ON org FOR SELECT
    USING (flametrench_has_org_membership(id));

-- ===========================================================================
-- mem — memberships
-- ===========================================================================
--
-- A user sees:
--   - their own memberships (any org), and
--   - memberships of orgs they belong to (the "see your teammates" UX).
--
-- Admins see all. Inserts/updates/deletes go through the application
-- (addMember, changeRole, selfLeave, adminRemove); RLS additionally
-- gates writes to admins to prevent bypass via raw SQL.

ALTER TABLE mem ENABLE ROW LEVEL SECURITY;

CREATE POLICY mem_admin_all ON mem FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY mem_visibility_read ON mem FOR SELECT
    USING (
           usr_id = flametrench_current_usr_id()
        OR flametrench_has_org_membership(org_id)
    );

-- ===========================================================================
-- inv — invitations
-- ===========================================================================
--
-- A user sees:
--   - invitations targeted at their identifier (so accept/decline UX works)
--   - invitations to orgs they belong to (admin views)
--
-- Note: the identifier-based read path requires the application to
-- pass the current user's canonical identifier in a third GUC, which
-- this reference deliberately does NOT define. Most deployments either
-- (a) accept the modest leak that org members can see all org-scoped
-- invitations, or (b) layer a view over inv that filters by an
-- application-managed identifier match.
--
-- The default policy here exposes invitations to org members. Tighten
-- as needed.

ALTER TABLE inv ENABLE ROW LEVEL SECURITY;

CREATE POLICY inv_admin_all ON inv FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY inv_org_member_read ON inv FOR SELECT
    USING (flametrench_has_org_membership(org_id));

-- ===========================================================================
-- tup — authorization tuples
-- ===========================================================================
--
-- The most sensitive table. A user sees:
--   - tuples where they are the subject (their own permissions)
--   - tuples scoped to objects in orgs they belong to (e.g. a project
--     tuple for an org they're a member of)
--
-- The "object in their org" check is per-deployment because tup's
-- object_type is unconstrained — the app knows that 'project' rows
-- live under an org_id but Postgres doesn't. The default policy here
-- exposes only the subject-scoped path; deployments with custom
-- object types should add per-object-type policies.

ALTER TABLE tup ENABLE ROW LEVEL SECURITY;

CREATE POLICY tup_admin_all ON tup FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY tup_self_read ON tup FOR SELECT
    USING (
           subject_type = 'usr'
        AND subject_id = flametrench_current_usr_id()
    );

-- Org-scoped object rows: a user sees tup rows whose object is an org
-- they belong to. This covers the membership tuple and any
-- relation-on-org grants.
CREATE POLICY tup_org_object_read ON tup FOR SELECT
    USING (
           object_type = 'org'
        AND flametrench_has_org_membership(object_id)
    );

-- ===========================================================================
-- v0.2: mfa
-- ===========================================================================
--
-- Highly sensitive — TOTP secrets, WebAuthn public keys + counters,
-- recovery hashes. Strict per-user isolation.
--
-- The verifyMfa flow runs as admin (or the user's session token must
-- already be authenticated to scope to their usr_id) — the user
-- viewing/verifying their own factor must produce a usr_id GUC.

ALTER TABLE mfa ENABLE ROW LEVEL SECURITY;

CREATE POLICY mfa_admin_all ON mfa FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY mfa_self_read ON mfa FOR SELECT
    USING (usr_id = flametrench_current_usr_id());

-- ===========================================================================
-- v0.2: usr_mfa_policy
-- ===========================================================================

ALTER TABLE usr_mfa_policy ENABLE ROW LEVEL SECURITY;

CREATE POLICY usr_mfa_policy_admin_all ON usr_mfa_policy FOR ALL
    USING (flametrench_is_admin())
    WITH CHECK (flametrench_is_admin());

CREATE POLICY usr_mfa_policy_self_read ON usr_mfa_policy FOR SELECT
    USING (usr_id = flametrench_current_usr_id());

-- ===========================================================================
-- Operational notes
-- ===========================================================================
--
-- 1. The 'admin' role is a footgun. Reserve it for:
--      - migrations
--      - the verifyPassword pre-auth lookup
--      - background jobs that genuinely need cross-tenant access
--    NEVER set flametrench.actor_role = 'admin' on a user-bound
--    request. Audit every callsite that escalates.
--
-- 2. Functions called from policies (flametrench_*) are NOT subject to
--    RLS themselves — they execute with the table owner's privileges.
--    This is what makes flametrench_has_org_membership() able to read
--    `mem` even when the calling session would be filtered.
--
-- 3. RLS is enforced for every role except superusers (and table
--    owners with BYPASSRLS). Connection roles in production should
--    NEVER be superuser; create a dedicated role:
--
--      CREATE ROLE flametrench_app NOINHERIT NOSUPERUSER;
--      GRANT USAGE ON SCHEMA public TO flametrench_app;
--      GRANT SELECT, INSERT, UPDATE, DELETE
--          ON ALL TABLES IN SCHEMA public TO flametrench_app;
--
--    The application connects as flametrench_app. RLS then applies on
--    every query, regardless of which GUC the application sets.
--
-- 4. Tests that need to bypass RLS (table truncations, bulk seeding)
--    SHOULD set flametrench.actor_role = 'admin' rather than
--    connecting as a superuser. This keeps the bypass auditable.
--
-- 5. Performance: RLS adds a function call per row scanned. The hot
--    paths in Flametrench (verifyMfa, check) hit primary keys or
--    covered indexes, so the overhead is negligible. List endpoints
--    over `mem`, `inv`, or `tup` benefit from indexes that include
--    usr_id / org_id (already present in postgres.sql) so RLS
--    predicates can short-circuit before touching the row data.
