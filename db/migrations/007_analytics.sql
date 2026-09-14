-- ============================================================================
-- 007_analytics.sql — the engine that answers the thesis question
--
-- Which periods, subjects, topics and skills depress a student's progress, and
-- is the cause this student or the teaching?
--
-- THREE THINGS THIS LAYER REFUSES TO DO, each a documented way these systems lie:
--
-- 1. It never treats an absence as a zero. pct is NULL unless status='scored'.
-- 2. It never pools normalised values across two grading frameworks unless both
--    scales are anchored or equated. A DP 6 and an MYP 6/8 both land near 0.72
--    under equal spacing and are not the same standard.
-- 3. It never reports a verdict from a point estimate. Every individual gap
--    carries a one-sided interval and an evidence count, and an underpowered
--    comparison returns INSUFFICIENT_EVIDENCE rather than a confident wrong answer.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- REFERENCE DATE. Every recency window is relative to the most recent evidence
-- in the data, NOT to current_date. Running the engine in August (or over last
-- year's data for a thesis) would otherwise blank every trajectory: "last 90
-- days" contains nothing during a school holiday.
-- ---------------------------------------------------------------------------
-- Materialised, not a per-row function call. Calling a scalar function that
-- scans the fact table from inside an aggregate expression re-evaluates it once
-- PER ROW: a 5k-row refresh took over two minutes before this was a table.
CREATE MATERIALIZED VIEW analytics.mv_ref_date AS
SELECT r.tenant_id, max(r.observed_on) AS ref_date
FROM gradebook.result r
WHERE r.status = 'scored'
GROUP BY r.tenant_id;

CREATE UNIQUE INDEX mv_ref_date_pk ON analytics.mv_ref_date (tenant_id);

-- Convenience accessor for ad-hoc queries only. Never use inside a matview.
CREATE OR REPLACE FUNCTION analytics.ref_date(p_tenant uuid) RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT ref_date FROM analytics.mv_ref_date WHERE tenant_id = p_tenant),
                  current_date)
$$;

-- ---------------------------------------------------------------------------
-- BASE FACT. One row per scored response, with context resolved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_response AS
SELECT
  r.id                    AS result_id,
  r.tenant_id,
  r.student_id,
  r.item_id,
  a.id                    AS assessment_id,
  a.teaching_group_id,
  tg.subject_id,
  tg.academic_year_id,
  tg.framework_version_id,
  a.term_id,
  a.kind                  AS assessment_kind,
  a.weight                AS assessment_weight,
  r.pct,
  r.status,
  r.is_defaulted,
  r.marker_role,
  r.observed_on,
  it.is_anchor,
  it.max_value,
  -- Tag resolution, cheapest wins: item tag, else the assessment's one dropdown.
  coalesce(it.topic_tag_id, a.topic_tag_id) AS topic_tag_id,
  it.skill_tag_id,
  it.measure_id,
  r.scale_id,
  -- Days since the academic year started: the time axis for growth.
  (r.observed_on - ay.starts_on)::numeric   AS day_index,
  r.recorded_at
FROM gradebook.result r
JOIN gradebook.item it        ON it.id = r.item_id
JOIN gradebook.assessment a   ON a.id = it.assessment_id AND a.deleted_at IS NULL
JOIN org.teaching_group tg    ON tg.id = a.teaching_group_id
JOIN org.academic_year ay     ON ay.id = tg.academic_year_id
WHERE r.status = 'scored'
  AND r.pct IS NOT NULL
  AND r.marker_role IN ('primary','moderated');

-- ---------------------------------------------------------------------------
-- ITEM DIFFICULTY. The control that stops "December was bad" from meaning
-- "December's paper was harder".
--
-- discrimination = correlation between performance on this item and overall
-- performance. A near-zero or negative value means the item is measuring noise,
-- and a "systemic gap" built on such items is an assessment artefact.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_item_stats AS
WITH student_overall AS (
  SELECT tenant_id, teaching_group_id, student_id, avg(pct) AS overall_pct
  FROM analytics.v_response GROUP BY 1,2,3
)
SELECT
  v.tenant_id,
  v.item_id,
  v.teaching_group_id,
  count(*)                                   AS n_responses,
  avg(v.pct)                                 AS mean_pct,      -- facility
  coalesce(stddev_samp(v.pct), 0)            AS sd_pct,
  min(v.observed_on)                         AS observed_on,
  corr(v.pct, so.overall_pct)                AS discrimination,
  bool_or(v.is_anchor)                       AS is_anchor
