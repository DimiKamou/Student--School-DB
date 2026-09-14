-- ============================================================================
-- 11_ib_dp.sql — International Baccalaureate Diploma Programme, as CONFIGURATION
--
-- Everything below is INSERTs into ref.*. No DDL, no code path, no migration.
-- If this file runs clean and ref.v_config_errors is empty, the claim holds for
-- the DP: a grading system with per-session moving boundaries, component
-- weightings that differ by subject AND by level, a 2-D core bonus matrix and a
-- 0-45 aggregate is *data*.
--
-- ---------------------------------------------------------------------------
-- HOW THE DP ACTUALLY GRADES (for the developer who has never seen it)
-- ---------------------------------------------------------------------------
-- A candidate takes six subjects (normally 3 HL + 3 SL, at most 4 HL). Each
-- subject is graded 1-7. On top of that sit the three "core" elements:
--   TOK  Theory of Knowledge   graded A-E
--   EE   Extended Essay        graded A-E   (a 4000-word independent research essay)
--   CAS  Creativity/Activity/Service — NOT graded, but completion is required
-- TOK and EE together contribute 0-3 bonus points via a published matrix.
-- Diploma total = sum of the six subject grades (max 42) + bonus (max 3) = 45.
--
-- Within a subject the grade 1-7 is produced in two steps:
--   1. each assessment COMPONENT (Paper 1, Paper 2, Paper 3, Internal
--      Assessment, oral) is marked, and the component marks are combined using
--      the WEIGHTINGS published in that subject's guide (they differ by subject
--      and by level — Biology HL Paper 2 is 36% of the subject, History HL
--      Paper 2 is 25%);
--   2. the resulting subject total is cut into 1-7 by GRADE BOUNDARIES that are
--      set AFTER marking, separately for every subject, every level and every
--      session (May 2024, November 2024, and by timezone where applicable).
-- Step 1 is ref.conversion_rule(method='weighted_sum'); step 2 is
-- ref.boundary_table + ref.conversion_rule(method='boundary'). That is the
-- whole of DP subject grading.
--
-- ---------------------------------------------------------------------------
-- WHY THIS PLATFORM MATTERS FOR THE DP SPECIFICALLY
-- ---------------------------------------------------------------------------
-- The IB returns, per candidate, a component-level mark breakdown and a subject
-- grade. It publishes NO topic-level or question-level breakdown of exam
-- performance: no per-question facility, no per-syllabus-topic score, nothing
-- that says "this cohort cannot do respiration" or "this cohort cannot do
-- integration by parts". Subject reports contain prose, not data.
-- Therefore, for the DP, ALL topic-level and skill-level diagnosis has to come
-- from the school's own internal assessments, mocks and past-paper marking —
-- which is exactly what gradebook.item + curric.tag capture. The external data
-- can tell a school THAT it under-performed; only the school's own data can
-- tell it WHERE. This seed sets up both halves: the external side (boundaries,
-- benchmarks, awarded grades) and the internal side (component measures at a
-- finer grain than the IB reports, plus a topic taxonomy to tag mocks against).
--
-- ---------------------------------------------------------------------------
-- HONESTY MARKERS USED IN THIS FILE
-- ---------------------------------------------------------------------------
--   source_ref LIKE 'ILLUSTRATIVE%'  -> the numbers are plausible, NOT published.
--                                       Replace before anyone trusts a report.
--   is_provisional = true            -> same, on boundary tables.
-- Grade boundaries are the single most-requested and most-dangerous thing to
-- guess. Every boundary table in this file is marked illustrative, because real
-- DP boundaries are published per session per subject per level in the
-- "Grade boundaries" document issued with results and cannot be derived,
-- predicted or reused from another session.
--
-- No ref.scale here is marked 'anchored'. See the SCALES section for why.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Session-local helpers. pg_temp lives and dies with this psql session, so this
-- file adds no functions to the database. They exist to keep the seed
-- idempotent and to keep the DATA (which is the documentation) readable.
-- ---------------------------------------------------------------------------

