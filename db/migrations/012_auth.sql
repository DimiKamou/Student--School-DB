-- ============================================================================
-- 012_auth.sql — real authentication
--
-- Replaces the development user-picker. Password credentials rather than magic
-- links, because a self-hosted school install cannot be made to depend on an
-- email provider existing before anyone can log in; invites use email when it
-- is configured and fall back to a copyable link when it is not.
--
-- Hashes are scrypt, computed in the application. The database never sees a
-- plaintext password and no column here can be reversed into one.
-- ============================================================================

-- Seeds ship a demo tenant (the UK seed needs one to own its Key Stage 3 scale
-- and prove school-authored frameworks work). Without a way to tell a demo
-- tenant from a real school, first-run setup sees a tenant already present and
-- refuses to run -- on every fresh install.
ALTER TABLE platform.tenant ADD COLUMN is_reference boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN platform.tenant.is_reference IS
  'Demo/reference tenant shipped by a seed. Never a real school; excluded from '
  'first-run setup checks, billing and any "schools using this" count.';

CREATE TABLE platform.credential (
  user_id         uuid PRIMARY KEY REFERENCES platform.app_user(id) ON DELETE CASCADE,
  password_hash   text NOT NULL,          -- scrypt$N$r$p$salt$hash, all base64url
  must_change     boolean NOT NULL DEFAULT false,
  failed_attempts smallint NOT NULL DEFAULT 0,
  locked_until    timestamptz,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Bumping this invalidates every existing session for that user: the signed
-- cookie carries the epoch it was issued under. That is how "sign out
-- everywhere" and "revoke a compromised account" work without server state.
ALTER TABLE platform.app_user ADD COLUMN session_epoch integer NOT NULL DEFAULT 1;

-- Invitations. A school admin invites staff; nobody self-registers into a
-- school, because self-registration into a database of children is a hole.
CREATE TABLE platform.invite (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  email        citext NOT NULL,
  display_name text,
  roles        text[] NOT NULL DEFAULT ARRAY['teacher'],
  -- Only the hash is stored: a leaked database does not yield usable invites.
  token_hash   text NOT NULL UNIQUE,
  invited_by   uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  person_id    uuid REFERENCES org.person(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL DEFAULT now() + interval '14 days',
  accepted_at  timestamptz,
  accepted_user_id uuid REFERENCES platform.app_user(id) ON DELETE SET NULL
);
CREATE INDEX invite_tenant_ix ON platform.invite (tenant_id, created_at DESC);
CREATE INDEX invite_open_ix ON platform.invite (tenant_id) WHERE accepted_at IS NULL;

-- Throttling, recorded per identifier rather than per account so that probing
-- for which addresses exist is as slow as guessing a password.
CREATE TABLE platform.login_attempt (
  id         bigserial PRIMARY KEY,
  identifier citext NOT NULL,
  succeeded  boolean NOT NULL,
  at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_attempt_ix ON platform.login_attempt (identifier, at DESC);

-- Recent failures for one identifier, for the lockout decision.
CREATE OR REPLACE FUNCTION platform.recent_failures(p_identifier text, p_minutes integer DEFAULT 15)
RETURNS integer LANGUAGE sql STABLE AS $$
  SELECT count(*)::integer FROM platform.login_attempt
  WHERE identifier = p_identifier
    AND NOT succeeded
    AND at > now() - make_interval(mins => p_minutes)
$$;

-- Password reset, same shape as an invite.
CREATE TABLE platform.password_reset (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES platform.app_user(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '2 hours',
  used_at    timestamptz
);
CREATE INDEX password_reset_user_ix ON platform.password_reset (user_id, created_at DESC);

SELECT app.secure_all_views();