FROM analytics.v_response v
JOIN student_overall so
  ON so.tenant_id = v.tenant_id AND so.student_id = v.student_id
 AND so.teaching_group_id = v.teaching_group_id
GROUP BY v.tenant_id, v.item_id, v.teaching_group_id;

CREATE UNIQUE INDEX mv_item_stats_pk ON analytics.mv_item_stats (tenant_id, item_id);

-- Difficulty-adjusted performance: how a student did relative to how this
-- particular item played across the class.
CREATE OR REPLACE VIEW analytics.v_response_adj AS
SELECT v.*,
       s.mean_pct       AS item_mean_pct,
       s.n_responses    AS item_n,
       s.discrimination,
       (v.pct - s.mean_pct) AS d_adj
FROM analytics.v_response v
JOIN analytics.mv_item_stats s ON s.tenant_id = v.tenant_id AND s.item_id = v.item_id
WHERE s.n_responses >= 3;    -- an item with two responses has no meaningful mean

-- ---------------------------------------------------------------------------
-- STUDENT ABILITY **AND GROWTH**.
--
-- Modelling a student as one constant for the year is the error that makes
-- every Term 1 look bad and every Term 3 look good, in every cohort, in every
-- subject — pure growth reported as a period effect. So the baseline is a LINE,
-- not a level: d_adj ~ intercept + slope * day_index.
--
-- Under 6 observations a regression slope is noise, so the model degrades to a
-- flat mean and says so via model_kind.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_student_trend AS
SELECT
  tenant_id,
  student_id,
  teaching_group_id,
  count(*)                                          AS n_obs,
  avg(d_adj)                                        AS mean_d,
  coalesce(stddev_samp(d_adj), 0)                   AS sd_d,
  CASE WHEN count(*) >= 6 AND var_samp(day_index) > 0
       THEN coalesce(regr_slope(d_adj, day_index), 0) ELSE 0 END       AS slope,
  CASE WHEN count(*) >= 6 AND var_samp(day_index) > 0
       THEN coalesce(regr_intercept(d_adj, day_index), avg(d_adj))
       ELSE avg(d_adj) END                                              AS intercept,
  CASE WHEN count(*) >= 6 AND var_samp(day_index) > 0
       THEN 'linear_growth' ELSE 'flat_mean' END                        AS model_kind
FROM analytics.v_response_adj
GROUP BY tenant_id, student_id, teaching_group_id;

CREATE UNIQUE INDEX mv_student_trend_pk ON analytics.mv_student_trend
  (tenant_id, student_id, teaching_group_id);

-- Residual: performance net of item difficulty AND net of the student's own
-- expected growth path. This is the number every downstream signal uses.
CREATE OR REPLACE VIEW analytics.v_residual AS
SELECT v.*,
       t.slope,
       t.intercept,
       t.model_kind,
       t.n_obs,
       (v.d_adj - (t.intercept + t.slope * v.day_index)) AS residual
FROM analytics.v_response_adj v
JOIN analytics.mv_student_trend t
  ON t.tenant_id = v.tenant_id AND t.student_id = v.student_id
 AND t.teaching_group_id = v.teaching_group_id;

-- ---------------------------------------------------------------------------
-- TAG EXPANSION. A response tagged at a leaf counts toward every ancestor, so
-- "Ολοκληρώματα" rolls up into "Ανάλυση" without the caller writing recursion.
-- Axis comes from the taxonomy: topic, skill, content_type, command_term, ATL.
-- Nothing below is hardcoded to topics.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_response_tag AS
SELECT DISTINCT
  v.tenant_id, v.result_id, c.ancestor_id AS tag_id, tx.axis, c.distance