CREATE FUNCTION pg_temp.f_scale(p_code text, p_name text, p_kind text,
                                p_min numeric DEFAULT NULL, p_max numeric DEFAULT NULL,
                                p_dec int DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = p_code;
  IF v IS NULL THEN
    INSERT INTO ref.scale (code, name, kind, min_value, max_value, decimals)
    VALUES (p_code, p_name, p_kind, p_min, p_max, p_dec)
    RETURNING id INTO v;
  END IF;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_construct(p_fw uuid, p_code text, p_label text,
                                    p_kind text, p_axis text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  INSERT INTO ref.construct (framework_id, code, label, kind, semantic_axis)
  VALUES (p_fw, p_code, p_label, p_kind, p_axis)
  ON CONFLICT (framework_id, code) DO NOTHING;
  SELECT id INTO v FROM ref.construct WHERE framework_id = p_fw AND code = p_code;
  RETURN v;
END $fn$;

-- Resolve a measure by its natural key (the expression index on ref.measure).
CREATE FUNCTION pg_temp.f_mid(p_fv uuid, p_code text,
                              p_subj text DEFAULT NULL, p_level text DEFAULT NULL)
RETURNS uuid LANGUAGE sql STABLE AS $fn$
  SELECT id FROM ref.measure
   WHERE framework_version_id = p_fv AND code = p_code
     AND coalesce(subject_group_code,'') = coalesce(p_subj,'')
     AND coalesce(level_code,'')         = coalesce(p_level,'')
$fn$;

CREATE FUNCTION pg_temp.f_measure(p_fv uuid, p_construct_code text, p_scale_code text,
                                  p_code text, p_label text, p_role text,
                                  p_subj text DEFAULT NULL, p_level text DEFAULT NULL,
                                  p_weight numeric DEFAULT NULL, p_sort int DEFAULT 0,
                                  p_parent uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; v_con uuid; v_scale uuid; v_fw uuid;
BEGIN
  v := pg_temp.f_mid(p_fv, p_code, p_subj, p_level);
  IF v IS NOT NULL THEN RETURN v; END IF;

  SELECT framework_id INTO v_fw FROM ref.framework_version WHERE id = p_fv;
  SELECT id INTO v_con   FROM ref.construct WHERE framework_id = v_fw AND code = p_construct_code;
  IF v_con IS NULL THEN
    RAISE EXCEPTION 'unknown construct % for framework %', p_construct_code, v_fw;
  END IF;
  SELECT id INTO v_scale FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = p_scale_code;
  IF v_scale IS NULL THEN
    RAISE EXCEPTION 'unknown scale %', p_scale_code;
  END IF;

  INSERT INTO ref.measure (framework_version_id, construct_id, scale_id, code, label,
                           role, subject_group_code, level_code, weight, sort_order,
                           parent_measure_id)
  VALUES (p_fv, v_con, v_scale, p_code, p_label, p_role, p_subj, p_level,
          p_weight, p_sort, p_parent)
  RETURNING id INTO v;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_rule(p_out uuid, p_method text, p_bt uuid DEFAULT NULL,
                               p_note text DEFAULT NULL, p_requires_all boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM ref.conversion_rule
   WHERE output_measure_id = p_out AND method = p_method;
  IF v IS NULL THEN
    INSERT INTO ref.conversion_rule (output_measure_id, method, boundary_table_id,
                                     note, requires_all_inputs)
    VALUES (p_out, p_method, p_bt, p_note, p_requires_all)
    RETURNING id INTO v;
  END IF;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_input(p_rule uuid, p_in uuid, p_w numeric DEFAULT 1,
                                p_required boolean DEFAULT true)
RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO ref.conversion_input (rule_id, input_measure_id, weight, is_required)
  VALUES (p_rule, p_in, p_w, p_required)
  ON CONFLICT (rule_id, input_measure_id)
  DO UPDATE SET weight = EXCLUDED.weight, is_required = EXCLUDED.is_required;
$fn$;

CREATE FUNCTION pg_temp.f_bt(p_measure uuid, p_in_scale text, p_out_scale text,
                             p_session text, p_from date, p_src text,
                             p_provisional boolean DEFAULT true)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; v_in uuid; v_out uuid;
BEGIN
  SELECT id INTO v FROM ref.boundary_table
   WHERE owner_tenant_id = app.global_tenant()
     AND measure_id = p_measure AND session_label = p_session;
  IF v IS NOT NULL THEN RETURN v; END IF;
  SELECT id INTO v_in  FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = p_in_scale;
  SELECT id INTO v_out FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = p_out_scale;
  INSERT INTO ref.boundary_table (measure_id, in_scale_id, out_scale_id, session_label,
                                  valid_from, source_ref, is_provisional)
  VALUES (p_measure, v_in, v_out, p_session, p_from, p_src, p_provisional)
  RETURNING id INTO v;
  RETURN v;
END $fn$;

-- One row of a boundary table. bounds is a numrange: half-marks and decimal
-- scaled totals fall inside a range by construction, and the GiST exclusion
-- constraint makes an overlapping boundary set impossible to seed by accident.
CREATE FUNCTION pg_temp.f_brow(p_bt uuid, p_out text, p_lo numeric, p_hi numeric)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ref.boundary_row
                  WHERE boundary_table_id = p_bt AND out_code = p_out) THEN
    INSERT INTO ref.boundary_row (boundary_table_id, out_code, bounds)
    VALUES (p_bt, p_out, numrange(p_lo, p_hi, '[)'));
  END IF;
END $fn$;

-- A full 1-7 boundary set from the six lower cut-offs (for grades 2,3,4,5,6,7),
-- which is exactly how the IB publishes them: a row of six numbers per subject
-- per level per session.
CREATE FUNCTION pg_temp.f_grade_boundaries(p_measure uuid, p_session text, p_from date,
                                           p_src text, p_cuts numeric[])
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; i int;
BEGIN
  v := pg_temp.f_bt(p_measure, 'IB_DP_PCT_0_100', 'IB_DP_GRADE_1_7', p_session, p_from, p_src, true);
  PERFORM pg_temp.f_brow(v, '1', 0, p_cuts[1]);
  FOR i IN 1..5 LOOP
    PERFORM pg_temp.f_brow(v, (i+1)::text, p_cuts[i], p_cuts[i+1]);
  END LOOP;
  -- Top band runs past 100 so a scaled total of exactly 100 is still a 7.
  PERFORM pg_temp.f_brow(v, '7', p_cuts[6], 101);
  RETURN v;
END $fn$;

-- A-E boundary set from the four lower cut-offs (D,C,B,A) over any input scale.
CREATE FUNCTION pg_temp.f_letter_boundaries(p_measure uuid, p_in_scale text, p_session text,
                                            p_from date, p_src text, p_cuts numeric[], p_top numeric)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  v := pg_temp.f_bt(p_measure, p_in_scale, 'IB_DP_TOK_EE_A_E', p_session, p_from, p_src, true);
  PERFORM pg_temp.f_brow(v, 'E', 0,          p_cuts[1]);
  PERFORM pg_temp.f_brow(v, 'D', p_cuts[1],  p_cuts[2]);
  PERFORM pg_temp.f_brow(v, 'C', p_cuts[2],  p_cuts[3]);
  PERFORM pg_temp.f_brow(v, 'B', p_cuts[3],  p_cuts[4]);
  PERFORM pg_temp.f_brow(v, 'A', p_cuts[4],  p_top);
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_bench(p_measure uuid, p_scale uuid, p_scope text, p_scope_label text,
                                p_stat text, p_value numeric, p_year int, p_src text,
                                p_n int DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM ref.benchmark
     WHERE owner_tenant_id = app.global_tenant()
       AND measure_id IS NOT DISTINCT FROM p_measure
       AND scale_id   IS NOT DISTINCT FROM p_scale
       AND scope = p_scope
       AND coalesce(scope_label,'') = coalesce(p_scope_label,'')
       AND statistic = p_stat
       AND coalesce(year, 0) = coalesce(p_year, 0)) THEN
    INSERT INTO ref.benchmark (measure_id, scale_id, scope, scope_label, statistic,
                               value, year, source_ref, n_candidates)
    VALUES (p_measure, p_scale, p_scope, p_scope_label, p_stat, p_value, p_year, p_src, p_n);
  END IF;
END $fn$;

CREATE FUNCTION pg_temp.f_tr(p_kind text, p_id uuid, p_locale text, p_value text,
                             p_field text DEFAULT 'label')
RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO ref.translation (entity_kind, entity_id, locale, field, value)
  VALUES (p_kind, p_id, p_locale, p_field, p_value)
  ON CONFLICT (entity_kind, entity_id, locale, field) DO UPDATE SET value = EXCLUDED.value;
$fn$;

-- ===========================================================================
-- 1. SCALES
--
-- A NOTE ON equating_status, WHICH IS DELIBERATELY LEFT 'assumed_linear'
-- EVERYWHERE IN THIS FILE:
--
-- ref.scale_point.pct_anchor is "where this grade sits on a 0-1 axis". For the
-- DP 1-7 scale the honest anchor would come from the worldwide grade
-- distribution published in the IB Statistical Bulletin: if 14% of candidates
-- worldwide are awarded a 7 and 1% a 1, then a 7 and a 1 are nowhere near
-- symmetric and equal spacing (1->0.000, 4->0.500, 7->1.000) is wrong.
-- Computing that anchor needs the actual bulletin table, per subject, per
-- session. This seed does NOT ship one, so every scale stays 'assumed_linear'
-- and cross-framework pooling stays correctly blocked. Setting 'anchored' from
-- remembered approximate percentages would silently corrupt every
-- DP-vs-A-Level-vs-Panhellenic comparison downstream, which is a far worse
-- outcome than an honest 'assumed_linear'.
--
-- For the POINTS scales (0-45, 0-3, the matrix sum) equal spacing is not an
-- assumption at all — diploma points are added arithmetically, so the linear
-- anchor is exactly right. The vocabulary has no value for "linear by
-- definition", so they too read 'assumed_linear'. That is a vocabulary gap,
-- not a modelling error.
-- ===========================================================================

DO $seed$
DECLARE
  s_grade uuid; s_ae uuid; s_points uuid; s_bonus uuid; s_sum uuid; s_pct uuid;
  s_bio_ia uuid; s_hist_ia uuid; s_math_ia uuid; s_langa_io uuid;
  s_tok10 uuid; s_ee34 uuid;
BEGIN
  -- The subject grade. Ordinal: a 7 is better than a 6, but "how much better"
  -- is not knowable from the label alone.
  s_grade := pg_temp.f_scale('IB_DP_GRADE_1_7', 'IB DP subject grade 1-7', 'ordinal_grade', 1, 7, 0);
  PERFORM ref.seed_scale_points(s_grade, ARRAY['1','2','3','4','5','6','7']);
  UPDATE ref.scale_point SET label = x.lbl
    FROM (VALUES ('1','Very poor'),('2','Poor'),('3','Mediocre'),('4','Satisfactory'),
                 ('5','Good'),('6','Very good'),('7','Excellent')) AS x(code,lbl)
   WHERE scale_id = s_grade AND ref.scale_point.code = x.code AND label IS DISTINCT FROM x.lbl;
  -- is_pass is deliberately left NULL on every point. The DP has NO per-subject
  -- pass mark. A grade 3 is not a "fail" — it is a 3, and whether the candidate
  -- gets a diploma depends on the whole profile (see FAILING CONDITIONS below).
  -- Writing is_pass = (grade >= 4) here would encode a staffroom convention as
  -- if it were IB policy and would make every "pass rate" report wrong.

  -- TOK and EE grades. 'N' (no grade submitted) is NOT a scale point: an
  -- unsubmitted component is gradebook.result.status = 'not_submitted', not a
  -- grade. Modelling N as a grade would let it be averaged.
  s_ae := pg_temp.f_scale('IB_DP_TOK_EE_A_E', 'IB DP TOK / Extended Essay grade A-E', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s_ae, ARRAY['E','D','C','B','A']);   -- rank 1 = lowest = E
  UPDATE ref.scale_point SET label = x.lbl, is_pass = x.pass
    FROM (VALUES ('A','Excellent',true),('B','Good',true),('C','Satisfactory',true),
                 ('D','Mediocre',true),('E','Elementary',false)) AS x(code,lbl,pass)
   WHERE scale_id = s_ae AND ref.scale_point.code = x.code;
  -- is_pass IS meaningful here and it is not a convention: a grade E in TOK or
  -- in the EE is an explicit FAILING CONDITION — no diploma, whatever the
  -- points total. Grades A-D are all "passing" for diploma purposes.

  -- The diploma total.
  s_points := pg_temp.f_scale('IB_DP_POINTS_0_45', 'IB DP diploma points total 0-45', 'interval_points', 0, 45, 0);
  PERFORM ref.seed_scale_points(s_points, ARRAY(SELECT i::text FROM generate_series(0,45) AS i));

  -- The core bonus.
  s_bonus := pg_temp.f_scale('IB_DP_BONUS_0_3', 'IB DP TOK/EE bonus points 0-3', 'interval_points', 0, 3, 0);
  PERFORM ref.seed_scale_points(s_bonus, ARRAY['0','1','2','3']);

  -- Internal working scale for the TOK/EE matrix — see section 6.
  s_sum := pg_temp.f_scale('IB_DP_TOK_EE_SUM_4_10', 'TOK+EE combined rank sum (matrix input)', 'interval_points', 4, 10, 0);
  PERFORM ref.seed_scale_points(s_sum, ARRAY(SELECT i::text FROM generate_series(4,10) AS i));

  -- The subject percentage: the weighted combination of components, before
  -- boundaries are applied. The IB itself works in "scaled marks" whose total
  -- varies by subject; expressing the intermediate as a percentage of the
  -- subject maximum is the normalised form that lets ONE boundary table shape
  -- serve every subject.
  s_pct := pg_temp.f_scale('IB_DP_PCT_0_100', 'IB DP subject scaled total (percent)', 'ratio_marks', 0, 100, 2);

  -- Raw mark scales for the components whose maximum is FIXED BY THE GUIDE.
  -- Written papers are deliberately NOT given raw scales: Biology HL Paper 2 is
  -- worth a different number of raw marks in different sessions, so a raw
  -- maximum seeded here would be wrong by next May. Papers are therefore
  -- recorded as a percentage of whatever that session's paper was out of, and
  -- the per-session raw max lives on gradebook.item.max_value where it belongs.
  -- Internal assessment and oral criteria totals, by contrast, are printed in
  -- the subject guide and stay put for the life of the guide.
  s_bio_ia   := pg_temp.f_scale('IB_DP_IA_BIO_0_24',    'Biology IA (scientific investigation), 24 marks', 'ratio_marks', 0, 24, 1);
  s_hist_ia  := pg_temp.f_scale('IB_DP_IA_HIST_0_25',   'History IA (historical investigation), 25 marks', 'ratio_marks', 0, 25, 0);
  s_math_ia  := pg_temp.f_scale('IB_DP_IA_MATH_0_20',   'Mathematics IA (exploration), 20 marks', 'ratio_marks', 0, 20, 0);
  s_langa_io := pg_temp.f_scale('IB_DP_IO_LANGA_0_40',  'Language A individual oral, 40 marks (4 criteria x 10)', 'ratio_marks', 0, 40, 0);
  s_tok10    := pg_temp.f_scale('IB_DP_TOK_0_10',       'TOK essay / exhibition, 10 marks', 'ratio_marks', 0, 10, 0);
  s_ee34     := pg_temp.f_scale('IB_DP_EE_0_34',        'Extended Essay, 34 marks (criteria A-E)', 'ratio_marks', 0, 34, 0);
END $seed$;

-- ===========================================================================
-- 2. FRAMEWORK AND VERSIONS
--
-- There is no such thing as "the DP 2016 specification". The IB reissues each
-- subject guide on its own rolling cycle, and a school runs several vintages at
-- once: in 2024 a school taught Biology under the 2014 guide, History under the
-- 2015 guide and Mathematics AA under the 2019 guide, simultaneously. So a
-- ref.framework_version here is ONE SUBJECT GUIDE, not a calendar year. This is
-- what org.teaching_group.framework_version_id should point at.
-- ===========================================================================

DO $seed$
DECLARE fw uuid;
BEGIN
  INSERT INTO ref.framework (code, name, country_code, awarding_body)
  VALUES ('IB_DP', 'International Baccalaureate Diploma Programme', NULL, 'IBO')
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  SELECT id INTO fw FROM ref.framework
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP';

  INSERT INTO ref.framework_version (framework_id, label, valid_from, valid_to) VALUES
    (fw, 'Biology guide 2014 (first assessment 2016)',                 DATE '2014-08-01', DATE '2024-11-30'),
    (fw, 'Biology guide 2023 (first assessment 2025)',                 DATE '2023-08-01', NULL),
    (fw, 'History guide 2015 (first assessment 2017)',                 DATE '2015-08-01', NULL),
    (fw, 'Mathematics: Analysis and Approaches guide 2019 (first assessment 2021)',
                                                                        DATE '2019-08-01', NULL),
    (fw, 'Language A: Literature guide 2019 (first assessment 2021)',   DATE '2019-08-01', NULL),
    (fw, 'Mathematics SL/HL guide 2012 (final assessment 2020)',        DATE '2012-08-01', DATE '2020-11-30'),
    (fw, 'DP core and diploma award (TOK first assessment 2022, EE first assessment 2018)',
                                                                        DATE '2020-08-01', NULL)
  ON CONFLICT (framework_id, label) DO NOTHING;

  -- Supersession chains: this is how a multi-year trend knows it crossed a
  -- guide change rather than silently averaging two different exams together.
  UPDATE ref.framework_version old
     SET superseded_by = (SELECT id FROM ref.framework_version
                           WHERE framework_id = fw AND label = 'Biology guide 2023 (first assessment 2025)')
   WHERE old.framework_id = fw
     AND old.label = 'Biology guide 2014 (first assessment 2016)'
     AND old.superseded_by IS NULL;

  UPDATE ref.framework_version old
     SET superseded_by = (SELECT id FROM ref.framework_version
                           WHERE framework_id = fw
                             AND label = 'Mathematics: Analysis and Approaches guide 2019 (first assessment 2021)')
   WHERE old.framework_id = fw
     AND old.label = 'Mathematics SL/HL guide 2012 (final assessment 2020)'
     AND old.superseded_by IS NULL;

  PERFORM pg_temp.f_tr('framework', fw, 'es', 'Programa del Diploma del Bachillerato Internacional');
  PERFORM pg_temp.f_tr('framework', fw, 'fr', 'Programme du diplôme du Baccalauréat International');
  PERFORM pg_temp.f_tr('framework', fw, 'el', 'Διεθνές Απολυτήριο (IB) — Πρόγραμμα Διπλώματος');
END $seed$;

-- ===========================================================================
-- 3. CONSTRUCTS — the pedagogically stable identities
--
-- A construct survives guide changes; a measure does not. "Biology Paper 2" is
-- one construct that has existed continuously since long before the 2014 guide;
-- the row that says "Biology HL Paper 2, worth 36% of the subject, marked under
-- the 2014 guide" is a measure and dies when that guide dies. Without the
-- construct, a school's 2023 and 2025 Biology cohorts are unjoinable.
--
-- subject_group_code carries the DP subject identity in the form Gn_SUBJECT
-- (G4_BIOLOGY = group 4, Biology). The schema has one column for "which variant
-- of this framework does this measure belong to" and the DP needs both group
-- and subject, so both are packed into it; the group number is the part that is
-- semantically a "subject group", the rest disambiguates.
-- ===========================================================================

DO $seed$
DECLARE fw uuid;
BEGIN
  SELECT id INTO fw FROM ref.framework
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP';

  -- ---- Group 4: Biology -------------------------------------------------
  -- Paper 1 gets TWO constructs on purpose. Under the 2014 guide Paper 1 was
  -- pure multiple choice testing recall and straightforward application. Under
  -- the 2023 guide "Paper 1" means 1A (multiple choice) + 1B (data-based
  -- questions), which is a different cognitive demand. Trending a 2024 Paper 1
  -- percentage against a 2026 Paper 1 percentage as if they were the same thing
  -- would be a lie, so the constructs are distinct and joined by a
  -- construct_transition marked trend_safe = false.
  PERFORM pg_temp.f_construct(fw, 'BIO_P1_MCQ',      'Biology Paper 1 — multiple choice (2014 guide)', 'component', 'knowledge');
  PERFORM pg_temp.f_construct(fw, 'BIO_P1_MCQ_DATA', 'Biology Paper 1 — multiple choice + data-based (2023 guide)', 'component', 'analysis');
  -- Paper 2 and the IA keep ONE construct across both guides: same kind of
  -- task, same demand, renamed at most. This is the join that makes a
  -- five-year Biology trend possible.
  PERFORM pg_temp.f_construct(fw, 'BIO_P2',          'Biology Paper 2 — data analysis, short and extended response', 'component', 'application');
  PERFORM pg_temp.f_construct(fw, 'BIO_P3',          'Biology Paper 3 — practical/data section + options (2014 guide only)', 'component', 'skill_practical');
  PERFORM pg_temp.f_construct(fw, 'BIO_IA',          'Biology internal assessment — individual scientific investigation', 'component', 'inquiry');
  PERFORM pg_temp.f_construct(fw, 'BIO_SUBJECT',     'Biology — overall subject attainment', 'subject', 'unspecified');

  -- ---- Group 3: History --------------------------------------------------
  PERFORM pg_temp.f_construct(fw, 'HIST_P1',      'History Paper 1 — source-based, prescribed subject', 'component', 'evaluation');
  PERFORM pg_temp.f_construct(fw, 'HIST_P2',      'History Paper 2 — world history topics, comparative essays', 'component', 'synthesis');
  PERFORM pg_temp.f_construct(fw, 'HIST_P3',      'History Paper 3 — HL regional option essays', 'component', 'synthesis');
  PERFORM pg_temp.f_construct(fw, 'HIST_IA',      'History internal assessment — historical investigation', 'component', 'inquiry');
  PERFORM pg_temp.f_construct(fw, 'HIST_SUBJECT', 'History — overall subject attainment', 'subject', 'unspecified');

  -- ---- Group 5: Mathematics ---------------------------------------------
  PERFORM pg_temp.f_construct(fw, 'MAA_P1',      'Mathematics AA Paper 1 — no technology permitted', 'component', 'application');
  PERFORM pg_temp.f_construct(fw, 'MAA_P2',      'Mathematics AA Paper 2 — technology required', 'component', 'application');
  PERFORM pg_temp.f_construct(fw, 'MAA_P3',      'Mathematics AA Paper 3 — HL extended problem solving', 'component', 'synthesis');
  PERFORM pg_temp.f_construct(fw, 'MAA_IA',      'Mathematics AA internal assessment — the exploration', 'component', 'inquiry');
  PERFORM pg_temp.f_construct(fw, 'MAA_SUBJECT', 'Mathematics: Analysis and Approaches — overall subject attainment', 'subject', 'unspecified');
  -- The pre-2019 course that was split into AA and AI. Kept so that a school
  -- with results from 2018 can still see them on the same axis, with the caveat
  -- attached in machine-readable form.
  PERFORM pg_temp.f_construct(fw, 'MATH_2012_SUBJECT', 'Mathematics SL/HL (2012 guide) — overall subject attainment', 'subject', 'unspecified');

  -- ---- Group 1: Language A: Literature ----------------------------------
  PERFORM pg_temp.f_construct(fw, 'LANGA_P1',       'Language A: Literature Paper 1 — guided literary analysis', 'component', 'analysis');
  PERFORM pg_temp.f_construct(fw, 'LANGA_P2',       'Language A: Literature Paper 2 — comparative essay', 'component', 'synthesis');
  PERFORM pg_temp.f_construct(fw, 'LANGA_IO',       'Language A: Literature individual oral', 'component', 'communication');
  PERFORM pg_temp.f_construct(fw, 'LANGA_HL_ESSAY', 'Language A: Literature HL essay', 'component', 'evaluation');
  PERFORM pg_temp.f_construct(fw, 'LANGA_SUBJECT',  'Language A: Literature — overall subject attainment', 'subject', 'unspecified');

  -- ---- The core ----------------------------------------------------------
  PERFORM pg_temp.f_construct(fw, 'TOK_ESSAY',      'TOK essay on a prescribed title (externally assessed)', 'component', 'evaluation');
  PERFORM pg_temp.f_construct(fw, 'TOK_EXHIBITION', 'TOK exhibition (internally assessed, externally moderated)', 'component', 'reflection');
  PERFORM pg_temp.f_construct(fw, 'TOK_OVERALL',    'Theory of Knowledge — overall grade', 'project', 'evaluation');
  PERFORM pg_temp.f_construct(fw, 'EE_OVERALL',     'Extended Essay — overall grade', 'project', 'inquiry');
  PERFORM pg_temp.f_construct(fw, 'CORE_BONUS',     'TOK/EE bonus points', 'overall', 'unspecified');
  PERFORM pg_temp.f_construct(fw, 'DIPLOMA_SLOT',   'One of the six subjects contributing to the diploma total', 'subject', 'unspecified');
  PERFORM pg_temp.f_construct(fw, 'DIPLOMA_TOTAL',  'IB Diploma points total (0-45)', 'overall', 'unspecified');

  -- Construct transitions. 'same'/'renamed' with trend_safe = true means the
  -- analytics layer may draw one line through the change; anything else forces
  -- a visible caveat on the chart.
  INSERT INTO ref.construct_transition (from_construct_id, to_construct_id, transition, trend_safe, note)
  SELECT a.id, b.id, 'rescoped', false,
         'Biology Paper 1 under the 2023 guide adds a data-based section (1B) to the multiple-choice section (1A) and its weighting rises from 20% to 36% of the subject. Percentages are not comparable across the change.'
  FROM ref.construct a, ref.construct b
  WHERE a.framework_id = fw AND a.code = 'BIO_P1_MCQ'
    AND b.framework_id = fw AND b.code = 'BIO_P1_MCQ_DATA'
  ON CONFLICT DO NOTHING;

  INSERT INTO ref.construct_transition (from_construct_id, to_construct_id, transition, trend_safe, note)
  SELECT a.id, b.id, 'merged', false,
         'Biology Paper 3 was removed in the 2023 guide. Its Section A (analysis of data from the practical scheme) has a partial successor in Paper 1B; its Section B (the options: neurobiology, biotechnology, ecology, human physiology) was discontinued outright along with the options themselves. MODELLING NOTE: ref.construct_transition requires a target construct, so "discontinued" cannot be recorded without pointing somewhere — this row points at the closest successor and carries the real story in this note.'
  FROM ref.construct a, ref.construct b
  WHERE a.framework_id = fw AND a.code = 'BIO_P3'
    AND b.framework_id = fw AND b.code = 'BIO_P1_MCQ_DATA'
  ON CONFLICT DO NOTHING;

  INSERT INTO ref.construct_transition (from_construct_id, to_construct_id, transition, trend_safe, note)
  SELECT a.id, b.id, 'split', false,
         'Mathematics SL/HL (2012 guide, final assessment 2020) was split into Analysis and Approaches and Applications and Interpretation for first assessment 2021. A 2019 Mathematics SL grade 5 and a 2022 Mathematics AA SL grade 5 are different courses; trend only with an explicit caveat.'
  FROM ref.construct a, ref.construct b
  WHERE a.framework_id = fw AND a.code = 'MATH_2012_SUBJECT'
    AND b.framework_id = fw AND b.code = 'MAA_SUBJECT'
  ON CONFLICT DO NOTHING;
END $seed$;

-- ===========================================================================
-- 4. SUBJECT MEASURES, WEIGHTINGS AND CONVERSION RULES
--
-- THE ARITHMETIC CONTRACT FOR weighted_sum IN THIS FILE
--   output_pct(0-100) = 100 * SUM( weight_i * normalised_pct_i )
-- where normalised_pct_i is gradebook.result.pct (0-1) for that component,
-- computed on write by gradebook.tg_result_normalise from whatever scale the
-- component is recorded on. Weights are fractions of the subject and sum to 1.
-- This is why a component recorded out of 24 IA marks and a component recorded
-- as a percentage of a written paper can sit in the same rule: they are
-- combined on the normalised axis, not on raw marks.
--
-- ref.measure.weight carries the same published weighting as the corresponding
-- ref.conversion_input.weight. The duplication is intentional: the measure row
-- is what a UI renders ("Paper 2 — 36% of your Biology grade") without needing
-- to resolve a rule, and the conversion_input row is what the engine consumes.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 4a. BIOLOGY — 2014 guide (first assessment 2016, last assessment Nov 2024)
--
--   HL   Paper 1 20%   Paper 2 36%   Paper 3 24%   IA 20%
--   SL   Paper 1 20%   Paper 2 40%   Paper 3 20%   IA 20%
-- Paper 3 Section A drew on the practical scheme of work; Section B was the
-- chosen option. The IA is the individual investigation, 24 marks, marked
-- against 5 criteria and externally moderated.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE
  fv uuid; m_p1 uuid; m_p2 uuid; m_p3 uuid; m_ia uuid; m_pct uuid; m_gr uuid;
  r uuid; bt uuid; lvl text; w2 numeric; w3 numeric;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'Biology guide 2014 (first assessment 2016)';

  FOREACH lvl IN ARRAY ARRAY['HL','SL'] LOOP
    w2 := CASE lvl WHEN 'HL' THEN 0.36 ELSE 0.40 END;
    w3 := CASE lvl WHEN 'HL' THEN 0.24 ELSE 0.20 END;

    m_p1 := pg_temp.f_measure(fv, 'BIO_P1_MCQ', 'IB_DP_PCT_0_100', 'P1',
              'Biology ' || lvl || ' Paper 1 — multiple choice (' || lvl || ': ' ||
              CASE lvl WHEN 'HL' THEN '40' ELSE '30' END || ' items, no calculator)',
              'observed', 'G4_BIOLOGY', lvl, 0.20, 1);
    m_p2 := pg_temp.f_measure(fv, 'BIO_P2', 'IB_DP_PCT_0_100', 'P2',
              'Biology ' || lvl || ' Paper 2 — data-based, short answer, extended response',
              'observed', 'G4_BIOLOGY', lvl, w2, 2);
    m_p3 := pg_temp.f_measure(fv, 'BIO_P3', 'IB_DP_PCT_0_100', 'P3',
              'Biology ' || lvl || ' Paper 3 — Section A practical scheme data, Section B option',
              'observed', 'G4_BIOLOGY', lvl, w3, 3);
    m_ia := pg_temp.f_measure(fv, 'BIO_IA', 'IB_DP_IA_BIO_0_24', 'IA',
              'Biology ' || lvl || ' internal assessment — individual investigation (24 marks)',
              'observed', 'G4_BIOLOGY', lvl, 0.20, 4);

    m_pct := pg_temp.f_measure(fv, 'BIO_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
              'Biology ' || lvl || ' — weighted scaled total (percent)', 'derived',
              'G4_BIOLOGY', lvl, NULL, 10);
    m_gr  := pg_temp.f_measure(fv, 'BIO_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
              'Biology ' || lvl || ' — subject grade 1-7', 'derived',
              'G4_BIOLOGY', lvl, NULL, 11);

    r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
           'Component weightings published in the IB Biology guide (first assessment 2016). '
           'requires_all_inputs = false so that a mid-year view built from two of four '
           'components still renders, flagged low-confidence, instead of refusing.', false);
    PERFORM pg_temp.f_input(r, m_p1, 0.20);
    PERFORM pg_temp.f_input(r, m_p2, w2);
    PERFORM pg_temp.f_input(r, m_p3, w3);
    PERFORM pg_temp.f_input(r, m_ia, 0.20);

    bt := pg_temp.f_grade_boundaries(m_gr, 'May 2024 (ILLUSTRATIVE)', DATE '2024-05-01',
            'ILLUSTRATIVE PLACEHOLDER — not IB data. Real values: "Grade boundaries", '
            'published by the IB with results for each session, subject and level.',
            CASE lvl WHEN 'HL' THEN ARRAY[10,21,32,44,57,71]::numeric[]
                     ELSE           ARRAY[11,22,34,46,58,72]::numeric[] END);
    PERFORM pg_temp.f_rule(m_gr, 'boundary', bt,
           'Apply the session grade boundaries to the weighted scaled total. '
           'A NEW ROW OF ref.boundary_table IS REQUIRED FOR EVERY SESSION — May and '
           'November boundaries differ, and in subjects with timezone variants they '
           'differ by timezone too. Nothing in this row is reusable across sessions.', true);
    PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt, NULL, true), m_pct, 1);
  END LOOP;
