-- ============================================================================
-- 011_serving_api.sql — the read API over the analytics matviews
--
-- Materialized views cannot carry RLS. 009 therefore withheld them from app_rw
-- entirely, because granting them would be a scope bypass wearing a
-- materialized view: any teacher could read any student's gap profile.
--
-- Every function here is SECURITY DEFINER (so it CAN read the matviews) and
-- therefore MUST re-apply scope by hand. That is the deal: bypass the fence,
-- rebuild the fence. Each one filters on app.current_tenant() and, where a
-- student is involved, app.can_see_student().
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Class topic heatmap. The teacher-facing give-back: which topics is this class
-- strong and weak on, and is the weakness mine to fix or the curriculum's.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.class_heatmap(p_group_id uuid, p_axis text DEFAULT 'topic')
RETURNS TABLE (
  tag_id uuid, tag_code text, tag_label text,
  n_responses bigint, n_students bigint,
  cohort_mean_pct numeric, cohort_verdict text,
  external_facility numeric,
  lessons_delivered bigint, delivery_ratio numeric,
  n_students_below bigint
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT
    c.tag_id, t.code, t.label,
    c.n_responses, c.n_students,
    round((c.cohort_mean_pct)::numeric, 4), c.cohort_verdict,
    round((c.external_facility)::numeric, 4),
    tt.lessons_delivered, tt.delivery_ratio,
    (SELECT count(*) FROM analytics.mv_gap_signal g
      WHERE g.tenant_id = c.tenant_id AND g.teaching_group_id = c.teaching_group_id
        AND g.tag_id = c.tag_id
        AND g.verdict IN ('individual','systemic_and_individual'))
  FROM analytics.mv_cohort_tag c
  JOIN curric.tag t ON t.id = c.tag_id
  LEFT JOIN analytics.v_teaching_time tt
    ON tt.tenant_id = c.tenant_id AND tt.teaching_group_id = c.teaching_group_id
   AND tt.tag_id = c.tag_id
  WHERE c.tenant_id = app.current_tenant()
    AND c.teaching_group_id = p_group_id
    AND c.axis = p_axis
    -- Scope: you may only see a class you are attached to.
    AND (app.is_school_wide() OR EXISTS (
      SELECT 1 FROM org.teaching_assignment ta
      JOIN org.person staff ON staff.id = ta.staff_id
      WHERE ta.teaching_group_id = p_group_id AND ta.to_date IS NULL
        AND staff.user_id = app.current_user_id()))
  ORDER BY c.cohort_mean_pct NULLS LAST;
$$;

-- ---------------------------------------------------------------------------
-- One student's profile: where they stand per topic, and why.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.student_gaps(p_student_id uuid, p_axis text DEFAULT 'topic')
RETURNS TABLE (
  teaching_group_id uuid, group_label text, subject_name text,
  tag_id uuid, tag_label text,
  n_responses bigint, n_assessments bigint,
  mean_pct numeric, mean_pct_recent numeric,
  mean_residual numeric, residual_ci_upper numeric,
  cohort_mean_pct numeric, verdict text, time_context text,
  missed_ratio numeric
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT
    g.teaching_group_id, tg.label, sub.name,
    g.tag_id, t.label,
    g.n_responses, g.n_assessments,
    round((g.mean_pct)::numeric, 4), round((g.mean_pct_recent)::numeric, 4),
    round((g.mean_residual)::numeric, 4), round((g.residual_ci_upper)::numeric, 4),
    round((g.cohort_mean_pct)::numeric, 4), g.verdict, g.time_context,
    g.missed_ratio
  FROM analytics.mv_gap_signal g
  JOIN curric.tag t ON t.id = g.tag_id
  JOIN org.teaching_group tg ON tg.id = g.teaching_group_id
  JOIN org.subject sub ON sub.id = tg.subject_id
  WHERE g.tenant_id = app.current_tenant()
    AND g.student_id = p_student_id
    AND g.axis = p_axis
    AND app.can_see_student(p_student_id)
  ORDER BY
    CASE g.verdict
      WHEN 'systemic_and_individual' THEN 1 WHEN 'individual' THEN 2
      WHEN 'systemic' THEN 3 WHEN 'explained_by_absence' THEN 4 ELSE 5 END,
    g.mean_residual;
$$;

-- Trajectory over time, for the student chart. Returns raw normalised score and
-- the cohort-relative adjusted score side by side: the first is what a parent
-- understands, the second is what actually means something.
CREATE OR REPLACE FUNCTION analytics.student_timeline(p_student_id uuid)
RETURNS TABLE (
  observed_on date, teaching_group_id uuid, group_label text, subject_name text,
  assessment_id uuid, assessment_title text,
  mean_pct numeric, mean_adj numeric, n_responses bigint
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT
    r.observed_on, r.teaching_group_id, tg.label, sub.name,
    r.assessment_id, a.title,
    round((avg(r.pct))::numeric, 4), round((avg(r.d_adj))::numeric, 4), count(*)
  FROM analytics.v_response_adj r
  JOIN org.teaching_group tg ON tg.id = r.teaching_group_id
  JOIN org.subject sub ON sub.id = tg.subject_id
  JOIN gradebook.assessment a ON a.id = r.assessment_id
  WHERE r.tenant_id = app.current_tenant()
    AND r.student_id = p_student_id
    AND app.can_see_student(p_student_id)
  GROUP BY r.observed_on, r.teaching_group_id, tg.label, sub.name, r.assessment_id, a.title
  ORDER BY r.observed_on;
$$;

CREATE OR REPLACE FUNCTION analytics.student_trajectory(p_student_id uuid)
RETURNS TABLE (
  teaching_group_id uuid, group_label text, subject_name text,
  trajectory text, shift numeric, n_recent bigint, n_prior bigint,
  slope_year numeric, model_kind text
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT tr.teaching_group_id, tg.label, sub.name,
         tr.trajectory, round((tr.shift)::numeric, 4), tr.n_recent, tr.n_prior,
         round((tr.slope_year)::numeric, 6), tr.model_kind
  FROM analytics.mv_trajectory tr
  JOIN org.teaching_group tg ON tg.id = tr.teaching_group_id
  JOIN org.subject sub ON sub.id = tg.subject_id
  WHERE tr.tenant_id = app.current_tenant()
    AND tr.student_id = p_student_id
    AND app.can_see_student(p_student_id);
$$;

-- ---------------------------------------------------------------------------
-- "Five things worth your attention." The screen that decides whether the
-- product reads as help or as admin. Capped, ranked by effect size, and never
-- a wall of every student who dipped once.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.attention_list(p_limit integer DEFAULT 5)
RETURNS TABLE (
  kind text, student_id uuid, student_name text,
  teaching_group_id uuid, group_label text,
  tag_id uuid, tag_label text,
  headline text, effect numeric, evidence bigint, time_context text
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH mine AS (
    SELECT tg.id, tg.label
    FROM org.teaching_group tg
    JOIN org.academic_year ay ON ay.id = tg.academic_year_id AND ay.is_current
    WHERE tg.tenant_id = app.current_tenant()
      AND (app.is_school_wide() OR EXISTS (
        SELECT 1 FROM org.teaching_assignment ta
        JOIN org.person staff ON staff.id = ta.staff_id
        WHERE ta.teaching_group_id = tg.id AND ta.to_date IS NULL
          AND staff.user_id = app.current_user_id()))
  ),
  -- A cohort-wide weakness is ONE item, attributed to the class, never twenty
  -- separate student alerts. Reporting it per student is how a teaching problem
  -- gets misread as twenty struggling children.
  systemic AS (
    SELECT 'systemic_topic_gap'::text AS kind, NULL::uuid AS student_id, NULL::text AS student_name,
           c.teaching_group_id, m.label AS group_label, c.tag_id, t.label AS tag_label,
           'Whole class is below expectation on ' || t.label AS headline,
           round((1 - c.cohort_mean_pct)::numeric, 4) AS effect, c.n_responses AS evidence,
           CASE WHEN tt.delivery_ratio IS NULL THEN 'time_not_recorded'
                WHEN tt.delivery_ratio < 0.6 THEN 'under_taught'
                ELSE 'time_adequate' END AS time_context
    FROM analytics.mv_cohort_tag c
    JOIN mine m ON m.id = c.teaching_group_id
    JOIN curric.tag t ON t.id = c.tag_id
    LEFT JOIN analytics.v_teaching_time tt
      ON tt.teaching_group_id = c.teaching_group_id AND tt.tag_id = c.tag_id
    WHERE c.tenant_id = app.current_tenant()
      AND c.cohort_verdict IN ('below_absolute_floor','below_external_benchmark')
  ),
  declining AS (
    SELECT 'trajectory_decline'::text, tr.student_id,
           p.given_name || ' ' || p.family_name, tr.teaching_group_id, m.label,
           NULL::uuid, NULL::text,
           p.given_name || ' ' || p.family_name || ' has dropped against their own baseline',
           round((abs(tr.shift))::numeric, 4), tr.n_recent, NULL::text
    FROM analytics.mv_trajectory tr
    JOIN mine m ON m.id = tr.teaching_group_id
    JOIN org.person p ON p.id = tr.student_id
    WHERE tr.tenant_id = app.current_tenant() AND tr.trajectory = 'declining'
  ),
  individual AS (
    SELECT 'individual_topic_gap'::text, g.student_id,
           p.given_name || ' ' || p.family_name, g.teaching_group_id, m.label,
           g.tag_id, t.label,
           p.given_name || ' ' || p.family_name || ' is behind on ' || t.label,
           round((abs(g.mean_residual))::numeric, 4), g.n_responses, g.time_context
    FROM analytics.mv_gap_signal g
    JOIN mine m ON m.id = g.teaching_group_id
    JOIN org.person p ON p.id = g.student_id
    JOIN curric.tag t ON t.id = g.tag_id
    WHERE g.tenant_id = app.current_tenant()
      AND g.verdict IN ('individual','systemic_and_individual')
      AND abs(g.mean_residual) >= 0.08
  )
  SELECT * FROM (
    SELECT * FROM systemic UNION ALL SELECT * FROM declining UNION ALL SELECT * FROM individual
  ) q
  ORDER BY
    -- Systemic first: it is one action that helps a whole class.
    CASE q.kind WHEN 'systemic_topic_gap' THEN 1 WHEN 'trajectory_decline' THEN 2 ELSE 3 END,
    q.effect DESC
  LIMIT greatest(p_limit, 1);
$$;

-- ---------------------------------------------------------------------------
-- Class-level marking coverage. Non-random missingness reverses period effects:
-- if the weakest students miss the hard paper, the cohort mean RISES.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.group_coverage(p_group_id uuid)
RETURNS TABLE (term_label text, n_responses bigint, cohort_coverage numeric,
               identifiability text, caveat text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT tm.label, cpe.n_responses, cpe.cohort_coverage, cpe.identifiability, cpe.caveat
  FROM analytics.mv_cohort_period_effect cpe
  JOIN org.term tm ON tm.id = cpe.term_id
  WHERE cpe.tenant_id = app.current_tenant()
    AND cpe.teaching_group_id = p_group_id
  ORDER BY tm.seq;
$$;

GRANT EXECUTE ON FUNCTION
  analytics.class_heatmap(uuid, text),
  analytics.student_gaps(uuid, text),
  analytics.student_timeline(uuid),
  analytics.student_trajectory(uuid),
  analytics.attention_list(integer),
  analytics.group_coverage(uuid)
TO app_rw, app_ro;

-- Re-secure in case this migration introduced or replaced a view.
SELECT app.secure_all_views();