FROM analytics.v_response v
JOIN LATERAL (VALUES (v.topic_tag_id), (v.skill_tag_id)) AS src(tag_id) ON src.tag_id IS NOT NULL
JOIN curric.tag_closure c ON c.descendant_id = src.tag_id
JOIN curric.tag t         ON t.id = c.ancestor_id
JOIN curric.taxonomy tx   ON tx.id = t.taxonomy_id;

CREATE UNIQUE INDEX mv_response_tag_pk ON analytics.mv_response_tag (tenant_id, result_id, tag_id);
CREATE INDEX mv_response_tag_tag_ix ON analytics.mv_response_tag (tenant_id, axis, tag_id);

-- ---------------------------------------------------------------------------
-- MONEY QUERY 2 + 3a: INDIVIDUAL gap.
--
-- Is this student worse on this tag than on everything else they did, after
-- difficulty and growth are removed? A one-sided 95% interval, not a threshold
-- on a point estimate: the panel's point-estimate classifier measured ~25%
-- precision, and a noisy alert destroys adoption faster than any keystroke cost.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_student_tag_gap AS
SELECT
  r.tenant_id,
  r.student_id,
  r.teaching_group_id,
  rt.axis,
  rt.tag_id,
  count(*)                                        AS n_responses,
  count(DISTINCT r.assessment_id)                 AS n_assessments,
  avg(r.residual)                                 AS mean_residual,
  avg(r.pct)                                      AS mean_pct,
  coalesce(stddev_samp(r.residual), 0.15)         AS sd_residual,
  -- Standard error, floored so a two-observation tag cannot fake precision.
  greatest(coalesce(stddev_samp(r.residual), 0.15), 0.05) / sqrt(count(*)) AS se_residual,
  max(r.observed_on)                              AS last_seen_on,
  -- Recency-weighted mastery: 182-day half-life. Lost in September but fine now
  -- and fine in September but lost now are otherwise the same number.
  sum(r.pct * exp(-ln(2) * (rd.ref_date - r.observed_on) / 182.5))
    / nullif(sum(exp(-ln(2) * (rd.ref_date - r.observed_on) / 182.5)), 0)
                                                  AS mean_pct_recent,
  -- Evidence quality: defaulted bulk entries are weak evidence.
  count(*) FILTER (WHERE NOT r.is_defaulted)      AS n_deliberate
FROM analytics.v_residual r
JOIN analytics.mv_response_tag rt
  ON rt.tenant_id = r.tenant_id AND rt.result_id = r.result_id
JOIN analytics.mv_ref_date rd ON rd.tenant_id = r.tenant_id
GROUP BY r.tenant_id, r.student_id, r.teaching_group_id, rt.axis, rt.tag_id;

CREATE UNIQUE INDEX mv_student_tag_gap_pk ON analytics.mv_student_tag_gap
  (tenant_id, student_id, teaching_group_id, axis, tag_id);