END $seed$;

-- ---------------------------------------------------------------------------
-- 4b. BIOLOGY — 2023 guide (first assessment 2025)
--
--   HL and SL alike:  Paper 1 36%   Paper 2 44%   IA 20%
-- Paper 3 is gone. Paper 1 is now 1A (multiple choice) + 1B (data-based).
-- The IA is a "scientific investigation", still 24 marks.
--
-- This is the whole point of separating construct from measure: the IA and
-- Paper 2 measures below are NEW ROWS pointing at the SAME constructs as 4a,
-- so a Biology department's 2023-2027 trend is a single query. Paper 1 points
-- at a different construct because it genuinely became a different paper.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE
  fv uuid; m_p1 uuid; m_p1a uuid; m_p1b uuid; m_p2 uuid; m_ia uuid;
  m_pct uuid; m_gr uuid; r uuid; bt uuid; lvl text;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'Biology guide 2023 (first assessment 2025)';

  FOREACH lvl IN ARRAY ARRAY['HL','SL'] LOOP
    m_p1 := pg_temp.f_measure(fv, 'BIO_P1_MCQ_DATA', 'IB_DP_PCT_0_100', 'P1',
              'Biology ' || lvl || ' Paper 1 — 1A multiple choice + 1B data-based',
              'observed', 'G4_BIOLOGY', lvl, 0.36, 1);
    -- Sub-components. The IB reports Paper 1 as one mark; a school marking a
    -- mock knows 1A and 1B separately and that difference is diagnostic (recall
    -- versus data handling). They carry weight NULL because the IB publishes no
    -- weighting between them — the split is just however many marks each
    -- section was worth on that paper. They are NOT inputs to the rule below;
    -- the write path aggregates them into P1 when they are the grain entered.
    m_p1a := pg_temp.f_measure(fv, 'BIO_P1_MCQ_DATA', 'IB_DP_PCT_0_100', 'P1A',
              'Biology ' || lvl || ' Paper 1A — multiple choice', 'observed',
              'G4_BIOLOGY', lvl, NULL, 2, m_p1);
    m_p1b := pg_temp.f_measure(fv, 'BIO_P1_MCQ_DATA', 'IB_DP_PCT_0_100', 'P1B',
              'Biology ' || lvl || ' Paper 1B — data-based questions', 'observed',
              'G4_BIOLOGY', lvl, NULL, 3, m_p1);

    m_p2 := pg_temp.f_measure(fv, 'BIO_P2', 'IB_DP_PCT_0_100', 'P2',
              'Biology ' || lvl || ' Paper 2 — short answer and extended response',
              'observed', 'G4_BIOLOGY', lvl, 0.44, 4);
    m_ia := pg_temp.f_measure(fv, 'BIO_IA', 'IB_DP_IA_BIO_0_24', 'IA',
              'Biology ' || lvl || ' internal assessment — scientific investigation (24 marks)',
              'observed', 'G4_BIOLOGY', lvl, 0.20, 5);

    m_pct := pg_temp.f_measure(fv, 'BIO_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
              'Biology ' || lvl || ' — weighted scaled total (percent)', 'derived',
              'G4_BIOLOGY', lvl, NULL, 10);
    m_gr  := pg_temp.f_measure(fv, 'BIO_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
              'Biology ' || lvl || ' — subject grade 1-7', 'derived',
              'G4_BIOLOGY', lvl, NULL, 11);

    r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
           'Component weightings published in the IB Biology guide (first assessment 2025): '
           'Paper 1 36%, Paper 2 44%, IA 20%. No Paper 3.', false);
    PERFORM pg_temp.f_input(r, m_p1, 0.36);
    PERFORM pg_temp.f_input(r, m_p2, 0.44);
    PERFORM pg_temp.f_input(r, m_ia, 0.20);

    bt := pg_temp.f_grade_boundaries(m_gr, 'May 2025 (ILLUSTRATIVE)', DATE '2025-05-01',
            'ILLUSTRATIVE PLACEHOLDER — not IB data. A new guide''s first session '
            'boundaries are genuinely unknowable in advance; do not let anyone treat '
            'these as a forecast.',
            CASE lvl WHEN 'HL' THEN ARRAY[11,22,34,46,59,72]::numeric[]
                     ELSE           ARRAY[12,23,35,47,60,73]::numeric[] END);
    PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt,
              'Apply May 2025 boundaries to the weighted scaled total.', true), m_pct, 1);
  END LOOP;
