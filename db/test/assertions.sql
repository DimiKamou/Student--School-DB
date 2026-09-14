-- ============================================================================
-- assertions.sql — score the engine against the PLANTED ground truth in
-- db/test/generate_synthetic.py. Run after loading synthetic.sql and refreshing.
-- Every row must report PASS.
-- ============================================================================
\pset pager off
\set ON_ERROR_STOP on

WITH t AS (
  SELECT
  -- A: the planted individual gap must be found
  (SELECT g.verdict FROM analytics.mv_gap_signal g
     JOIN org.person p ON p.id=g.student_id JOIN curric.tag c ON c.id=g.tag_id
    WHERE p.external_ref='STU-A1' AND c.code='INT') AS a_verdict,
  -- D: the clean student must NOT be flagged anywhere an individual gap wasn't planted
  (SELECT count(*) FROM analytics.mv_gap_signal g
     JOIN org.person p ON p.id=g.student_id
    WHERE p.external_ref='STU-A3'
      AND g.verdict IN ('individual','systemic_and_individual')) AS d_false_positives,
  -- B: the planted cohort gap must be found in group 1
  (SELECT c2.cohort_verdict FROM analytics.mv_cohort_tag c2
     JOIN org.teaching_group tg ON tg.id=c2.teaching_group_id
     JOIN curric.tag c ON c.id=c2.tag_id
    WHERE tg.label='11M/1' AND c.code='SRC') AS b_verdict,
  -- G: the parallel class must NOT inherit it
  (SELECT c2.cohort_verdict FROM analytics.mv_cohort_tag c2
     JOIN org.teaching_group tg ON tg.id=c2.teaching_group_id
     JOIN curric.tag c ON c.id=c2.tag_id
    WHERE tg.label='11M/2' AND c.code='SRC') AS g_verdict,
  -- C: the declining student must be found
  (SELECT tr.trajectory FROM analytics.mv_trajectory tr
     JOIN org.person p ON p.id=tr.student_id WHERE p.external_ref='STU-A2') AS c_traj,
  -- C2: and the other 47 must not be
  (SELECT count(*) FROM analytics.mv_trajectory tr JOIN org.person p ON p.id=tr.student_id
    WHERE tr.trajectory='declining' AND p.external_ref<>'STU-A2') AS c_false_declines,
  -- E: under-taught context must be attached to the systemic finding
  (SELECT g.time_context FROM analytics.mv_gap_signal g
     JOIN org.person p ON p.id=g.student_id JOIN curric.tag c ON c.id=g.tag_id
    WHERE p.external_ref='STU-A3' AND c.code='SRC') AS e_time,
  -- F: cohort period effect must declare itself unidentifiable-without-anchors
  (SELECT count(DISTINCT identifiability) FROM analytics.mv_cohort_period_effect) AS f_ident_kinds,
  (SELECT bool_and(identifiability='cross_class_confounded')
     FROM analytics.mv_cohort_period_effect) AS f_confounded,
  -- H: overall false-positive rate on individual verdicts across all 48 students
  (SELECT round(100.0*count(*) FILTER (WHERE verdict IN ('individual','systemic_and_individual'))
                / nullif(count(*),0), 1) FROM analytics.mv_gap_signal) AS h_flag_rate_pct
)
SELECT * FROM (
  SELECT 'A  planted individual gap detected'        AS assertion,
         a_verdict::text AS got, 'individual' AS want,
         CASE WHEN a_verdict='individual' THEN 'PASS' ELSE 'FAIL' END AS result FROM t
  UNION ALL SELECT 'D  clean student not flagged',
         d_false_positives::text, '0',
         CASE WHEN d_false_positives=0 THEN 'PASS' ELSE 'FAIL' END FROM t
  UNION ALL SELECT 'B  planted cohort gap detected',
         b_verdict::text, 'below_absolute_floor',
         CASE WHEN b_verdict='below_absolute_floor' THEN 'PASS' ELSE 'FAIL' END FROM t
  UNION ALL SELECT 'G  parallel class NOT contaminated',
         g_verdict::text, 'ok',
         CASE WHEN g_verdict='ok' THEN 'PASS' ELSE 'FAIL' END FROM t
  UNION ALL SELECT 'C  declining student detected',
         c_traj::text, 'declining',
         CASE WHEN c_traj='declining' THEN 'PASS' ELSE 'FAIL' END FROM t
  UNION ALL SELECT 'C2 no spurious declines',
         c_false_declines::text, '0',
         CASE WHEN c_false_declines=0 THEN 'PASS' ELSE 'FAIL' END FROM t
  UNION ALL SELECT 'E  under-taught context attached',
         e_time::text, 'under_taught',
         CASE WHEN e_time='under_taught' THEN 'PASS' ELSE 'FAIL' END FROM t
  UNION ALL SELECT 'F  cohort period effect declares confound',
         f_confounded::text, 'true',
         CASE WHEN f_confounded THEN 'PASS' ELSE 'FAIL' END FROM t
  UNION ALL SELECT 'H  individual flag rate stays low',
         h_flag_rate_pct::text||'%', '<12%',
         CASE WHEN h_flag_rate_pct < 12 THEN 'PASS' ELSE 'FAIL' END FROM t
) q ORDER BY assertion;