-- ---------------------------------------------------------------------------
-- MONEY QUERY 3b: SYSTEMIC gap — the whole cohort, against an EXTERNAL anchor.
--
-- This is the half that within-class statistics structurally cannot see. Every
-- residual model centres on the class mean, so a class taught badly on
-- everything produces residuals summing to exactly zero. Only ref.benchmark —
-- a national facility, a published mean, an ΕΒΕ — can detect it.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_cohort_tag AS
WITH base AS (
  SELECT
    v.tenant_id, v.teaching_group_id, rt.axis, rt.tag_id,
    count(*)                         AS n_responses,
    count(DISTINCT v.student_id)     AS n_students,
    count(DISTINCT v.item_id)        AS n_items,
    avg(v.pct)                       AS cohort_mean_pct,
    coalesce(stddev_samp(v.pct), 0)  AS cohort_sd_pct,
    avg(s.discrimination)            AS mean_discrimination,
    count(*) FILTER (WHERE v.is_anchor) AS n_anchor_responses
  FROM analytics.v_response v
  JOIN analytics.mv_response_tag rt
    ON rt.tenant_id = v.tenant_id AND rt.result_id = v.result_id
  LEFT JOIN analytics.mv_item_stats s
    ON s.tenant_id = v.tenant_id AND s.item_id = v.item_id
  GROUP BY 1,2,3,4
), anchored AS (
  -- External expectation for this tag, if the school has one.
  SELECT b.tenant_id, b.teaching_group_id, b.axis, b.tag_id,
         (SELECT bm.value FROM ref.benchmark bm
          JOIN curric.tag ct ON ct.id = b.tag_id
          JOIN curric.taxonomy ctx ON ctx.id = ct.taxonomy_id
          WHERE bm.statistic = 'facility' AND bm.scope IN ('national','board','world')
            AND bm.measure_id IS NULL
          LIMIT 1) AS external_facility
  FROM base b
)
SELECT
  b.*,
  a.external_facility,
  CASE
    WHEN b.n_responses < 20 OR b.n_students < 5 THEN 'insufficient_evidence'
    WHEN b.mean_discrimination IS NOT NULL AND b.mean_discrimination < 0.10
      THEN 'assessment_artefact'
    WHEN a.external_facility IS NOT NULL AND b.cohort_mean_pct < a.external_facility - 0.10
      THEN 'below_external_benchmark'
    WHEN b.cohort_mean_pct < 0.55 THEN 'below_absolute_floor'
    ELSE 'ok'
  END AS cohort_verdict
FROM base b JOIN anchored a
  ON a.tenant_id = b.tenant_id AND a.teaching_group_id = b.teaching_group_id
 AND a.axis = b.axis AND a.tag_id = b.tag_id;

CREATE UNIQUE INDEX mv_cohort_tag_pk ON analytics.mv_cohort_tag
  (tenant_id, teaching_group_id, axis, tag_id);

-- ---------------------------------------------------------------------------
-- TEACHING TIME per tag. Turns an ambiguous SYSTEMIC verdict into an actionable
-- one: a cohort failing a topic that got two lessons is a curriculum-design
-- finding; the same failure on a topic that got twelve is a teaching finding.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_teaching_time AS
SELECT
  l.tenant_id,
  l.teaching_group_id,
  c.ancestor_id                                     AS tag_id,
  count(*) FILTER (WHERE NOT l.was_cancelled)       AS lessons_delivered,
  count(*) FILTER (WHERE l.was_cancelled)           AS lessons_cancelled,
  sum(l.minutes) FILTER (WHERE NOT l.was_cancelled) AS minutes_delivered,
  max(t.nominal_minutes)                            AS minutes_nominal,
  CASE WHEN max(t.nominal_minutes) > 0
       THEN round(sum(l.minutes) FILTER (WHERE NOT l.was_cancelled)::numeric
                  / max(t.nominal_minutes), 3) END  AS delivery_ratio
FROM org.lesson l
JOIN curric.tag_closure c ON c.descendant_id = l.topic_tag_id
JOIN curric.tag t         ON t.id = c.ancestor_id
WHERE l.topic_tag_id IS NOT NULL
GROUP BY l.tenant_id, l.teaching_group_id, c.ancestor_id;

-- Lessons a student missed on a given topic. The single most common real cause
-- of an individual topic gap, and without it the classifier reports "unexplained
-- ability deficit" for a student who was simply not in the room.
CREATE OR REPLACE VIEW analytics.v_topic_attendance AS
SELECT
  la.tenant_id,
  la.student_id,
  l.teaching_group_id,
  c.ancestor_id                                        AS tag_id,
  count(*)                                             AS lessons_tracked,
  count(*) FILTER (WHERE la.status IN ('absent'))       AS lessons_missed,
  round(count(*) FILTER (WHERE la.status IN ('absent'))::numeric
        / nullif(count(*), 0), 3)                      AS missed_ratio
FROM org.lesson_attendance la
JOIN org.lesson l         ON l.id = la.lesson_id
JOIN curric.tag_closure c ON c.descendant_id = l.topic_tag_id
WHERE l.topic_tag_id IS NOT NULL AND NOT l.was_cancelled
GROUP BY la.tenant_id, la.student_id, l.teaching_group_id, c.ancestor_id;

