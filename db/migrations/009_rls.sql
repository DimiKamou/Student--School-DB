-- ============================================================================
-- 009_rls.sql — Row-Level Security
--
-- Two independent gates, both enforced in the database rather than in
-- application code, because an ORM bug must not become a cross-school breach:
--   1. TENANT   — you never see another school's rows. Non-negotiable.
--   2. SCOPE    — within your school, a teacher sees the students they teach,
--                 a tutor their tutees, a student themselves, a guardian their
--                 children. A maths teacher has no business reading a
--                 safeguarding-adjacent pattern in another department's cohort.
--
-- The app server must run every request as:
--   BEGIN;
--   SET LOCAL app.tenant_id = '...'; SET LOCAL app.user_id = '...';
--   ...
--   COMMIT;
-- SET LOCAL, never SET: it dies with the transaction and therefore cannot leak
-- across a pooled connection to the next request.
-- ============================================================================

-- Roles are CLUSTER-wide, not per-database, so creating them must be idempotent
-- or every rebuild against an existing cluster fails here.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro') THEN
    CREATE ROLE app_ro NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA app, platform, ref, org, curric, gradebook, analytics, teach TO app_rw, app_ro;

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

-- The scope predicate. Written once, applied everywhere student data lives.
CREATE OR REPLACE FUNCTION app.can_see_student(p_student uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT
    app.is_school_wide()
    -- teaches them, currently
    OR EXISTS (
      SELECT 1
      FROM org.enrolment e
      JOIN org.teaching_assignment ta ON ta.teaching_group_id = e.teaching_group_id
      JOIN org.person staff ON staff.id = ta.staff_id
      WHERE e.student_id = p_student
        AND e.tenant_id = app.current_tenant()
        AND e.to_date IS NULL
        AND ta.to_date IS NULL
        AND staff.user_id = app.current_user_id())
    -- is their tutor / homeroom
    OR EXISTS (
      SELECT 1 FROM org.tutor_assignment tu
      JOIN org.person staff ON staff.id = tu.staff_id
      WHERE tu.student_id = p_student
        AND tu.tenant_id = app.current_tenant()
        AND tu.to_date IS NULL
        AND staff.user_id = app.current_user_id())
    -- is the student
    OR EXISTS (
      SELECT 1 FROM org.person p
      WHERE p.id = p_student AND p.user_id = app.current_user_id())
    -- is their guardian
    OR EXISTS (
      SELECT 1 FROM org.guardian_link gl
      JOIN org.person g ON g.id = gl.guardian_id
      WHERE gl.student_id = p_student
        AND gl.tenant_id = app.current_tenant()
        AND g.user_id = app.current_user_id())
$$;

-- ---------------------------------------------------------------------------
-- Apply tenant isolation to every tenant-scoped table, generated rather than
-- hand-written so a new table cannot be forgotten.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname, n.nspname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND a.attnum > 0
    WHERE c.relkind = 'r'
      AND n.nspname IN ('org','curric','gradebook','analytics','teach','platform')
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.nspname, r.relname);
    EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', r.nspname, r.relname);
    EXECUTE format($f$
      CREATE POLICY tenant_isolation ON %I.%I
      USING (tenant_id = app.current_tenant())
      WITH CHECK (tenant_id = app.current_tenant())$f$, r.nspname, r.relname);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO app_rw', r.nspname, r.relname);
    EXECUTE format('GRANT SELECT ON %I.%I TO app_ro', r.nspname, r.relname);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Reference data: global rows are readable by everyone, school-authored rows
-- only by their author. This is what stops tenant B binding its classes to
-- tenant A's school-owned scale — FK validation bypasses RLS, so the check has
-- to exist on the read path too.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname, n.nspname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'owner_tenant_id' AND a.attnum > 0
    WHERE c.relkind = 'r' AND n.nspname IN ('ref','curric')
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.nspname, r.relname);
    EXECUTE format($f$
      CREATE POLICY ref_visibility ON %I.%I
      USING (owner_tenant_id = app.global_tenant() OR owner_tenant_id = app.current_tenant())
      WITH CHECK (owner_tenant_id = app.current_tenant())$f$, r.nspname, r.relname);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO app_rw', r.nspname, r.relname);
    EXECUTE format('GRANT SELECT ON %I.%I TO app_ro', r.nspname, r.relname);
  END LOOP;
END $$;

-- Framework config without an owner column (children of owned rows) is world-readable.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname, n.nspname FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r' AND n.nspname IN ('ref','curric')
      AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                      WHERE a.attrelid = c.oid AND a.attname IN ('owner_tenant_id','tenant_id')
                        AND a.attnum > 0)
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO app_rw', r.nspname, r.relname);
    EXECUTE format('GRANT SELECT ON %I.%I TO app_ro', r.nspname, r.relname);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Per-student scope, layered ON TOP of tenant isolation. Both must pass.
-- ---------------------------------------------------------------------------
ALTER TABLE org.person ENABLE ROW LEVEL SECURITY;
CREATE POLICY person_scope ON org.person
  AS RESTRICTIVE
  USING (NOT is_student OR app.can_see_student(id));

ALTER TABLE gradebook.result ENABLE ROW LEVEL SECURITY;
CREATE POLICY result_scope ON gradebook.result
  AS RESTRICTIVE
  USING (app.can_see_student(student_id))
  WITH CHECK (app.can_see_student(student_id));

ALTER TABLE gradebook.outcome ENABLE ROW LEVEL SECURITY;
CREATE POLICY outcome_scope ON gradebook.outcome
  AS RESTRICTIVE
  USING (app.can_see_student(student_id))
  WITH CHECK (app.can_see_student(student_id));

-- Students and guardians never see raw alerts; those are a professional
-- artefact, and an "at risk" label reflected back at a 14-year-old is a
-- self-fulfilling prophecy the product should not manufacture.
ALTER TABLE analytics.alert ENABLE ROW LEVEL SECURITY;
CREATE POLICY alert_scope ON analytics.alert
  AS RESTRICTIVE
  USING (
    NOT (app.has_role('student') OR app.has_role('guardian'))
    AND (student_id IS NULL OR app.can_see_student(student_id))
    AND (visibility_scope <> 'leadership'
         OR app.is_school_wide()
         OR visible_to_leadership_after IS NULL
         OR visible_to_leadership_after <= now()));

GRANT USAGE ON ALL SEQUENCES IN SCHEMA platform, gradebook, org TO app_rw;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app, gradebook, teach, analytics, ref, curric TO app_rw;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO app_ro;

-- Matviews cannot carry RLS. They hold aggregates over student data, so they
-- are NOT granted to app_ro/app_rw directly — the API reads them through
-- SECURITY DEFINER functions that re-apply app.can_see_student. Granting these
-- to the app role would be a scope bypass wearing a materialised view.
