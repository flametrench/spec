-- Flametrench v0.1 reference Postgres schema.
--
-- This file is a REFERENCE implementation of the Flametrench v0.1 data
-- model. The table shapes, column names, constraint semantics, and
-- lifecycle behaviors are normative per the specification; the exact
-- DDL (indexes, trigger implementations, storage parameters) is
-- reference material that implementations may adapt.
--
-- Copyright 2026 NDC Digital, LLC
-- SPDX-License-Identifier: Apache-2.0

-- ===========================================================================
-- Extensions
-- ===========================================================================

-- pgcrypto provides gen_random_uuid() for random UUIDs. UUIDv7 is preferred
-- for Flametrench IDs and is typically generated at the SDK layer; Postgres
-- 17+ ships uuidv7() natively, earlier versions need an extension or app-
-- side generation.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===========================================================================
-- Conventions used throughout
-- ===========================================================================
--
-- * All IDs are stored as native UUID. The Flametrench wire format
--   (e.g. "usr_0190f2a8...") is computed at the SDK layer from the
--   underlying UUID; it is never stored in the database.
--
-- * All timestamps are TIMESTAMPTZ. Naive timestamps are not allowed.
--
-- * Status columns use CHECK-constrained TEXT rather than Postgres enum
--   types. Enums are painful to evolve across migrations; CHECK text is
--   portable and self-documenting.
--
-- * Lifecycle entities (cred, mem) use a `replaces` self-referencing FK
--   to form an append-only chain. The chain root is the original record;
--   walking replaces backward gives full history. This encodes the
--   "revoke and re-add" pattern spec'd in the decisions doc.
--
-- * Partial unique indexes enforce "at most one active X" semantics
--   while allowing multiple historical (revoked) rows.

-- ===========================================================================
-- Users (usr_)
-- ===========================================================================
--
-- An opaque identity. No required identifiers live on this table;
-- identifiers (email, phone, passkey credential-id) live on cred rows.
-- This lets a usr exist without an email (service accounts, users who
-- only authenticate via SSO, migration scenarios).

CREATE TABLE usr (
    id          UUID PRIMARY KEY,
    status      TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'suspended', 'revoked')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===========================================================================
-- Credentials (cred_)
-- ===========================================================================
--
-- A way for a user to prove they are the user. One usr has N creds.
-- v0.1 types: password, passkey, oidc.
--
-- When a credential is rotated (password change, passkey rotation),
-- the old row goes to status='revoked' and a new row is created with
-- replaces=old.id. This gives uniform audit history and a clean
-- timeline of "what credentials has this user ever held."

CREATE TABLE cred (
    id                  UUID PRIMARY KEY,
    usr_id              UUID NOT NULL REFERENCES usr(id),
    type                TEXT NOT NULL
                          CHECK (type IN ('password', 'passkey', 'oidc')),

    -- Human-meaningful identifier, interpreted per type:
    --   password  -> email or handle
    --   oidc      -> email or subject alias (app choice)
    --   passkey   -> credential ID (base64url of the WebAuthn credentialId)
    identifier          TEXT NOT NULL,

    status              TEXT NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active', 'suspended', 'revoked')),
    replaces            UUID REFERENCES cred(id),

    -- password-specific. PHC-encoded so the algorithm and parameters
    -- travel with the hash. Spec pins Argon2id with minimum parameters:
    -- memory>=19 MiB, iterations>=2, parallelism>=1 (OWASP floor).
    password_hash       TEXT,

    -- passkey-specific (WebAuthn).
    passkey_public_key  BYTEA,
    passkey_sign_count  BIGINT,
    passkey_rp_id       TEXT,

    -- oidc-specific. The pair (issuer, subject) uniquely identifies the
    -- account at the identity provider.
    oidc_issuer         TEXT,
    oidc_subject        TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Type-discriminated required/forbidden columns.
    CHECK (
        (type = 'password'
            AND password_hash       IS NOT NULL
            AND passkey_public_key  IS NULL
            AND oidc_issuer         IS NULL)
     OR (type = 'passkey'
            AND passkey_public_key  IS NOT NULL
            AND passkey_sign_count  IS NOT NULL
            AND password_hash       IS NULL
            AND oidc_issuer         IS NULL)
     OR (type = 'oidc'
            AND oidc_issuer         IS NOT NULL
            AND oidc_subject        IS NOT NULL
            AND password_hash       IS NULL
            AND passkey_public_key  IS NULL)
    )
);