-- ---------------------------------------------------------------------------
-- THE VERDICT. Individual vs systemic, with the alternative explanations
-- checked before either is asserted.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_gap_signal AS
SELECT
  g.tenant_id,
  g.student_id,
  g.teaching_group_id,
  g.axis,
  g.tag_id,
  g.n_responses,
  g.n_assessments,
  g.mean_residual,
  g.se_residual,
  g.mean_pct,
  g.mean_pct_recent,
  c.cohort_mean_pct,
  c.cohort_verdict,
  c.n_responses          AS cohort_n_responses,
  tt.delivery_ratio,
  att.missed_ratio,
  -- Upper bound of a one-sided 95% interval on the student's mean residual.
  (g.mean_residual + 1.645 * g.se_residual) AS residual_ci_upper,
  CASE
    -- Evidence gates first. An underpowered comparison gets no verdict at all.
    WHEN g.n_responses < 5 OR g.n_deliberate < 3 OR g.n_assessments < 2
      THEN 'insufficient_evidence'
    WHEN c.cohort_verdict = 'assessment_artefact'
      THEN 'assessment_artefact'
    -- Attendance explains it: not an ability deficit, a presence deficit.
    WHEN att.missed_ratio IS NOT NULL AND att.missed_ratio > 0.30
         AND (g.mean_residual + 1.645 * g.se_residual) < 0
      THEN 'explained_by_absence'
    -- Both: the cohort is weak here AND this student is weaker still.
    WHEN c.cohort_verdict IN ('below_external_benchmark','below_absolute_floor')
         AND (g.mean_residual + 1.645 * g.se_residual) < 0
      THEN 'systemic_and_individual'
    WHEN c.cohort_verdict IN ('below_external_benchmark','below_absolute_floor')
      THEN 'systemic'
    WHEN (g.mean_residual + 1.645 * g.se_residual) < 0
      THEN 'individual'
    ELSE 'ok'
  END AS verdict,
  -- Only meaningful alongside a systemic verdict.
  CASE
    WHEN tt.delivery_ratio IS NULL THEN 'time_not_recorded'
    WHEN tt.delivery_ratio < 0.6   THEN 'under_taught'
    ELSE 'time_adequate'
  END AS time_context
FROM analytics.mv_student_tag_gap g
LEFT JOIN analytics.mv_cohort_tag c
  ON c.tenant_id = g.tenant_id AND c.teaching_group_id = g.teaching_group_id
 AND c.axis = g.axis AND c.tag_id = g.tag_id
LEFT JOIN analytics.v_teaching_time tt
  ON tt.tenant_id = g.tenant_id AND tt.teaching_group_id = g.teaching_group_id
 AND tt.tag_id = g.tag_id
LEFT JOIN analytics.v_topic_attendance att
  ON att.tenant_id = g.tenant_id AND att.student_id = g.student_id
 AND att.teaching_group_id = g.teaching_group_id AND att.tag_id = g.tag_id;

CREATE UNIQUE INDEX mv_gap_signal_pk ON analytics.mv_gap_signal
  (tenant_id, student_id, teaching_group_id, axis, tag_id);
CREATE INDEX mv_gap_signal_verdict_ix ON analytics.mv_gap_signal
  (tenant_id, teaching_group_id, verdict);

