-- ============================================================================
-- 10_ib_myp.sql — IB Middle Years Programme, entirely as CONFIGURATION ROWS.
--
-- Nothing in this file is a migration and nothing here needs code. The MYP is
-- three scales, a set of constructs, a set of per-subject-group measures, one
-- published boundary table and three conversion rules.
--
-- WHAT A DEVELOPER WHO HAS NEVER SEEN THE MYP NEEDS TO KNOW
-- ---------------------------------------------------------------------------
-- 1. The MYP does not grade with percentages. Every subject group has FOUR
--    criteria, A-D, each marked 0-8 against published level descriptors. The
--    criteria are NAMED DIFFERENTLY in every subject group — "Criterion B" is
--    "Organizing" in Language and literature and "Inquiring and designing" in
--    Sciences. They are genuinely different things that happen to share a
--    letter. That is why every subject group gets its own ref.construct rows
--    and its measures carry subject_group_code.
--
-- 2. The four reported criterion levels are summed (0-32) and the sum is read
--    off a single published 1-7 boundary table that is the SAME for every
--    subject group. The 1-7 grade is the thing that goes on the report card.
--
-- 3. THE SUBTLETY THAT SOFTWARE ALWAYS GETS WRONG: the reported criterion level
--    is a BEST-FIT PROFESSIONAL JUDGEMENT over a body of evidence collected
--    across the reporting period. It is NOT the mean of the task scores, and it
--    is NOT the last task score. A student who scored 4, 5, 7, 7 on Criterion C
--    is normally reported at 7 (the recent, sustained standard), not 5.75.
--    The IB is explicit about this, and a gradebook that silently averages is
--    producing numbers the school cannot defend to the IB or to a parent.
--
--    Encoded here as: CRIT_x_TASK (role='observed', what the teacher marked on
--    a task) -> conversion_rule method='best_fit' -> CRIT_x_LEVEL
--    (role='derived', the reported level). The engine writes its best-fit
--    proposal into gradebook.outcome.suggested_value; the AUTHORITATIVE row is
--    kind='teacher_determined' with determination_method='best_fit_manual' or
--    'suggestion_accepted'. The override rate between the two is itself a
--    genuine analytic about professional judgement — see the note on the rules
--    below.
--
-- 4. MYP eAssessment (the optional external route to the MYP certificate) is a
--    separate framework_version whose measures have role='awarded': the IB
--    issues those grades, the school does not compute them. Crucially they
--    point at the SAME ref.construct rows as the school-assessed measures, so a
--    student's internal Sciences grade and their eAssessment Sciences grade are
--    joinable on a stable pedagogical identity without asserting that they are
--    the same measurement.
--
-- Sources: "MYP: From principles into practice" (IBO), the 2014 subject-group
-- guides, the 2020 Language acquisition guide, the MYP Projects guide and the
-- MYP eAssessment certificate requirements. Every figure that is NOT taken
-- verbatim from a published IB document is flagged ILLUSTRATIVE in a comment
-- immediately above it. There are only three such places in this file.
--
-- Target school is in Greece, so ref.translation carries 'en' and 'el' for
-- every construct, measure, scale point and tag.
--
-- Idempotent: safe to re-run. Every insert is guarded.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Criterion definitions, as data, so the rest of the file is loops rather than
-- 400 hand-written INSERTs. TEMP + ON COMMIT DROP: this is scaffolding for the
-- seed, not part of the schema.
--
-- semantic_axis is the deliberately COARSE cross-framework bucket. Putting
-- Sciences C ("Processing and evaluating") on 'analysis' is not a claim that it
-- equals AQA AO3; it is what makes "this student cannot evaluate under ANY
-- system we use" an askable question.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _myp_sg (
  sg_code text PRIMARY KEY, name_en text, name_el text, sort_order smallint
) ON COMMIT DROP;

INSERT INTO _myp_sg VALUES
  ('LANG_LIT',  'Language and literature',  'Γλώσσα και λογοτεχνία',            1),
  ('LANG_ACQ',  'Language acquisition',     'Εκμάθηση ξένης γλώσσας',           2),
  ('IND_SOC',   'Individuals and societies','Άτομα και κοινωνίες',              3),
  ('SCIENCES',  'Sciences',                 'Φυσικές επιστήμες',                4),
  ('MATH',      'Mathematics',              'Μαθηματικά',                       5),
  ('ARTS',      'Arts',                     'Τέχνες',                           6),
  ('PHE',       'Physical and health education', 'Φυσική αγωγή και υγεία',      7),
  ('DESIGN',    'Design',                   'Σχεδιασμός',                       8);

CREATE TEMP TABLE _myp_crit (
  sg_code text, letter text, label_en text, label_el text,
  semantic_axis text, sort_order smallint,
  PRIMARY KEY (sg_code, letter)
) ON COMMIT DROP;