END $seed$;

-- ---------------------------------------------------------------------------
-- 4c. HISTORY — 2015 guide (first assessment 2017)
--
--   HL   Paper 1 20%   Paper 2 25%   Paper 3 35%   IA 20%
--   SL   Paper 1 30%   Paper 2 45%   (no Paper 3)  IA 25%
--
-- History is the clearest demonstration that weightings are not a property of
-- the framework but of the subject AND level: the same Paper 1, the same
-- prescribed subject, the same one-hour source booklet, is worth 20% of an HL
-- grade and 30% of an SL grade. Any schema that stored one weight per component
-- code would get this wrong.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE
  fv uuid; m_p1 uuid; m_p2 uuid; m_p3 uuid; m_ia uuid; m_pct uuid; m_gr uuid;
  r uuid; bt uuid;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'History guide 2015 (first assessment 2017)';

  -- ---- History HL -------------------------------------------------------
  m_p1 := pg_temp.f_measure(fv, 'HIST_P1', 'IB_DP_PCT_0_100', 'P1',
            'History HL Paper 1 — source-based paper on the prescribed subject', 'observed', 'G3_HISTORY', 'HL', 0.20, 1);
  m_p2 := pg_temp.f_measure(fv, 'HIST_P2', 'IB_DP_PCT_0_100', 'P2',
            'History HL Paper 2 — two essays on world history topics', 'observed', 'G3_HISTORY', 'HL', 0.25, 2);
  m_p3 := pg_temp.f_measure(fv, 'HIST_P3', 'IB_DP_PCT_0_100', 'P3',
            'History HL Paper 3 — three essays on the HL regional option', 'observed', 'G3_HISTORY', 'HL', 0.35, 3);
  m_ia := pg_temp.f_measure(fv, 'HIST_IA', 'IB_DP_IA_HIST_0_25', 'IA',
            'History HL internal assessment — historical investigation (25 marks)', 'observed', 'G3_HISTORY', 'HL', 0.20, 4);
  m_pct := pg_temp.f_measure(fv, 'HIST_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
            'History HL — weighted scaled total (percent)', 'derived', 'G3_HISTORY', 'HL', NULL, 10);
  m_gr  := pg_temp.f_measure(fv, 'HIST_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
            'History HL — subject grade 1-7', 'derived', 'G3_HISTORY', 'HL', NULL, 11);

  r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
         'Weightings from the IB History guide (first assessment 2017), HL column.', false);
  PERFORM pg_temp.f_input(r, m_p1, 0.20);
  PERFORM pg_temp.f_input(r, m_p2, 0.25);
  PERFORM pg_temp.f_input(r, m_p3, 0.35);
  PERFORM pg_temp.f_input(r, m_ia, 0.20);

  bt := pg_temp.f_grade_boundaries(m_gr, 'May 2024 (ILLUSTRATIVE)', DATE '2024-05-01',
          'ILLUSTRATIVE PLACEHOLDER — not IB data.', ARRAY[12,24,35,47,59,71]::numeric[]);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt, NULL, true), m_pct, 1);

  -- ---- History SL -------------------------------------------------------
  m_p1 := pg_temp.f_measure(fv, 'HIST_P1', 'IB_DP_PCT_0_100', 'P1',
            'History SL Paper 1 — source-based paper on the prescribed subject', 'observed', 'G3_HISTORY', 'SL', 0.30, 1);
  m_p2 := pg_temp.f_measure(fv, 'HIST_P2', 'IB_DP_PCT_0_100', 'P2',
            'History SL Paper 2 — two essays on world history topics', 'observed', 'G3_HISTORY', 'SL', 0.45, 2);
  m_ia := pg_temp.f_measure(fv, 'HIST_IA', 'IB_DP_IA_HIST_0_25', 'IA',
            'History SL internal assessment — historical investigation (25 marks)', 'observed', 'G3_HISTORY', 'SL', 0.25, 4);
  m_pct := pg_temp.f_measure(fv, 'HIST_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
            'History SL — weighted scaled total (percent)', 'derived', 'G3_HISTORY', 'SL', NULL, 10);
  m_gr  := pg_temp.f_measure(fv, 'HIST_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
            'History SL — subject grade 1-7', 'derived', 'G3_HISTORY', 'SL', NULL, 11);

  r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
         'Weightings from the IB History guide (first assessment 2017), SL column. '
         'There is no Paper 3 at SL, and the IA is worth more (25% vs 20%).', false);
  PERFORM pg_temp.f_input(r, m_p1, 0.30);
  PERFORM pg_temp.f_input(r, m_p2, 0.45);
  PERFORM pg_temp.f_input(r, m_ia, 0.25);

  bt := pg_temp.f_grade_boundaries(m_gr, 'May 2024 (ILLUSTRATIVE)', DATE '2024-05-01',
          'ILLUSTRATIVE PLACEHOLDER — not IB data.', ARRAY[13,25,36,48,60,72]::numeric[]);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt, NULL, true), m_pct, 1);