-- ---------------------------------------------------------------------------
-- MONEY QUERY 4: PERIOD EFFECT
--
-- READ THIS BEFORE TRUSTING ANY PERIOD NUMBER.
--
-- Item difficulty is estimated WITHIN the cohort (mv_item_stats), so
-- pct - item_mean mathematically removes any effect common to the whole class.
-- In a balanced design the term-level mean residual is then IDENTICALLY ZERO --
-- not small, not noisy: exactly zero. Verified empirically in db/test.
--
-- The consequence is not a bug to patch but a limit to respect:
--   * A period effect SPECIFIC TO A STUDENT is identifiable. "Maria had a bad
--     Term 2 relative to her peers and her own trend" is a real, honest finding.
--   * A period effect COMMON TO THE WHOLE COHORT is NOT identifiable from that
--     cohort's own marks. "Everyone had a bad December" and "December's paper
--     was harder" produce numerically identical data. Separating them needs an
--     external anchor: anchor items of known difficulty, a published benchmark,
--     or a parallel class sitting the same assessment.
--
-- So there are two views, and the cohort one states its own identifiability
-- instead of returning a confident zero.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_student_period_effect AS
SELECT
  r.tenant_id,
  r.student_id,
  r.teaching_group_id,
  r.term_id,
  count(*)                             AS n_responses,
  avg(r.residual)                      AS mean_residual,
  avg(r.pct)                           AS mean_pct,
  greatest(coalesce(stddev_samp(r.residual), 0.15), 0.05) / sqrt(count(*)) AS se_residual,
  CASE
    WHEN count(*) < 8 THEN 'insufficient_evidence'
    WHEN avg(r.residual) + 1.645 * (greatest(coalesce(stddev_samp(r.residual), 0.15), 0.05)
                                    / sqrt(count(*))) < 0 THEN 'below_own_baseline'
    WHEN avg(r.residual) - 1.645 * (greatest(coalesce(stddev_samp(r.residual), 0.15), 0.05)
                                    / sqrt(count(*))) > 0 THEN 'above_own_baseline'
    ELSE 'as_expected'
  END AS verdict
FROM analytics.v_residual r
WHERE r.term_id IS NOT NULL
GROUP BY r.tenant_id, r.student_id, r.teaching_group_id, r.term_id;

CREATE UNIQUE INDEX mv_student_period_effect_pk ON analytics.mv_student_period_effect
  (tenant_id, student_id, teaching_group_id, term_id);

CREATE MATERIALIZED VIEW analytics.mv_cohort_period_effect AS
WITH grp AS (
  SELECT
    v.tenant_id, v.teaching_group_id, v.subject_id, v.academic_year_id, v.term_id,
    count(*)                     AS n_responses,
    count(DISTINCT v.student_id) AS n_students,
    avg(v.pct)                   AS cohort_mean_pct,
    avg(v.pct) FILTER (WHERE v.is_anchor)      AS anchor_mean_pct,
    count(*)   FILTER (WHERE v.is_anchor)      AS n_anchor_responses
  FROM analytics.v_response v
  WHERE v.term_id IS NOT NULL
  GROUP BY 1,2,3,4,5
), peers AS (
  -- Parallel classes: same subject, same year, same term, different group.
  SELECT g.tenant_id, g.teaching_group_id, g.term_id,
         avg(p.cohort_mean_pct)  AS peer_mean_pct,
         count(*)                AS n_peer_groups
  FROM grp g
  JOIN grp p ON p.tenant_id = g.tenant_id AND p.subject_id = g.subject_id
            AND p.academic_year_id = g.academic_year_id AND p.term_id = g.term_id
            AND p.teaching_group_id <> g.teaching_group_id
  GROUP BY 1,2,3
)
SELECT
  g.tenant_id, g.teaching_group_id, g.term_id,
  g.n_responses, g.n_students, g.cohort_mean_pct,
  g.anchor_mean_pct, g.n_anchor_responses,
  pr.peer_mean_pct, pr.n_peer_groups,
  (g.cohort_mean_pct - pr.peer_mean_pct) AS peer_contrast,
  round(g.n_students::numeric
        / nullif((SELECT count(*) FROM org.enrolment e
                  WHERE e.teaching_group_id = g.teaching_group_id
                    AND e.tenant_id = g.tenant_id AND e.to_date IS NULL), 0), 3) AS cohort_coverage,
  CASE
    WHEN g.n_anchor_responses >= 30 THEN 'anchor_based'
    WHEN pr.n_peer_groups >= 1      THEN 'cross_class_confounded'
    ELSE 'not_identifiable'
  END AS identifiability,
  CASE
    WHEN g.n_anchor_responses >= 30 THEN NULL
    WHEN pr.n_peer_groups >= 1 THEN
      'Parallel-class contrast is confounded by set allocation. Without prior '
      'attainment, a lower mean may mean a lower-attaining set, not a worse term.'
    ELSE
      'No anchor items and no parallel class: a cohort-wide period effect cannot '
      'be separated from assessment difficulty in this data. Do not report one.'
  END AS caveat