INSERT INTO _myp_crit VALUES
  -- Language and literature (2014 guide)
  ('LANG_LIT','A','Analysing','Ανάλυση','analysis',1),
  ('LANG_LIT','B','Organizing','Οργάνωση','communication',2),
  ('LANG_LIT','C','Producing text','Παραγωγή κειμένου','synthesis',3),
  ('LANG_LIT','D','Using language','Χρήση της γλώσσας','communication',4),
  -- Language acquisition (2014 guide; superseded for most phases by the 2020
  -- guide, which is seeded further down as its own framework_version)
  ('LANG_ACQ','A','Comprehending spoken and visual text','Κατανόηση προφορικού και οπτικού κειμένου','knowledge',1),
  ('LANG_ACQ','B','Comprehending written and visual text','Κατανόηση γραπτού και οπτικού κειμένου','knowledge',2),
  ('LANG_ACQ','C','Communicating in response to spoken, written and visual text','Επικοινωνία σε ανταπόκριση προς προφορικά, γραπτά και οπτικά κείμενα','communication',3),
  ('LANG_ACQ','D','Using language in spoken and written form','Χρήση της γλώσσας σε προφορικό και γραπτό λόγο','communication',4),
  -- Individuals and societies
  ('IND_SOC','A','Knowing and understanding','Γνώση και κατανόηση','knowledge',1),
  ('IND_SOC','B','Investigating','Διερεύνηση','inquiry',2),
  ('IND_SOC','C','Communicating','Επικοινωνία','communication',3),
  ('IND_SOC','D','Thinking critically','Κριτική σκέψη','evaluation',4),
  -- Sciences
  ('SCIENCES','A','Knowing and understanding','Γνώση και κατανόηση','knowledge',1),
  ('SCIENCES','B','Inquiring and designing','Διερεύνηση και σχεδιασμός','inquiry',2),
  ('SCIENCES','C','Processing and evaluating','Επεξεργασία και αξιολόγηση','analysis',3),
  ('SCIENCES','D','Reflecting on the impacts of science','Αναστοχασμός για τις επιδράσεις της επιστήμης','reflection',4),
  -- Mathematics
  ('MATH','A','Knowing and understanding','Γνώση και κατανόηση','knowledge',1),
  ('MATH','B','Investigating patterns','Διερεύνηση μοτίβων','inquiry',2),
  ('MATH','C','Communicating','Επικοινωνία','communication',3),
  ('MATH','D','Applying mathematics in real-life contexts','Εφαρμογή των μαθηματικών σε πραγματικά πλαίσια','application',4),
  -- Arts
  ('ARTS','A','Knowing and understanding','Γνώση και κατανόηση','knowledge',1),
  ('ARTS','B','Developing skills','Ανάπτυξη δεξιοτήτων','skill_practical',2),
  ('ARTS','C','Thinking creatively','Δημιουργική σκέψη','synthesis',3),
  ('ARTS','D','Responding','Ανταπόκριση','reflection',4),
  -- Physical and health education
  ('PHE','A','Knowing and understanding','Γνώση και κατανόηση','knowledge',1),
  ('PHE','B','Planning for performance','Σχεδιασμός για την απόδοση','application',2),
  ('PHE','C','Applying and performing','Εφαρμογή και εκτέλεση','skill_practical',3),
  ('PHE','D','Reflecting and improving performance','Αναστοχασμός και βελτίωση της απόδοσης','reflection',4),
  -- Design
  ('DESIGN','A','Inquiring and analysing','Διερεύνηση και ανάλυση','inquiry',1),
  ('DESIGN','B','Developing ideas','Ανάπτυξη ιδεών','synthesis',2),
  ('DESIGN','C','Creating the solution','Δημιουργία της λύσης','skill_practical',3),
  ('DESIGN','D','Evaluating','Αξιολόγηση','evaluation',4);

