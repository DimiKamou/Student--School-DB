-- ============================================================================
-- 003_frameworks.sql — grading systems as CONFIGURATION, not code
--
-- Adding the French Baccalauréat must be INSERTs, never a migration. Every
-- framework here is data: IB MYP, IB DP, Greek Panhellenic, GCSE/A-Level, and
-- a school's own internal scheme are the same five tables with different rows.
--
-- Ownership: a config row is owned either by the GLOBAL tenant (platform-
-- published: IB criteria, AQA boundaries, ΙΕΠ ύλη) or by one school (their own
-- internal scale). A school may READ global rows and its own, never another's.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Framework identity and versioning
-- ---------------------------------------------------------------------------
CREATE TABLE ref.framework (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid NOT NULL DEFAULT app.global_tenant()
                    REFERENCES platform.tenant(id) ON DELETE CASCADE,
  code            text NOT NULL,              -- 'IB_MYP','IB_DP','GR_PANHELLENIC','UK_GCSE'
  name            text NOT NULL,
  country_code    char(2),
  awarding_body   text,                       -- 'IBO','AQA','Pearson','ΥΠΑΙΘ'
  UNIQUE (owner_tenant_id, code)
);

CREATE TABLE ref.framework_version (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_id  uuid NOT NULL REFERENCES ref.framework(id) ON DELETE CASCADE,
  label         text NOT NULL,                -- 'MYP 2022 Sciences', 'AQA 8145 (2016)'
  valid_from    date NOT NULL,
  valid_to      date,
  superseded_by uuid REFERENCES ref.framework_version(id),
  UNIQUE (framework_id, label)
);