END $seed$;

-- ---------------------------------------------------------------------------
-- 4d. MATHEMATICS: ANALYSIS AND APPROACHES — 2019 guide (first assessment 2021)
--
--   SL   Paper 1 40%  (no technology)   Paper 2 40%  (technology)   IA 20%
--   HL   Paper 1 30%                    Paper 2 30%                 Paper 3 20%   IA 20%
--
-- The IA is "the exploration", 20 marks over 5 criteria. HL Paper 3 is two
-- extended problem-solving questions and is the component HL candidates most
-- often collapse on — worth isolating, which is exactly what a per-component
-- measure buys a department.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE
  fv uuid; m_p1 uuid; m_p2 uuid; m_p3 uuid; m_ia uuid; m_pct uuid; m_gr uuid;
  r uuid; bt uuid;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'Mathematics: Analysis and Approaches guide 2019 (first assessment 2021)';

  -- ---- Mathematics AA SL ------------------------------------------------
  m_p1 := pg_temp.f_measure(fv, 'MAA_P1', 'IB_DP_PCT_0_100', 'P1',
            'Mathematics AA SL Paper 1 — no technology permitted', 'observed', 'G5_MATH_AA', 'SL', 0.40, 1);
  m_p2 := pg_temp.f_measure(fv, 'MAA_P2', 'IB_DP_PCT_0_100', 'P2',
            'Mathematics AA SL Paper 2 — graphic display calculator required', 'observed', 'G5_MATH_AA', 'SL', 0.40, 2);
  m_ia := pg_temp.f_measure(fv, 'MAA_IA', 'IB_DP_IA_MATH_0_20', 'IA',
            'Mathematics AA SL internal assessment — the exploration (20 marks)', 'observed', 'G5_MATH_AA', 'SL', 0.20, 4);
  m_pct := pg_temp.f_measure(fv, 'MAA_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
            'Mathematics AA SL — weighted scaled total (percent)', 'derived', 'G5_MATH_AA', 'SL', NULL, 10);
  m_gr  := pg_temp.f_measure(fv, 'MAA_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
            'Mathematics AA SL — subject grade 1-7', 'derived', 'G5_MATH_AA', 'SL', NULL, 11);

  r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
         'Weightings from the IB Mathematics: Analysis and Approaches guide (first assessment 2021), SL.', false);
  PERFORM pg_temp.f_input(r, m_p1, 0.40);
  PERFORM pg_temp.f_input(r, m_p2, 0.40);
  PERFORM pg_temp.f_input(r, m_ia, 0.20);

  bt := pg_temp.f_grade_boundaries(m_gr, 'May 2024 (ILLUSTRATIVE)', DATE '2024-05-01',
          'ILLUSTRATIVE PLACEHOLDER — not IB data.', ARRAY[13,26,40,53,66,79]::numeric[]);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt, NULL, true), m_pct, 1);

  -- ---- Mathematics AA HL ------------------------------------------------
  m_p1 := pg_temp.f_measure(fv, 'MAA_P1', 'IB_DP_PCT_0_100', 'P1',
            'Mathematics AA HL Paper 1 — no technology permitted', 'observed', 'G5_MATH_AA', 'HL', 0.30, 1);
  m_p2 := pg_temp.f_measure(fv, 'MAA_P2', 'IB_DP_PCT_0_100', 'P2',
            'Mathematics AA HL Paper 2 — graphic display calculator required', 'observed', 'G5_MATH_AA', 'HL', 0.30, 2);
  m_p3 := pg_temp.f_measure(fv, 'MAA_P3', 'IB_DP_PCT_0_100', 'P3',
            'Mathematics AA HL Paper 3 — two extended problem-solving questions', 'observed', 'G5_MATH_AA', 'HL', 0.20, 3);
  m_ia := pg_temp.f_measure(fv, 'MAA_IA', 'IB_DP_IA_MATH_0_20', 'IA',
            'Mathematics AA HL internal assessment — the exploration (20 marks)', 'observed', 'G5_MATH_AA', 'HL', 0.20, 4);
  m_pct := pg_temp.f_measure(fv, 'MAA_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
            'Mathematics AA HL — weighted scaled total (percent)', 'derived', 'G5_MATH_AA', 'HL', NULL, 10);
  m_gr  := pg_temp.f_measure(fv, 'MAA_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
            'Mathematics AA HL — subject grade 1-7', 'derived', 'G5_MATH_AA', 'HL', NULL, 11);

  r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
         'Weightings from the IB Mathematics: Analysis and Approaches guide (first assessment 2021), HL.', false);
  PERFORM pg_temp.f_input(r, m_p1, 0.30);
  PERFORM pg_temp.f_input(r, m_p2, 0.30);
  PERFORM pg_temp.f_input(r, m_p3, 0.20);
  PERFORM pg_temp.f_input(r, m_ia, 0.20);

  bt := pg_temp.f_grade_boundaries(m_gr, 'May 2024 (ILLUSTRATIVE)', DATE '2024-05-01',
          'ILLUSTRATIVE PLACEHOLDER — not IB data. Note that real AA HL boundaries sit '
          'strikingly low — a 7 has been awarded from the mid-60s and a 4 from the high '
          'twenties in some sessions — which is precisely why a school must never reuse '
          'last year''s numbers or borrow another subject''s.',
          ARRAY[11,23,35,48,61,74]::numeric[]);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt, NULL, true), m_pct, 1);
END $seed$;