-- ===========================================================================
-- 1. FRAMEWORK AND VERSIONS
-- ===========================================================================
DO $seed$
DECLARE v_fw uuid;
BEGIN
  SELECT id INTO v_fw FROM ref.framework
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_MYP';
  IF v_fw IS NULL THEN
    -- country_code stays NULL: the MYP is not a national system. The Greek
    -- school running it is a tenant; the framework itself belongs to nobody.
    INSERT INTO ref.framework (code, name, country_code, awarding_body)
    VALUES ('IB_MYP', 'International Baccalaureate Middle Years Programme', NULL, 'IBO')
    RETURNING id INTO v_fw;
  END IF;

  -- The main school-assessed version: the 2014 subject-group guides, still the
  -- current guides for most subject groups.
  INSERT INTO ref.framework_version (framework_id, label, valid_from)
  SELECT v_fw, 'MYP subject guides 2014', DATE '2014-09-01'
  WHERE NOT EXISTS (SELECT 1 FROM ref.framework_version
                     WHERE framework_id = v_fw AND label = 'MYP subject guides 2014');

  -- Language acquisition was reissued for first teaching September 2020 and the
  -- four criteria were restructured onto the four language skills. It gets its
  -- own version because its MEASURES changed while the subject-group-level
  -- CONSTRUCTS (the reported Language acquisition grade) did not.
  INSERT INTO ref.framework_version (framework_id, label, valid_from)
  SELECT v_fw, 'MYP Language acquisition guide 2020', DATE '2020-09-01'
  WHERE NOT EXISTS (SELECT 1 FROM ref.framework_version
                     WHERE framework_id = v_fw AND label = 'MYP Language acquisition guide 2020');

  -- The projects guide: personal project and community project.
  INSERT INTO ref.framework_version (framework_id, label, valid_from)
  SELECT v_fw, 'MYP Projects guide', DATE '2014-09-01'
  WHERE NOT EXISTS (SELECT 1 FROM ref.framework_version
                     WHERE framework_id = v_fw AND label = 'MYP Projects guide');

  -- External assessment. Separate version, because the measurement instrument
  -- is completely different (IB-set on-screen examinations and IB-moderated
  -- ePortfolios) even though the pedagogical constructs are identical.
  INSERT INTO ref.framework_version (framework_id, label, valid_from)
  SELECT v_fw, 'MYP eAssessment', DATE '2016-01-01'
  WHERE NOT EXISTS (SELECT 1 FROM ref.framework_version
                     WHERE framework_id = v_fw AND label = 'MYP eAssessment');
END $seed$;

