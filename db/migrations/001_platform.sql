-- ============================================================================
-- 001_platform.sql — tenancy, identity, RLS plumbing
--
-- Tenant == school. A school group buying three schools gets three tenants.
-- Isolation: shared schema + tenant_id + Row-Level Security. Schema-per-tenant
-- was rejected: migrating 300 schemas on every release is the ops failure that
-- kills small SaaS teams.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE SCHEMA IF NOT EXISTS app;       -- session helpers
CREATE SCHEMA IF NOT EXISTS platform;  -- cross-tenant control plane
CREATE SCHEMA IF NOT EXISTS ref;       -- grading framework configuration
CREATE SCHEMA IF NOT EXISTS org;       -- school structure, people, lessons
CREATE SCHEMA IF NOT EXISTS curric;    -- curriculum taxonomy + tagging
CREATE SCHEMA IF NOT EXISTS gradebook; -- assessments, items, the results fact
CREATE SCHEMA IF NOT EXISTS analytics; -- derived signals
CREATE SCHEMA IF NOT EXISTS teach;     -- teacher affordances (comments, workload)

-- The sentinel tenant that owns platform-published reference data (IB, AQA,
-- ΙΕΠ ...). Framework config rows are either GLOBAL (this id) or school-owned.
CREATE OR REPLACE FUNCTION app.global_tenant() RETURNS uuid
  LANGUAGE sql IMMUTABLE PARALLEL SAFE
  AS $$ SELECT '00000000-0000-0000-0000-000000000000'::uuid $$;

-- ---------------------------------------------------------------------------
-- Session context. The app server runs every request inside a transaction that
-- issues:  SET LOCAL app.tenant_id = '...'; SET LOCAL app.user_id = '...';
-- SET LOCAL (not SET) is mandatory: it dies with the transaction and therefore
-- cannot leak across a pooled connection.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.current_tenant() RETURNS uuid
  LANGUAGE sql STABLE PARALLEL SAFE
  AS $$ SELECT nullif(current_setting('app.tenant_id', true), '')::uuid $$;

CREATE OR REPLACE FUNCTION app.current_user_id() RETURNS uuid
  LANGUAGE sql STABLE PARALLEL SAFE
  AS $$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$;

CREATE OR REPLACE FUNCTION app.require_tenant() RETURNS uuid
  LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE t uuid;
BEGIN
  t := app.current_tenant();
  IF t IS NULL THEN
    RAISE EXCEPTION 'no tenant in session context'
      USING HINT = 'issue SET LOCAL app.tenant_id before touching tenant data',
            ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN t;
END $$;

-- Current role of the acting user, used by RLS policies.
CREATE OR REPLACE FUNCTION app.current_role_name() RETURNS text
  LANGUAGE sql STABLE PARALLEL SAFE
  AS $$ SELECT coalesce(nullif(current_setting('app.role', true), ''), 'none') $$;

-- ---------------------------------------------------------------------------
-- Control plane
-- ---------------------------------------------------------------------------
CREATE TABLE platform.tenant (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  name                text NOT NULL,
  country_code        char(2) NOT NULL,
  timezone            text NOT NULL DEFAULT 'Europe/Athens',
  default_locale      text NOT NULL DEFAULT 'en',
  -- Subscription
  plan                text NOT NULL DEFAULT 'trial'
                        CHECK (plan IN ('trial','standard','institutional','disabled')),
  subscription_ends_on date,
  -- Alert governance. Teachers ignore noisy systems; these are hard caps.
  alert_budget_weekly  smallint NOT NULL DEFAULT 5 CHECK (alert_budget_weekly BETWEEN 0 AND 50),
  leadership_delay_days smallint NOT NULL DEFAULT 7 CHECK (leadership_delay_days >= 0),
  -- GDPR
  data_retention_years smallint NOT NULL DEFAULT 7 CHECK (data_retention_years BETWEEN 1 AND 30),
  created_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz
);
COMMENT ON COLUMN platform.tenant.leadership_delay_days IS
  'Right of first sight: a systemic flag about a class is visible to its teacher '
  'this many days before leadership sees it. Without this, the product reads as '
  'surveillance and teachers stop entering data.';

INSERT INTO platform.tenant (id, slug, name, country_code)
VALUES (app.global_tenant(), 'global', 'Platform reference data', 'ZZ');

CREATE TABLE platform.app_user (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  email         citext,
  display_name  text NOT NULL,
  locale        text,
  is_active     boolean NOT NULL DEFAULT true,
  last_seen_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX app_user_email_uq ON platform.app_user (tenant_id, lower(email::text))
  WHERE email IS NOT NULL;
CREATE INDEX app_user_tenant_ix ON platform.app_user (tenant_id);

-- Roles are per-tenant and additive. A head of department is also a teacher.
CREATE TABLE platform.user_role (
  tenant_id  uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES platform.app_user(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN
               ('school_admin','head_of_dept','teacher','tutor','student','guardian','dpo')),
  scope_id   uuid   -- e.g. department/subject for head_of_dept; NULL = tenant-wide
);
CREATE UNIQUE INDEX user_role_uq ON platform.user_role
  (tenant_id, user_id, role, coalesce(scope_id, app.global_tenant()));
CREATE INDEX user_role_lookup_ix ON platform.user_role (tenant_id, user_id);

-- ---------------------------------------------------------------------------
-- Role helpers. Defined here, immediately after platform.user_role, because
-- views in later migrations reference them. app.can_see_student() lives in
-- 009 instead: it needs the org tables, which do not exist yet.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.has_role(p_role text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM platform.user_role ur
    WHERE ur.tenant_id = app.current_tenant()
      AND ur.user_id = app.current_user_id()
      AND ur.role = p_role)
$$;

-- Whole-school readers. DPO is included for subject-access requests and is
-- itself audited via platform.access_log.
CREATE OR REPLACE FUNCTION app.is_school_wide() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT app.has_role('school_admin') OR app.has_role('dpo')
$$;

-- ---------------------------------------------------------------------------
-- Access audit. Schools WILL be asked "who looked at my child's record".
-- ---------------------------------------------------------------------------
CREATE TABLE platform.access_log (
  id          bigserial PRIMARY KEY,
  tenant_id   uuid NOT NULL,
  user_id     uuid,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  action      text NOT NULL,
  subject_kind text,
  subject_id  uuid,
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX access_log_tenant_time_ix ON platform.access_log (tenant_id, occurred_at DESC);
CREATE INDEX access_log_subject_ix ON platform.access_log (tenant_id, subject_kind, subject_id, occurred_at DESC);

-- ---------------------------------------------------------------------------
-- GDPR erasure behaviour, declared per column so it is testable rather than
-- living in a runbook nobody reads.
-- ---------------------------------------------------------------------------
CREATE TABLE platform.data_map (
  schema_name    text NOT NULL,
  table_name     text NOT NULL,
  column_name    text NOT NULL,
  category       text NOT NULL CHECK (category IN
                    ('identifier','contact','academic','sensitive','behavioural','derived','operational')),
  erasure_action text NOT NULL CHECK (erasure_action IN
                    ('delete','anonymise','crypto_shred','redact','retain')),
  portable       boolean NOT NULL DEFAULT false,   -- Art. 20 export
  lawful_basis   text,
  PRIMARY KEY (schema_name, table_name, column_name)
);