-- At most one active credential per (type, identifier). Historical
-- revoked rows may share identifiers (e.g. user re-registers same email).
CREATE UNIQUE INDEX cred_unique_active_identifier
    ON cred (type, identifier) WHERE status = 'active';

CREATE INDEX cred_usr_idx      ON cred (usr_id);
CREATE INDEX cred_replaces_idx ON cred (replaces) WHERE replaces IS NOT NULL;

-- ===========================================================================
-- Sessions (ses_)
-- ===========================================================================
--
-- A live authentication. User-bound (not org-bound): switching active
-- org is a context change, not a session change. The cred_id field
-- records which credential established this session, giving forensic
-- traceability when a credential is later found to be compromised.
--
-- Sessions are rotated on refresh (new ses_ id, old marked with
-- revoked_at), matching the lifecycle pattern used for creds and mems.

CREATE TABLE ses (
    id          UUID PRIMARY KEY,
    usr_id      UUID NOT NULL REFERENCES usr(id),
    cred_id     UUID NOT NULL REFERENCES cred(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ NOT NULL,
    revoked_at  TIMESTAMPTZ,
    -- For opaque-token implementations: SHA-256 of the bearer token,
    -- stored as 32 raw bytes. NULL for JWT-style implementations where
    -- the token self-verifies. See the comment block below for the
    -- conformant patterns.
    token_hash  BYTEA,

    CHECK (expires_at > created_at),
    CHECK (revoked_at IS NULL OR revoked_at >= created_at),
    CHECK (token_hash IS NULL OR octet_length(token_hash) = 32)
);

CREATE INDEX ses_usr_idx    ON ses (usr_id);
CREATE INDEX ses_active_idx ON ses (usr_id, expires_at)
    WHERE revoked_at IS NULL;
-- Unique partial index: enforces that no two ACTIVE sessions share a
-- token hash. Revoked sessions are excluded so the same column may
-- legitimately hold the historical hash of a rotated token (or NULL,
-- if the implementation prefers to clear it on revoke).
CREATE UNIQUE INDEX ses_token_hash_idx ON ses (token_hash)
    WHERE token_hash IS NOT NULL AND revoked_at IS NULL;

-- NOTE on session tokens: ses.id is the session identifier, not the
-- bearer token. The token carried by the client is opaque to the spec.
-- v0.1 sanctions two implementation patterns:
--
--   1. Opaque tokens. The server generates random_bytes(32),
--      base64url-encodes them, returns to the client, and persists
--      SHA-256(token) in `ses.token_hash`. On each request the server
--      computes SHA-256 of the presented token, looks up the row by
--      token_hash, and constant-time-compares the stored hash. The
--      reference InMemoryIdentityStore in every SDK uses this pattern.
--
--   2. Signed tokens (typically JWT). The token carries ses.id as a
--      claim and is verified by signature. No server-side lookup of
--      the token itself is required; revocation works by checking
--      revoked_at on the session row. `ses.token_hash` stays NULL.
--
-- Implementations MUST verify token authenticity on each check.
-- Implementations using opaque tokens MUST populate ses.token_hash on
-- session creation. The spec does not mandate either pattern; choose
-- per the deployment's needs (opaque tokens trade a DB lookup for
-- simpler revocation semantics; JWT trades signature-verify CPU for
-- statelessness).
--
-- On rotation/revocation: implementations MAY set ses.token_hash to
-- NULL when revoked_at is set, OR keep the stored hash for forensic
-- purposes. The unique partial index above accommodates both choices.