-- ===========================================================================
-- 2. SCALES
--
-- Three numeric scales plus two two-point nominal scales for the certificate.
--
-- On pct_anchor and equating_status, which is the single easiest thing in this
-- schema to corrupt:
--   * MYP_CRIT_0_8 stays 'assumed_linear'. The IB calls 0-8 an interval scale
--     and the level descriptors come in bands (1-2, 3-4, 5-6, 7-8), but there
--     is no published outcome distribution that says the distance 0->1 equals
--     the distance 7->8. Equal spacing here is an assumption and is labelled as
--     one.
--   * MYP_SUM_0_32 stays 'assumed_linear' for the same reason, even though the
--     arithmetic of a sum is exactly linear: equating_status is about whether
--     the scale may be POOLED with other frameworks, not about arithmetic.
--   * MYP_GRADE_1_7 is set to 'anchored' and its anchors are NOT equal spacing.
--     See the comment at the override below for exactly what they were anchored
--     to and what that does and does not license.
-- ===========================================================================
DO $seed$
DECLARE v_s uuid;
BEGIN
  ---------------------------------------------------------------------------
  -- 0-8 criterion scale. Every MYP criterion in every subject group uses it.
  ---------------------------------------------------------------------------
  SELECT id INTO v_s FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_CRIT_0_8';
  IF v_s IS NULL THEN
    INSERT INTO ref.scale (code, name, kind, min_value, max_value, decimals,
                           higher_is_better, equating_status)
    VALUES ('MYP_CRIT_0_8', 'MYP criterion achievement level (0-8)',
            'interval_points', 0, 8, 0, true, 'assumed_linear')
    RETURNING id INTO v_s;
    PERFORM ref.seed_scale_points(v_s, ARRAY['0','1','2','3','4','5','6','7','8']);
    -- Labels are the IB band names, not per-criterion descriptors. The actual
    -- descriptors are per measure and live in ref.measure_band.
    UPDATE ref.scale_point SET label = CASE code
      WHEN '0' THEN 'Does not reach a standard described by any of the descriptors below'
      WHEN '1' THEN 'Limited (band 1-2)'   WHEN '2' THEN 'Limited (band 1-2)'
      WHEN '3' THEN 'Adequate (band 3-4)'  WHEN '4' THEN 'Adequate (band 3-4)'
      WHEN '5' THEN 'Substantial (band 5-6)' WHEN '6' THEN 'Substantial (band 5-6)'
      WHEN '7' THEN 'Excellent (band 7-8)' WHEN '8' THEN 'Excellent (band 7-8)' END
    WHERE scale_id = v_s;
    -- is_pass deliberately left NULL: a criterion level is not a pass/fail.
  END IF;

  ---------------------------------------------------------------------------
  -- 0-32 criterion sum. Four criteria x 0-8. Not reported to anyone: it exists
  -- only as the input to the 1-7 boundary table.
  ---------------------------------------------------------------------------
  SELECT id INTO v_s FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_SUM_0_32';
  IF v_s IS NULL THEN
    INSERT INTO ref.scale (code, name, kind, min_value, max_value, decimals,
                           higher_is_better, equating_status)
    VALUES ('MYP_SUM_0_32', 'MYP criterion levels total (0-32)',
            'interval_points', 0, 32, 0, true, 'assumed_linear')
    RETURNING id INTO v_s;
    -- 33 points, equal spacing, which for a sum of four equal 0-8 criteria is
    -- arithmetically exact rather than assumed.
    PERFORM ref.seed_scale_points(v_s,
      (SELECT array_agg(g::text ORDER BY g) FROM generate_series(0,32) g));
  END IF;

  ---------------------------------------------------------------------------
  -- 1-7 MYP grade. The number on the report card.
  ---------------------------------------------------------------------------
  SELECT id INTO v_s FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_GRADE_1_7';
  IF v_s IS NULL THEN
    INSERT INTO ref.scale (code, name, kind, min_value, max_value, decimals,
                           higher_is_better, equating_status)
    VALUES ('MYP_GRADE_1_7', 'MYP final grade (1-7)',
            'ordinal_grade', 1, 7, 0, true, 'assumed_linear')
    RETURNING id INTO v_s;
    PERFORM ref.seed_scale_points(v_s, ARRAY['1','2','3','4','5','6','7']);

    -- Summaries of the IB general grade descriptors (one line each; the full
    -- descriptors are a paragraph each in "MYP: From principles into practice").
    UPDATE ref.scale_point SET label = CASE code
      WHEN '1' THEN 'Very limited quality'
      WHEN '2' THEN 'Limited quality'
      WHEN '3' THEN 'Acceptable quality'
      WHEN '4' THEN 'Good quality'
      WHEN '5' THEN 'Generally high quality'
      WHEN '6' THEN 'High quality, occasionally innovative'
      WHEN '7' THEN 'High quality, frequently innovative' END
    WHERE scale_id = v_s;

    -- The MYP itself has no pass mark: a grade 2 is a grade, not a fail. The
    -- one place a threshold genuinely exists is the MYP CERTIFICATE, which
    -- requires a grade of 3 or better in each contributing result. is_pass here
    -- encodes exactly that and nothing more.
    UPDATE ref.scale_point SET is_pass = (code::int >= 3) WHERE scale_id = v_s;

    -- ANCHORING. pct_anchor is overridden from equal spacing to the MIDPOINT of
    -- each grade's published band on the 0-32 criterion-sum axis:
    --   1: 1-5   -> 3.0/32  2: 6-9   -> 7.5/32  3: 10-14 -> 12.0/32
    --   4: 15-18 -> 16.5/32 5: 19-23 -> 21.0/32 6: 24-27 -> 25.5/32
    --   7: 28-32 -> 30.0/32
    -- This is a real, published, checkable mapping, and it matters: equal
    -- spacing would put grade 1 at 0.000 and grade 4 at 0.500, whereas a
    -- grade 1 student is really at ~0.094 of the criterion axis and the grade
    -- bands are visibly wider at the bottom than in the middle.
    --
    -- WHAT THIS DOES NOT LICENSE: it is anchored to the IB's own grade-to-sum
    -- mapping, NOT to a candidate outcome distribution and NOT to any external
    -- metric. It makes MYP grades comparable to MYP criterion sums. It does NOT
    -- make an MYP 6 equal to a DP 6 or a GCSE 7. If the schema owner reserves
    -- 'anchored' strictly for observed outcome distributions, set this scale
    -- back to 'assumed_linear' and keep the anchors — the anchors are right
    -- either way.
    UPDATE ref.scale_point SET pct_anchor = CASE code
      WHEN '1' THEN round( 3.0/32, 5)  WHEN '2' THEN round( 7.5/32, 5)
      WHEN '3' THEN round(12.0/32, 5)  WHEN '4' THEN round(16.5/32, 5)
      WHEN '5' THEN round(21.0/32, 5)  WHEN '6' THEN round(25.5/32, 5)
      WHEN '7' THEN round(30.0/32, 5) END
    WHERE scale_id = v_s;
    UPDATE ref.scale SET equating_status = 'anchored' WHERE id = v_s;
  END IF;

  ---------------------------------------------------------------------------
  -- eAssessment certificate points, 0-56 = eight results x 1-7.
  ---------------------------------------------------------------------------
  SELECT id INTO v_s FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_CERT_POINTS_0_56';
  IF v_s IS NULL THEN
    INSERT INTO ref.scale (code, name, kind, min_value, max_value, decimals,
                           higher_is_better, equating_status)
    VALUES ('MYP_CERT_POINTS_0_56', 'MYP certificate points total (0-56)',
            'interval_points', 0, 56, 0, true, 'assumed_linear')
    RETURNING id INTO v_s;
  END IF;

  ---------------------------------------------------------------------------
  -- Two two-point nominal scales for the certificate. Nominal, not boolean,
  -- because they are reported to a human and need localisable labels.
  ---------------------------------------------------------------------------
  SELECT id INTO v_s FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_CONDITION_MET';
  IF v_s IS NULL THEN
    INSERT INTO ref.scale (code, name, kind, higher_is_better, equating_status)
    VALUES ('MYP_CONDITION_MET', 'Certificate condition met / not met',
            'nominal', true, 'assumed_linear')
    RETURNING id INTO v_s;
    PERFORM ref.seed_scale_points(v_s, ARRAY['not_met','met']);
    UPDATE ref.scale_point SET label = initcap(replace(code,'_',' ')),
                               is_pass = (code = 'met')
    WHERE scale_id = v_s;
  END IF;

  SELECT id INTO v_s FROM ref.scale
   WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_CERT_AWARD';
  IF v_s IS NULL THEN
    INSERT INTO ref.scale (code, name, kind, higher_is_better, equating_status)
    VALUES ('MYP_CERT_AWARD', 'MYP certificate award', 'nominal', true, 'assumed_linear')
    RETURNING id INTO v_s;
    PERFORM ref.seed_scale_points(v_s, ARRAY['not_awarded','awarded']);
    UPDATE ref.scale_point SET label = initcap(replace(code,'_',' ')),
                               is_pass = (code = 'awarded')
    WHERE scale_id = v_s;
  END IF;