FROM grp g
LEFT JOIN peers pr ON pr.tenant_id = g.tenant_id
                  AND pr.teaching_group_id = g.teaching_group_id AND pr.term_id = g.term_id;

CREATE UNIQUE INDEX mv_cohort_period_effect_pk ON analytics.mv_cohort_period_effect
  (tenant_id, teaching_group_id, term_id);

-- Period x tag. "Term 2" is not an answer; "the Term 2 sources unit is where
-- this cohort fell apart" is. Same identifiability caveat applies to the
-- cohort-level reading, so this is keyed by student and aggregated by the UI.
CREATE MATERIALIZED VIEW analytics.mv_period_tag_effect AS
SELECT
  r.tenant_id,
  r.teaching_group_id,
  r.term_id,
  rt.axis,
  rt.tag_id,
  count(*)                             AS n_responses,
  count(DISTINCT r.student_id)         AS n_students,
  avg(r.residual)                      AS mean_residual,
  avg(r.pct)                           AS mean_pct,
  greatest(coalesce(stddev_samp(r.residual), 0.15), 0.05) / sqrt(count(*)) AS se_residual,
  count(DISTINCT r.student_id) FILTER (WHERE r.residual < 0) AS n_students_below
FROM analytics.v_residual r
JOIN analytics.mv_response_tag rt
  ON rt.tenant_id = r.tenant_id AND rt.result_id = r.result_id
WHERE r.term_id IS NOT NULL
GROUP BY 1,2,3,4,5;

CREATE UNIQUE INDEX mv_period_tag_effect_pk ON analytics.mv_period_tag_effect
  (tenant_id, teaching_group_id, term_id, axis, tag_id);

-- ---------------------------------------------------------------------------
-- TRAJECTORY / CHANGE DETECTION. "Intervene early" needs a DIRECTION; a student
-- can sit at a perfectly average level all year while falling off a cliff.
--
-- CRITICAL: this uses d_adj, NOT residual.
--
-- residual has the student's OWN fitted slope removed, so looking for a trend
-- in it is circular: a steadily declining student gets a fitted negative slope
-- and residuals near zero, and the decline becomes invisible. That exact bug
-- failed assertion C in db/test.
--
-- d_adj = pct - item_mean is already measured against the cohort's own movement
-- on the same items, so a student keeping pace sits near zero and a student
-- falling behind goes negative. That is the signal.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_trajectory AS
WITH recent AS (
  SELECT v.tenant_id, v.student_id, v.teaching_group_id,
         count(*)                                        AS n_recent,
         avg(v.d_adj)                                    AS mean_adj_recent,
         CASE WHEN count(*) >= 4 AND var_samp(v.day_index) > 0
              THEN regr_slope(v.d_adj, v.day_index) END  AS slope_recent
  FROM analytics.v_response_adj v
  JOIN analytics.mv_ref_date rd ON rd.tenant_id = v.tenant_id
  WHERE v.observed_on >= rd.ref_date - 90
  GROUP BY 1,2,3
), prior AS (
  SELECT v.tenant_id, v.student_id, v.teaching_group_id,
         count(*)                              AS n_prior,
         avg(v.d_adj)                          AS mean_adj_prior,
         coalesce(stddev_samp(v.d_adj), 0.15)  AS sd_prior
  FROM analytics.v_response_adj v
  JOIN analytics.mv_ref_date rd ON rd.tenant_id = v.tenant_id
  WHERE v.observed_on < rd.ref_date - 90
  GROUP BY 1,2,3
)
SELECT
  t.tenant_id, t.student_id, t.teaching_group_id,
  t.n_obs,
  t.slope      AS slope_year,     -- per day, relative to the cohort's own movement
  t.model_kind,
  rc.n_recent, rc.mean_adj_recent, rc.slope_recent,
  pr.n_prior,  pr.mean_adj_prior, pr.sd_prior,
  (rc.mean_adj_recent - pr.mean_adj_prior) AS shift,
  CASE
    WHEN rc.n_recent IS NULL OR rc.n_recent < 4 THEN 'insufficient_recent_evidence'
    WHEN pr.n_prior  IS NULL OR pr.n_prior  < 4 THEN 'no_baseline'
    -- A shift of more than 0.75 baseline SDs: the standard changepoint gate.
    WHEN (rc.mean_adj_recent - pr.mean_adj_prior) < -0.75 * greatest(pr.sd_prior, 0.05)
      THEN 'declining'
    WHEN (rc.mean_adj_recent - pr.mean_adj_prior) >  0.75 * greatest(pr.sd_prior, 0.05)
      THEN 'improving'
    ELSE 'stable'
  END AS trajectory