-- ===========================================================================
-- Organizations (org_)
-- ===========================================================================
--
-- Flat in v0.1: org has no parent_org_id. Nested orgs are deferred to
-- v0.2+ and will require the rewrite-rules authz extension.

CREATE TABLE org (
    id          UUID PRIMARY KEY,
    status      TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'suspended', 'revoked')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===========================================================================
-- Memberships (mem_)
-- ===========================================================================
--
-- A user's membership in an org. Dual-represented: this row carries
-- tenancy metadata (joined-at, who invited, status), and a parallel
-- tup row (subject=usr, relation=role, object=org) carries the
-- authorization fact. The tup row exists iff mem.status='active'.
--
-- Role changes are modeled as revoke+re-add: the old mem goes to
-- status='revoked' and a new mem is inserted with replaces=old.id.
-- Walking `replaces` backward yields the full role history, with
-- monotonic timestamps providing tamper-evidence.

CREATE TABLE mem (
    id          UUID PRIMARY KEY,
    usr_id      UUID NOT NULL REFERENCES usr(id),
    org_id      UUID NOT NULL REFERENCES org(id),
    role        TEXT NOT NULL
                  CHECK (role IN ('owner', 'admin', 'member', 'guest',
                                  'viewer', 'editor')),
    status      TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'suspended', 'revoked')),
    replaces    UUID REFERENCES mem(id),

    -- Forensic fields. invited_by is never null for accepted invites;
    -- it is null for org-creator memberships (the bootstrap case).
    -- removed_by is null for self-leave, non-null for admin-remove.
    invited_by  UUID REFERENCES usr(id),
    removed_by  UUID REFERENCES usr(id),

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- At most one active membership per (usr, org). Historical revoked
-- memberships accumulate; the replaces chain provides the history walk.
CREATE UNIQUE INDEX mem_unique_active
    ON mem (usr_id, org_id) WHERE status = 'active';

CREATE INDEX mem_org_idx      ON mem (org_id);
CREATE INDEX mem_usr_idx      ON mem (usr_id);
CREATE INDEX mem_replaces_idx ON mem (replaces) WHERE replaces IS NOT NULL;

-- INVARIANT (enforced at the SDK/application layer, not in SQL):
-- Every org with any active mem row must have at least one active mem
-- with role='owner'. The sole-owner protection in self-leave and
-- admin-remove flows guarantees this; expressing it purely as a CHECK
-- constraint would require a deferred trigger that complicates bulk
-- operations.

-- ===========================================================================
-- Invitations (inv_)
-- ===========================================================================
--
-- State machine: pending -> one of {accepted, declined, revoked, expired}.
-- Non-pending states are terminal and immutable.
--
-- An invitation may carry pre-declared tuples to materialize at
-- acceptance time, enabling resource-scoped invites (e.g. "invite
-- Carol as guest of Acme AND make her a viewer of project_42").
-- The subject of those tuples is the usr created/resolved at accept.

CREATE TABLE inv (
    id               UUID PRIMARY KEY,
    org_id           UUID NOT NULL REFERENCES org(id),

    -- Invitee identifier (email is typical). Resolved to invited_user_id
    -- if the identifier matches an existing cred at accept time.
    identifier       TEXT NOT NULL,

    role             TEXT NOT NULL
                       CHECK (role IN ('owner', 'admin', 'member', 'guest',
                                       'viewer', 'editor')),
    status           TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'accepted', 'declined',
                                         'revoked', 'expired')),

    -- Pre-declared tuples to materialize on accept. Array of objects
    -- shaped as { "relation": <string>, "object_type": <string>,
    -- "object_id": <uuid-string> }. Subject is implicit (the accepting
    -- usr). Materialization is atomic with the accept transition.
    pre_tuples       JSONB NOT NULL DEFAULT '[]',

    invited_by       UUID NOT NULL REFERENCES usr(id),
    invited_user_id  UUID REFERENCES usr(id),

    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at       TIMESTAMPTZ NOT NULL,

    -- Set when the invitation leaves 'pending'. terminal_by records
    -- the actor: self for accept/decline; admin for revoke; null for
    -- expire (there is no human actor).
    terminal_at      TIMESTAMPTZ,
    terminal_by      UUID REFERENCES usr(id),

    -- pending iff terminal_at is null.
    CHECK ((status = 'pending') = (terminal_at IS NULL)),
    CHECK (expires_at > created_at)
);