ALTER TABLE org.teaching_group
  ADD CONSTRAINT teaching_group_framework_fk
  FOREIGN KEY (framework_version_id) REFERENCES ref.framework_version(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- CONSTRUCT — the pedagogical thing being measured, stable ACROSS versions.
--
-- When the MYP Sciences guide is reissued or AQA reforms a spec, "Criterion B"
-- and "AO3" get brand-new measure rows. Without a stable construct id, every
-- mark recorded under the old guide becomes unjoinable to the new one and the
-- multi-year trend — the entire point of this database — silently resets at
-- every spec change. A school on a 5-year MYP cycle hits this guaranteed.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.construct (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_id uuid NOT NULL REFERENCES ref.framework(id) ON DELETE CASCADE,
  code         text NOT NULL,                 -- 'CRIT_B','AO3','P1'
  label        text NOT NULL,
  kind         text NOT NULL CHECK (kind IN
                 ('criterion','assessment_objective','component','subject','skill','project','overall')),
  -- Cross-framework semantic bucket. Deliberately coarse. This is how "cannot
  -- evaluate under ANY system" becomes askable; it is NOT a claim that MYP
  -- Criterion D equals AQA AO4.
  semantic_axis text CHECK (semantic_axis IN
                 ('knowledge','application','analysis','evaluation','synthesis',
                  'communication','inquiry','reflection','skill_practical','unspecified')),
  UNIQUE (framework_id, code)
);

CREATE TABLE ref.construct_transition (
  from_construct_id uuid NOT NULL REFERENCES ref.construct(id) ON DELETE CASCADE,
  to_construct_id   uuid NOT NULL REFERENCES ref.construct(id) ON DELETE CASCADE,
  transition        text NOT NULL CHECK (transition IN
                      ('same','renamed','split','merged','rescoped','discontinued')),
  -- Comparability across the transition. 'same'/'renamed' => safe to trend.
  -- 'split'/'merged'/'rescoped' => trend only with an explicit caveat.
  trend_safe        boolean NOT NULL DEFAULT false,
  note              text,
  PRIMARY KEY (from_construct_id, to_construct_id)
);

-- ---------------------------------------------------------------------------
-- SCALES
--
-- No n_points column. It would be a hand-typed integer acting as the
-- denominator of every normalisation in the system, with nothing tying it to
-- reality. Instead each scale_point carries its own pct_anchor.
--
-- pct_anchor is the scale point's position on [0,1]. Defaulting it to equal
-- spacing is a MODELLING ASSUMPTION, and equating_status records whether that
-- assumption has ever been checked. GCSE 3→4 is not the same distance as 8→9;
-- a DP 6 and an MYP 6/8 are not the same standard. The schema refuses to
-- pretend otherwise.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.scale (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid NOT NULL DEFAULT app.global_tenant()
                    REFERENCES platform.tenant(id) ON DELETE CASCADE,
  code            text NOT NULL,              -- 'MYP_CRIT_0_8','GR_0_20','GCSE_9_1'
  name            text NOT NULL,
  kind            text NOT NULL CHECK (kind IN
                    ('ratio_marks',     -- raw marks out of a maximum; 0 means zero knowledge
                     'ordinal_grade',   -- 1-7, 9-1, A*-E: ordered labels, spacing unknown
                     'interval_points', -- 0-8 MYP criterion, 0-20 Greek: numeric, treated as interval
                     'nominal',         -- P/M/D, pass/fail: unordered or barely ordered
                     'boolean')),
  min_value       numeric(10,4),              -- for numeric kinds
  max_value       numeric(10,4),
  decimals        smallint NOT NULL DEFAULT 0 CHECK (decimals BETWEEN 0 AND 4),
  higher_is_better boolean NOT NULL DEFAULT true,
  equating_status text NOT NULL DEFAULT 'assumed_linear' CHECK (equating_status IN
                    ('assumed_linear',  -- spacing is a guess; do NOT pool across frameworks
                     'anchored',        -- pct_anchor set from real outcome distributions
                     'equated')),       -- formally equated to a common latent metric
  UNIQUE (owner_tenant_id, code),
  CHECK (kind NOT IN ('ratio_marks','interval_points')
         OR (min_value IS NOT NULL AND max_value IS NOT NULL AND max_value > min_value))
);
COMMENT ON COLUMN ref.scale.equating_status IS
  'Gate for cross-framework pooling. analytics refuses to average normalised '
  'values across two scales unless both are anchored or equated.';

CREATE TABLE ref.scale_point (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scale_id     uuid NOT NULL REFERENCES ref.scale(id) ON DELETE CASCADE,
  code         text NOT NULL,                 -- '7','9','A*','D','Μ.Ο.'
  label        text,
  ordinal_rank smallint NOT NULL,             -- 1 = lowest
  -- Position on [0,1]. Seeded as equal spacing, overwritable with real data.
  pct_anchor   numeric(6,5) NOT NULL CHECK (pct_anchor BETWEEN 0 AND 1),
  is_pass      boolean,
  UNIQUE (scale_id, code),
  UNIQUE (scale_id, ordinal_rank)
);

-- Seed a scale's points with equal spacing. Explicit call, so the assumption is
-- always a deliberate act that leaves equating_status = 'assumed_linear'.
CREATE OR REPLACE FUNCTION ref.seed_scale_points(p_scale_id uuid, p_codes text[])
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer := array_length(p_codes, 1); i integer;
BEGIN
  IF n IS NULL OR n < 2 THEN RAISE EXCEPTION 'a scale needs at least 2 points'; END IF;
  FOR i IN 1..n LOOP
    INSERT INTO ref.scale_point (scale_id, code, ordinal_rank, pct_anchor)
    VALUES (p_scale_id, p_codes[i], i, round(((i - 1)::numeric / (n - 1)), 5))
    ON CONFLICT (scale_id, code) DO UPDATE SET ordinal_rank = EXCLUDED.ordinal_rank;
  END LOOP;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------------
-- MEASURE — a specific scored thing in a specific framework version.
-- 'MYP 2022 Sciences Criterion B, scored 0-8' is one row.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.measure (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  framework_version_id uuid NOT NULL REFERENCES ref.framework_version(id) ON DELETE CASCADE,
  construct_id         uuid NOT NULL REFERENCES ref.construct(id) ON DELETE RESTRICT,
  scale_id             uuid NOT NULL REFERENCES ref.scale(id) ON DELETE RESTRICT,
  code                 text NOT NULL,
  label                text NOT NULL,
  role                 text NOT NULL CHECK (role IN
                         ('observed',   -- marked directly by a teacher
                          'derived',    -- computed from other measures
                          'awarded',    -- issued by an external authority
                          'predicted')),
  -- MYP criteria differ per subject group; AQA specs differ per tier.
  subject_group_code   text,
  level_code           text,
  parent_measure_id    uuid REFERENCES ref.measure(id) ON DELETE CASCADE,
  weight               numeric(8,5) CHECK (weight IS NULL OR weight >= 0),
  sort_order           smallint NOT NULL DEFAULT 0,
  CONSTRAINT measure_weight_ck CHECK (weight IS NULL OR weight >= 0)
);
CREATE UNIQUE INDEX measure_code_uq ON ref.measure
  (framework_version_id, code, coalesce(subject_group_code,''), coalesce(level_code,''));
CREATE INDEX measure_fv_ix ON ref.measure (framework_version_id);
CREATE INDEX measure_construct_ix ON ref.measure (construct_id);

-- ---------------------------------------------------------------------------
-- BOUNDARIES — raw total to reported grade.
--
-- Stored as numrange with an exclusion constraint. Ranges cannot overlap, and
-- half-marks and decimal UMS anchors work by construction. The obvious
-- alternative (in_min/in_max integers plus a "next.in_min > prev.in_max + 1"
-- gap check) silently returns NULL for a mark of 44.5.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.boundary_table (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid NOT NULL DEFAULT app.global_tenant()
                    REFERENCES platform.tenant(id) ON DELETE CASCADE,
  measure_id      uuid REFERENCES ref.measure(id) ON DELETE CASCADE,
  in_scale_id     uuid NOT NULL REFERENCES ref.scale(id) ON DELETE RESTRICT,
  out_scale_id    uuid NOT NULL REFERENCES ref.scale(id) ON DELETE RESTRICT,
  -- Boundaries move every session. 'May 2025 TZ1', 'June 2024', 'Πανελλαδικές 2025'.
  session_label   text NOT NULL,
  valid_from      date NOT NULL,
  supersedes_id   uuid REFERENCES ref.boundary_table(id),
  source_ref      text,                        -- the published document this came from
  is_provisional  boolean NOT NULL DEFAULT false,
  UNIQUE (owner_tenant_id, measure_id, session_label)
);

CREATE TABLE ref.boundary_row (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  boundary_table_id  uuid NOT NULL REFERENCES ref.boundary_table(id) ON DELETE CASCADE,
  out_code           text NOT NULL,
  bounds             numrange NOT NULL,
  EXCLUDE USING gist (boundary_table_id WITH =, bounds WITH &&),
  UNIQUE (boundary_table_id, out_code)
);

CREATE OR REPLACE FUNCTION ref.apply_boundary(p_table_id uuid, p_value numeric)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT br.out_code FROM ref.boundary_row br
  WHERE br.boundary_table_id = p_table_id AND br.bounds @> p_value
$$;

-- ---------------------------------------------------------------------------
-- CONVERSION RULES — how derived measures are computed.
-- Declarative so a new country is data. Deliberately a SMALL vocabulary:
-- an unbounded expression language would be an unqueryable soup.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.conversion_rule (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id   uuid NOT NULL DEFAULT app.global_tenant()
                      REFERENCES platform.tenant(id) ON DELETE CASCADE,
  output_measure_id uuid NOT NULL REFERENCES ref.measure(id) ON DELETE CASCADE,
  method            text NOT NULL CHECK (method IN
                      ('sum',            -- MYP: criteria A+B+C+D -> 0..32
                       'weighted_sum',   -- DP components; Greek μόρια
                       'mean',
                       'best_fit',       -- MYP period level: teacher judgement over evidence
                       'boundary',       -- apply a boundary table to an input
                       'passthrough',
                       'scaled_sum')),   -- weighted_sum then boundary
  boundary_table_id uuid REFERENCES ref.boundary_table(id) ON DELETE SET NULL,
  -- Effective dating so the 2016 and 2021 Greek formulae coexist.
  valid_from        date NOT NULL DEFAULT '1900-01-01',
  valid_to          date,
  eval_order        smallint NOT NULL DEFAULT 100,
  -- If false, the rule emits a partial result flagged low-confidence rather
  -- than refusing. A teacher mid-term has 2 of 4 criteria and still wants a view.
  requires_all_inputs boolean NOT NULL DEFAULT false,
  note              text
);
CREATE INDEX conversion_rule_out_ix ON ref.conversion_rule (output_measure_id, eval_order);

CREATE TABLE ref.conversion_input (
  rule_id          uuid NOT NULL REFERENCES ref.conversion_rule(id) ON DELETE CASCADE,
  input_measure_id uuid NOT NULL REFERENCES ref.measure(id) ON DELETE CASCADE,
  weight           numeric(8,5) NOT NULL DEFAULT 1,
  is_required      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (rule_id, input_measure_id)
);

-- ---------------------------------------------------------------------------
-- BENCHMARKS — external reference distributions.
--
-- This table is what lets the system detect a UNIFORMLY WEAK COHORT. Every
-- within-class residual model centres on the class mean, so a class that is
-- badly taught on EVERYTHING produces residuals summing to zero and raises no
-- flag at all. Only an external anchor — national mean, published facility,
-- ΕΒΕ, a department βάση — can see that. It is the single biggest threat to
-- the thesis claim, so it gets a first-class table and is joined in analytics.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.benchmark (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_tenant_id uuid NOT NULL DEFAULT app.global_tenant()
                    REFERENCES platform.tenant(id) ON DELETE CASCADE,
  measure_id    uuid REFERENCES ref.measure(id) ON DELETE CASCADE,
  scale_id      uuid REFERENCES ref.scale(id) ON DELETE CASCADE,
  scope         text NOT NULL CHECK (scope IN ('national','regional','world','board','field','school')),
  scope_label   text,
  statistic     text NOT NULL CHECK (statistic IN
                  ('mean','sd','facility','p25','p50','p75','cutoff','ebe','base_admission')),
  value         numeric(12,4) NOT NULL,
  n_candidates  integer,
  year          smallint,
  source_ref    text,
  CONSTRAINT benchmark_target_ck CHECK (measure_id IS NOT NULL OR scale_id IS NOT NULL)
);
CREATE UNIQUE INDEX benchmark_uq ON ref.benchmark
  (owner_tenant_id, coalesce(measure_id, app.global_tenant()),
   coalesce(scale_id, app.global_tenant()), scope,
   coalesce(scope_label,''), statistic, coalesce(year, 0));

-- ---------------------------------------------------------------------------
-- Localised labels. A Greek MYP school marks against IB descriptors in English
-- and reports to parents in Greek. One text column per descriptor cannot do
-- both, and translating by hand in the UI loses the authoritative wording.
-- ---------------------------------------------------------------------------
CREATE TABLE ref.translation (
  entity_kind text NOT NULL CHECK (entity_kind IN
                ('measure','construct','scale_point','tag','framework','band_descriptor')),
  entity_id   uuid NOT NULL,
  locale      text NOT NULL,
  field       text NOT NULL DEFAULT 'label',
  value       text NOT NULL,
  PRIMARY KEY (entity_kind, entity_id, locale, field)
);

-- Band descriptors (MYP level descriptors, mark scheme bands) live here so the
-- marking screen can show the wording inline — the single biggest speed-up in
-- criterion marking.
CREATE TABLE ref.measure_band (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  measure_id   uuid NOT NULL REFERENCES ref.measure(id) ON DELETE CASCADE,
  bounds       numrange NOT NULL,             -- e.g. [7,8] for MYP level 7-8
  label        text,
  descriptor   text NOT NULL,
  EXCLUDE USING gist (measure_id WITH =, bounds WITH &&)
);

-- ---------------------------------------------------------------------------
-- Configuration validator. Run in CI and after any seed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ref.v_config_errors AS
  -- ordinal scale with fewer than two points
  SELECT 'scale' AS entity, s.id, s.code AS ref_code,
         'scale has fewer than 2 scale_points' AS problem
  FROM ref.scale s
  WHERE s.kind IN ('ordinal_grade','nominal')
    AND (SELECT count(*) FROM ref.scale_point p WHERE p.scale_id = s.id) < 2
UNION ALL
  -- pct_anchor must be monotone in ordinal_rank, or normalisation inverts
  SELECT 'scale', s.id, s.code,
         'pct_anchor is not monotonically increasing with ordinal_rank'
  FROM ref.scale s
  WHERE EXISTS (
    SELECT 1 FROM (
      SELECT pct_anchor, lag(pct_anchor) OVER (ORDER BY ordinal_rank) AS prev
      FROM ref.scale_point WHERE scale_id = s.id) q
    WHERE q.prev IS NOT NULL AND q.pct_anchor <= q.prev)
UNION ALL
  -- boundary table not covering its input scale's full range
  SELECT 'boundary_table', bt.id, bt.session_label,
         'boundary rows do not cover the input scale range'
  FROM ref.boundary_table bt
  JOIN ref.scale s ON s.id = bt.in_scale_id
  WHERE s.min_value IS NOT NULL AND s.max_value IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM ref.boundary_row br
                    WHERE br.boundary_table_id = bt.id AND br.bounds @> s.min_value)
UNION ALL
  -- a weighted rule whose weights are all zero produces a silent zero
  SELECT 'conversion_rule', r.id, r.method,
         'weighted rule has no positive input weights'
  FROM ref.conversion_rule r
  WHERE r.method IN ('weighted_sum','scaled_sum')
    AND NOT EXISTS (SELECT 1 FROM ref.conversion_input i
                    WHERE i.rule_id = r.id AND i.weight > 0)
UNION ALL
  -- derived measure with no rule to derive it
  SELECT 'measure', m.id, m.code, 'measure role=derived but no conversion_rule targets it'
  FROM ref.measure m
  WHERE m.role = 'derived'
    AND NOT EXISTS (SELECT 1 FROM ref.conversion_rule r WHERE r.output_measure_id = m.id);