FROM analytics.mv_student_trend t
LEFT JOIN recent rc ON rc.tenant_id = t.tenant_id AND rc.student_id = t.student_id
                   AND rc.teaching_group_id = t.teaching_group_id
LEFT JOIN prior  pr ON pr.tenant_id = t.tenant_id AND pr.student_id = t.student_id
                   AND pr.teaching_group_id = t.teaching_group_id;

CREATE UNIQUE INDEX mv_trajectory_pk ON analytics.mv_trajectory
  (tenant_id, student_id, teaching_group_id);

-- ---------------------------------------------------------------------------
-- CROSS-FRAMEWORK POOLING GUARD.
--
-- A student moving MYP -> DP, ΓΕΛ -> IB or IGCSE -> DP is the normal case in
-- the international schools this is sold to, and their trajectory must cross
-- that boundary. But pooling raw normalised values across two 'assumed_linear'
-- scales is arithmetic on a false premise. This view reports whether a given
-- student's history can honestly be pooled, and the UI must respect it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_pooling_check AS
SELECT
  v.tenant_id,
  v.student_id,
  count(DISTINCT v.framework_version_id)                              AS n_frameworks,
  count(DISTINCT v.scale_id)                                          AS n_scales,
  bool_and(coalesce(s.equating_status, 'assumed_linear') <> 'assumed_linear') AS all_scales_anchored,
  CASE
    WHEN count(DISTINCT v.framework_version_id) <= 1 THEN 'safe_single_framework'
    WHEN bool_and(coalesce(s.equating_status,'assumed_linear') <> 'assumed_linear')
      THEN 'safe_anchored'
    ELSE 'unsafe_display_separately'
  END AS pooling_verdict
FROM analytics.v_response v
LEFT JOIN ref.scale s ON s.id = v.scale_id
GROUP BY v.tenant_id, v.student_id;

-- ---------------------------------------------------------------------------
-- Refresh, in dependency order, without locking out readers. Plain REFRESH
-- takes ACCESS EXCLUSIVE and would block the class heatmap for the duration of
-- the nightly job; every matview above carries the unique index CONCURRENTLY
-- requires.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.refresh_all(p_concurrent boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_mv text;
  v_order text[] := ARRAY[
    'analytics.mv_ref_date',
    'analytics.mv_item_stats',
    'analytics.mv_student_trend',
    'analytics.mv_response_tag',
    'analytics.mv_student_tag_gap',
    'analytics.mv_cohort_tag',
    'analytics.mv_gap_signal',
    'analytics.mv_student_period_effect',
    'analytics.mv_cohort_period_effect',
    'analytics.mv_period_tag_effect',
    'analytics.mv_trajectory'];
BEGIN
  FOREACH v_mv IN ARRAY v_order LOOP
    IF p_concurrent THEN
      BEGIN
        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %s', v_mv);
      EXCEPTION WHEN OTHERS THEN
        -- CONCURRENTLY cannot run on a never-populated matview.
        EXECUTE format('REFRESH MATERIALIZED VIEW %s', v_mv);
      END;
    ELSE
      EXECUTE format('REFRESH MATERIALIZED VIEW %s', v_mv);
    END IF;
  END LOOP;
END $$;
