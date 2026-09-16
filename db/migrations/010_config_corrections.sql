-- ============================================================================
-- 010_config_corrections.sql
--
-- Corrections found by seeding four real grading systems onto 001-009. Every
-- change here was reported as a schema misfit by a framework seed, not invented.
-- Additive only: every value that was legal before is still legal.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. equating_status conflated three different things, which made the
--    cross-framework pooling guard wrong in BOTH directions:
--
--    * The Greek 0-20 axis and raw mark totals are arithmetic scales where
--      equal spacing is exactly correct BY DEFINITION, not an assumption. They
--      read 'assumed_linear' and were needlessly blocked from pooling.
--    * BTEC P/M/D is anchored to a points TARIFF, and GCSE 9-1 is anchored to a
--      population DISTRIBUTION. Both read 'anchored', so a guard checking only
--      that word would happily pool BTEC with GCSE — which is meaningless.
--
--    Only a distribution anchor licenses comparison against a population.
-- ---------------------------------------------------------------------------
ALTER TABLE ref.scale DROP CONSTRAINT scale_equating_status_check;
ALTER TABLE ref.scale ADD CONSTRAINT scale_equating_status_check
  CHECK (equating_status IN (
    'assumed_linear',        -- equal spacing, unverified. Do not pool.
    'linear_by_definition',  -- an arithmetic axis: marks, 0-20, μόρια. Exactly linear.
    'anchored_tariff',       -- spacing from a published points tariff (BTEC).
                             -- Correct within its own system; NOT a population claim.
    'anchored_distribution', -- spacing from a real outcome distribution (JCQ/Ofqual).
                             -- This is what licenses population comparison.
    'anchored',              -- legacy alias for anchored_distribution; kept so
                             -- existing seeds load unchanged.
    'equated'));             -- formally equated to a common latent metric.

COMMENT ON COLUMN ref.scale.equating_status IS
  'Gate for cross-framework pooling. Only linear_by_definition, '
  'anchored_distribution, anchored and equated may be pooled across frameworks. '
  'anchored_tariff is anchored WITHIN its own system only: a BTEC Merit and a '
  'GCSE 6 are not comparable just because both scales carry real numbers.';