CREATE INDEX inv_org_idx      ON inv (org_id);
CREATE INDEX inv_pending_idx  ON inv (identifier) WHERE status = 'pending';

-- ===========================================================================
-- Authorization tuples (tup_)
-- ===========================================================================
--
-- The unified authz primitive. (subject, relation, object) rows are the
-- only source of permission. v0.1 checks are exact-match only: no
-- implication, no inheritance, no rewrite rules. Those are deferred to
-- v0.2+ once real usage tells us which derivations matter.
--
-- subject_type is constrained to 'usr' in v0.1. 'grp' (groups) is a
-- v0.2+ subject type and will allow group-subject tuples to expand to
-- individual members at check time.
--
-- object_type is unconstrained at the type level: applications freely
-- tup custom object types (e.g. 'project', 'doc'). The format pattern
-- enforces the spec's prefix rules.

CREATE TABLE tup (
    id            UUID PRIMARY KEY,
    subject_type  TEXT NOT NULL
                    CHECK (subject_type IN ('usr')),
    subject_id    UUID NOT NULL,
    relation      TEXT NOT NULL
                    CHECK (relation ~ '^[a-z_]{2,32}$'),
    object_type   TEXT NOT NULL
                    CHECK (object_type ~ '^[a-z]{2,6}$'),
    object_id     UUID NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID REFERENCES usr(id),

    UNIQUE (subject_type, subject_id, relation, object_type, object_id)
);

-- Covering indexes for the three hot paths:
--
-- 1. Exact-match check: served by the implicit index behind UNIQUE.
-- 2. Enumeration ("who holds relation R on object O?"):
CREATE INDEX tup_object_relation_idx
    ON tup (object_type, object_id, relation);
-- 3. Cascade on subject revocation ("delete everything subject holds"):
CREATE INDEX tup_subject_idx
    ON tup (subject_type, subject_id);

-- ---------------------------------------------------------------------------
-- Reference implementation of the check() primitive.
--
-- Accepts a non-empty array of relations and returns true if any
-- matching tuple exists. An SDK may reproduce this logic natively in
-- its host language; this function is the canonical semantics.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION tup_check(
    p_subject_type TEXT,
    p_subject_id   UUID,
    p_relations    TEXT[],
    p_object_type  TEXT,
    p_object_id    UUID
) RETURNS BOOLEAN
LANGUAGE SQL STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM tup
         WHERE subject_type = p_subject_type
           AND subject_id   = p_subject_id
           AND relation     = ANY (p_relations)
           AND object_type  = p_object_type
           AND object_id    = p_object_id
    );
$$;

-- ===========================================================================
-- updated_at triggers
-- ===========================================================================

CREATE OR REPLACE FUNCTION flametrench_touch_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER usr_touch  BEFORE UPDATE ON usr
    FOR EACH ROW EXECUTE FUNCTION flametrench_touch_updated_at();
CREATE TRIGGER cred_touch BEFORE UPDATE ON cred
    FOR EACH ROW EXECUTE FUNCTION flametrench_touch_updated_at();
CREATE TRIGGER org_touch  BEFORE UPDATE ON org
    FOR EACH ROW EXECUTE FUNCTION flametrench_touch_updated_at();
CREATE TRIGGER mem_touch  BEFORE UPDATE ON mem
    FOR EACH ROW EXECUTE FUNCTION flametrench_touch_updated_at();

-- ses, inv, and tup are append-only / lifecycle-terminal; no updated_at.
-- Changes to these entities happen via inserts (rotation) or via
-- specific terminal-state updates (inv accept/decline/revoke), not
-- via general-purpose updates.