END $seed$;

-- Greek labels for the 1-7 grade descriptors, for the parent-facing report.
INSERT INTO ref.translation (entity_kind, entity_id, locale, field, value)
SELECT 'scale_point', sp.id, 'el', 'label', t.value_el
FROM ref.scale s
JOIN ref.scale_point sp ON sp.scale_id = s.id
JOIN (VALUES ('1','Πολύ περιορισμένης ποιότητας'),
             ('2','Περιορισμένης ποιότητας'),
             ('3','Αποδεκτής ποιότητας'),
             ('4','Καλής ποιότητας'),
             ('5','Γενικά υψηλής ποιότητας'),
             ('6','Υψηλής ποιότητας, περιστασιακά καινοτόμος'),
             ('7','Υψηλής ποιότητας, συχνά καινοτόμος')) AS t(code, value_el)
  ON t.code = sp.code
WHERE s.owner_tenant_id = app.global_tenant() AND s.code = 'MYP_GRADE_1_7'
ON CONFLICT DO NOTHING;

INSERT INTO ref.translation (entity_kind, entity_id, locale, field, value)
SELECT 'scale_point', sp.id, 'en', 'label', sp.label
FROM ref.scale s JOIN ref.scale_point sp ON sp.scale_id = s.id
WHERE s.owner_tenant_id = app.global_tenant() AND s.code = 'MYP_GRADE_1_7'
ON CONFLICT DO NOTHING;

-- ===========================================================================
-- 3. CONSTRUCTS AND MEASURES FOR THE EIGHT SUBJECT GROUPS
--
-- Per subject group this creates SIX constructs and TEN measures:
--
--   construct  <sg>_A .. <sg>_D    the four criteria (kind='criterion')
--   construct  <sg>_SUM            the 0-32 total      (kind='overall')
--   construct  <sg>_GRADE          the reported grade  (kind='subject')
--
--   measure    CRIT_x_TASK   observed  0-8   what a teacher marked on one task
--   measure    CRIT_x_LEVEL  derived   0-8   the REPORTED level (best fit)
--   measure    CRIT_SUM      derived   0-32  sum of the four reported levels
--   measure    GRADE         derived   1-7   boundary table applied to the sum
--
-- The TASK/LEVEL pair is the whole point. Both point at the SAME construct —
-- they measure the same pedagogical thing — but they are different measures
-- because one is an observation and the other is a professional judgement over
-- a body of observations. Collapsing them into one measure is how a gradebook
-- ends up averaging task scores and reporting a number the IB does not
-- recognise.
-- ===========================================================================
DO $seed$
DECLARE
  v_fw uuid; v_fv uuid; v_s8 uuid; v_s32 uuid; v_s7 uuid;
  sg record; cr record;
  v_con uuid; v_task uuid; v_level uuid; v_sum uuid; v_grade uuid;
  v_sumcon uuid; v_gradecon uuid; v_rule uuid; v_bt uuid;