-- ---------------------------------------------------------------------------
-- 4e. LANGUAGE A: LITERATURE — 2019 guide (first assessment 2021)
--
--   SL   Paper 1 35%   Paper 2 35%   Individual oral 30%
--   HL   Paper 1 35%   Paper 2 25%   HL essay 20%   Individual oral 20%
--
-- The ORAL COMPONENT. The individual oral is a 15-minute recorded oral on a
-- global issue, 40 marks over four criteria, internally marked and externally
-- moderated. It is worth up to 30% of a Group 1 grade and is the component most
-- likely to be entered late and least likely to be practised more than once —
-- which makes "has this student ever been given a practice oral, and when"
-- something a school genuinely cannot answer today without this platform.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE
  fv uuid; m_p1 uuid; m_p2 uuid; m_io uuid; m_hle uuid; m_pct uuid; m_gr uuid;
  r uuid; bt uuid;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'Language A: Literature guide 2019 (first assessment 2021)';

  -- ---- SL ---------------------------------------------------------------
  m_p1 := pg_temp.f_measure(fv, 'LANGA_P1', 'IB_DP_PCT_0_100', 'P1',
            'Language A: Literature SL Paper 1 — guided literary analysis (one passage)', 'observed', 'G1_LANG_A_LIT', 'SL', 0.35, 1);
  m_p2 := pg_temp.f_measure(fv, 'LANGA_P2', 'IB_DP_PCT_0_100', 'P2',
            'Language A: Literature SL Paper 2 — comparative essay', 'observed', 'G1_LANG_A_LIT', 'SL', 0.35, 2);
  m_io := pg_temp.f_measure(fv, 'LANGA_IO', 'IB_DP_IO_LANGA_0_40', 'IO',
            'Language A: Literature SL individual oral — 15 minutes, 40 marks', 'observed', 'G1_LANG_A_LIT', 'SL', 0.30, 3);
  m_pct := pg_temp.f_measure(fv, 'LANGA_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
            'Language A: Literature SL — weighted scaled total (percent)', 'derived', 'G1_LANG_A_LIT', 'SL', NULL, 10);
  m_gr  := pg_temp.f_measure(fv, 'LANGA_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
            'Language A: Literature SL — subject grade 1-7', 'derived', 'G1_LANG_A_LIT', 'SL', NULL, 11);

  r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
         'Weightings from the IB Language A: Literature guide (first assessment 2021), SL.', false);
  PERFORM pg_temp.f_input(r, m_p1, 0.35);
  PERFORM pg_temp.f_input(r, m_p2, 0.35);
  PERFORM pg_temp.f_input(r, m_io, 0.30);

  bt := pg_temp.f_grade_boundaries(m_gr, 'May 2024 (ILLUSTRATIVE)', DATE '2024-05-01',
          'ILLUSTRATIVE PLACEHOLDER — not IB data.', ARRAY[9,19,32,45,58,72]::numeric[]);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt, NULL, true), m_pct, 1);

  -- ---- HL ---------------------------------------------------------------
  m_p1  := pg_temp.f_measure(fv, 'LANGA_P1', 'IB_DP_PCT_0_100', 'P1',
             'Language A: Literature HL Paper 1 — guided literary analysis (two passages)', 'observed', 'G1_LANG_A_LIT', 'HL', 0.35, 1);
  m_p2  := pg_temp.f_measure(fv, 'LANGA_P2', 'IB_DP_PCT_0_100', 'P2',
             'Language A: Literature HL Paper 2 — comparative essay', 'observed', 'G1_LANG_A_LIT', 'HL', 0.25, 2);
  m_hle := pg_temp.f_measure(fv, 'LANGA_HL_ESSAY', 'IB_DP_PCT_0_100', 'HL_ESSAY',
             'Language A: Literature HL essay — 1200-1500 words on one studied work', 'observed', 'G1_LANG_A_LIT', 'HL', 0.20, 3);
  m_io  := pg_temp.f_measure(fv, 'LANGA_IO', 'IB_DP_IO_LANGA_0_40', 'IO',
             'Language A: Literature HL individual oral — 15 minutes, 40 marks', 'observed', 'G1_LANG_A_LIT', 'HL', 0.20, 4);
  m_pct := pg_temp.f_measure(fv, 'LANGA_SUBJECT', 'IB_DP_PCT_0_100', 'SUBJ_PCT',
             'Language A: Literature HL — weighted scaled total (percent)', 'derived', 'G1_LANG_A_LIT', 'HL', NULL, 10);
  m_gr  := pg_temp.f_measure(fv, 'LANGA_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
             'Language A: Literature HL — subject grade 1-7', 'derived', 'G1_LANG_A_LIT', 'HL', NULL, 11);

  r := pg_temp.f_rule(m_pct, 'weighted_sum', NULL,
         'Weightings from the IB Language A: Literature guide (first assessment 2021), HL. '
         'The HL essay is recorded as a percentage rather than against a raw maximum '
         'because this seed is not certain of the published mark total for it.', false);
  PERFORM pg_temp.f_input(r, m_p1, 0.35);
  PERFORM pg_temp.f_input(r, m_p2, 0.25);
  PERFORM pg_temp.f_input(r, m_hle, 0.20);
  PERFORM pg_temp.f_input(r, m_io, 0.20);

  bt := pg_temp.f_grade_boundaries(m_gr, 'May 2024 (ILLUSTRATIVE)', DATE '2024-05-01',
          'ILLUSTRATIVE PLACEHOLDER — not IB data.', ARRAY[10,20,33,46,59,73]::numeric[]);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_gr, 'boundary', bt, NULL, true), m_pct, 1);
END $seed$;

-- ---------------------------------------------------------------------------
-- 4f. The retired Mathematics SL/HL (2012 guide). Only the awarded subject
-- grade is seeded: a school importing historical results needs somewhere to put
-- a 2018 Mathematics SL grade 6, and it must NOT land on the AA measure.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE fv uuid;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'Mathematics SL/HL guide 2012 (final assessment 2020)';

  PERFORM pg_temp.f_measure(fv, 'MATH_2012_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
            'Mathematics SL (2012 guide) — subject grade 1-7 as awarded', 'awarded', 'G5_MATH_2012', 'SL', NULL, 11);
  PERFORM pg_temp.f_measure(fv, 'MATH_2012_SUBJECT', 'IB_DP_GRADE_1_7', 'SUBJ_GRADE',
            'Mathematics HL (2012 guide) — subject grade 1-7 as awarded', 'awarded', 'G5_MATH_2012', 'HL', NULL, 11);
END $seed$;

-- ===========================================================================
-- 5. THE CORE: TOK AND THE EXTENDED ESSAY
--
-- TOK  = essay on a prescribed title (external, 10 marks) 2/3
--      + exhibition (internal, externally moderated, 10 marks) 1/3
--        -> percentage -> A-E boundaries -> TOK grade
-- EE   = one 34-mark assessment against criteria A-E
--        -> A-E boundaries -> EE grade
-- ===========================================================================

DO $seed$
DECLARE
  fv uuid; m_tess uuid; m_texh uuid; m_tpct uuid; m_tgr uuid;
  m_eeraw uuid; m_eegr uuid; r uuid; bt uuid; c uuid;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'DP core and diploma award (TOK first assessment 2022, EE first assessment 2018)';

  m_tess := pg_temp.f_measure(fv, 'TOK_ESSAY', 'IB_DP_TOK_0_10', 'TOK_ESSAY',
              'TOK essay on a prescribed title — 1600 words, 10 marks, externally assessed',
              'observed', NULL, NULL, 0.6667, 1);
  m_texh := pg_temp.f_measure(fv, 'TOK_EXHIBITION', 'IB_DP_TOK_0_10', 'TOK_EXHIBITION',
              'TOK exhibition — three objects and commentary, 10 marks, internally assessed and externally moderated',
              'observed', NULL, NULL, 0.3333, 2);
  m_tpct := pg_temp.f_measure(fv, 'TOK_OVERALL', 'IB_DP_PCT_0_100', 'TOK_PCT',
              'TOK — weighted total (percent)', 'derived', NULL, NULL, NULL, 3);
  m_tgr  := pg_temp.f_measure(fv, 'TOK_OVERALL', 'IB_DP_TOK_EE_A_E', 'TOK_GRADE',
              'Theory of Knowledge — grade A-E', 'derived', NULL, NULL, NULL, 4);

  r := pg_temp.f_rule(m_tpct, 'weighted_sum', NULL,
         'TOK essay two thirds, TOK exhibition one third (both marked out of 10).', false);
  PERFORM pg_temp.f_input(r, m_tess, 0.6667);
  PERFORM pg_temp.f_input(r, m_texh, 0.3333);

  bt := pg_temp.f_letter_boundaries(m_tgr, 'IB_DP_PCT_0_100', 'May 2024 (ILLUSTRATIVE)',
          DATE '2024-05-01',
          'ILLUSTRATIVE PLACEHOLDER — not IB data. TOK A-E boundaries are published per '
          'session like every other boundary set.',
          ARRAY[15,30,48,66]::numeric[], 101);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_tgr, 'boundary', bt, NULL, true), m_tpct, 1);

  m_eeraw := pg_temp.f_measure(fv, 'EE_OVERALL', 'IB_DP_EE_0_34', 'EE_MARK',
               'Extended Essay — total mark out of 34 (criteria A focus and method 6, B knowledge and understanding 6, C critical thinking 12, D presentation 4, E engagement 6)',
               'observed', NULL, NULL, NULL, 5);
  m_eegr  := pg_temp.f_measure(fv, 'EE_OVERALL', 'IB_DP_TOK_EE_A_E', 'EE_GRADE',
               'Extended Essay — grade A-E', 'derived', NULL, NULL, NULL, 6);

  bt := pg_temp.f_letter_boundaries(m_eegr, 'IB_DP_EE_0_34', 'May 2024 (ILLUSTRATIVE)',
          DATE '2024-05-01', 'ILLUSTRATIVE PLACEHOLDER — not IB data.',
          ARRAY[7,13,20,26]::numeric[], 35);
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_eegr, 'boundary', bt, NULL, true), m_eeraw, 1);

  -- The published EE grade descriptors, so the supervisor sees the wording while
  -- marking. bounds is a numrange, so for a letter scale the band is expressed
  -- over the scale point's ordinal_rank (E = 1 ... A = 5).
  INSERT INTO ref.measure_band (measure_id, bounds, label, descriptor)
  SELECT m_eegr, numrange(x.lo, x.hi, '[)'), x.lbl, x.d
  FROM (VALUES
    (1::numeric, 2::numeric, 'E', 'Elementary — a superficial essay, weak in focus, method, knowledge and critical thinking. An E in the Extended Essay is a failing condition for the diploma.'),
    (2, 3, 'D', 'Mediocre — a descriptive essay with limited analysis and inconsistent method.'),
    (3, 4, 'C', 'Satisfactory — a reasonably focused essay with adequate knowledge and some analysis.'),
    (4, 5, 'B', 'Good — a well-focused, well-researched essay with consistent analysis and clear presentation.'),
    (5, 6, 'A', 'Excellent — a sharply focused, well-researched essay with sustained critical argument and exemplary presentation.')
  ) AS x(lo, hi, lbl, d)
  WHERE NOT EXISTS (SELECT 1 FROM ref.measure_band b WHERE b.measure_id = m_eegr);

  -- Localised labels. A Spanish- or French-medium DP school marks against the
  -- English criteria wording and reports to families in its own language.
  PERFORM pg_temp.f_tr('measure', m_tgr, 'es', 'Teoría del Conocimiento — calificación A-E');
  PERFORM pg_temp.f_tr('measure', m_tgr, 'fr', 'Théorie de la connaissance — note A-E');
  PERFORM pg_temp.f_tr('measure', m_tgr, 'el', 'Θεωρία της Γνώσης — βαθμός A-E');
  PERFORM pg_temp.f_tr('measure', m_eegr, 'es', 'Monografía — calificación A-E');
  PERFORM pg_temp.f_tr('measure', m_eegr, 'fr', 'Mémoire — note A-E');
  PERFORM pg_temp.f_tr('measure', m_eegr, 'el', 'Εκτεταμένη Εργασία — βαθμός A-E');

  SELECT id INTO c FROM ref.construct
   WHERE framework_id = (SELECT framework_id FROM ref.framework_version WHERE id = fv)
     AND code = 'TOK_OVERALL';
  PERFORM pg_temp.f_tr('construct', c, 'es', 'Teoría del Conocimiento');
  PERFORM pg_temp.f_tr('construct', c, 'fr', 'Théorie de la connaissance');
  SELECT id INTO c FROM ref.construct
   WHERE framework_id = (SELECT framework_id FROM ref.framework_version WHERE id = fv)
     AND code = 'EE_OVERALL';
  PERFORM pg_temp.f_tr('construct', c, 'es', 'Monografía');
  PERFORM pg_temp.f_tr('construct', c, 'fr', 'Mémoire');
END $seed$;

