-- ============================================================================
-- 013_alert_serving.sql — the read API over intervention effect
--
-- analytics.v_intervention_effect joins analytics.v_residual, which resolves
-- through mv_student_trend, mv_item_stats and mv_response_tag. Materialized
-- views cannot carry RLS, so 009 withheld them from app_rw entirely: a
-- security_invoker view over them is not a scope bypass, it is a permission
-- error. The API therefore cannot read that view directly at all.
--
-- Same deal as 011: this function is SECURITY DEFINER so it CAN read the
-- matview stack, and therefore re-applies scope BY HAND — tenant, plus
-- app.can_see_student() for a student-level intervention, plus class
-- attachment for a class-level one. Bypass the fence, rebuild the fence.
--
-- No new table: analytics.intervention and analytics.alert already exist
-- (008) and both carry ordinary RLS, so everything else in this slice is read
-- and written through the base tables in the normal way.
-- ============================================================================

CREATE OR REPLACE FUNCTION analytics.intervention_effects()
RETURNS TABLE (
  intervention_id uuid,
  student_id uuid, teaching_group_id uuid, tag_id uuid,
  kind text, started_on date,
  n_before bigint, n_after bigint,
  mean_residual_before numeric, mean_residual_after numeric, delta numeric,
  status text
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT
    e.intervention_id,
    e.student_id, e.teaching_group_id, e.tag_id,
    e.kind, e.started_on,
    e.n_before, e.n_after,
    round((e.mean_residual_before)::numeric, 4),
    round((e.mean_residual_after)::numeric, 4),
    -- Rounded, never re-derived: the view decides whether a delta exists at
    -- all, and its status column is what the UI must obey. A delta that comes
    -- back alongside 'too_early_to_tell' or 'no_baseline' is not a result.
    round((e.delta)::numeric, 4),
    e.status
  FROM analytics.v_intervention_effect e
  WHERE e.tenant_id = app.current_tenant()
    AND (
      -- A student-level intervention follows the student, not the class:
      -- a tutor who can see the child but does not teach that group is a
      -- legitimate reader, and an AND on class attachment would hide it.
      (e.student_id IS NOT NULL AND app.can_see_student(e.student_id))
      OR (e.student_id IS NULL AND (
            app.is_school_wide()
            OR e.teaching_group_id IS NULL
            OR EXISTS (
              SELECT 1 FROM org.teaching_assignment ta
              JOIN org.person staff ON staff.id = ta.staff_id
              WHERE ta.teaching_group_id = e.teaching_group_id
                AND ta.to_date IS NULL
                AND staff.user_id = app.current_user_id())))
    );
$$;

COMMENT ON FUNCTION analytics.intervention_effects() IS
  'Serving wrapper over analytics.v_intervention_effect. Re-applies tenant and '
  'per-student scope by hand because the view reaches matviews that cannot '
  'carry RLS. Returns no row at all for an intervention whose targeted student '
  'has no residual series — including every class-level intervention, which the '
  'view cannot score. Absence of a row means unmeasured, never zero effect.';

GRANT EXECUTE ON FUNCTION analytics.intervention_effects() TO app_rw, app_ro;

-- Re-secure in case this migration introduced or replaced a view.
SELECT app.secure_all_views();