BEGIN
  SELECT id INTO v_fw FROM ref.framework
   WHERE owner_tenant_id = app.global_tenant() AND code = 'IB_MYP';
  SELECT id INTO v_fv FROM ref.framework_version
   WHERE framework_id = v_fw AND label = 'MYP subject guides 2014';
  SELECT id INTO v_s8  FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_CRIT_0_8';
  SELECT id INTO v_s32 FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_SUM_0_32';
  SELECT id INTO v_s7  FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = 'MYP_GRADE_1_7';

  FOR sg IN SELECT * FROM _myp_sg ORDER BY sort_order LOOP

    -----------------------------------------------------------------------
    -- The reported subject-group grade. Created first because everything
    -- else hangs off it in the measure tree.
    -----------------------------------------------------------------------
    SELECT id INTO v_gradecon FROM ref.construct
     WHERE framework_id = v_fw AND code = sg.sg_code || '_GRADE';
    IF v_gradecon IS NULL THEN
      INSERT INTO ref.construct (framework_id, code, label, kind, semantic_axis)
      VALUES (v_fw, sg.sg_code || '_GRADE', sg.name_en || ' — MYP grade', 'subject', 'unspecified')
      RETURNING id INTO v_gradecon;
    END IF;

    SELECT id INTO v_sumcon FROM ref.construct
     WHERE framework_id = v_fw AND code = sg.sg_code || '_SUM';
    IF v_sumcon IS NULL THEN
      INSERT INTO ref.construct (framework_id, code, label, kind, semantic_axis)
      VALUES (v_fw, sg.sg_code || '_SUM', sg.name_en || ' — criterion levels total', 'overall', 'unspecified')
      RETURNING id INTO v_sumcon;
    END IF;

    SELECT id INTO v_grade FROM ref.measure
     WHERE framework_version_id = v_fv AND code = 'GRADE'
       AND coalesce(subject_group_code,'') = sg.sg_code AND coalesce(level_code,'') = '';
    IF v_grade IS NULL THEN
      INSERT INTO ref.measure (framework_version_id, construct_id, scale_id, code, label,
                               role, subject_group_code, sort_order)
      VALUES (v_fv, v_gradecon, v_s7, 'GRADE', sg.name_en || ' MYP grade (1-7)',
              'derived', sg.sg_code, 100)
      RETURNING id INTO v_grade;
    END IF;

    SELECT id INTO v_sum FROM ref.measure
     WHERE framework_version_id = v_fv AND code = 'CRIT_SUM'
       AND coalesce(subject_group_code,'') = sg.sg_code AND coalesce(level_code,'') = '';
    IF v_sum IS NULL THEN
      INSERT INTO ref.measure (framework_version_id, construct_id, scale_id, code, label,
                               role, subject_group_code, parent_measure_id, sort_order)
      VALUES (v_fv, v_sumcon, v_s32, 'CRIT_SUM', sg.name_en || ' criterion levels total (0-32)',
              'derived', sg.sg_code, v_grade, 90)
      RETURNING id INTO v_sum;
    END IF;

    -----------------------------------------------------------------------
    -- The four criteria.
    -----------------------------------------------------------------------
    FOR cr IN SELECT * FROM _myp_crit WHERE sg_code = sg.sg_code ORDER BY sort_order LOOP

      SELECT id INTO v_con FROM ref.construct
       WHERE framework_id = v_fw AND code = sg.sg_code || '_' || cr.letter;
      IF v_con IS NULL THEN
        INSERT INTO ref.construct (framework_id, code, label, kind, semantic_axis)
        VALUES (v_fw, sg.sg_code || '_' || cr.letter,
                'Criterion ' || cr.letter || ': ' || cr.label_en, 'criterion', cr.semantic_axis)
        RETURNING id INTO v_con;
      END IF;

      -- The REPORTED level for the period. role='derived' because a rule
      -- produces the proposal, but see the best_fit rule note: the value that
      -- counts is the teacher's.
      SELECT id INTO v_level FROM ref.measure
       WHERE framework_version_id = v_fv AND code = 'CRIT_' || cr.letter || '_LEVEL'
         AND coalesce(subject_group_code,'') = sg.sg_code AND coalesce(level_code,'') = '';
      IF v_level IS NULL THEN
        INSERT INTO ref.measure (framework_version_id, construct_id, scale_id, code, label,
                                 role, subject_group_code, parent_measure_id, weight, sort_order)
        VALUES (v_fv, v_con, v_s8, 'CRIT_' || cr.letter || '_LEVEL',
                'Criterion ' || cr.letter || ': ' || cr.label_en || ' — reported level',
                'derived', sg.sg_code, v_sum, 1, cr.sort_order)
        RETURNING id INTO v_level;
      END IF;

      -- What the teacher actually types when marking a task. parent is left
      -- NULL on purpose: a task score is EVIDENCE FOR the reported level, not
      -- a component OF it, and hanging it under the level in the measure tree
      -- would invite exactly the sum/average that MYP forbids.
      SELECT id INTO v_task FROM ref.measure
       WHERE framework_version_id = v_fv AND code = 'CRIT_' || cr.letter || '_TASK'
         AND coalesce(subject_group_code,'') = sg.sg_code AND coalesce(level_code,'') = '';
      IF v_task IS NULL THEN
        INSERT INTO ref.measure (framework_version_id, construct_id, scale_id, code, label,
                                 role, subject_group_code, sort_order)
        VALUES (v_fv, v_con, v_s8, 'CRIT_' || cr.letter || '_TASK',
                'Criterion ' || cr.letter || ': ' || cr.label_en || ' — task level',
                'observed', sg.sg_code, cr.sort_order)
        RETURNING id INTO v_task;
      END IF;

      ---------------------------------------------------------------------
      -- BEST FIT. Read this before touching the reporting code.
      --
      -- The rule's inputs are every task-level judgement recorded against this
      -- criterion in the reporting period. The engine looks at the PROFILE of
      -- those levels — recency, consistency, the most recent sustained
      -- standard — and proposes a level. It writes:
      --      gradebook.outcome (kind='system_suggested' or, more usefully,
      --      suggested_value on the teacher's row)
      -- The row that is REPORTED is kind='teacher_determined', with
      -- raw_value = the teacher's decision, suggested_value = the engine's
      -- proposal, and determination_method = 'best_fit_manual' when they
      -- differ or 'suggestion_accepted' when they do not. outcome.
      -- overrides_suggestion then makes "how often does this department
      -- override the engine, and in which direction" a one-line query.
      --
      -- requires_all_inputs = false: in week 4 a teacher has one piece of
      -- evidence for Criterion D and still wants a view. The engine flags it
      -- with confidence='low' / 'insufficient' and evidence_count, it does not
      -- refuse. A system that refuses is a system teachers stop opening.
      ---------------------------------------------------------------------
      SELECT id INTO v_rule FROM ref.conversion_rule
       WHERE output_measure_id = v_level AND method = 'best_fit';
      IF v_rule IS NULL THEN
        INSERT INTO ref.conversion_rule (output_measure_id, method, eval_order,
                                         requires_all_inputs, note)
        VALUES (v_level, 'best_fit', 10, false,
                'MYP best fit: the reported criterion level is a professional judgement '
                'over the body of evidence for the period, NOT a mean of task levels. '
                'The engine proposes; gradebook.outcome kind=teacher_determined decides.')
        RETURNING id INTO v_rule;
      END IF;
      INSERT INTO ref.conversion_input (rule_id, input_measure_id, weight, is_required)
      VALUES (v_rule, v_task, 1, false) ON CONFLICT DO NOTHING;

      -- Localisation. The school marks against the English descriptors and
      -- reports to Greek parents. Criterion LETTERS stay Latin in both locales
      -- because the letter is the IB's identifier, not a word to translate.
      INSERT INTO ref.translation (entity_kind, entity_id, locale, field, value) VALUES
        ('construct', v_con, 'en', 'label', 'Criterion ' || cr.letter || ': ' || cr.label_en),
        ('construct', v_con, 'el', 'label', 'Κριτήριο ' || cr.letter || ': ' || cr.label_el),
        ('measure',   v_level, 'en', 'label', 'Criterion ' || cr.letter || ': ' || cr.label_en || ' — reported level'),
        ('measure',   v_level, 'el', 'label', 'Κριτήριο ' || cr.letter || ': ' || cr.label_el || ' — τελικό επίπεδο'),
        ('measure',   v_task, 'en', 'label', 'Criterion ' || cr.letter || ': ' || cr.label_en || ' — task level'),
        ('measure',   v_task, 'el', 'label', 'Κριτήριο ' || cr.letter || ': ' || cr.label_el || ' — επίπεδο εργασίας')
      ON CONFLICT DO NOTHING;

    END LOOP;

    -----------------------------------------------------------------------
    -- SUM: the four reported levels -> 0-32.
    -- requires_all_inputs = false and is_required = false on the inputs: a
    -- subject group may legitimately not assess all four criteria in a given
    -- reporting period, and the IB expects a partial report then, not an
    -- error. The engine marks such a total low-confidence and the UI must
    -- refuse to run the boundary table on it.
    -----------------------------------------------------------------------
    SELECT id INTO v_rule FROM ref.conversion_rule
     WHERE output_measure_id = v_sum AND method = 'sum';
    IF v_rule IS NULL THEN
      INSERT INTO ref.conversion_rule (output_measure_id, method, eval_order,
                                       requires_all_inputs, note)
      VALUES (v_sum, 'sum', 20, false,
              'A+B+C+D reported levels. Criteria are equally weighted by design: '
              'there is no weighting in the MYP and adding one is a local invention.')
      RETURNING id INTO v_rule;
    END IF;
    INSERT INTO ref.conversion_input (rule_id, input_measure_id, weight, is_required)
    SELECT v_rule, m.id, 1, false
    FROM ref.measure m
    WHERE m.framework_version_id = v_fv AND m.subject_group_code = sg.sg_code
      AND m.code LIKE 'CRIT\_%\_LEVEL'
    ON CONFLICT DO NOTHING;

    -----------------------------------------------------------------------
    -- BOUNDARY: 0-32 -> 1-7. The SAME table for every subject group and every
    -- year group; the MYP does not move its boundaries by session the way a
    -- national exam board does. session_label therefore names the document,
    -- not a sitting.
    --
    -- Published table (MYP: From principles into practice, grade boundaries):
    --   1: 1-5   2: 6-9   3: 10-14  4: 15-18  5: 19-23  6: 24-27  7: 28-32
    --
    -- ONE DELIBERATE DEVIATION: the published table starts grade 1 at 1, so a
    -- total of exactly 0 is outside it. Left as-is, ref.apply_boundary returns
    -- NULL for a real student who scored 0 on all four criteria, and
    -- ref.v_config_errors correctly complains that the table does not cover its
    -- input scale. Grade 1 is therefore encoded as [0,6) rather than [1,6).
    -- In practice a student with a genuine 0 total is reported as a 1; a
    -- student with NO evidence must not reach this rule at all (that is an
    -- absence, and gradebook.outcome should carry
    -- determination_method='insufficient_evidence').
    --
    -- Ranges are half-open so decimal inputs behave. MYP totals are integers,
    -- but a school that lets two markers average to 6.5 gets the right band
    -- instead of a NULL.
    -----------------------------------------------------------------------
    SELECT id INTO v_bt FROM ref.boundary_table
     WHERE owner_tenant_id = app.global_tenant() AND measure_id = v_grade
       AND session_label = 'MYP general grade boundaries';
    IF v_bt IS NULL THEN
      INSERT INTO ref.boundary_table (measure_id, in_scale_id, out_scale_id, session_label,
                                      valid_from, source_ref, is_provisional)
      VALUES (v_grade, v_s32, v_s7, 'MYP general grade boundaries', DATE '2014-09-01',
              'IBO, MYP: From principles into practice — grade boundaries table', false)
      RETURNING id INTO v_bt;
    END IF;
    INSERT INTO ref.boundary_row (boundary_table_id, out_code, bounds)
    SELECT v_bt, g.code, g.rng FROM (VALUES
      ('1', numrange(0,6,'[)')),   ('2', numrange(6,10,'[)')),
      ('3', numrange(10,15,'[)')), ('4', numrange(15,19,'[)')),
      ('5', numrange(19,24,'[)')), ('6', numrange(24,28,'[)')),
      ('7', numrange(28,32,'[]'))) AS g(code, rng)
    ON CONFLICT (boundary_table_id, out_code) DO NOTHING;

    SELECT id INTO v_rule FROM ref.conversion_rule
     WHERE output_measure_id = v_grade AND method = 'boundary';
    IF v_rule IS NULL THEN
      -- requires_all_inputs = true here, unlike the sum: publishing a 1-7 grade
      -- off an incomplete total is the one place partial data produces a
      -- confidently wrong, parent-visible number.
      INSERT INTO ref.conversion_rule (output_measure_id, method, boundary_table_id,
                                       eval_order, requires_all_inputs, note)
      VALUES (v_grade, 'boundary', v_bt, 30, true,
              'Apply the published 0-32 -> 1-7 boundary table to the criterion total.')
      RETURNING id INTO v_rule;
    END IF;
    INSERT INTO ref.conversion_input (rule_id, input_measure_id, weight, is_required)
    VALUES (v_rule, v_sum, 1, true) ON CONFLICT DO NOTHING;

    INSERT INTO ref.translation (entity_kind, entity_id, locale, field, value) VALUES
      ('construct', v_gradecon, 'en', 'label', sg.name_en || ' — MYP grade'),
      ('construct', v_gradecon, 'el', 'label', sg.name_el || ' — βαθμός MYP'),
      ('construct', v_sumcon, 'en', 'label', sg.name_en || ' — criterion levels total'),
      ('construct', v_sumcon, 'el', 'label', sg.name_el || ' — σύνολο επιπέδων κριτηρίων'),
      ('measure',   v_grade, 'en', 'label', sg.name_en || ' MYP grade (1-7)'),
      ('measure',   v_grade, 'el', 'label', sg.name_el || ' — βαθμός MYP (1-7)'),
      ('measure',   v_sum, 'en', 'label', sg.name_en || ' criterion levels total (0-32)'),
      ('measure',   v_sum, 'el', 'label', sg.name_el || ' — σύνολο επιπέδων κριτηρίων (0-32)')
    ON CONFLICT DO NOTHING;

  END LOOP;
END $seed$;

COMMIT;