-- ===========================================================================
-- 6. THE TOK/EE BONUS MATRIX, AND THE 0-45 TOTAL
--
-- The published matrix (points awarded):
--
--                      EXTENDED ESSAY
--                 A     B     C     D     E
--          A      3     3     2     2     F
--   T      B      3     2     2     1     F
--   O      C      2     2     1     0     F
--   K      D      2     1     0     0     F
--          E      F     F     F     F     F
--
--   F = failing condition: no diploma is awarded, whatever the points total.
--
-- ref.conversion_rule has no 2-D lookup method, and inventing one would mean a
-- new table for a five-by-five grid. It does not need one, because the matrix
-- is EXACTLY a function of the sum of the two grades' ordinal ranks
-- (E=1, D=2, C=3, B=4, A=5):
--
--   rank sum   4     5     6       7       8       9     10
--   pairs      D+D   C+D   C+C,B+D B+C,A+D B+B,A+C A+B   A+A
--   points     0     0     1       2       2       3     3
--
-- Every cell of the non-E region of the matrix is reproduced, with no
-- exceptions. So the matrix is one weighted_sum (both weights 1) followed by one
-- boundary table of four rows — ordinary configuration.
--
-- THE E ROW AND COLUMN ARE DELIBERATELY OUT OF THE DOMAIN. The input scale
-- IB_DP_TOK_EE_SUM_4_10 starts at 4, which is D+D: any sum below 4 involves a
-- grade E, and an E is not a bonus-points question at all — it is a failing
-- condition evaluated before any total is computed. Encoding E as a number and
-- letting it into the sum would produce, for example, TOK E + EE A = rank sum 6
-- = 1 bonus point, and hand a diploma to a candidate who cannot have one. The
-- engine must refuse to evaluate this rule when either grade is E; the scale
-- domain is how that refusal is declared in data.
-- ===========================================================================

DO $seed$
DECLARE
  fv uuid; m_tgr uuid; m_eegr uuid; m_sum uuid; m_bonus uuid; m_total uuid;
  m_slot uuid; r uuid; bt uuid; i int;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'DP core and diploma award (TOK first assessment 2022, EE first assessment 2018)';

  m_tgr  := pg_temp.f_mid(fv, 'TOK_GRADE');
  m_eegr := pg_temp.f_mid(fv, 'EE_GRADE');

  m_sum := pg_temp.f_measure(fv, 'CORE_BONUS', 'IB_DP_TOK_EE_SUM_4_10', 'CORE_RANK_SUM',
             'TOK grade rank + EE grade rank (matrix lookup key, 4-10)', 'derived', NULL, NULL, NULL, 1);
  r := pg_temp.f_rule(m_sum, 'weighted_sum', NULL,
         'Sum of the two core grades taken as ordinal ranks (E=1 ... A=5). '
         'requires_all_inputs = true: half the matrix key is not a matrix key. '
         'The engine must NOT evaluate this when either grade is E — see the '
         'section comment above.', true);
  PERFORM pg_temp.f_input(r, m_tgr, 1);
  PERFORM pg_temp.f_input(r, m_eegr, 1);

  m_bonus := pg_temp.f_measure(fv, 'CORE_BONUS', 'IB_DP_BONUS_0_3', 'CORE_BONUS',
               'TOK/EE bonus points (0-3)', 'derived', NULL, NULL, NULL, 2);
  bt := pg_temp.f_bt(m_bonus, 'IB_DP_TOK_EE_SUM_4_10', 'IB_DP_BONUS_0_3',
          'Standing (matrix unchanged across sessions)', DATE '2010-01-01',
          'IB Diploma Programme: TOK/EE points matrix, published in the Diploma '
          'Programme Assessment procedures and in the TOK and EE guides. Unlike grade '
          'boundaries this table does NOT move per session — it is policy, not statistics.',
          false);
  PERFORM pg_temp.f_brow(bt, '0', 4, 6);    -- D+D, C+D
  PERFORM pg_temp.f_brow(bt, '1', 6, 7);    -- C+C, B+D
  PERFORM pg_temp.f_brow(bt, '2', 7, 9);    -- B+C, A+D, B+B, A+C
  PERFORM pg_temp.f_brow(bt, '3', 9, 11);   -- A+B, A+A
  PERFORM pg_temp.f_input(pg_temp.f_rule(m_bonus, 'boundary', bt,
            'The TOK/EE matrix as a one-dimensional boundary table over the rank sum.', true),
          m_sum, 1);

  -- -------------------------------------------------------------------------
  -- THE SIX DIPLOMA SLOTS.
  --
  -- The diploma total is "the sum of the candidate's six subject grades", and
  -- WHICH six is a property of the candidate, not of the framework. A
  -- conversion rule cannot name them. The faithful encoding is six SLOT
  -- measures: each slot holds the grade awarded for whichever subject the
  -- candidate registered in that slot, and the total is the sum of the slots
  -- plus the bonus. The slot is level-agnostic on purpose — the usual profile
  -- is 3 HL + 3 SL but 4 HL + 2 SL is permitted, and the slot number carries no
  -- HL/SL meaning.
  --
  -- Populating a slot is the engine's job: copy gradebook.outcome for the
  -- student's six subject-grade measures into the six slot measures. The slots
  -- are role='awarded' rather than 'derived' because what lands in them is a
  -- grade issued elsewhere (by the IB, or estimated by the school), not
  -- something this rule computes.
  -- -------------------------------------------------------------------------
  m_total := pg_temp.f_measure(fv, 'DIPLOMA_TOTAL', 'IB_DP_POINTS_0_45', 'DP_TOTAL',
               'IB Diploma points total (0-45)', 'derived', NULL, NULL, NULL, 20);
  r := pg_temp.f_rule(m_total, 'sum', NULL,
         'Six subject grades (max 7 each = 42) plus the TOK/EE bonus (max 3) = 45. '
         'requires_all_inputs = false so that a partial total is visible in DP1 and '
         'through DP2, flagged low-confidence: "4 of 6 subjects reported" is the most '
         'useful number a DP coordinator can see in February.', false);
  FOR i IN 1..6 LOOP
    m_slot := pg_temp.f_measure(fv, 'DIPLOMA_SLOT', 'IB_DP_GRADE_1_7', 'DP_SLOT_' || i,
                'Diploma subject slot ' || i || ' — grade 1-7 for the subject registered in this slot',
                'awarded', NULL, NULL, NULL, 10 + i);
    PERFORM pg_temp.f_input(r, m_slot, 1, false);
  END LOOP;
  PERFORM pg_temp.f_input(r, m_bonus, 1, false);
END $seed$;

-- ===========================================================================
-- FAILING CONDITIONS — POLICY, NOT ARITHMETIC
--
-- The diploma is awarded when ALL of the following hold. They are recorded here
-- as documentation rather than as config rows because they are predicates over
-- a candidate's whole profile, not conversions between measures, and the
-- conversion vocabulary (sum / weighted_sum / mean / best_fit / boundary /
-- passthrough / scaled_sum) deliberately cannot express them. Anything that
-- could express them would be an expression language, and an expression
-- language in this table would make the config unqueryable.
--
--   1.  CAS requirements have been met.                    (not graded at all)
--   2.  Total is 24 points or more.
--   3.  No grade 1 in any subject, HL or SL.
--   4.  Grade 2 has not been awarded three or more times.
--   5.  Grade 3 or below has not been awarded four or more times.
--   6.  At least 12 points from HL subjects. (With four HL subjects, the three
--       highest HL grades count towards this test.)
--   7.  At least 9 points from SL subjects. (With only two SL subjects, at
--       least 5 points.)
--   8.  No grade E in TOK and no grade E in the EE.
--   9.  No 'N' — no missing grade — in TOK, the EE, or any contributing subject.
--   10. No finding of academic misconduct.
--
-- Consequences for this platform: a student can be on 27 points and still not
-- get a diploma. A "predicted total" that ignores conditions 3-8 is misleading
-- in exactly the cases a school most needs the warning, so the analytics layer
-- must evaluate these predicates separately from the sum, and a UI that shows
-- the total without them is doing harm. This is also why ref.scale_point
-- .is_pass is NULL on the 1-7 scale: there is no per-subject pass to report.
-- ===========================================================================

-- ===========================================================================
-- 7. PREDICTED GRADES
--
-- Every DP school submits predicted grades to the IB and to universities, and
-- for many students the university offer is made against the prediction, not
-- the result. The gap between a school's predictions and the grades the IB
-- awards is therefore a first-class analytic ABOUT THE SCHOOL, not about the
-- student: a department that predicts +1.3 grades above outturn year after year
-- is systematically mis-calibrated and is costing its students offers (and,
-- when it under-predicts, costing them places they would have got).
--
-- Predicted measures share the CONSTRUCT with the awarded subject grade, so
-- predicted-vs-actual is a join on construct_id and nothing else:
--
--   SELECT p.value_code AS predicted, a.value_code AS awarded
--   FROM gradebook.outcome p
--   JOIN ref.measure pm ON pm.id = p.measure_id AND pm.role = 'predicted'
--   JOIN ref.measure am ON am.construct_id = pm.construct_id
--                      AND am.role <> 'predicted'
--                      AND coalesce(am.level_code,'') = coalesce(pm.level_code,'')
--   JOIN gradebook.outcome a ON a.measure_id = am.id
--                           AND a.student_id = p.student_id
--                           AND a.kind = 'awarded_official';
--
-- CONVENTION for where a value is written:
--   role='predicted' measure + outcome.kind='predicted_teacher' -> what the
--        school told the IB and UCAS/universities.
--   role='predicted' measure + outcome.kind='predicted_model'   -> what this
--        platform's model says, so the two can be compared to each other as
--        well as to the outturn.
--   role='derived'   measure + outcome.kind='system_suggested'  -> the engine's
--        boundary-applied estimate from mock components.
--   role='derived'   measure + outcome.kind='awarded_official'  -> the grade the
--        IB actually issued in July.
-- ===========================================================================

DO $seed$
DECLARE r record; fv_core uuid; m uuid;
BEGIN
  -- One predicted measure per (guide, subject, level) that has a subject grade.
  FOR r IN
    SELECT m2.framework_version_id AS fv, c.code AS construct_code,
           m2.subject_group_code AS subj, m2.level_code AS lvl, m2.label AS lbl
    FROM ref.measure m2
    JOIN ref.construct c ON c.id = m2.construct_id
    JOIN ref.framework f ON f.id = c.framework_id
    WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
      AND m2.code = 'SUBJ_GRADE'
  LOOP
    PERFORM pg_temp.f_measure(r.fv, r.construct_code, 'IB_DP_GRADE_1_7', 'PRED_GRADE',
              replace(r.lbl, 'subject grade 1-7', 'PREDICTED subject grade 1-7'),
              'predicted', r.subj, r.lvl, NULL, 20);
  END LOOP;

  SELECT fv2.id INTO fv_core FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'DP core and diploma award (TOK first assessment 2022, EE first assessment 2018)';

  PERFORM pg_temp.f_measure(fv_core, 'TOK_OVERALL', 'IB_DP_TOK_EE_A_E', 'PRED_TOK_GRADE',
            'Theory of Knowledge — PREDICTED grade A-E', 'predicted', NULL, NULL, NULL, 30);
  PERFORM pg_temp.f_measure(fv_core, 'EE_OVERALL', 'IB_DP_TOK_EE_A_E', 'PRED_EE_GRADE',
            'Extended Essay — PREDICTED grade A-E', 'predicted', NULL, NULL, NULL, 31);
  -- The predicted total is the number on the university reference. It is
  -- deliberately role='predicted' with NO conversion rule: schools do not always
  -- compute it as the sum of the predicted parts, and forcing it to be derived
  -- would hide the (very informative) cases where a coordinator adjusts it.
  PERFORM pg_temp.f_measure(fv_core, 'DIPLOMA_TOTAL', 'IB_DP_POINTS_0_45', 'PRED_DP_TOTAL',
            'IB Diploma points total — PREDICTED (0-45)', 'predicted', NULL, NULL, NULL, 32);
