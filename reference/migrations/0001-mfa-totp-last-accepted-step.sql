-- Migration: add TOTP replay-protection state to `mfa` (ADR 0008 §verifyMfa).
--
-- Additive and backward-compatible: a nullable column plus two tightened
-- type-discriminator clauses that existing rows already satisfy (the new
-- column is NULL everywhere after ADD COLUMN). Not re-runnable (a second run fails
-- on "already exists" inside BEGIN/COMMIT, leaving nothing half-applied). No backfill is needed: a NULL
-- value means "no code accepted yet under replay tracking", so the first
-- post-upgrade verify of each factor records its step. Consequence adopters
-- must know: a code accepted by a PRE-upgrade SDK within its window cannot be
-- recognised as a replay by the upgraded SDK (at most one 30s step, ±1 drift).
--
-- Deploy order: run this migration BEFORE rolling out SDK versions that
-- read/write the column. Pre-upgrade SDKs ignore the column safely.

BEGIN;

ALTER TABLE mfa
    ADD COLUMN totp_last_accepted_step BIGINT
        CHECK (totp_last_accepted_step IS NULL OR totp_last_accepted_step >= 0);

-- Non-TOTP factors must never carry the column. Enforced as a separate named
-- constraint so the existing type-discriminator CHECK (unnamed in the
-- reference DDL) need not be dropped and recreated on live databases.
ALTER TABLE mfa
    ADD CONSTRAINT mfa_totp_last_accepted_step_totp_only
        CHECK (type = 'totp' OR totp_last_accepted_step IS NULL);

COMMIT;

-- Down (only if no SDK version relying on the column is deployed):
-- BEGIN;
-- ALTER TABLE mfa DROP CONSTRAINT mfa_totp_last_accepted_step_totp_only;
-- ALTER TABLE mfa DROP COLUMN totp_last_accepted_step;
-- COMMIT;