-- ---------------------------------------------------------------------------
-- 2. Two national thresholds, not one. GCSE has grade 4 "standard pass" AND
--    grade 5 "strong pass"; reporting the wrong one overstates a school's
--    headline measure by roughly 20 percentage points. Greek has βάση 9.5 and
--    separate ΕΒΕ floors. is_pass as a single boolean cannot hold this.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.scale_threshold (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scale_id      uuid NOT NULL REFERENCES ref.scale(id) ON DELETE CASCADE,
  code          text NOT NULL,          -- 'standard_pass','strong_pass','βάση'
  label         text NOT NULL,
  min_ordinal_rank smallint,            -- for ordinal scales
  min_value     numeric(12,4),          -- for numeric scales
  is_headline   boolean NOT NULL DEFAULT false,
  source_ref    text,
  UNIQUE (scale_id, code),
  CHECK (min_ordinal_rank IS NOT NULL OR min_value IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- 3. Published coefficients must stay literally readable.
--    The Greek μόρια formula is Σ(βαθμός × σ) × 100. Folding the ×100 into each
--    weight is arithmetically exact but destroys auditability: someone checking
--    a row against the ΦΕΚ sees 30 where the document says 0,30.
-- ---------------------------------------------------------------------------
ALTER TABLE ref.conversion_rule
  ADD COLUMN output_multiplier numeric(12,5) NOT NULL DEFAULT 1
    CHECK (output_multiplier > 0);
COMMENT ON COLUMN ref.conversion_rule.output_multiplier IS
  'Applied to the rule output AFTER the weighted sum, so ref.conversion_input.'
  'weight can hold the coefficient exactly as published.';

-- ---------------------------------------------------------------------------
-- 4. A school target and a model prediction are different objects. Conflating
--    them is the most common misunderstanding in English school data.
-- ---------------------------------------------------------------------------
ALTER TABLE ref.measure DROP CONSTRAINT measure_role_check;
ALTER TABLE ref.measure ADD CONSTRAINT measure_role_check
  CHECK (role IN ('observed','derived','awarded','predicted','target','baseline'));

-- ---------------------------------------------------------------------------
-- 5. Benchmarks: a university department cut-off is not a "national" statistic,
--    and every UK national outcome table is a CUMULATIVE PROPORTION at or above
--    a grade, which had no statistic value.
-- ---------------------------------------------------------------------------
ALTER TABLE ref.benchmark DROP CONSTRAINT benchmark_scope_check;
ALTER TABLE ref.benchmark ADD CONSTRAINT benchmark_scope_check
  CHECK (scope IN ('national','regional','world','board','field','school','institution'));

ALTER TABLE ref.benchmark DROP CONSTRAINT benchmark_statistic_check;
ALTER TABLE ref.benchmark ADD CONSTRAINT benchmark_statistic_check
  CHECK (statistic IN ('mean','sd','facility','p25','p50','p75','cutoff','ebe',
                       'base_admission','cum_proportion_at_or_above'));

-- Some benchmarks are grades, not numbers: "the national median A-Level grade
-- is a B" could not be stored at all while value was numeric-only.
ALTER TABLE ref.benchmark ADD COLUMN value_code text;
ALTER TABLE ref.benchmark ALTER COLUMN value DROP NOT NULL;
ALTER TABLE ref.benchmark ADD CONSTRAINT benchmark_has_a_value
  CHECK (value IS NOT NULL OR value_code IS NOT NULL);

-- ---------------------------------------------------------------------------
-- 6. PATHWAYS AND ADMISSION TARGETS
--
--    Greek ΟΜΑΔΑ ΠΡΟΣΑΝΑΤΟΛΙΣΜΟΥ and ΕΠΙΣΤΗΜΟΝΙΚΟ ΠΕΔΙΟ are first-class legal
--    objects with validity periods and an eligibility matrix between them. They
--    were encoded as opaque strings in measure.subject_group_code, so the set of
--    fields was not queryable, not translatable, and the eligibility matrix had
--    nowhere to live.
--
--    ΤΜΗΜΑ matters more. Post-Ν.4777/2021 the department IS the unit of grading
--    configuration: ~500 of them each publish four συντελεστές βαρύτητας and a
--    συντελεστής ΕΒΕ annually. As free text repeated across benchmark rows,
--    nothing enforced that 'Ιατρικής (ΕΚΠΑ)' was spelled the same way twice.
--
--    And it is the single best student-facing feature in the Greek market:
--    plot a student's projected μόρια against their target department's βάση.
--    That needs the department to be a row.
--
--    Named generically: a pathway is also a French série or a German
--    Leistungskurs profile; an admission target is also a UCAS course.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.pathway (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_id uuid NOT NULL REFERENCES ref.framework(id) ON DELETE CASCADE,
  kind         text NOT NULL CHECK (kind IN ('orientation_group','admission_field','track','option_block')),
  code         text NOT NULL,
  label        text NOT NULL,
  valid_from   date,
  valid_to     date,
  UNIQUE (framework_id, kind, code)
);

-- Which orientation group may apply to which field.
CREATE TABLE ref.pathway_eligibility (
  from_pathway_id uuid NOT NULL REFERENCES ref.pathway(id) ON DELETE CASCADE,
  to_pathway_id   uuid NOT NULL REFERENCES ref.pathway(id) ON DELETE CASCADE,
  valid_from      date,
  valid_to        date,
  PRIMARY KEY (from_pathway_id, to_pathway_id)
);

CREATE TABLE ref.institution (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code char(2),
  code         text NOT NULL,
  name         text NOT NULL,
  UNIQUE (country_code, code)
);

CREATE TABLE ref.admission_target (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_id   uuid NOT NULL REFERENCES ref.framework(id) ON DELETE CASCADE,
  institution_id uuid REFERENCES ref.institution(id) ON DELETE SET NULL,
  pathway_id     uuid REFERENCES ref.pathway(id) ON DELETE SET NULL,  -- its επιστημονικό πεδίο
  code           text NOT NULL,          -- the ΥΠΑΙΘ κωδικός σχολής, or a UCAS code
  name           text NOT NULL,
  UNIQUE (framework_id, code)
);
CREATE INDEX admission_target_inst_ix ON ref.admission_target (institution_id);

-- Attach βάσεις and ΕΒΕ to the department instead of to a free-text label.
ALTER TABLE ref.benchmark
  ADD COLUMN admission_target_id uuid REFERENCES ref.admission_target(id) ON DELETE CASCADE;
CREATE INDEX benchmark_target_ix ON ref.benchmark (admission_target_id)
  WHERE admission_target_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 7. ΕΒΕ IS A GATE, NOT A NUMBER.
--
--    ref.benchmark held the value, but nothing expressed the RULE: a candidate
--    whose μ.ο. falls below this floor is ineligible for the department AT ANY
--    μόρια. That is binding admission law and it existed only as prose in
--    source_ref. A projection that ignores it tells a student they are on track
--    for a place they cannot legally be offered.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.admission_gate (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_target_id uuid NOT NULL REFERENCES ref.admission_target(id) ON DELETE CASCADE,
  gate_kind           text NOT NULL CHECK (gate_kind IN
                        ('field_minimum',        -- ΕΒΕ on the μ.ο. of the four subjects
                         'subject_minimum',      -- ΕΒΕ on a single subject
                         'special_subject_minimum', -- ΕΒΕ ειδικού μαθήματος
                         'points_minimum')),     -- an outright μόρια floor
  -- What must clear the gate.
  measure_id          uuid REFERENCES ref.measure(id) ON DELETE CASCADE,
  -- The department's own coefficient (Greek συντελεστής ΕΒΕ, 0.80-1.20). The
  -- effective floor is the national field average x this.
  coefficient         numeric(6,4) CHECK (coefficient IS NULL OR coefficient > 0),
  threshold_value     numeric(12,4),
  year                smallint,
  source_ref          text
);
CREATE UNIQUE INDEX admission_gate_uq ON ref.admission_gate
  (admission_target_id, gate_kind, coalesce(measure_id, admission_target_id), coalesce(year, 0));

-- ---------------------------------------------------------------------------
-- 8. Rebuild the pooling guard on the corrected vocabulary.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS analytics.v_pooling_check;
CREATE VIEW analytics.v_pooling_check AS
SELECT
  v.tenant_id,
  v.student_id,
  count(DISTINCT v.framework_version_id) AS n_frameworks,
  count(DISTINCT v.scale_id)             AS n_scales,
  bool_and(coalesce(s.equating_status, 'assumed_linear') IN
           ('linear_by_definition','anchored_distribution','anchored','equated'))
                                         AS all_scales_poolable,
  count(*) FILTER (WHERE s.equating_status = 'anchored_tariff')   AS n_tariff_responses,
  count(*) FILTER (WHERE coalesce(s.equating_status,'assumed_linear')
                         = 'assumed_linear')                     AS n_unanchored_responses,
  CASE
    WHEN count(DISTINCT v.framework_version_id) <= 1 THEN 'safe_single_framework'
    WHEN bool_and(coalesce(s.equating_status, 'assumed_linear') IN
                  ('linear_by_definition','anchored_distribution','anchored','equated'))
      THEN 'safe_pooled'
    WHEN count(*) FILTER (WHERE s.equating_status = 'anchored_tariff') > 0
      THEN 'unsafe_tariff_scale_present'
    ELSE 'unsafe_display_separately'
  END AS pooling_verdict
FROM analytics.v_response v
LEFT JOIN ref.scale s ON s.id = v.scale_id
GROUP BY v.tenant_id, v.student_id;

-- ---------------------------------------------------------------------------
-- 9. Extend the validator to the new objects.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ref.v_config_errors AS
  SELECT 'scale' AS entity, s.id, s.code AS ref_code,
         'scale has fewer than 2 scale_points' AS problem
  FROM ref.scale s
  WHERE s.kind IN ('ordinal_grade','nominal')
    AND (SELECT count(*) FROM ref.scale_point p WHERE p.scale_id = s.id) < 2
UNION ALL
  SELECT 'scale', s.id, s.code,
         'pct_anchor is not monotonically increasing with ordinal_rank'
  FROM ref.scale s
  WHERE EXISTS (
    SELECT 1 FROM (
      SELECT pct_anchor, lag(pct_anchor) OVER (ORDER BY ordinal_rank) AS prev
      FROM ref.scale_point WHERE scale_id = s.id) q
    WHERE q.prev IS NOT NULL AND q.pct_anchor <= q.prev)
UNION ALL
  SELECT 'boundary_table', bt.id, bt.session_label,
         'boundary rows do not cover the input scale range'
  FROM ref.boundary_table bt
  JOIN ref.scale s ON s.id = bt.in_scale_id
  WHERE s.min_value IS NOT NULL AND s.max_value IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM ref.boundary_row br
                    WHERE br.boundary_table_id = bt.id AND br.bounds @> s.min_value)
UNION ALL
  SELECT 'conversion_rule', r.id, r.method,
         'weighted rule has no positive input weights'
  FROM ref.conversion_rule r
  WHERE r.method IN ('weighted_sum','scaled_sum')
    AND NOT EXISTS (SELECT 1 FROM ref.conversion_input i
                    WHERE i.rule_id = r.id AND i.weight > 0)
UNION ALL
  SELECT 'measure', m.id, m.code, 'measure role=derived but no conversion_rule targets it'
  FROM ref.measure m
  WHERE m.role = 'derived'
    AND NOT EXISTS (SELECT 1 FROM ref.conversion_rule r WHERE r.output_measure_id = m.id)
UNION ALL
  -- A scale claiming a distribution anchor must actually differ from equal
  -- spacing, or the claim is decorative and licenses pooling it has not earned.
  SELECT 'scale', s.id, s.code,
         'equating_status claims a distribution anchor but pct_anchor is exactly equal spacing'
  FROM ref.scale s
  WHERE s.equating_status IN ('anchored_distribution','anchored')
    AND NOT EXISTS (
      SELECT 1 FROM (
        SELECT sp.pct_anchor,
               (sp.ordinal_rank - 1)::numeric
                 / nullif((SELECT count(*) - 1 FROM ref.scale_point x WHERE x.scale_id = s.id), 0) AS linear
        FROM ref.scale_point sp WHERE sp.scale_id = s.id) q
      WHERE abs(q.pct_anchor - q.linear) > 0.001)
UNION ALL
  SELECT 'admission_gate', g.id, g.gate_kind,
         'gate has neither a threshold_value nor a coefficient to derive one from'
  FROM ref.admission_gate g
  WHERE g.threshold_value IS NULL AND g.coefficient IS NULL;

-- v_pooling_check and v_config_errors were just recreated; re-secure them.
SELECT app.secure_all_views();