END $seed$;

-- ===========================================================================
-- 8. BENCHMARKS — the external anchor
--
-- Without these rows a DP school can only compare its students to each other.
-- A cohort that is uniformly a grade below where it should be produces perfectly
-- ordinary-looking within-class statistics: the residuals sum to zero by
-- construction and nothing is flagged. The worldwide mean diploma total is the
-- cheapest external anchor in existence for the DP and it is published twice a
-- year by the IB.
--
-- Rows whose source_ref starts with 'ILLUSTRATIVE' are NOT published data and
-- must be replaced before any report built on them is shown to a school.
-- ===========================================================================

DO $seed$
DECLARE s_points uuid; s_grade uuid; m uuid; fv uuid;
BEGIN
  SELECT id INTO s_points FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP_POINTS_0_45';
  SELECT id INTO s_grade FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP_GRADE_1_7';

  -- Worldwide mean diploma points, May sessions. Recalled figures, not read
  -- from the bulletin in this session — verify each against the IB Statistical
  -- Bulletin for that session before publishing a comparison built on it.
  -- The SHAPE of the series is the important part and is not in doubt: the 2021
  -- and 2022 sessions were inflated by the pandemic-era awarding model and 2023
  -- returned to roughly the pre-pandemic level. Comparing a school's 2022 cohort
  -- with its 2023 cohort without this series is comparing two different worlds.
  PERFORM pg_temp.f_bench(NULL, s_points, 'world', 'All DP candidates, May session',
            'mean', 31.98, 2022,
            'IB Statistical Bulletin, May 2022 session (recalled figure — verify).');
  PERFORM pg_temp.f_bench(NULL, s_points, 'world', 'All DP candidates, May session',
            'mean', 30.24, 2023,
            'IB Statistical Bulletin, May 2023 session (recalled figure — verify).');
  PERFORM pg_temp.f_bench(NULL, s_points, 'world', 'All DP candidates, May session',
            'mean', 30.32, 2024,
            'IB Statistical Bulletin, May 2024 session (recalled figure — verify).');

  -- The diploma award threshold. This one is policy, exact, and does not move.
  PERFORM pg_temp.f_bench(NULL, s_points, 'world', 'Diploma award threshold',
            'cutoff', 24, NULL,
            'IB Diploma Programme Assessment procedures: 24 points is the minimum '
            'total for the award of the diploma, subject to the failing conditions.');

  -- Spread of diploma totals. Needed for any z-score against the world mean.
  PERFORM pg_temp.f_bench(NULL, s_points, 'world', 'All DP candidates, May session',
            'sd', 6.0, 2023,
            'ILLUSTRATIVE PLACEHOLDER — plausible order of magnitude only, not published data.');

  -- Per-subject mean grades. These are the rows that make "this whole Biology
  -- HL cohort is a grade light" detectable. All illustrative here.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'Biology guide 2014 (first assessment 2016)';
  m := pg_temp.f_mid(fv, 'SUBJ_GRADE', 'G4_BIOLOGY', 'HL');
  PERFORM pg_temp.f_bench(m, NULL, 'world', 'Biology HL, May session', 'mean', 4.5, 2024,
            'ILLUSTRATIVE PLACEHOLDER — replace with the subject grade distribution from '
            'the IB Statistical Bulletin. Note the bulletin gives the full 1-7 distribution, '
            'from which both the mean AND a proper pct_anchor for the 1-7 scale can be computed.');

  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'History guide 2015 (first assessment 2017)';
  m := pg_temp.f_mid(fv, 'SUBJ_GRADE', 'G3_HISTORY', 'HL');
  PERFORM pg_temp.f_bench(m, NULL, 'world', 'History HL, May session', 'mean', 4.6, 2024,
            'ILLUSTRATIVE PLACEHOLDER — not published data.');

  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.owner_tenant_id = app.global_tenant() AND f.code = 'IB_DP'
     AND fv2.label = 'Mathematics: Analysis and Approaches guide 2019 (first assessment 2021)';
  m := pg_temp.f_mid(fv, 'SUBJ_GRADE', 'G5_MATH_AA', 'SL');
  PERFORM pg_temp.f_bench(m, NULL, 'world', 'Mathematics AA SL, May session', 'mean', 4.4, 2024,
            'ILLUSTRATIVE PLACEHOLDER — not published data.');

  -- WHAT IS DELIBERATELY ABSENT, AND WHY IT MATTERS
  -- There is no 'facility' benchmark anywhere in this file. For GCSE or the
  -- Greek Panhellenic exams a per-question or per-topic facility is obtainable;
  -- for the DP it is not. The IB publishes component grade boundaries and prose
  -- subject reports, but no per-question statistics and no per-syllabus-topic
  -- breakdown of candidate performance, worldwide or per school. So a DP
  -- department asking "are we weak on genetics, or weak on data analysis?"
  -- cannot get the answer from the IB at any price. It can only be answered
  -- from the school's own mocks and internal assessments, tagged — which is
  -- what curric.tag and gradebook.item exist for, and is the single strongest
  -- argument for this platform in a DP school.
END $seed$;

-- ===========================================================================
-- 9. A TOPIC TAXONOMY TO TAG INTERNAL ASSESSMENT AGAINST
--
-- Following directly from the note above: since the IB supplies no topic-level
-- outcome data, the topic axis has to come from the school's own marking. The
-- 2023 Biology guide is organised as a 4 x 4 grid — four themes, each visited
-- at four levels of organisation — which is unusually convenient to tag against:
-- a mock question is (theme, level) and a department can see instantly that its
-- students can do A1 (molecules) and cannot do C4 (ecosystems).
--
-- This is rung 1-2 of the tagging ladder in 004_curriculum.sql: one dropdown on
-- the assessment, optionally one per question group. Nothing here is mandatory.
-- ===========================================================================

DO $seed$
DECLARE
  fw uuid; tx uuid; theme uuid; th record; lv record;
BEGIN
  SELECT id INTO fw FROM ref.framework
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP';

  INSERT INTO curric.taxonomy (code, name, axis, framework_id, source_ref)
  VALUES ('IB_DP_BIO_2023_THEMES', 'IB DP Biology (2023 guide) — themes x levels of organisation',
          'topic', fw, 'IB Biology guide, first assessment 2025')
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  SELECT id INTO tx FROM curric.taxonomy
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP_BIO_2023_THEMES';

  FOR th IN SELECT * FROM (VALUES
      ('A', 'Unity and diversity', 1),
      ('B', 'Form and function', 2),
      ('C', 'Interaction and interdependence', 3),
      ('D', 'Continuity and change', 4)) AS t(code, label, ord)
  LOOP
    INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf)
    VALUES (tx, NULL, th.code, 'Theme ' || th.code || ': ' || th.label, th.ord, false)
    ON CONFLICT (taxonomy_id, code) DO NOTHING;
    SELECT id INTO theme FROM curric.tag WHERE taxonomy_id = tx AND code = th.code;

    FOR lv IN SELECT * FROM (VALUES
        (1, 'Molecules'), (2, 'Cells'), (3, 'Organisms'), (4, 'Ecosystems')) AS l(n, label)
    LOOP
      INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf)
      VALUES (tx, theme, th.code || lv.n::text,
              th.code || lv.n::text || ' ' || th.label || ' — ' || lv.label, lv.n, true)
      ON CONFLICT (taxonomy_id, code) DO NOTHING;
    END LOOP;
  END LOOP;
END $seed$;

-- ---------------------------------------------------------------------------
-- Command terms. The IB defines its command terms centrally and maps them to
-- the three assessment objectives; every DP exam question begins with one.
-- Tagging mock questions by command term answers a question no mark total can:
-- "our students can 'outline' and cannot 'evaluate'" — a skill diagnosis that
-- is invisible in a percentage and directly actionable in a lesson.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE fw uuid; tx uuid; parent uuid; g record; t text;
BEGIN
  SELECT id INTO fw FROM ref.framework
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP';

  INSERT INTO curric.taxonomy (code, name, axis, framework_id, source_ref)
  VALUES ('IB_DP_SCI_COMMAND_TERMS', 'IB DP sciences command terms by assessment objective',
          'command_term', fw, 'IB sciences subject guides — command terms appendix')
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  SELECT id INTO tx FROM curric.taxonomy
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_DP_SCI_COMMAND_TERMS';

  FOR g IN SELECT * FROM (VALUES
      ('AO1', 'Objective 1 — demonstrate knowledge: recall and state',
       ARRAY['define','draw','label','list','measure','state']),
      ('AO2', 'Objective 2 — understanding and application',
       ARRAY['annotate','apply','calculate','describe','distinguish','estimate','identify','outline']),
      ('AO3', 'Objective 3 — analysis, evaluation and synthesis',
       ARRAY['analyse','comment','compare','construct','deduce','derive','design','determine',
             'discuss','evaluate','explain','predict','sketch','suggest'])
    ) AS x(code, label, terms)
  LOOP
    INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf)
    VALUES (tx, NULL, g.code, g.label, 0, false)
    ON CONFLICT (taxonomy_id, code) DO NOTHING;
    SELECT id INTO parent FROM curric.tag WHERE taxonomy_id = tx AND code = g.code;

    FOREACH t IN ARRAY g.terms LOOP
      INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf)
      VALUES (tx, parent, g.code || '_' || upper(t), t, 0, true)
      ON CONFLICT (taxonomy_id, code) DO NOTHING;
    END LOOP;
  END LOOP;
END $seed$;

COMMIT;

-- ===========================================================================
-- WHAT A DP SCHOOL STILL HAS TO DO AFTER THIS FILE
--   1. Replace every boundary table whose source_ref says ILLUSTRATIVE with the
--      real "Grade boundaries" document for the session, per subject, per level.
--      Add one new ref.boundary_table row per session; never edit an old one —
--      last year's grades must keep resolving against last year's boundaries.
--   2. Replace the ILLUSTRATIVE benchmark rows with the IB Statistical Bulletin.
--   3. If and when the full worldwide 1-7 distribution is loaded, recompute
--      ref.scale_point.pct_anchor for IB_DP_GRADE_1_7 from it and only then set
--      ref.scale.equating_status = 'anchored'.
--   4. Point each org.teaching_group at the ref.framework_version for the GUIDE
--      it is taught under, not at a calendar year.
-- ===========================================================================
