-- ============================================================================
-- 13_uk_gcse_alevel.sql — England/Wales/NI school qualifications, as CONFIGURATION
--
--   GCSE (9-1) · GCE A-Level (A*-E) · BTEC (P/M/D/D*) · Cambridge International
--   · Key Stage 3 (a SCHOOL'S OWN scheme) · baselines and target grades
--
-- Everything below is INSERTs into ref.*, curric.* and one platform.tenant row.
-- No DDL. No migration. No code path. If this file runs clean and
-- ref.v_config_errors returns nothing, then the claim holds for the single
-- messiest qualification landscape in Europe: four awarding bodies selling
-- different specifications for the same subject, boundaries that move every
-- June, two tiers of entry with different maximum grades, a vocational
-- qualification that accumulates unit points instead of marking a paper, and
-- every school running its own invented Key Stage 3 scheme underneath all of it.
--
-- ---------------------------------------------------------------------------
-- HOW UK SCHOOL QUALIFICATIONS ACTUALLY WORK (for the developer who has not
-- sat one)
-- ---------------------------------------------------------------------------
-- AGE 16 — GCSE. Nine to eleven separate subject qualifications, each bought
-- from an AWARDING BODY (AQA, Pearson Edexcel, OCR, WJEC/Eduqas). A school may
-- and routinely does use different boards for different subjects, and a
-- department may switch board between cohorts. Since the 2015-2017 reform,
-- GCSEs in England are graded 9 to 1 (9 highest) plus U (ungraded); 4 is the
-- "standard pass", 5 the "strong pass". Wales and Northern Ireland kept A*-G.
--
-- AGE 18 — GCE A-Level. Graded A*, A, B, C, D, E plus U. Since the 2015 reform
-- these are LINEAR in England: everything is examined at the end of two years,
-- and the AS qualification is decoupled and no longer contributes. University
-- offers are expressed in A-Level grades ("AAB"), so a predicted grade is a
-- financially consequential number, which is why predicted/target measures are
-- first-class in this file rather than a school spreadsheet.
--
-- VOCATIONAL — BTEC (Pearson). NOT an exam-and-boundary system at all. A
-- qualification is a set of UNITS, each graded Pass/Merit/Distinction (or U),
-- each carrying a point tariff proportional to its size in guided learning
-- hours. Unit points are summed and the total is cut into Pass / Merit /
-- Distinction / Distinction*. Most units are internally assessed and
-- externally verified, so there is no national raw-mark scale to anchor to.
--
-- INTERNATIONAL — Cambridge International (CAIE) sells IGCSE and International
-- A-Level worldwide. The grade LABELS are the same letters and digits as the
-- English ones. The candidate populations are not remotely the same. This file
-- therefore gives Cambridge its OWN scale rows; see section 1 for why that is
-- the single most important modelling decision here.
--
-- AGES 11-14 — KEY STAGE 3. There is no national qualification, no national
-- scale and, since National Curriculum levels were abolished in 2014, no
-- national vocabulary at all. Every school invented its own scheme. That is
-- not an edge case to be tolerated; it is the majority of the marks a
-- secondary school records. Section 9 seeds one, school-owned, as the template.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FILE IS TRYING TO PROVE, SPECIFICALLY
-- ---------------------------------------------------------------------------
-- 1. "A GCSE 6 and an MYP 6/8 are not the same standard." Equal spacing on an
--    ordinal grade scale is a lie that propagates into every cross-framework
--    average. Sections 1.1 and 1.2 replace equal spacing on the two English
--    national scales with pct_anchor values derived from the NATIONAL
--    CUMULATIVE OUTCOME DISTRIBUTION, and only those two scales are marked
--    'anchored'. Every other scale here stays 'assumed_linear' and says why.
-- 2. "The same subject is not the same exam." AQA 8300, Edexcel 1MA1 and OCR
--    J560 are all "GCSE Mathematics". They have different paper totals and
--    different boundaries; a raw 65 is a grade 4 on one and a grade 3 on
--    another. Section 6 seeds all three so that the difference is a JOIN, not
--    a footnote.
-- 3. "Foundation tier caps at grade 5." Not as a validation rule in code — as
--    the plain absence of grade 6-9 rows in the Foundation boundary table. A
--    grade the config cannot represent cannot be awarded by accident.
--
-- ---------------------------------------------------------------------------
-- HONESTY MARKERS USED IN THIS FILE  (read this before trusting any number)
-- ---------------------------------------------------------------------------
--   source_ref LIKE 'ILLUSTRATIVE%'  -> plausible, correctly SHAPED, and NOT
--                                       published fact. Replace before any
--                                       report goes to a parent or a student.
--   source_ref LIKE 'APPROX%'        -> a real published quantity, recalled to
--                                       within a point or two, not transcribed
--                                       from the source document. Good enough
--                                       to anchor a scale; not good enough to
--                                       quote.
--   is_provisional = true            -> the same warning, on a boundary table.
--
-- EVERY grade boundary in this file is ILLUSTRATIVE. Real GCSE and A-Level
-- boundaries are set after marking, published per board per specification per
-- tier per series, and cannot be derived, predicted, or carried over from last
-- June. Guessing one and presenting it as fact is the most damaging thing this
-- file could do, so it does not do it anywhere.
--
-- The national outcome distributions in sections 1.1, 1.2 and 12 are marked
-- APPROX: they are the JCQ/Ofqual summer-2019 England cumulative outcomes as
-- recalled, accurate to roughly a percentage point, NOT transcribed from the
-- JCQ tables. They are good enough to make grade spacing far less wrong than
-- equal spacing, which is the bar this file has to clear. They are not good
-- enough to publish. Section 13 says exactly how to replace them.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Session-local helpers. pg_temp dies with this psql session, so this file
-- adds nothing permanent to the database. They exist to keep the seed
-- idempotent and to keep the DATA — which is the actual documentation —
-- readable instead of drowned in boilerplate.
--
-- Every helper is owner-tenant-aware, because unlike the IB files this one has
-- to seed BOTH platform-published config (AQA, Pearson, OCR, Cambridge) and
-- one school's private config (Key Stage 3), through the same code path.
-- ---------------------------------------------------------------------------

CREATE FUNCTION pg_temp.f_tenant(p_slug text, p_name text, p_country text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM platform.tenant WHERE slug = p_slug;
  IF v IS NULL THEN
    INSERT INTO platform.tenant (slug, name, country_code, timezone, default_locale, plan)
    VALUES (p_slug, p_name, p_country, 'Europe/London', 'en', 'standard')
    RETURNING id INTO v;
  END IF;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_scale(p_code text, p_name text, p_kind text,
                                p_min numeric DEFAULT NULL, p_max numeric DEFAULT NULL,
                                p_dec int DEFAULT 0, p_owner uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; o uuid := coalesce(p_owner, app.global_tenant());
BEGIN
  SELECT id INTO v FROM ref.scale WHERE owner_tenant_id = o AND code = p_code;
  IF v IS NULL THEN
    INSERT INTO ref.scale (owner_tenant_id, code, name, kind, min_value, max_value, decimals)
    VALUES (o, p_code, p_name, p_kind, p_min, p_max, p_dec)
    RETURNING id INTO v;
  END IF;
  RETURN v;
END $fn$;

-- Override one scale point's position on the normalised [0,1] axis. Calling
-- this is the deliberate act of replacing the equal-spacing ASSUMPTION with
-- evidence; ref.scale.equating_status must then be moved off 'assumed_linear'
-- by hand, with a comment citing the evidence. Nothing here does that for you.
CREATE FUNCTION pg_temp.f_anchor(p_scale uuid, p_code text, p_pct numeric,
                                 p_label text DEFAULT NULL, p_pass boolean DEFAULT NULL)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE ref.scale_point
     SET pct_anchor = p_pct,
         label      = coalesce(p_label, label),
         is_pass    = coalesce(p_pass, is_pass)
   WHERE scale_id = p_scale AND code = p_code;
$fn$;

CREATE FUNCTION pg_temp.f_framework(p_code text, p_name text, p_country text,
                                    p_body text, p_owner uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; o uuid := coalesce(p_owner, app.global_tenant());
BEGIN
  INSERT INTO ref.framework (owner_tenant_id, code, name, country_code, awarding_body)
  VALUES (o, p_code, p_name, p_country, p_body)
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  SELECT id INTO v FROM ref.framework WHERE owner_tenant_id = o AND code = p_code;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_version(p_fw uuid, p_label text, p_from date, p_to date DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  INSERT INTO ref.framework_version (framework_id, label, valid_from, valid_to)
  VALUES (p_fw, p_label, p_from, p_to)
  ON CONFLICT (framework_id, label) DO NOTHING;
  SELECT id INTO v FROM ref.framework_version WHERE framework_id = p_fw AND label = p_label;
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

-- Resolve a measure by its natural key (matching the expression index on
-- ref.measure). subject_group_code and level_code are part of that key, which
-- is exactly what makes "the same paper, Foundation tier" a different row from
-- "the same paper, Higher tier" without a second table.
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
DECLARE v uuid; v_con uuid; v_scale uuid; v_fw uuid; v_owner uuid;
BEGIN
  v := pg_temp.f_mid(p_fv, p_code, p_subj, p_level);
  IF v IS NOT NULL THEN RETURN v; END IF;

  SELECT fv.framework_id, f.owner_tenant_id INTO v_fw, v_owner
    FROM ref.framework_version fv JOIN ref.framework f ON f.id = fv.framework_id
   WHERE fv.id = p_fv;

  SELECT id INTO v_con FROM ref.construct WHERE framework_id = v_fw AND code = p_construct_code;
  IF v_con IS NULL THEN
    RAISE EXCEPTION 'unknown construct % for framework %', p_construct_code, v_fw;
  END IF;

  -- A school framework may build on platform scales, on its own, or on both.
  -- Prefer its own when the code collides, so a school can shadow a published
  -- scale without the platform noticing or caring.
  SELECT id INTO v_scale FROM ref.scale
   WHERE code = p_scale_code AND owner_tenant_id IN (v_owner, app.global_tenant())
   ORDER BY (owner_tenant_id = app.global_tenant())
   LIMIT 1;
  IF v_scale IS NULL THEN RAISE EXCEPTION 'unknown scale %', p_scale_code; END IF;

  INSERT INTO ref.measure (framework_version_id, construct_id, scale_id, code, label,
                           role, subject_group_code, level_code, weight, sort_order,
                           parent_measure_id)
  VALUES (p_fv, v_con, v_scale, p_code, p_label, p_role, p_subj, p_level,
          p_weight, p_sort, p_parent)
  RETURNING id INTO v;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_rule(p_out uuid, p_method text, p_bt uuid DEFAULT NULL,
                               p_note text DEFAULT NULL, p_requires_all boolean DEFAULT false,
                               p_from date DEFAULT DATE '1900-01-01', p_to date DEFAULT NULL,
                               p_owner uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; o uuid := coalesce(p_owner, app.global_tenant());
BEGIN
  SELECT id INTO v FROM ref.conversion_rule
   WHERE output_measure_id = p_out AND method = p_method AND valid_from = p_from;
  IF v IS NULL THEN
    INSERT INTO ref.conversion_rule (owner_tenant_id, output_measure_id, method,
                                     boundary_table_id, note, requires_all_inputs,
                                     valid_from, valid_to)
    VALUES (o, p_out, p_method, p_bt, p_note, p_requires_all, p_from, p_to)
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
                             p_provisional boolean DEFAULT true, p_owner uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; v_in uuid; v_out uuid; o uuid := coalesce(p_owner, app.global_tenant());
BEGIN
  SELECT id INTO v FROM ref.boundary_table
   WHERE owner_tenant_id = o AND measure_id = p_measure AND session_label = p_session;
  IF v IS NOT NULL THEN RETURN v; END IF;

  SELECT id INTO v_in FROM ref.scale
   WHERE code = p_in_scale AND owner_tenant_id IN (o, app.global_tenant())
   ORDER BY (owner_tenant_id = app.global_tenant()) LIMIT 1;
  SELECT id INTO v_out FROM ref.scale
   WHERE code = p_out_scale AND owner_tenant_id IN (o, app.global_tenant())
   ORDER BY (owner_tenant_id = app.global_tenant()) LIMIT 1;
  IF v_in IS NULL OR v_out IS NULL THEN
    RAISE EXCEPTION 'boundary table % : unknown scale (% -> %)', p_session, p_in_scale, p_out_scale;
  END IF;

  INSERT INTO ref.boundary_table (owner_tenant_id, measure_id, in_scale_id, out_scale_id,
                                  session_label, valid_from, source_ref, is_provisional)
  VALUES (o, p_measure, v_in, v_out, p_session, p_from, p_src, p_provisional)
  RETURNING id INTO v;
  RETURN v;
END $fn$;

-- One row of a boundary table. bounds is a numrange, so a half-mark or a
-- decimal scaled total lands in a band by construction, and the GiST exclusion
-- constraint makes an overlapping boundary set impossible to seed by accident.
-- Half-open '[)' throughout: the published boundary mark is the LOWEST mark
-- that earns the grade, which is exactly the closed lower bound.
CREATE FUNCTION pg_temp.f_brow(p_bt uuid, p_out text, p_lo numeric, p_hi numeric)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ref.boundary_row
                  WHERE boundary_table_id = p_bt AND out_code = p_out) THEN
    INSERT INTO ref.boundary_row (boundary_table_id, out_code, bounds)
    VALUES (p_bt, p_out, numrange(p_lo, p_hi, '[)'));
  END IF;
END $fn$;

-- Build a whole boundary set from the published shape: an ordered array of
-- out_codes from the BOTTOM up, and the array of lower cut-offs for every code
-- except the lowest (which always starts at the bottom of the input scale).
-- This is exactly how a board publishes it: one row of numbers per spec, per
-- tier, per series.
CREATE FUNCTION pg_temp.f_bset(p_bt uuid, p_codes text[], p_cuts numeric[],
                               p_floor numeric, p_ceiling numeric)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE n int := array_length(p_codes, 1); i int;
BEGIN
  IF array_length(p_cuts, 1) <> n - 1 THEN
    RAISE EXCEPTION 'f_bset: % codes needs % cut-offs, got %',
      n, n - 1, array_length(p_cuts, 1);
  END IF;
  PERFORM pg_temp.f_brow(p_bt, p_codes[1], p_floor, p_cuts[1]);
  FOR i IN 2..n-1 LOOP
    PERFORM pg_temp.f_brow(p_bt, p_codes[i], p_cuts[i-1], p_cuts[i]);
  END LOOP;
  -- The top band runs one unit past the maximum so that a perfect score is
  -- inside it: numrange '[)' excludes its upper bound.
  PERFORM pg_temp.f_brow(p_bt, p_codes[n], p_cuts[n-1], p_ceiling);
END $fn$;

CREATE FUNCTION pg_temp.f_bench(p_measure uuid, p_scale uuid, p_scope text, p_scope_label text,
                                p_stat text, p_value numeric, p_year int, p_src text,
                                p_n int DEFAULT NULL, p_owner uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE o uuid := coalesce(p_owner, app.global_tenant());
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM ref.benchmark
     WHERE owner_tenant_id = o
       AND measure_id IS NOT DISTINCT FROM p_measure
       AND scale_id   IS NOT DISTINCT FROM p_scale
       AND scope = p_scope
       AND coalesce(scope_label,'') = coalesce(p_scope_label,'')
       AND statistic = p_stat
       AND coalesce(year, 0) = coalesce(p_year, 0)) THEN
    INSERT INTO ref.benchmark (owner_tenant_id, measure_id, scale_id, scope, scope_label,
                               statistic, value, year, source_ref, n_candidates)
    VALUES (o, p_measure, p_scale, p_scope, p_scope_label, p_stat, p_value, p_year, p_src, p_n);
  END IF;
END $fn$;

CREATE FUNCTION pg_temp.f_tr(p_kind text, p_id uuid, p_locale text, p_value text,
                             p_field text DEFAULT 'label')
RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO ref.translation (entity_kind, entity_id, locale, field, value)
  VALUES (p_kind, p_id, p_locale, p_field, p_value)
  ON CONFLICT (entity_kind, entity_id, locale, field) DO UPDATE SET value = EXCLUDED.value;
$fn$;

CREATE FUNCTION pg_temp.f_band(p_measure uuid, p_lo numeric, p_hi numeric,
                               p_label text, p_descriptor text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ref.measure_band
                  WHERE measure_id = p_measure AND bounds = numrange(p_lo, p_hi, '[)')) THEN
    INSERT INTO ref.measure_band (measure_id, bounds, label, descriptor)
    VALUES (p_measure, numrange(p_lo, p_hi, '[)'), p_label, p_descriptor);
  END IF;
END $fn$;

-- ===========================================================================
-- 0. THE DEMO SCHOOL TENANT
--
-- Needed for section 8 (a school-owned Key Stage 3 scheme) and section 11's
-- school-scope benchmark. Everything else in this file is platform-published
-- and owned by app.global_tenant(). Idempotent on slug, so re-running this
-- seed never creates a second school.
-- ===========================================================================

DO $seed$
DECLARE t uuid;
BEGIN
  t := pg_temp.f_tenant('greenfield-academy', 'Greenfield Academy (demo school)', 'GB');
  -- (no NOTICE: the seed stays quiet so rebuild output stays readable)
END $seed$;

-- ===========================================================================
-- 1. SCALES
--
-- This is the section that matters most in this file, so it is worth being
-- explicit about what a pct_anchor IS and what it is NOT.
--
-- pct_anchor is the grade's position on a normalised [0,1] axis. It is what
-- gradebook.tg_result_normalise() writes into result.pct whenever a value is
-- recorded as an ordinal CODE rather than a mark, and it is therefore the
-- number that every cross-subject and cross-framework comparison in this
-- platform is ultimately computed from. Get it wrong and nothing downstream
-- can be right.
--
-- Equal spacing — what ref.seed_scale_points() gives you — says a GCSE 9 is
-- exactly as far above an 8 as a 2 is above a 1. That is false, and it is
-- false in a DIRECTION: the top grades are much rarer than equal spacing
-- implies, so equal spacing systematically UNDER-rewards a 9 and OVER-rewards
-- a 2. Averaged across a cohort it flatters weak performance and flattens
-- strong performance, which is the precise opposite of what a school needs.
--
-- What is defensible instead: place each grade at the POPULATION PERCENTILE of
-- the middle of its band. If 4.5% of candidates get a 9 and 11.5% get an 8 or
-- better, then a 9 sits at the midpoint of the top 4.5% of the distribution,
-- i.e. at percentile 1 - 0.045/2 = 0.9775. This does not claim to be an
-- interval scale in any psychometric sense — it is not equated, and it is not
-- marked 'equated'. It claims only this: the grades are positioned by how rare
-- they actually are. That is a strictly better claim than equal spacing, and
-- it is the reason ref.scale.equating_status has three values and not two.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1.1 GCSE 9-1 — ANCHORED
--
-- DISTRIBUTION USED (state it here, in the file, next to the numbers it
-- produced, so nobody ever has to reverse-engineer where an anchor came from):
--
--   JCQ/Ofqual summer 2019, England, all entries, all ages. Cumulative
--   percentage awarded each grade OR ABOVE. Summer 2019 is used deliberately
--   rather than a more recent series: 2020 and 2021 were centre/teacher
--   assessed, 2022 and 2023 were staged returns to pre-pandemic standards, and
--   only a normal series gives a distribution that a school can sensibly judge
--   itself against. RECALLED TO ABOUT A PERCENTAGE POINT — see the APPROX
--   marker convention in the header, and section 12 for how to replace it.
--
--     grade 9 or above    4.5%          grade 4 or above   67.0%
--     grade 8 or above   11.5%          grade 3 or above   81.5%
--     grade 7 or above   20.7%          grade 2 or above   91.0%
--     grade 6 or above   32.0%          grade 1 or above   98.0%
--     grade 5 or above   47.0%          U                   2.0%
--
-- ANCHOR = 1 - (cum_above(this grade) + cum_above(next grade up)) / 2, i.e.
-- the percentile of the MIDDLE of the grade's band. Worked, for grade 4:
--     cum_above(4) = 0.670, cum_above(5) = 0.470
--     anchor(4)    = 1 - (0.670 + 0.470)/2 = 1 - 0.570 = 0.430
-- Equal spacing would have put grade 4 at 0.4444 and grade 2 at 0.2222; the
-- anchored values are 0.430 and 0.1375. The bottom of the scale is where equal
-- spacing is most wrong, which is exactly where the students the product
-- exists to find are sitting.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE s uuid;
BEGIN
  s := pg_temp.f_scale('UK_GCSE_9_1', 'GCSE grade 9-1 (England, reformed)', 'ordinal_grade');
  -- rank 1 = lowest. U is a scale point here because U is an AWARDED outcome:
  -- the candidate sat the exam and was ungraded. It is emphatically NOT the
  -- same thing as absent or not submitted, which are gradebook.result.status
  -- values and carry no pct at all.
  PERFORM ref.seed_scale_points(s, ARRAY['U','1','2','3','4','5','6','7','8','9']);

  PERFORM pg_temp.f_anchor(s, 'U', 0.01000, 'Ungraded',    false);
  PERFORM pg_temp.f_anchor(s, '1', 0.05500, 'Grade 1',     false);
  PERFORM pg_temp.f_anchor(s, '2', 0.13750, 'Grade 2',     false);
  PERFORM pg_temp.f_anchor(s, '3', 0.25750, 'Grade 3',     false);
  PERFORM pg_temp.f_anchor(s, '4', 0.43000, 'Grade 4 (standard pass)', true);
  PERFORM pg_temp.f_anchor(s, '5', 0.60500, 'Grade 5 (strong pass)',   true);
  PERFORM pg_temp.f_anchor(s, '6', 0.73650, 'Grade 6',     true);
  PERFORM pg_temp.f_anchor(s, '7', 0.83900, 'Grade 7',     true);
  PERFORM pg_temp.f_anchor(s, '8', 0.92000, 'Grade 8',     true);
  PERFORM pg_temp.f_anchor(s, '9', 0.97750, 'Grade 9',     true);

  -- is_pass = true from grade 4 up records the STANDARD PASS, because that is
  -- the threshold in statutory school performance tables for English and maths.
  -- It cannot also record the STRONG PASS at grade 5, which is the threshold
  -- used by the Basics measure and by most sixth-form entry requirements.
  -- One boolean, two national thresholds: see the misfit note in section 12.
  -- Any report that means 5+ must filter on ordinal_rank >= 6 or on
  -- pct_anchor >= 0.605, never on is_pass.

  UPDATE ref.scale SET equating_status = 'anchored' WHERE id = s;
  -- ANCHORED, and this is the only justification: pct_anchor above was
  -- computed from the England 2019 cumulative outcome distribution recorded in
  -- the comment above and re-seeded as ref.benchmark rows in section 11. It is
  -- NOT 'equated': no common-item equating, no latent trait model, no link to
  -- any other framework's metric has been performed. Anchored means "the
  -- spacing reflects how rare each grade actually is". It licenses comparing a
  -- GCSE profile against the England GCSE population, and it licenses
  -- comparing GCSE with A-Level (section 1.2, anchored the same way, same
  -- country, same year). It does NOT license averaging a GCSE grade with an
  -- MYP criterion level, because no MYP scale in this database is anchored at
  -- all — and analytics is required to refuse that join.
END $seed$;

-- ---------------------------------------------------------------------------
-- 1.2 A-LEVEL A*-E — ANCHORED
--
-- DISTRIBUTION USED: JCQ summer 2019, England, all A-Level entries, cumulative
-- percentage at or above each grade. APPROX, same caveat as 1.1.
--
--     A*        7.8%        C or above   75.8%
--     A+       25.5%        D or above   91.6%
--     B+       51.1%        E or above   97.6%
--                           U             2.4%
--
-- Same midpoint-percentile rule. The headline result is worth staring at:
--     equal spacing puts grade C at 0.5000  (dead centre of the scale)
--     anchoring   puts grade C at 0.3655  (the 37th percentile of entrants)
-- A C at A-Level is not an average performance in any population sense; it is
-- well below the middle of a population that has ALREADY been selected by
-- getting good GCSEs. Any "average grade" report built on equal spacing is
-- wrong by about a third of a grade, always in the flattering direction.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE s uuid;
BEGIN
  s := pg_temp.f_scale('UK_ALEVEL_A_E', 'GCE A-Level grade A*-E (England, reformed/linear)', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','E','D','C','B','A','A*']);

  PERFORM pg_temp.f_anchor(s, 'U',  0.01200, 'Ungraded',    false);
  PERFORM pg_temp.f_anchor(s, 'E',  0.05400, 'Grade E',     true);
  PERFORM pg_temp.f_anchor(s, 'D',  0.16300, 'Grade D',     true);
  PERFORM pg_temp.f_anchor(s, 'C',  0.36550, 'Grade C',     true);
  PERFORM pg_temp.f_anchor(s, 'B',  0.61700, 'Grade B',     true);
  PERFORM pg_temp.f_anchor(s, 'A',  0.83350, 'Grade A',     true);
  PERFORM pg_temp.f_anchor(s, 'A*', 0.96100, 'Grade A*',    true);
  -- is_pass here is not a convention: A*-E are passing grades of the
  -- qualification and U is not. Unlike GCSE there is no second national
  -- threshold, so the single boolean is faithful.

  UPDATE ref.scale SET equating_status = 'anchored' WHERE id = s;
END $seed$;

-- ---------------------------------------------------------------------------
-- 1.3 Everything else — DELIBERATELY LEFT 'assumed_linear'
--
-- Each of these could have been given confident-looking anchors. None of them
-- has been, and the reason is different in each case. A wrong 'anchored' is
-- worse than an honest 'assumed_linear' because it silently unlocks pooling.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE s uuid;
BEGIN
  -- Legacy GCSE A*-G. Needed because a school's historic data does not vanish
  -- when a specification is reformed, and a five-year trend for a department
  -- crosses the 2017 changeover. NOT anchored: the 2016 A*-G distribution is a
  -- different population on a different qualification, and the official
  -- Ofqual mapping is only the three points A/7, C/4, G/1 — it is explicitly
  -- NOT a grade-for-grade conversion, so inventing anchors that made the two
  -- scales look comparable would be exactly the lie this column exists to
  -- prevent.
  s := pg_temp.f_scale('UK_GCSE_LEGACY_A_G', 'GCSE grade A*-G (legacy, final award 2016-2019)', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','G','F','E','D','C','B','A','A*']);
  UPDATE ref.scale_point SET is_pass = (code IN ('C','B','A','A*')) WHERE scale_id = s;

  -- Cambridge International IGCSE 9-1. SAME LABELS AS 1.1, DIFFERENT SCALE ROW,
  -- ON PURPOSE. Cambridge IGCSE is sat by a worldwide, largely independent- and
  -- international-school population; the proportion awarded a 9 has no
  -- relationship to the England GCSE proportion. Reusing UK_GCSE_9_1 would
  -- silently apply England's 2019 anchors to candidates in Dubai and Nairobi
  -- and make every cross-cohort statistic in an international school wrong,
  -- while looking completely clean in the UI. Two scale rows is the whole fix.
  s := pg_temp.f_scale('CIE_IGCSE_9_1', 'Cambridge IGCSE grade 9-1', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','1','2','3','4','5','6','7','8','9']);
  UPDATE ref.scale_point SET is_pass = (code NOT IN ('U','1','2','3')) WHERE scale_id = s;

  -- Cambridge IGCSE A*-G — still the majority syllabus variant outside the UK.
  s := pg_temp.f_scale('CIE_IGCSE_A_G', 'Cambridge IGCSE grade A*-G', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','G','F','E','D','C','B','A','A*']);
  UPDATE ref.scale_point SET is_pass = (code IN ('C','B','A','A*')) WHERE scale_id = s;

  -- Cambridge International A-Level. Same argument as CIE_IGCSE_9_1.
  s := pg_temp.f_scale('CIE_AL_A_E', 'Cambridge International A Level grade A*-E', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','E','D','C','B','A','A*']);
  UPDATE ref.scale_point SET is_pass = (code <> 'U') WHERE scale_id = s;

  -- Cambridge AS Level stops at A: there is no A* at AS. Encoding that as a
  -- separate scale rather than "the A* row that we promise never to use" means
  -- an AS result of A* is unrepresentable rather than merely discouraged.
  s := pg_temp.f_scale('CIE_AS_A_E', 'Cambridge International AS Level grade A-E', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','E','D','C','B','A']);
  UPDATE ref.scale_point SET is_pass = (code <> 'U') WHERE scale_id = s;
END $seed$;

-- ---------------------------------------------------------------------------
-- 1.4 Raw-mark scales.
--
-- These are ratio_marks: 0 means zero marks, and the distance between 40 and
-- 50 marks IS the distance between 50 and 60 marks, so linear normalisation is
-- correct by construction rather than by assumption. The vocabulary has no
-- value meaning "linear by definition", so they read 'assumed_linear'; that is
-- a vocabulary gap, not a modelling error, and the same gap the IB DP seed
-- notes for diploma points.
--
-- A scale is seeded here only where the maximum is FIXED BY THE SPECIFICATION
-- and stable for the life of that specification (AQA GCSE Maths has been three
-- papers of 80 marks since 2017). Where a paper total moves between series,
-- the per-series maximum belongs on gradebook.item.max_value, not here.
-- ---------------------------------------------------------------------------

DO $seed$
BEGIN
  PERFORM pg_temp.f_scale('UK_MARKS_0_80',  'Exam paper, 80 marks',  'ratio_marks', 0, 80,  1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_84',  'Exam paper, 84 marks',  'ratio_marks', 0, 84,  1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_91',  'Exam paper, 91 marks',  'ratio_marks', 0, 91,  1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_78',  'Exam paper, 78 marks',  'ratio_marks', 0, 78,  1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_100', 'Exam paper, 100 marks', 'ratio_marks', 0, 100, 1);
  -- Qualification totals. Different boards, same subject, different totals —
  -- which is the entire reason a boundary mark from one board is meaningless
  -- against another board's paper.
  PERFORM pg_temp.f_scale('UK_MARKS_0_160', 'Qualification total, 160 marks (AQA GCSE English Language)', 'ratio_marks', 0, 160, 1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_168', 'Qualification total, 168 marks (AQA GCSE History)',          'ratio_marks', 0, 168, 1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_240', 'Qualification total, 240 marks (AQA / Edexcel GCSE Maths)',  'ratio_marks', 0, 240, 1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_260', 'Qualification total, 260 marks (AQA A-level Biology)',       'ratio_marks', 0, 260, 1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_300', 'Qualification total, 300 marks (OCR GCSE Maths)',            'ratio_marks', 0, 300, 1);
  -- A normalised percentage, for measures whose raw total moves every series
  -- (Cambridge component totals) and for internal mock marking.
  PERFORM pg_temp.f_scale('UK_PCT_0_100',   'Percentage of available marks', 'ratio_marks', 0, 100, 2);
END $seed$;

-- ---------------------------------------------------------------------------
-- 1.5 BTEC scales.
--
-- BTEC is the interesting case in this file, because it is the one system here
-- that is NOT "mark a paper and cut it with boundaries". A BTEC qualification
-- is an accumulation: each UNIT is graded U/P/M/D against published assessment
-- criteria (no marks at all — a criterion is met or it is not), each unit is
-- worth points in proportion to its guided learning hours, and the points are
-- summed and cut into the qualification grade U/P/M/D/D*.
--
-- Note that D* exists ONLY at qualification level. There is no Distinction*
-- unit. Modelling both with one scale would make a D* unit grade typeable, and
-- the first person to type one would corrupt the points total.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE s uuid;
BEGIN
  -- The unit grade scale, and the one place in this file where an anchor comes
  -- from a TARIFF rather than an outcome distribution — see the long note below.
  s := pg_temp.f_scale('BTEC_UNIT_U_P_M_D', 'BTEC unit grade U/P/M/D', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','P','M','D']);
  PERFORM pg_temp.f_anchor(s, 'U', 0.00000, 'Unclassified', false);
  PERFORM pg_temp.f_anchor(s, 'P', 0.37500, 'Pass',         true);
  PERFORM pg_temp.f_anchor(s, 'M', 0.62500, 'Merit',        true);
  PERFORM pg_temp.f_anchor(s, 'D', 1.00000, 'Distinction',  true);
  UPDATE ref.scale SET equating_status = 'anchored' WHERE id = s;
  -- WHY 'anchored', AND EXACTLY WHAT IT DOES AND DOES NOT MEAN HERE:
  --
  -- Pearson's own points tariff for a 60-guided-learning-hour unit is
  -- U=0, P=6, M=10, D=16 points, scaling in proportion for 90 and 120 GLH
  -- units. (Believed to match the 2016 BTEC Nationals specification; VERIFY
  -- against Pearson's "calculation of qualification grade" tables before use —
  -- flagged in this file's uncertainty list.) Dividing by the maximum gives
  -- 0, 0.375, 0.625, 1.0, which is what is seeded above. Equal spacing would
  -- have given 0, 0.333, 0.667, 1.0 and would make the points arithmetic in
  -- section 7 produce the WRONG NUMBER OF POINTS — the aggregation in this
  -- system genuinely depends on these values, so leaving equal spacing here
  -- would be a live bug, not a cautious choice.
  --
  -- This is nevertheless a weaker kind of anchoring than sections 1.1 and 1.2,
  -- and the schema has no vocabulary for the difference. Anchored-to-a-tariff
  -- means "these values are the awarding body's own arithmetic and are exact
  -- WITHIN this qualification". It does NOT mean, and must not be read as
  -- meaning, that a BTEC Merit sits at the 62.5th percentile of anything. A
  -- BTEC cohort is not a random sample of the GCSE cohort, so pooling BTEC
  -- normalised values with GCSE ones is unjustified even though both scales
  -- now say 'anchored'. That is a genuine gap in equating_status and it is
  -- reported as a schema misfit rather than papered over.

  s := pg_temp.f_scale('BTEC_QUAL_U_P_M_D_DS', 'BTEC qualification grade U/P/M/D/D*', 'ordinal_grade');
  PERFORM ref.seed_scale_points(s, ARRAY['U','P','M','D','D*']);
  UPDATE ref.scale_point SET is_pass = (code <> 'U') WHERE scale_id = s;
  UPDATE ref.scale_point SET label = x.lbl
    FROM (VALUES ('U','Unclassified'),('P','Pass'),('M','Merit'),
                 ('D','Distinction'),('D*','Distinction*')) AS x(code,lbl)
   WHERE scale_id = s AND ref.scale_point.code = x.code;
  -- Left 'assumed_linear' on purpose. The qualification grade is produced by
  -- cutting a points total at 36/52/74/90 out of a possible 120 for an
  -- Extended Certificate (section 7), and those cut-offs are nowhere near
  -- equally spaced — but converting them into pct_anchors would encode ONE
  -- qualification size's thresholds into a scale shared by every size. The
  -- honest position is that the spacing of this ordinal scale is unknown; the
  -- points total, which is where the real arithmetic lives, is a ratio scale
  -- immediately below.

  PERFORM pg_temp.f_scale('BTEC_POINTS_0_120', 'BTEC qualification points total (Extended Certificate, 360 GLH)',
                          'ratio_marks', 0, 120, 0);
END $seed$;

-- ---------------------------------------------------------------------------
-- 1.6 Baseline and target scales.
--
-- CAT4 (GL Assessment) and MidYIS (CEM) are standardised cognitive baseline
-- tests taken on entry. Both report a standardised age score with a national
-- mean of 100 and a standard deviation of 15 — that part is a real, published,
-- definitional property of the test and is seeded as a benchmark in section 11.
-- The scale is interval, not ordinal: 100 and 115 really are one SD apart.
-- ---------------------------------------------------------------------------

DO $seed$
BEGIN
  PERFORM pg_temp.f_scale('UK_SAS_60_140', 'Standardised age score (mean 100, SD 15)', 'interval_points', 60, 140, 0);
  -- Mean GCSE points score: the average of a student's GCSE grades read as
  -- points (grade 9 = 9 points ... grade 1 = 1 point). This is the standard
  -- prior-attainment input to both Alps and FFT sixth-form target setting, and
  -- it is a genuine ratio quantity once the underlying grades are anchored.
  PERFORM pg_temp.f_scale('UK_MEAN_GCSE_0_9', 'Mean GCSE points score (grades read as 9..1)', 'ratio_marks', 0, 9, 2);
END $seed$;

-- ===========================================================================
-- 2. FRAMEWORKS AND VERSIONS
--
-- ONE FRAMEWORK PER AWARDING BODY, not one framework called "GCSE".
--
-- This is the decision a developer new to the English system always gets
-- wrong, so here is the justification in full. "GCSE Mathematics" is not a
-- qualification; it is a category. What a student actually holds is
-- "AQA GCSE Mathematics 8300" or "Pearson Edexcel GCSE Mathematics 1MA1" or
-- "OCR GCSE Mathematics J560". These differ in:
--   * paper structure and total marks (240 for AQA and Edexcel, 300 for OCR);
--   * the wording, style and difficulty profile of the questions;
--   * the grade boundaries, which are set independently by each board every
--     series and routinely differ by several percentage points of the total;
--   * the content emphasis within the (nationally fixed) subject content.
-- A single "GCSE" framework would force all of that into one boundary table
-- and make a raw mark meaningless. Worse, it would make the most common real
-- question in a UK department — "we moved from Edexcel to AQA in 2022, did our
-- results actually change or did the exam?" — unanswerable, because the two
-- regimes would be indistinguishable rows.
--
-- ref.framework_version is then ONE SPECIFICATION, identified by its board
-- specification code (8300, 1MA1, J560), not a calendar year. A department
-- teaches one specification for years; specifications are reformed on their own
-- schedules; and org.teaching_group.framework_version_id should point at the
-- specification the class is actually entered for.
--
-- BTEC gets its own framework even though Pearson also owns Edexcel GCSEs,
-- because a framework in this schema is a GRADING SYSTEM, and P/M/D/D* over
-- accumulated unit points is not the same grading system as 9-1 over a raw
-- mark total, whoever sells it.
-- ===========================================================================

DO $seed$
DECLARE fw uuid; v_new uuid;
BEGIN
  ------------------------------------------------------------------ AQA ------
  fw := pg_temp.f_framework('UK_AQA', 'AQA — GCSE and GCE A-Level', 'GB', 'AQA');
  PERFORM pg_temp.f_version(fw, 'AQA GCSE Mathematics 8300 (first assessment 2017)',       DATE '2015-09-01');
  PERFORM pg_temp.f_version(fw, 'AQA GCSE Mathematics 4365 (legacy A*-G, final award 2016)',
                                                                     DATE '2010-09-01', DATE '2016-08-31');
  PERFORM pg_temp.f_version(fw, 'AQA GCSE English Language 8700 (first assessment 2017)',  DATE '2015-09-01');
  PERFORM pg_temp.f_version(fw, 'AQA GCSE History 8145 (first assessment 2018)',           DATE '2016-09-01');
  PERFORM pg_temp.f_version(fw, 'AQA A-level Biology 7402 (first assessment 2017)',        DATE '2015-09-01');

  -- The reform chain. A five-year departmental trend that crosses this line is
  -- crossing a change of grading scale AND a change of assessment structure;
  -- superseded_by is how the analytics layer knows to caveat rather than
  -- silently join 2015 to 2019.
  SELECT id INTO v_new FROM ref.framework_version
   WHERE framework_id = fw AND label = 'AQA GCSE Mathematics 8300 (first assessment 2017)';
  UPDATE ref.framework_version
     SET superseded_by = v_new
   WHERE framework_id = fw
     AND label = 'AQA GCSE Mathematics 4365 (legacy A*-G, final award 2016)'
     AND superseded_by IS NULL;

  -------------------------------------------------------- Pearson Edexcel ----
  fw := pg_temp.f_framework('UK_EDEXCEL', 'Pearson Edexcel — GCSE and GCE A-Level', 'GB', 'Pearson Edexcel');
  PERFORM pg_temp.f_version(fw, 'Pearson Edexcel GCSE Mathematics 1MA1 (first assessment 2017)', DATE '2015-09-01');
  PERFORM pg_temp.f_version(fw, 'Pearson Edexcel GCSE English Language 1EN0 (first assessment 2017)', DATE '2015-09-01');

  ------------------------------------------------------------------ OCR ------
  fw := pg_temp.f_framework('UK_OCR', 'OCR — GCSE and GCE A-Level', 'GB', 'OCR');
  PERFORM pg_temp.f_version(fw, 'OCR GCSE Mathematics J560 (first assessment 2017)', DATE '2015-09-01');

  ------------------------------------------------- Cambridge International ---
  -- country_code is NULL, not 'GB'. Cambridge International qualifications are
  -- sat in over 160 countries; tagging them GB would make any "show me the
  -- English qualifications" filter quietly wrong for every international school
  -- on the platform.
  fw := pg_temp.f_framework('CIE', 'Cambridge International — IGCSE and International AS/A Level',
                            NULL, 'Cambridge Assessment International Education');
  PERFORM pg_temp.f_version(fw, 'Cambridge IGCSE Mathematics 0580 (Core / Extended)', DATE '2018-09-01');
  PERFORM pg_temp.f_version(fw, 'Cambridge International AS & A Level Biology 9700',  DATE '2020-09-01');

  ----------------------------------------------------------------- BTEC ------
  fw := pg_temp.f_framework('UK_BTEC', 'Pearson BTEC (vocational, unit accumulation)', 'GB', 'Pearson');
  PERFORM pg_temp.f_version(fw, 'BTEC Level 3 National Extended Certificate in Applied Science (2016 specification)',
                            DATE '2016-09-01');

  ----------------------------------------- Baselines, predictions, targets ---
  -- Not an awarding body and not a qualification: a framework whose measures
  -- are the school's PRIOR-ATTAINMENT and TARGET-SETTING instruments. It is
  -- global config because CAT4, MidYIS, Alps and FFT are national products used
  -- identically across schools; a school's own bespoke target model would be a
  -- school-owned framework alongside it, exactly like section 8's Key Stage 3.
  fw := pg_temp.f_framework('UK_BASELINE_TARGET', 'UK baselines, predictions and target grades', 'GB',
                            'GL Assessment / CEM / Alps / FFT');
  PERFORM pg_temp.f_version(fw, 'Baseline and target grade model (generic)', DATE '2016-09-01');
END $seed$;

-- Localised labels. Wales sits inside this awarding landscape — English boards
-- are used in Welsh-medium schools and reports go home in Welsh — so the
-- framework and, later, the tier measures carry cy labels. This is the
-- ref.translation mechanism doing exactly the job it exists for: the
-- authoritative English wording stays authoritative, and the parent-facing
-- label is data.
DO $seed$
DECLARE fw uuid;
BEGIN
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_AQA';
  PERFORM pg_temp.f_tr('framework', fw, 'cy', 'AQA — TGAU a Safon Uwch');
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_EDEXCEL';
  PERFORM pg_temp.f_tr('framework', fw, 'cy', 'Pearson Edexcel — TGAU a Safon Uwch');
END $seed$;

-- ===========================================================================
-- 3. CONSTRUCTS — the pedagogically stable identities
--
-- A construct survives a specification change; a measure does not. "AQA GCSE
-- Maths Paper 1" is a construct that has outlived two reforms. The row saying
-- "Paper 1 of specification 8300, Higher tier, out of 80 marks" is a measure
-- and dies with 8300. Without the construct, a department's 2016 and 2019
-- results are unjoinable and the multi-year trend — the entire point of this
-- database — silently resets at the reform.
--
-- ASSESSMENT OBJECTIVES are the interesting constructs here, and the reason
-- this file exists alongside the IB one. An AO is a nationally defined strand
-- of what is being tested, with a mandated percentage of the total marks. Every
-- question on every paper is allocated to AOs by the board, usually in
-- fractions of a question. That means a UK department can, in principle, answer
-- "our students can recall but cannot evaluate" from marks it already collects
-- — which is precisely the diagnosis a raw percentage cannot give and precisely
-- what gradebook.item_measure_alloc is shaped to hold (section 5).
--
-- ONE SCHEMA NOTE, stated rather than hidden: ref.construct is unique on
-- (framework_id, code), but an assessment objective is only meaningful within a
-- SUBJECT — AQA's AO1 in Maths ("use and apply standard techniques") and AQA's
-- AO1 in English Language ("identify and interpret explicit and implicit
-- information") are entirely different things. The subject is therefore packed
-- into the construct code (MATH_AO1, ENGLANG_AO1). The same compression the IB
-- DP seed applies to subject_group_code, for the same reason.
--
-- semantic_axis is the coarse cross-framework bucket. It is a claim that AQA
-- Maths AO3 and IB DP objective 3 both live in the "synthesis" region of the
-- cognitive space. It is NOT a claim that they are the same standard, and
-- nothing in this platform may average across frameworks on the strength of it.
-- ===========================================================================

DO $seed$
DECLARE fw uuid; r record;
BEGIN
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_AQA';

  FOR r IN SELECT * FROM (VALUES
    -- ---- GCSE Mathematics 8300 ------------------------------------------
    -- The three AOs and their mark weightings are set by the Ofqual subject
    -- content requirements, so they are IDENTICAL across AQA, Edexcel and OCR.
    -- The weightings differ by TIER, which is why they are carried on the
    -- measure (level_code) and not on the construct.
    ('MATH_AO1','Mathematics AO1 — use and apply standard techniques','assessment_objective','application'),
    ('MATH_AO2','Mathematics AO2 — reason, interpret and communicate mathematically','assessment_objective','communication'),
    ('MATH_AO3','Mathematics AO3 — solve problems within mathematics and in other contexts','assessment_objective','synthesis'),
    ('MATH_P1','GCSE Mathematics Paper 1 (non-calculator)','component','unspecified'),
    ('MATH_P2','GCSE Mathematics Paper 2 (calculator)','component','unspecified'),
    ('MATH_P3','GCSE Mathematics Paper 3 (calculator)','component','unspecified'),
    ('MATH_TOTAL','GCSE Mathematics raw mark total','overall','unspecified'),
    ('MATH_GRADE','GCSE Mathematics awarded grade','overall','unspecified'),
    -- ---- GCSE Mathematics 4365 (legacy, A*-G) ---------------------------
    ('MATH_LEG_AO1','Legacy Mathematics AO1 — recall and use knowledge','assessment_objective','knowledge'),
    ('MATH_LEG_AO2','Legacy Mathematics AO2 — select and apply mathematical methods','assessment_objective','application'),
    ('MATH_LEG_AO3','Legacy Mathematics AO3 — interpret and analyse problems','assessment_objective','analysis'),
    ('MATH_LEG_GRADE','Legacy GCSE Mathematics awarded grade A*-G','overall','unspecified'),
    -- ---- GCSE English Language 8700 -------------------------------------
    ('ENGLANG_AO1','English Language AO1 — identify and interpret explicit and implicit information','assessment_objective','knowledge'),
    ('ENGLANG_AO2','English Language AO2 — explain, comment on and analyse language and structure','assessment_objective','analysis'),
    ('ENGLANG_AO3','English Language AO3 — compare writers'' ideas and perspectives across texts','assessment_objective','analysis'),
    ('ENGLANG_AO4','English Language AO4 — evaluate texts critically','assessment_objective','evaluation'),
    ('ENGLANG_AO5','English Language AO5 — communicate clearly and effectively in writing','assessment_objective','communication'),
    ('ENGLANG_AO6','English Language AO6 — use vocabulary and sentence structures accurately','assessment_objective','communication'),
    ('ENGLANG_P1','GCSE English Language Paper 1 — Explorations in creative reading and writing','component','unspecified'),
    ('ENGLANG_P2','GCSE English Language Paper 2 — Writers'' viewpoints and perspectives','component','unspecified'),
    ('ENGLANG_TOTAL','GCSE English Language raw mark total','overall','unspecified'),
    ('ENGLANG_GRADE','GCSE English Language awarded grade','overall','unspecified'),
    ('ENGLANG_SPOKEN','GCSE English Language spoken language endorsement','component','communication'),
    -- ---- GCSE History 8145 ----------------------------------------------
    ('HIST_AO1','History AO1 — demonstrate knowledge and understanding of the period','assessment_objective','knowledge'),
    ('HIST_AO2','History AO2 — explain and analyse historical events using second-order concepts','assessment_objective','analysis'),
    ('HIST_AO3','History AO3 — analyse, evaluate and use sources','assessment_objective','evaluation'),
    ('HIST_AO4','History AO4 — analyse, evaluate and make judgements about interpretations','assessment_objective','evaluation'),
    ('HIST_P1','GCSE History Paper 1 — Understanding the modern world','component','unspecified'),
    ('HIST_P2','GCSE History Paper 2 — Shaping the nation','component','unspecified'),
    ('HIST_TOTAL','GCSE History raw mark total','overall','unspecified'),
    ('HIST_GRADE','GCSE History awarded grade','overall','unspecified'),
    -- ---- A-level Biology 7402 -------------------------------------------
    ('BIO_AO1','Biology AO1 — demonstrate knowledge and understanding','assessment_objective','knowledge'),
    ('BIO_AO2','Biology AO2 — apply knowledge and understanding','assessment_objective','application'),
    ('BIO_AO3','Biology AO3 — analyse, interpret and evaluate scientific information','assessment_objective','evaluation'),
    ('BIO_P1','A-level Biology Paper 1','component','unspecified'),
    ('BIO_P2','A-level Biology Paper 2','component','unspecified'),
    ('BIO_P3','A-level Biology Paper 3','component','unspecified'),
    ('BIO_TOTAL','A-level Biology raw mark total','overall','unspecified'),
    ('BIO_GRADE','A-level Biology awarded grade','overall','unspecified'),
    ('BIO_CPAC','A-level Biology practical endorsement (CPAC)','component','skill_practical')
  ) AS x(code,label,kind,axis)
  LOOP
    PERFORM pg_temp.f_construct(fw, r.code, r.label, r.kind, r.axis);
  END LOOP;
END $seed$;

-- The other boards get the SAME construct codes for the same subject. They are
-- separate rows because they belong to separate frameworks, which is correct —
-- an AQA Paper 1 is not an Edexcel Paper 1 — but using an identical code makes
-- the cross-board question ("where in the AO profile do our Edexcel and AQA
-- sets differ?") a join on code and semantic_axis rather than a hand-written
-- mapping table.
DO $seed$
DECLARE fw uuid; b text; r record;
BEGIN
  FOREACH b IN ARRAY ARRAY['UK_EDEXCEL','UK_OCR'] LOOP
    SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = b;
    FOR r IN SELECT * FROM (VALUES
      ('MATH_AO1','Mathematics AO1 — use and apply standard techniques','assessment_objective','application'),
      ('MATH_AO2','Mathematics AO2 — reason, interpret and communicate mathematically','assessment_objective','communication'),
      ('MATH_AO3','Mathematics AO3 — solve problems within mathematics and in other contexts','assessment_objective','synthesis'),
      ('MATH_P1','GCSE Mathematics Paper 1','component','unspecified'),
      ('MATH_P2','GCSE Mathematics Paper 2','component','unspecified'),
      ('MATH_P3','GCSE Mathematics Paper 3','component','unspecified'),
      ('MATH_TOTAL','GCSE Mathematics raw mark total','overall','unspecified'),
      ('MATH_GRADE','GCSE Mathematics awarded grade','overall','unspecified')
    ) AS x(code,label,kind,axis)
    LOOP
      PERFORM pg_temp.f_construct(fw, r.code, r.label, r.kind, r.axis);
    END LOOP;
  END LOOP;

  -- Edexcel English Language, for the second subject with two boards.
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_EDEXCEL';
  FOR r IN SELECT * FROM (VALUES
    ('ENGLANG_AO1','English Language AO1 — identify and interpret information','assessment_objective','knowledge'),
    ('ENGLANG_AO2','English Language AO2 — analyse language and structure','assessment_objective','analysis'),
    ('ENGLANG_AO3','English Language AO3 — compare texts','assessment_objective','analysis'),
    ('ENGLANG_AO4','English Language AO4 — evaluate texts critically','assessment_objective','evaluation'),
    ('ENGLANG_AO5','English Language AO5 — communicate clearly and effectively','assessment_objective','communication'),
    ('ENGLANG_AO6','English Language AO6 — use vocabulary and sentence structures accurately','assessment_objective','communication'),
    ('ENGLANG_TOTAL','GCSE English Language raw mark total','overall','unspecified'),
    ('ENGLANG_GRADE','GCSE English Language awarded grade','overall','unspecified')
  ) AS x(code,label,kind,axis)
  LOOP
    PERFORM pg_temp.f_construct(fw, r.code, r.label, r.kind, r.axis);
  END LOOP;
END $seed$;

-- Cambridge International.
DO $seed$
DECLARE fw uuid; r record;
BEGIN
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'CIE';
  FOR r IN SELECT * FROM (VALUES
    ('IGMATH_AO1','IGCSE Mathematics AO1 — knowledge and understanding of techniques','assessment_objective','application'),
    ('IGMATH_AO2','IGCSE Mathematics AO2 — reasoning, interpretation and problem solving','assessment_objective','synthesis'),
    ('IGMATH_P1','IGCSE Mathematics Paper 1 (Core, short answer)','component','unspecified'),
    ('IGMATH_P2','IGCSE Mathematics Paper 2 (Extended, short answer)','component','unspecified'),
    ('IGMATH_P3','IGCSE Mathematics Paper 3 (Core, structured)','component','unspecified'),
    ('IGMATH_P4','IGCSE Mathematics Paper 4 (Extended, structured)','component','unspecified'),
    ('IGMATH_GRADE','IGCSE Mathematics awarded grade','overall','unspecified'),
    ('BIO_AO1','Biology AO1 — knowledge with understanding','assessment_objective','knowledge'),
    ('BIO_AO2','Biology AO2 — handling, applying and evaluating information','assessment_objective','evaluation'),
    ('BIO_AO3','Biology AO3 — experimental skills and investigations','assessment_objective','skill_practical'),
    ('BIO_P1','Biology Paper 1 — Multiple choice (AS)','component','unspecified'),
    ('BIO_P2','Biology Paper 2 — AS structured questions','component','unspecified'),
    ('BIO_P3','Biology Paper 3 — Advanced practical skills','component','skill_practical'),
    ('BIO_P4','Biology Paper 4 — A Level structured questions','component','unspecified'),
    ('BIO_P5','Biology Paper 5 — Planning, analysis and evaluation','component','evaluation'),
    ('BIO_AS_GRADE','Cambridge International AS Level Biology awarded grade','overall','unspecified'),
    ('BIO_AL_GRADE','Cambridge International A Level Biology awarded grade','overall','unspecified')
  ) AS x(code,label,kind,axis)
  LOOP
    PERFORM pg_temp.f_construct(fw, r.code, r.label, r.kind, r.axis);
  END LOOP;
END $seed$;

-- ---------------------------------------------------------------------------
-- 3.1 The reform, recorded as a construct transition.
--
-- This is what makes a trend across 2016-2017 honest instead of silent. The
-- legacy maths AOs were reorganised, not renamed: old AO1 (recall) largely
-- dissolved into the new AO1 (use and apply standard techniques), while old AO3
-- (interpret and analyse) split across new AO2 and AO3. trend_safe = false on
-- every edge, because "we improved on AO3" across the reform boundary would be
-- a statement about the specification, not about the students.
--
-- Deliberately NOT done here: construct_transition rows between AQA and Edexcel
-- constructs. The table records how a construct CHANGED OVER TIME within the
-- qualification lineage; using it to assert cross-board equivalence would
-- overload it into a "these two things are the same" table with no temporal
-- meaning, and would license pooling that nobody has evidence for. Cross-board
-- comparison is what semantic_axis and ref.benchmark are for.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE fw uuid; r record; c_from uuid; c_to uuid;
BEGIN
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_AQA';
  FOR r IN SELECT * FROM (VALUES
    ('MATH_LEG_AO1','MATH_AO1','merged',  'Legacy AO1 (recall and use knowledge) is absorbed into the new AO1; there is no longer a separate recall objective.'),
    ('MATH_LEG_AO2','MATH_AO1','rescoped','Legacy AO2 (select and apply methods) maps mostly to the new AO1, which is now defined as using and applying standard techniques.'),
    ('MATH_LEG_AO3','MATH_AO2','split',   'Legacy AO3 (interpret and analyse) splits: the reasoning and communication half becomes AO2.'),
    ('MATH_LEG_AO3','MATH_AO3','split',   'Legacy AO3 (interpret and analyse) splits: the problem-solving half becomes AO3, which grew from roughly a quarter of the legacy paper to 30% at Higher tier.'),
    ('MATH_LEG_GRADE','MATH_GRADE','rescoped','A*-G becomes 9-1 in 2017. Ofqual anchored only three points (A/7, C/4, G/1); this is NOT a grade-for-grade conversion and must never be trended as one.')
  ) AS x(f,t,kind,note)
  LOOP
    SELECT id INTO c_from FROM ref.construct WHERE framework_id = fw AND code = r.f;
    SELECT id INTO c_to   FROM ref.construct WHERE framework_id = fw AND code = r.t;
    INSERT INTO ref.construct_transition (from_construct_id, to_construct_id, transition, trend_safe, note)
    VALUES (c_from, c_to, r.kind, false, r.note)
    ON CONFLICT (from_construct_id, to_construct_id) DO NOTHING;
  END LOOP;
END $seed$;

-- ===========================================================================
-- 4. MEASURES — the version-specific scored things
--
-- Three kinds of measure appear for every examined specification:
--
--   role='observed'   a paper, marked by a teacher on a mock or by the board
--                     on the real thing, and the AO sub-totals that come from
--                     item-level mark allocation;
--   role='derived'    the raw mark total (sum of papers) and the grade
--                     (boundary applied to that total), each with a
--                     ref.conversion_rule in section 6;
--   role='awarded'    what the board actually issued in August, which is NOT
--                     the same row as the grade the system computed from a
--                     mock. Keeping them distinct is what makes
--                     "predicted vs actual" a query instead of an argument.
--
-- WHY AO SUB-TOTALS ARE 'observed' AND NOT 'derived':
-- an AO score is not computed from other MEASURES; it is computed from the
-- marks on individual QUESTIONS, via gradebook.item_measure_alloc. That path
-- lives in the gradebook, not in ref.conversion_rule, and conversion_input
-- cannot enumerate the questions on a paper that has not been written yet.
-- Calling them 'derived' would make ref.v_config_errors demand a conversion
-- rule that cannot meaningfully exist.
-- ===========================================================================

-- Two endorsement scales first: outcomes that are REPORTED ALONGSIDE a grade
-- and contribute nothing to it. Modelling them as measures with weight 0 (and
-- as no input to the grade rule) is what stops a well-meaning aggregate from
-- quietly folding a spoken-language Distinction into a student's English grade.
DO $seed$
DECLARE s uuid;
BEGIN
  s := pg_temp.f_scale('UK_SPOKEN_ENDORSE', 'GCSE English spoken language endorsement', 'nominal');
  PERFORM ref.seed_scale_points(s, ARRAY['NC','P','M','D']);
  UPDATE ref.scale_point SET label = x.lbl, is_pass = x.pass
    FROM (VALUES ('NC','Not classified',false),('P','Pass',true),
                 ('M','Merit',true),('D','Distinction',true)) AS x(code,lbl,pass)
   WHERE scale_id = s AND ref.scale_point.code = x.code;

  s := pg_temp.f_scale('UK_PRACT_ENDORSE', 'A-level science practical endorsement (CPAC)', 'nominal');
  PERFORM ref.seed_scale_points(s, ARRAY['NC','P']);
  UPDATE ref.scale_point SET label = x.lbl, is_pass = x.pass
    FROM (VALUES ('NC','Not classified',false),('P','Pass',true)) AS x(code,lbl,pass)
   WHERE scale_id = s AND ref.scale_point.code = x.code;
END $seed$;

-- ---------------------------------------------------------------------------
-- 4.1 GCSE Mathematics on three boards, both tiers.
--
-- TIERING, which is the structural feature with no analogue in the IB or the
-- Greek system: a maths candidate is entered for EITHER the Foundation tier
-- (papers targeting grades 1-5) OR the Higher tier (papers targeting 4-9). The
-- tier is a decision the school makes months before the exam, it is frequently
-- the single most consequential decision taken about a low-attaining student,
-- and getting it wrong is unrecoverable: a Foundation entry CANNOT be awarded
-- above a grade 5 however well the candidate performs.
--
-- That cap is represented here by the plain ABSENCE of grade 6-9 rows in the
-- Foundation boundary table (section 6.1). Not a CHECK constraint, not
-- application validation — an outcome the configuration cannot express. The
-- alternative designs both fail: a separate GCSE_9_1_FOUNDATION scale would
-- make a Foundation grade 5 a different value from a Higher grade 5 when they
-- are the same award on the same certificate, and a max_grade column on the
-- measure would be one more field for an importer to ignore.
--
-- Tier lives in ref.measure.level_code, which is part of the measure natural
-- key, so "Paper 1, Foundation" and "Paper 1, Higher" are different rows with
-- different mark profiles, different boundaries and — genuinely — different
-- AO weightings.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE
  fv uuid; tier text; ao record;
  spec record;
BEGIN
  FOR spec IN SELECT * FROM (VALUES
      -- board framework, specification label, paper mark scale, total scale, total marks
      ('UK_AQA',     'AQA GCSE Mathematics 8300 (first assessment 2017)',            'UK_MARKS_0_80',  'UK_MARKS_0_240'),
      ('UK_EDEXCEL', 'Pearson Edexcel GCSE Mathematics 1MA1 (first assessment 2017)','UK_MARKS_0_80',  'UK_MARKS_0_240'),
      ('UK_OCR',     'OCR GCSE Mathematics J560 (first assessment 2017)',            'UK_MARKS_0_100', 'UK_MARKS_0_300')
    ) AS s(board, spec_label, paper_scale, total_scale)
  LOOP
    SELECT fv2.id INTO fv
      FROM ref.framework_version fv2
      JOIN ref.framework f ON f.id = fv2.framework_id
     WHERE f.owner_tenant_id = app.global_tenant() AND f.code = spec.board
       AND fv2.label = spec.spec_label;

    FOREACH tier IN ARRAY ARRAY['F','H'] LOOP
      -- Three papers. Every board uses three equally weighted papers for GCSE
      -- maths; OCR's are out of 100 rather than 80, which is exactly why a
      -- boundary mark cannot be carried between boards.
      PERFORM pg_temp.f_measure(fv, 'MATH_P1', spec.paper_scale, 'P1',
        'Paper 1 (non-calculator), ' || CASE tier WHEN 'F' THEN 'Foundation' ELSE 'Higher' END || ' tier',
        'observed', 'MATHEMATICS', tier, 1, 1);
      PERFORM pg_temp.f_measure(fv, 'MATH_P2', spec.paper_scale, 'P2',
        'Paper 2 (calculator), '     || CASE tier WHEN 'F' THEN 'Foundation' ELSE 'Higher' END || ' tier',
        'observed', 'MATHEMATICS', tier, 1, 2);
      PERFORM pg_temp.f_measure(fv, 'MATH_P3', spec.paper_scale, 'P3',
        'Paper 3 (calculator), '     || CASE tier WHEN 'F' THEN 'Foundation' ELSE 'Higher' END || ' tier',
        'observed', 'MATHEMATICS', tier, 1, 3);

      PERFORM pg_temp.f_measure(fv, 'MATH_TOTAL', spec.total_scale, 'TOTAL',
        'Raw mark total, ' || CASE tier WHEN 'F' THEN 'Foundation' ELSE 'Higher' END || ' tier',
        'derived', 'MATHEMATICS', tier, NULL, 10);

      PERFORM pg_temp.f_measure(fv, 'MATH_GRADE', 'UK_GCSE_9_1', 'GRADE',
        'Awarded grade, ' || CASE tier WHEN 'F' THEN 'Foundation tier (maximum grade 5)'
                                       ELSE 'Higher tier (grades 9-4, allowed grade 3)' END,
        'derived', 'MATHEMATICS', tier, NULL, 20);

      -- The official grade, as issued by the board in August. Separate row,
      -- role='awarded': it is evidence, not a computation, and it is the thing
      -- every target and prediction in section 9 is ultimately judged against.
      PERFORM pg_temp.f_measure(fv, 'MATH_GRADE', 'UK_GCSE_9_1', 'GRADE_AWARDED',
        'Grade awarded by the board', 'awarded', 'MATHEMATICS', tier, NULL, 21);

      -- Assessment objective sub-totals, as a PERCENTAGE of the marks
      -- available for that objective. weight carries the nationally mandated
      -- share of the total marks, which differs by tier: the Higher tier
      -- deliberately demands more reasoning and problem solving.
      -- Source: Ofqual GCSE mathematics subject-level conditions. These
      -- weightings are identical for all three boards by regulation — one of
      -- the very few things about UK exams that IS the same across boards.
      -- APPROX: the published values are stated to within a percentage point
      -- (e.g. Higher AO1 is "40%" with a permitted range); verify per spec.
      FOR ao IN SELECT * FROM (VALUES
          ('MATH_AO1','AO1','Use and apply standard techniques',
           CASE WHEN tier = 'F' THEN 0.50 ELSE 0.40 END, 31),
          ('MATH_AO2','AO2','Reason, interpret and communicate mathematically',
           CASE WHEN tier = 'F' THEN 0.25 ELSE 0.30 END, 32),
          ('MATH_AO3','AO3','Solve problems within mathematics and in other contexts',
           CASE WHEN tier = 'F' THEN 0.25 ELSE 0.30 END, 33)
        ) AS a(con, code, label, w, sort)
      LOOP
        PERFORM pg_temp.f_measure(fv, ao.con, 'UK_PCT_0_100', ao.code,
          ao.label || ' (' || CASE tier WHEN 'F' THEN 'Foundation' ELSE 'Higher' END ||
          ' tier, ' || round(ao.w * 100) || '% of marks)',
          'observed', 'MATHEMATICS', tier, ao.w, ao.sort);
      END LOOP;
    END LOOP;
  END LOOP;
END $seed$;

-- Welsh labels for the two tiers, on the AQA measures, because tier is the
-- thing a parent asks about and the thing a report has to name correctly.
DO $seed$
DECLARE m uuid;
BEGIN
  SELECT mm.id INTO m FROM ref.measure mm
    JOIN ref.framework_version fv ON fv.id = mm.framework_version_id
    JOIN ref.framework f ON f.id = fv.framework_id
   WHERE f.code = 'UK_AQA' AND mm.code = 'GRADE' AND mm.level_code = 'F'
     AND mm.subject_group_code = 'MATHEMATICS';
  IF m IS NOT NULL THEN
    PERFORM pg_temp.f_tr('measure', m, 'cy', 'Gradd TGAU Mathemateg — Haen Sylfaen (uchafswm gradd 5)');
  END IF;
  SELECT mm.id INTO m FROM ref.measure mm
    JOIN ref.framework_version fv ON fv.id = mm.framework_version_id
    JOIN ref.framework f ON f.id = fv.framework_id
   WHERE f.code = 'UK_AQA' AND mm.code = 'GRADE' AND mm.level_code = 'H'
     AND mm.subject_group_code = 'MATHEMATICS';
  IF m IS NOT NULL THEN
    PERFORM pg_temp.f_tr('measure', m, 'cy', 'Gradd TGAU Mathemateg — Haen Uwch');
  END IF;
END $seed$;

-- ---------------------------------------------------------------------------
-- 4.2 The untiered specifications.
--
-- English, history and the sciences at A-Level are single-tier: one set of
-- papers, the full grade range available to everyone. level_code is therefore
-- NULL, which is the schema saying "this distinction does not apply here"
-- rather than inventing a default tier that means nothing.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE fv uuid; m uuid;
BEGIN
  ---------------------------------------------------------------------------
  -- AQA GCSE English Language 8700: two papers of 80 marks, total 160,
  -- plus a separately reported spoken language endorsement.
  ---------------------------------------------------------------------------
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA GCSE English Language 8700 (first assessment 2017)';

  PERFORM pg_temp.f_measure(fv, 'ENGLANG_P1', 'UK_MARKS_0_80', 'P1',
    'Paper 1 — Explorations in creative reading and writing (80 marks, 50%)',
    'observed', 'ENGLISH_LANGUAGE', NULL, 1, 1);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_P2', 'UK_MARKS_0_80', 'P2',
    'Paper 2 — Writers'' viewpoints and perspectives (80 marks, 50%)',
    'observed', 'ENGLISH_LANGUAGE', NULL, 1, 2);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_TOTAL', 'UK_MARKS_0_160', 'TOTAL',
    'Raw mark total (160)', 'derived', 'ENGLISH_LANGUAGE', NULL, NULL, 10);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_GRADE', 'UK_GCSE_9_1', 'GRADE',
    'Awarded grade 9-1', 'derived', 'ENGLISH_LANGUAGE', NULL, NULL, 20);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_GRADE', 'UK_GCSE_9_1', 'GRADE_AWARDED',
    'Grade awarded by the board', 'awarded', 'ENGLISH_LANGUAGE', NULL, NULL, 21);

  -- weight = 0 and, crucially, NOT an input to the grade rule in section 6.3.
  -- The endorsement is printed on the certificate and contributes nothing.
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_SPOKEN', 'UK_SPOKEN_ENDORSE', 'SPOKEN',
    'Spoken language endorsement (reported separately, contributes 0% to the grade)',
    'awarded', 'ENGLISH_LANGUAGE', NULL, 0, 30);

  -- AO weightings for 8700. Reading objectives AO1-AO4 are assessed across the
  -- two reading sections; writing objectives AO5-AO6 across the two writing
  -- sections, with AO5 (content and organisation) worth twice AO6 (technical
  -- accuracy). APPROX — confirm against the specification before reporting.
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO1', 'UK_PCT_0_100', 'AO1', 'AO1 — identify and interpret information (7.5%)',  'observed', 'ENGLISH_LANGUAGE', NULL, 0.075, 41);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO2', 'UK_PCT_0_100', 'AO2', 'AO2 — analyse language and structure (15%)',       'observed', 'ENGLISH_LANGUAGE', NULL, 0.150, 42);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO3', 'UK_PCT_0_100', 'AO3', 'AO3 — compare writers'' ideas and perspectives (7.5%)','observed','ENGLISH_LANGUAGE', NULL, 0.075, 43);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO4', 'UK_PCT_0_100', 'AO4', 'AO4 — evaluate texts critically (20%)',             'observed', 'ENGLISH_LANGUAGE', NULL, 0.200, 44);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO5', 'UK_PCT_0_100', 'AO5', 'AO5 — communicate clearly and effectively (30%)',   'observed', 'ENGLISH_LANGUAGE', NULL, 0.300, 45);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO6', 'UK_PCT_0_100', 'AO6', 'AO6 — vocabulary, sentence structures, spelling and punctuation (20%)', 'observed', 'ENGLISH_LANGUAGE', NULL, 0.200, 46);

  ---------------------------------------------------------------------------
  -- Pearson Edexcel GCSE English Language 1EN0 — the SECOND BOARD for the same
  -- subject. Same national AOs, same 160-mark total, different papers,
  -- different boundaries (section 6.3). This pair plus the three maths
  -- specifications is the demonstration that "the subject" is not the unit of
  -- comparison; the specification is.
  ---------------------------------------------------------------------------
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_EDEXCEL' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'Pearson Edexcel GCSE English Language 1EN0 (first assessment 2017)';

  PERFORM pg_temp.f_measure(fv, 'ENGLANG_TOTAL', 'UK_MARKS_0_160', 'TOTAL',
    'Raw mark total (160)', 'derived', 'ENGLISH_LANGUAGE', NULL, NULL, 10);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_GRADE', 'UK_GCSE_9_1', 'GRADE',
    'Awarded grade 9-1', 'derived', 'ENGLISH_LANGUAGE', NULL, NULL, 20);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO1', 'UK_PCT_0_100', 'AO1', 'AO1 — identify and interpret information',  'observed', 'ENGLISH_LANGUAGE', NULL, 0.075, 41);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO2', 'UK_PCT_0_100', 'AO2', 'AO2 — analyse language and structure',       'observed', 'ENGLISH_LANGUAGE', NULL, 0.150, 42);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_AO4', 'UK_PCT_0_100', 'AO4', 'AO4 — evaluate texts critically',            'observed', 'ENGLISH_LANGUAGE', NULL, 0.200, 44);

  ---------------------------------------------------------------------------
  -- AQA GCSE History 8145: two papers of 84 marks, total 168.
  -- This is the specification the item_measure_alloc worked example in
  -- section 5 is written against.
  ---------------------------------------------------------------------------
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA GCSE History 8145 (first assessment 2018)';

  PERFORM pg_temp.f_measure(fv, 'HIST_P1', 'UK_MARKS_0_84', 'P1',
    'Paper 1 — Understanding the modern world (84 marks incl. SPaG)', 'observed', 'HISTORY', NULL, 1, 1);
  PERFORM pg_temp.f_measure(fv, 'HIST_P2', 'UK_MARKS_0_84', 'P2',
    'Paper 2 — Shaping the nation (84 marks incl. SPaG)', 'observed', 'HISTORY', NULL, 1, 2);
  PERFORM pg_temp.f_measure(fv, 'HIST_TOTAL', 'UK_MARKS_0_168', 'TOTAL',
    'Raw mark total (168)', 'derived', 'HISTORY', NULL, NULL, 10);
  PERFORM pg_temp.f_measure(fv, 'HIST_GRADE', 'UK_GCSE_9_1', 'GRADE',
    'Awarded grade 9-1', 'derived', 'HISTORY', NULL, NULL, 20);
  PERFORM pg_temp.f_measure(fv, 'HIST_GRADE', 'UK_GCSE_9_1', 'GRADE_AWARDED',
    'Grade awarded by the board', 'awarded', 'HISTORY', NULL, NULL, 21);
  -- APPROX AO weightings for 8145: AO1 35%, AO2 35%, AO3 15%, AO4 15%.
  PERFORM pg_temp.f_measure(fv, 'HIST_AO1', 'UK_PCT_0_100', 'AO1', 'AO1 — knowledge and understanding (approx. 35%)', 'observed', 'HISTORY', NULL, 0.35, 41);
  PERFORM pg_temp.f_measure(fv, 'HIST_AO2', 'UK_PCT_0_100', 'AO2', 'AO2 — explain and analyse using second-order concepts (approx. 35%)', 'observed', 'HISTORY', NULL, 0.35, 42);
  PERFORM pg_temp.f_measure(fv, 'HIST_AO3', 'UK_PCT_0_100', 'AO3', 'AO3 — analyse, evaluate and use sources (approx. 15%)', 'observed', 'HISTORY', NULL, 0.15, 43);
  PERFORM pg_temp.f_measure(fv, 'HIST_AO4', 'UK_PCT_0_100', 'AO4', 'AO4 — analyse and evaluate interpretations (approx. 15%)', 'observed', 'HISTORY', NULL, 0.15, 44);

  ---------------------------------------------------------------------------
  -- AQA A-level Biology 7402: papers of 91, 91 and 78 marks, total 260,
  -- graded A*-E, plus the pass/not-classified practical endorsement.
  ---------------------------------------------------------------------------
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA A-level Biology 7402 (first assessment 2017)';

  PERFORM pg_temp.f_measure(fv, 'BIO_P1', 'UK_MARKS_0_91', 'P1', 'Paper 1 (91 marks, 35%)', 'observed', 'BIOLOGY', NULL, 1, 1);
  PERFORM pg_temp.f_measure(fv, 'BIO_P2', 'UK_MARKS_0_91', 'P2', 'Paper 2 (91 marks, 35%)', 'observed', 'BIOLOGY', NULL, 1, 2);
  PERFORM pg_temp.f_measure(fv, 'BIO_P3', 'UK_MARKS_0_78', 'P3', 'Paper 3 (78 marks, 30%)', 'observed', 'BIOLOGY', NULL, 1, 3);
  PERFORM pg_temp.f_measure(fv, 'BIO_TOTAL', 'UK_MARKS_0_260', 'TOTAL', 'Raw mark total (260)', 'derived', 'BIOLOGY', NULL, NULL, 10);
  PERFORM pg_temp.f_measure(fv, 'BIO_GRADE', 'UK_ALEVEL_A_E', 'GRADE', 'Awarded grade A*-E', 'derived', 'BIOLOGY', NULL, NULL, 20);
  PERFORM pg_temp.f_measure(fv, 'BIO_GRADE', 'UK_ALEVEL_A_E', 'GRADE_AWARDED', 'Grade awarded by the board', 'awarded', 'BIOLOGY', NULL, NULL, 21);
  -- The practical endorsement is pass/not-classified, is reported separately on
  -- the certificate, and contributes nothing to the A-Level grade — but a
  -- university offer can be conditional on it. Another zero-weight measure that
  -- must never be aggregated and must never be lost.
  PERFORM pg_temp.f_measure(fv, 'BIO_CPAC', 'UK_PRACT_ENDORSE', 'CPAC',
    'Practical endorsement — pass / not classified (0% of the grade)', 'awarded', 'BIOLOGY', NULL, 0, 30);
  -- APPROX AO weightings for A-level biology (Ofqual science subject criteria):
  -- AO1 30-35%, AO2 40-45%, AO3 25-30%. Midpoints used.
  PERFORM pg_temp.f_measure(fv, 'BIO_AO1', 'UK_PCT_0_100', 'AO1', 'AO1 — knowledge and understanding (approx. 32%)', 'observed', 'BIOLOGY', NULL, 0.32, 41);
  PERFORM pg_temp.f_measure(fv, 'BIO_AO2', 'UK_PCT_0_100', 'AO2', 'AO2 — application (approx. 42%)',                 'observed', 'BIOLOGY', NULL, 0.42, 42);
  PERFORM pg_temp.f_measure(fv, 'BIO_AO3', 'UK_PCT_0_100', 'AO3', 'AO3 — analyse, interpret and evaluate (approx. 26%)', 'observed', 'BIOLOGY', NULL, 0.26, 43);

  ---------------------------------------------------------------------------
  -- The legacy 4365 specification keeps ONE measure: the awarded A*-G grade.
  -- Nothing else is needed — the papers no longer exist and nobody will mark
  -- one again — but the awarded grade must remain recordable or every
  -- pre-2017 result a school imports has nowhere to go, and the department
  -- trend starts in 2017 with no explanation.
  ---------------------------------------------------------------------------
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA GCSE Mathematics 4365 (legacy A*-G, final award 2016)';
  PERFORM pg_temp.f_measure(fv, 'MATH_LEG_GRADE', 'UK_GCSE_LEGACY_A_G', 'GRADE_AWARDED',
    'Legacy GCSE Mathematics grade A*-G awarded by the board', 'awarded', 'MATHEMATICS', NULL, NULL, 20);
END $seed$;

-- ---------------------------------------------------------------------------
-- 4.3 Cambridge International.
--
-- Two structural features that neither the English boards nor the IB have, and
-- that the configuration has to survive:
--
-- TIERING BY SYLLABUS ROUTE. IGCSE Mathematics 0580 is entered at Core (papers
-- 1 and 3, grades C-G / 5-1) or Extended (papers 2 and 4, grades A*-E / 9-1).
-- Structurally identical to Foundation/Higher, so it uses the same mechanism:
-- level_code, and a boundary table for the Core route that simply has no rows
-- above grade 5.
--
-- VARIANTS. Cambridge runs the same paper in several time zones as variants
-- (paper 42, 43, 44...), each marked and BOUNDED separately. There is no
-- variant column in ref.boundary_table, and there should not be one — the
-- variant belongs in session_label, exactly as the IB's timezone does
-- ('June 2024 variant 2'). The UNIQUE (owner, measure, session_label) key then
-- keeps the variants apart automatically.
--
-- Components use the percentage scale rather than raw-mark scales, because
-- Cambridge component totals differ between variants and between syllabus
-- revisions; the per-sitting maximum belongs on gradebook.item.max_value.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE fv uuid; route text;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'CIE' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'Cambridge IGCSE Mathematics 0580 (Core / Extended)';

  -- Core route
  PERFORM pg_temp.f_measure(fv, 'IGMATH_P1', 'UK_PCT_0_100', 'P1', 'Paper 1 — Core, short answer', 'observed', 'MATHEMATICS', 'CORE', 0.35, 1);
  PERFORM pg_temp.f_measure(fv, 'IGMATH_P3', 'UK_PCT_0_100', 'P3', 'Paper 3 — Core, structured',   'observed', 'MATHEMATICS', 'CORE', 0.65, 2);
  PERFORM pg_temp.f_measure(fv, 'IGMATH_GRADE', 'CIE_IGCSE_9_1', 'GRADE',
    'Awarded grade — Core route (maximum grade 5)', 'derived', 'MATHEMATICS', 'CORE', NULL, 20);
  -- Extended route
  PERFORM pg_temp.f_measure(fv, 'IGMATH_P2', 'UK_PCT_0_100', 'P2', 'Paper 2 — Extended, short answer', 'observed', 'MATHEMATICS', 'EXTENDED', 0.35, 1);
  PERFORM pg_temp.f_measure(fv, 'IGMATH_P4', 'UK_PCT_0_100', 'P4', 'Paper 4 — Extended, structured',   'observed', 'MATHEMATICS', 'EXTENDED', 0.65, 2);
  PERFORM pg_temp.f_measure(fv, 'IGMATH_GRADE', 'CIE_IGCSE_9_1', 'GRADE',
    'Awarded grade — Extended route (grades 9-4)', 'derived', 'MATHEMATICS', 'EXTENDED', NULL, 20);

  -- Cambridge International AS & A Level Biology 9700. The AS qualification is
  -- a real, separately certificated award on its own A-E scale, and it is also
  -- half of the A Level. Two grade measures, two rules, one set of papers —
  -- the "staged" structure England abolished in 2015 and the rest of the world
  -- kept. APPROX component weightings within the full A Level.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'CIE' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'Cambridge International AS & A Level Biology 9700';

  PERFORM pg_temp.f_measure(fv, 'BIO_P1', 'UK_PCT_0_100', 'P1', 'Paper 1 — Multiple choice (AS)',             'observed', 'BIOLOGY', NULL, 0.155, 1);
  PERFORM pg_temp.f_measure(fv, 'BIO_P2', 'UK_PCT_0_100', 'P2', 'Paper 2 — AS structured questions',          'observed', 'BIOLOGY', NULL, 0.230, 2);
  PERFORM pg_temp.f_measure(fv, 'BIO_P3', 'UK_PCT_0_100', 'P3', 'Paper 3 — Advanced practical skills',        'observed', 'BIOLOGY', NULL, 0.115, 3);
  PERFORM pg_temp.f_measure(fv, 'BIO_P4', 'UK_PCT_0_100', 'P4', 'Paper 4 — A Level structured questions',     'observed', 'BIOLOGY', NULL, 0.385, 4);
  PERFORM pg_temp.f_measure(fv, 'BIO_P5', 'UK_PCT_0_100', 'P5', 'Paper 5 — Planning, analysis and evaluation','observed', 'BIOLOGY', NULL, 0.115, 5);
  PERFORM pg_temp.f_measure(fv, 'BIO_AS_GRADE', 'CIE_AS_A_E', 'AS_GRADE', 'Cambridge International AS Level grade A-E', 'derived', 'BIOLOGY', 'AS', NULL, 20);
  PERFORM pg_temp.f_measure(fv, 'BIO_AL_GRADE', 'CIE_AL_A_E', 'AL_GRADE', 'Cambridge International A Level grade A*-E', 'derived', 'BIOLOGY', 'AL', NULL, 21);
END $seed$;

-- ===========================================================================
-- 5. WORKED EXAMPLE — a 16-mark essay is 6 marks AO1 and 10 marks AO2
--
-- This section inserts nothing. It is the instruction manual for the one join
-- that makes UK assessment objective analytics work, written out in full
-- because it is the thing a developer will otherwise get wrong.
--
-- THE PROBLEM. A GCSE History Paper 2 question reads "Has the main consequence
-- of X been Y? [16 marks]". The board's mark scheme allocates that question's
-- 16 marks across assessment objectives: 6 to AO1 (knowledge and understanding
-- of the period) and 10 to AO2 (explanation and analysis using second-order
-- concepts). One question, two objectives, a weighted split.
--
-- THE WRONG MODELS, and what each costs:
--   * item.measure_id alone — one measure per question. Forces a choice; the
--     16-mark essay gets tagged AO2 and 6 marks of AO1 evidence vanish. Across
--     a paper this is a third of the AO1 evidence in the qualification.
--   * a percentage column on the item — "this question is 37.5% AO1". Cannot
--     express that AO1 is capped at 6 marks regardless of how well the student
--     writes, which is exactly how the mark scheme works.
--   * doing it in the application layer — every report then re-implements the
--     split, and two reports disagree.
--
-- THE MODEL: gradebook.item_measure_alloc, a WEIGHTED many-to-many between one
-- item and the measures it carries marks for, keyed (tenant_id, item_id,
-- measure_id) with marks > 0. Written out for this question:
--
--   -- the assessment: a mock Paper 2, marked question by question
--   INSERT INTO gradebook.assessment (tenant_id, teaching_group_id, title, kind,
--                                     occurred_on, max_total)
--   VALUES (:tenant, :y11_history_set, 'Mock Paper 2 — Shaping the nation',
--           'mock', DATE '2025-02-11', 84)
--   RETURNING id;                                   -- => :assessment
--
--   -- the 16-mark question, as one item
--   INSERT INTO gradebook.item (tenant_id, assessment_id, seq, label, max_value,
--                               scale_id, topic_tag_id)
--   VALUES (:tenant, :assessment, 7, 'Q7 — consequence essay', 16,
--           (SELECT id FROM ref.scale WHERE code = 'UK_MARKS_0_84'
--              AND owner_tenant_id = app.global_tenant()),
--           :tag_elizabethan_england)
--   RETURNING id;                                   -- => :item
--
--   -- the AO split, straight off the mark scheme: 6 + 10 = 16
--   INSERT INTO gradebook.item_measure_alloc (tenant_id, item_id, measure_id, marks)
--   SELECT :tenant, :item, m.id, a.marks
--   FROM (VALUES ('AO1', 6::numeric), ('AO2', 10::numeric)) AS a(code, marks)
--   JOIN ref.measure m ON m.code = a.code AND m.subject_group_code = 'HISTORY'
--   JOIN ref.framework_version fv ON fv.id = m.framework_version_id
--   JOIN ref.framework f ON f.id = fv.framework_id AND f.code = 'UK_AQA'
--   WHERE fv.label = 'AQA GCSE History 8145 (first assessment 2018)';
--
-- WHAT IT BUYS. The teacher still types ONE number per student — the mark out
-- of 16. The AO profile is then a query, not extra data entry:
--
--   SELECT m.code                                   AS assessment_objective,
--          sum(r.raw_value * a.marks / i.max_value) AS ao_marks_earned,
--          sum(a.marks)                             AS ao_marks_available,
--          round(100 * sum(r.raw_value * a.marks / i.max_value)
--                    / nullif(sum(a.marks), 0), 1)  AS ao_pct
--   FROM gradebook.result r
--   JOIN gradebook.item i                 ON i.id = r.item_id
--   JOIN gradebook.item_measure_alloc a   ON a.item_id = i.id AND a.tenant_id = r.tenant_id
--   JOIN ref.measure m                    ON m.id = a.measure_id
--   WHERE r.student_id = :student AND r.status = 'scored'
--   GROUP BY m.code ORDER BY m.code;
--
-- THE HONEST CAVEAT, which belongs in the UI and not only here: apportioning a
-- question's marks to AOs in proportion to the AO split assumes the student
-- lost marks evenly across the objectives. That is an assumption, not a
-- measurement — a student who wrote a factually rich but unanalytical answer
-- lost AO2 marks specifically. Only a mark scheme applied objective by
-- objective (which some departments do, and which this schema supports by
-- making the 16-mark question TWO items of 6 and 10) measures it directly. The
-- proportional version is still far better than throwing AO1 away, and a
-- department that wants the exact version can have it without a schema change.
--
-- AND THE REASON TO BOTHER: the AO profile is the one diagnosis that a UK
-- percentage cannot give. Two students on 58% of a history paper, one strong
-- on AO1 and weak on AO3-AO4, the other the reverse, need completely different
-- teaching. The mark is identical. The profile is not.
-- ===========================================================================

-- ===========================================================================
-- 6. GRADE BOUNDARIES AND THE RULES THAT APPLY THEM
--
-- READ THIS BEFORE USING ANY NUMBER BELOW.
--
-- Every boundary table in this section is ILLUSTRATIVE and is flagged both in
-- source_ref and by is_provisional = true. Real boundaries are set by each
-- board AFTER marking, published per specification per tier per series, and
-- they move — several marks either way, every June, for reasons (question
-- difficulty, cohort ability, statistical predictions) that are invisible in
-- advance. A seeded boundary that looks authoritative and is not would produce
-- confidently wrong predicted grades for real students, which is the single
-- most damaging failure mode this platform has. So: plausible shapes, real
-- structure, fake numbers, loudly labelled.
--
-- WHAT IS REAL in this section, and is the actual point of it:
--   * the structure — three papers, these totals, these grade sets;
--   * that each board's boundaries are INDEPENDENT of every other board's;
--   * that Foundation tier has no rows above grade 5;
--   * that Higher tier has an "allowed grade 3" band below the grade 4
--     boundary, which exists so that a candidate who was mis-entered for the
--     Higher tier is not automatically ungraded;
--   * that a new series is a NEW ref.boundary_table row, never an edit of an
--     old one. Last year's results must keep resolving against last year's
--     boundaries forever; editing in place silently rewrites history.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 6.1 GCSE Mathematics, three boards, both tiers, June 2024.
--
-- The comparison this makes possible, and the reason all three are seeded:
--
--   board      tier    grade 4 boundary    as % of total
--   AQA        H       62 / 240            25.8%
--   Edexcel    H       70 / 240            29.2%
--   OCR        H       67 / 300            22.3%
--
-- A student scoring 65 raw marks is a grade 4 with AQA and a grade 3 with
-- Edexcel, on the same day, in the same subject, at the same standard of
-- attainment. This is not a scandal — it is what boundaries are FOR; the
-- papers differ in difficulty and the boundary is what makes the GRADE
-- comparable. But it does mean that a raw mark without its boundary table is
-- meaningless, and that a department comparing "our average mark" across a
-- board switch is comparing nothing at all. In this schema you cannot make
-- that mistake silently: the mark and the grade live on different scales and
-- only ref.boundary_table connects them.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE
  fv uuid; m_total uuid; m_grade uuid; bt uuid; rule uuid; spec record;
BEGIN
  FOR spec IN SELECT * FROM (VALUES
      -- board, spec label, total scale, ceiling, Foundation cuts (1,2,3,4,5),
      -- Higher cuts (3,4,5,6,7,8,9)
      ('UK_AQA',     'AQA GCSE Mathematics 8300 (first assessment 2017)',
       'UK_MARKS_0_240', 241::numeric,
       ARRAY[20,55,96,137,178]::numeric[],  ARRAY[48,62,90,118,146,174,202]::numeric[]),
      ('UK_EDEXCEL', 'Pearson Edexcel GCSE Mathematics 1MA1 (first assessment 2017)',
       'UK_MARKS_0_240', 241::numeric,
       ARRAY[18,52,93,134,175]::numeric[],  ARRAY[56,70,97,124,151,178,205]::numeric[]),
      ('UK_OCR',     'OCR GCSE Mathematics J560 (first assessment 2017)',
       'UK_MARKS_0_300', 301::numeric,
       ARRAY[24,66,116,166,216]::numeric[], ARRAY[50,67,100,133,166,199,232]::numeric[])
    ) AS s(board, spec_label, total_scale, ceiling, f_cuts, h_cuts)
  LOOP
    SELECT fv2.id INTO fv FROM ref.framework_version fv2
      JOIN ref.framework f ON f.id = fv2.framework_id
     WHERE f.owner_tenant_id = app.global_tenant() AND f.code = spec.board
       AND fv2.label = spec.spec_label;

    ------------------------------------------------------------ Foundation ---
    m_total := pg_temp.f_mid(fv, 'TOTAL', 'MATHEMATICS', 'F');
    m_grade := pg_temp.f_mid(fv, 'GRADE', 'MATHEMATICS', 'F');

    bt := pg_temp.f_bt(m_grade, spec.total_scale, 'UK_GCSE_9_1', 'June 2024',
                       DATE '2024-06-01',
                       'ILLUSTRATIVE — shaped like a real Foundation tier boundary set, NOT the published ' || spec.board || ' June 2024 boundaries',
                       true);
    -- SIX out_codes only: U,1,2,3,4,5. There is no row for 6, 7, 8 or 9 and
    -- there never can be one, because ref.apply_boundary() can only return an
    -- out_code that exists. THIS IS THE FOUNDATION TIER CAP, expressed as an
    -- absence rather than as a rule somebody has to remember to enforce.
    PERFORM pg_temp.f_bset(bt, ARRAY['U','1','2','3','4','5'], spec.f_cuts, 0, spec.ceiling);

    rule := pg_temp.f_rule(m_grade, 'boundary', bt,
      'Foundation tier: apply the June 2024 boundary set to the raw total. The table has no band above grade 5, so a Foundation entry cannot be awarded one.',
      true, DATE '2024-06-01');
    PERFORM pg_temp.f_input(rule, m_total, 1, true);

    -- The total itself: the plain sum of the three papers. requires_all_inputs
    -- is FALSE on purpose — a teacher who has marked two of three mock papers
    -- still wants a provisional total, flagged low-confidence, rather than a
    -- blank cell that makes the product look broken in week two of the mocks.
    PERFORM pg_temp.f_input(
      pg_temp.f_rule(m_total, 'sum', NULL,
        'Raw total = Paper 1 + Paper 2 + Paper 3. Partial totals are allowed and are reported as low-confidence.',
        false),
      pg_temp.f_mid(fv, 'P1', 'MATHEMATICS', 'F'), 1, false);
    PERFORM pg_temp.f_input(pg_temp.f_rule(m_total, 'sum'), pg_temp.f_mid(fv, 'P2', 'MATHEMATICS', 'F'), 1, false);
    PERFORM pg_temp.f_input(pg_temp.f_rule(m_total, 'sum'), pg_temp.f_mid(fv, 'P3', 'MATHEMATICS', 'F'), 1, false);

    ---------------------------------------------------------------- Higher ---
    m_total := pg_temp.f_mid(fv, 'TOTAL', 'MATHEMATICS', 'H');
    m_grade := pg_temp.f_mid(fv, 'GRADE', 'MATHEMATICS', 'H');

    bt := pg_temp.f_bt(m_grade, spec.total_scale, 'UK_GCSE_9_1', 'June 2024',
                       DATE '2024-06-01',
                       'ILLUSTRATIVE — shaped like a real Higher tier boundary set, NOT the published ' || spec.board || ' June 2024 boundaries',
                       true);
    -- EIGHT out_codes: U,3,4,5,6,7,8,9. Note what is missing in the middle —
    -- there is no grade 1 or 2 on the Higher tier. The band between the
    -- ungraded floor and the grade 4 boundary is the ALLOWED GRADE 3, a
    -- deliberate safety net for a mis-entered candidate. Below it is U: a
    -- Higher tier candidate who cannot reach the allowed grade 3 gets nothing
    -- at all, which is why tiering decisions matter so much.
    PERFORM pg_temp.f_bset(bt, ARRAY['U','3','4','5','6','7','8','9'], spec.h_cuts, 0, spec.ceiling);

    rule := pg_temp.f_rule(m_grade, 'boundary', bt,
      'Higher tier: grades 9-4 plus the allowed grade 3 safety net. A candidate below the allowed grade 3 boundary is ungraded.',
      true, DATE '2024-06-01');
    PERFORM pg_temp.f_input(rule, m_total, 1, true);

    PERFORM pg_temp.f_input(
      pg_temp.f_rule(m_total, 'sum', NULL,
        'Raw total = Paper 1 + Paper 2 + Paper 3.', false),
      pg_temp.f_mid(fv, 'P1', 'MATHEMATICS', 'H'), 1, false);
    PERFORM pg_temp.f_input(pg_temp.f_rule(m_total, 'sum'), pg_temp.f_mid(fv, 'P2', 'MATHEMATICS', 'H'), 1, false);
    PERFORM pg_temp.f_input(pg_temp.f_rule(m_total, 'sum'), pg_temp.f_mid(fv, 'P3', 'MATHEMATICS', 'H'), 1, false);
  END LOOP;
END $seed$;

-- ---------------------------------------------------------------------------
-- 6.2 A SECOND SERIES for one specification, to prove that two regimes coexist.
--
-- ref.conversion_rule carries valid_from/valid_to. A school running this
-- platform across several years has 2024 leavers whose grades must keep
-- resolving against June 2024 boundaries and current Year 11 whose mocks
-- should be judged against June 2025. Both rules exist simultaneously,
-- discriminated by date, and neither overwrites the other — the same mechanism
-- the Greek seed needs for the 2016 and 2021 μόρια formulae.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE fv uuid; m_total uuid; m_grade uuid; bt uuid; rule uuid;
BEGIN
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA GCSE Mathematics 8300 (first assessment 2017)';

  m_total := pg_temp.f_mid(fv, 'TOTAL', 'MATHEMATICS', 'H');
  m_grade := pg_temp.f_mid(fv, 'GRADE', 'MATHEMATICS', 'H');

  bt := pg_temp.f_bt(m_grade, 'UK_MARKS_0_240', 'UK_GCSE_9_1', 'June 2025',
                     DATE '2025-06-01',
                     'ILLUSTRATIVE — a plausible next-series shift of 2-4 marks per grade, NOT published AQA June 2025 boundaries',
                     true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','3','4','5','6','7','8','9'],
                         ARRAY[50,65,93,121,149,177,205]::numeric[], 0, 241);

  -- Close the 2024 rule and open the 2025 one. Both rows survive.
  UPDATE ref.conversion_rule r
     SET valid_to = DATE '2025-05-31'
   WHERE r.output_measure_id = m_grade AND r.method = 'boundary'
     AND r.valid_from = DATE '2024-06-01' AND r.valid_to IS NULL;

  rule := pg_temp.f_rule(m_grade, 'boundary', bt,
    'June 2025 series. Supersedes the June 2024 rule by effective date, does not replace it: 2024 results must keep resolving against 2024 boundaries.',
    true, DATE '2025-06-01');
  PERFORM pg_temp.f_input(rule, m_total, 1, true);

  -- supersedes_id makes the same statement about the TABLES, so "show me how
  -- this grade boundary has moved over five years" is a recursive walk rather
  -- than a string match on session_label.
  UPDATE ref.boundary_table nbt
     SET supersedes_id = (SELECT o.id FROM ref.boundary_table o
                           WHERE o.measure_id = m_grade AND o.session_label = 'June 2024')
   WHERE nbt.id = bt AND nbt.supersedes_id IS NULL;
END $seed$;

-- ---------------------------------------------------------------------------
-- 6.3 GCSE English Language — the same subject on two boards, untiered.
-- 6.4 GCSE History and A-level Biology on AQA.
-- 6.5 Cambridge International, including the Core route cap and variants.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE fv uuid; m_total uuid; m_grade uuid; bt uuid; rule uuid;
BEGIN
  ---------------------------------------------------------------- 6.3 -------
  -- AQA English Language 8700, out of 160.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA GCSE English Language 8700 (first assessment 2017)';
  m_total := pg_temp.f_mid(fv, 'TOTAL', 'ENGLISH_LANGUAGE');
  m_grade := pg_temp.f_mid(fv, 'GRADE', 'ENGLISH_LANGUAGE');

  bt := pg_temp.f_bt(m_grade, 'UK_MARKS_0_160', 'UK_GCSE_9_1', 'June 2024', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT the published AQA 8700 June 2024 boundaries', true);
  -- Untiered: the full range U to 9 is available, so every out_code exists.
  PERFORM pg_temp.f_bset(bt, ARRAY['U','1','2','3','4','5','6','7','8','9'],
                         ARRAY[26,39,52,65,78,91,104,117,130]::numeric[], 0, 161);
  rule := pg_temp.f_rule(m_grade, 'boundary', bt, 'Untiered: the whole 9-1 range is available to every candidate.', true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, m_total, 1, true);

  rule := pg_temp.f_rule(m_total, 'sum', NULL, 'Raw total = Paper 1 + Paper 2. The spoken language endorsement is NOT an input: it contributes nothing to the grade.', false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P1', 'ENGLISH_LANGUAGE'), 1, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P2', 'ENGLISH_LANGUAGE'), 1, false);

  -- Edexcel English Language 1EN0, also out of 160 — and deliberately given
  -- DIFFERENT illustrative boundaries, because that is the reality: same
  -- subject, same total, different papers, different cut scores.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_EDEXCEL' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'Pearson Edexcel GCSE English Language 1EN0 (first assessment 2017)';
  m_total := pg_temp.f_mid(fv, 'TOTAL', 'ENGLISH_LANGUAGE');
  m_grade := pg_temp.f_mid(fv, 'GRADE', 'ENGLISH_LANGUAGE');

  bt := pg_temp.f_bt(m_grade, 'UK_MARKS_0_160', 'UK_GCSE_9_1', 'June 2024', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT the published Pearson Edexcel 1EN0 June 2024 boundaries', true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','1','2','3','4','5','6','7','8','9'],
                         ARRAY[22,36,50,64,79,94,109,124,139]::numeric[], 0, 161);
  rule := pg_temp.f_rule(m_grade, 'boundary', bt, 'Untiered.', true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, m_total, 1, true);
  -- The measurable consequence, which a head of department can now query
  -- rather than argue about: a raw 70/160 is a grade 4 under these AQA
  -- boundaries and a grade 3 under these Edexcel ones.

  ---------------------------------------------------------------- 6.4 -------
  -- AQA History 8145, out of 168.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA GCSE History 8145 (first assessment 2018)';
  m_total := pg_temp.f_mid(fv, 'TOTAL', 'HISTORY');
  m_grade := pg_temp.f_mid(fv, 'GRADE', 'HISTORY');

  bt := pg_temp.f_bt(m_grade, 'UK_MARKS_0_168', 'UK_GCSE_9_1', 'June 2024', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT the published AQA 8145 June 2024 boundaries', true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','1','2','3','4','5','6','7','8','9'],
                         ARRAY[20,32,44,57,71,85,100,115,130]::numeric[], 0, 169);
  rule := pg_temp.f_rule(m_grade, 'boundary', bt, 'Untiered.', true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, m_total, 1, true);

  rule := pg_temp.f_rule(m_total, 'sum', NULL, 'Raw total = Paper 1 + Paper 2, each including its SPaG marks.', false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P1', 'HISTORY'), 1, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P2', 'HISTORY'), 1, false);

  -- AQA A-level Biology 7402, out of 260, graded A*-E.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_AQA' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'AQA A-level Biology 7402 (first assessment 2017)';
  m_total := pg_temp.f_mid(fv, 'TOTAL', 'BIOLOGY');
  m_grade := pg_temp.f_mid(fv, 'GRADE', 'BIOLOGY');

  bt := pg_temp.f_bt(m_grade, 'UK_MARKS_0_260', 'UK_ALEVEL_A_E', 'June 2024', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT the published AQA 7402 June 2024 boundaries', true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','E','D','C','B','A','A*'],
                         ARRAY[84,108,132,156,180,202]::numeric[], 0, 261);
  rule := pg_temp.f_rule(m_grade, 'boundary', bt,
    'A-level A*-E. Note that A* is a boundary like any other here; before 2017 it was a separate rule requiring 90% on the A2 units, which is exactly the kind of change that must arrive as a new boundary table and a new effective-dated rule rather than as code.',
    true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, m_total, 1, true);

  rule := pg_temp.f_rule(m_total, 'sum', NULL,
    'Raw total = Paper 1 (91) + Paper 2 (91) + Paper 3 (78). The practical endorsement is not an input.', false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P1', 'BIOLOGY'), 1, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P2', 'BIOLOGY'), 1, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P3', 'BIOLOGY'), 1, false);

  ---------------------------------------------------------------- 6.5 -------
  -- Cambridge IGCSE Mathematics 0580. Components are percentages, combined by
  -- weighted_sum into a percentage, then cut. Two routes, two boundary tables,
  -- and the Core route has no band above grade 5 for exactly the same reason
  -- the Foundation tier does not.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'CIE' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'Cambridge IGCSE Mathematics 0580 (Core / Extended)';

  m_grade := pg_temp.f_mid(fv, 'GRADE', 'MATHEMATICS', 'CORE');
  bt := pg_temp.f_bt(m_grade, 'UK_PCT_0_100', 'CIE_IGCSE_9_1', 'June 2024 variant 2', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT published Cambridge 0580/12+32 June 2024 boundaries. Note the variant in the session label: Cambridge bounds each time-zone variant separately.', true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','1','2','3','4','5'],
                         ARRAY[15,26,38,50,64]::numeric[], 0, 101);
  rule := pg_temp.f_rule(m_grade, 'scaled_sum', bt,
    'Core route: weighted component percentages (Paper 1 35%, Paper 3 65%), then the boundary table. scaled_sum is exactly this two-step — combine, then cut — and exists so the intermediate does not need its own measure row.',
    true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P1', 'MATHEMATICS', 'CORE'), 0.35, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P3', 'MATHEMATICS', 'CORE'), 0.65, true);

  m_grade := pg_temp.f_mid(fv, 'GRADE', 'MATHEMATICS', 'EXTENDED');
  bt := pg_temp.f_bt(m_grade, 'UK_PCT_0_100', 'CIE_IGCSE_9_1', 'June 2024 variant 2', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT published Cambridge 0580/22+42 June 2024 boundaries', true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','4','5','6','7','8','9'],
                         ARRAY[22,33,45,57,70,84]::numeric[], 0, 101);
  rule := pg_temp.f_rule(m_grade, 'scaled_sum', bt,
    'Extended route: Paper 2 35% + Paper 4 65%, then the boundary table. Grades 1-3 are unavailable on this route.',
    true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P2', 'MATHEMATICS', 'EXTENDED'), 0.35, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P4', 'MATHEMATICS', 'EXTENDED'), 0.65, true);

  -- Cambridge Biology 9700: the AS award and the full A Level award are two
  -- different qualifications computed from overlapping component sets. This is
  -- the staged structure, and it is why AS_GRADE and AL_GRADE are separate
  -- measures on separate scales rather than one measure with a flag.
  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'CIE' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'Cambridge International AS & A Level Biology 9700';

  m_grade := pg_temp.f_mid(fv, 'AS_GRADE', 'BIOLOGY', 'AS');
  bt := pg_temp.f_bt(m_grade, 'UK_PCT_0_100', 'CIE_AS_A_E', 'June 2024 variant 2', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT published Cambridge 9700 June 2024 boundaries', true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','E','D','C','B','A'],
                         ARRAY[28,38,48,58,70]::numeric[], 0, 101);
  rule := pg_temp.f_rule(m_grade, 'scaled_sum', bt,
    'AS award from Papers 1, 2 and 3 only, renormalised to 100%. There is no A* at AS, and the scale has no such point.',
    true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P1', 'BIOLOGY'), 0.31, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P2', 'BIOLOGY'), 0.46, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P3', 'BIOLOGY'), 0.23, true);

  m_grade := pg_temp.f_mid(fv, 'AL_GRADE', 'BIOLOGY', 'AL');
  bt := pg_temp.f_bt(m_grade, 'UK_PCT_0_100', 'CIE_AL_A_E', 'June 2024 variant 2', DATE '2024-06-01',
                     'ILLUSTRATIVE — NOT published Cambridge 9700 June 2024 boundaries', true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','E','D','C','B','A','A*'],
                         ARRAY[30,40,50,60,70,82]::numeric[], 0, 101);
  rule := pg_temp.f_rule(m_grade, 'scaled_sum', bt,
    'Full A Level from all five components at their published weightings (AS papers carry forward).',
    true, DATE '2024-06-01');
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P1', 'BIOLOGY'), 0.155, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P2', 'BIOLOGY'), 0.230, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P3', 'BIOLOGY'), 0.115, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P4', 'BIOLOGY'), 0.385, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P5', 'BIOLOGY'), 0.115, true);
END $seed$;

-- ---------------------------------------------------------------------------
-- 6.6 The Edexcel English Language papers, and why they are seeded separately.
--
-- Both boards award a GCSE English Language out of 160 marks. AQA splits that
-- 80 + 80; Edexcel splits it 64 + 96, with the weight of the qualification
-- falling on the non-fiction and transactional writing paper. A department
-- switching board is therefore not just facing different boundaries — it is
-- facing a different balance of what is being examined, which shows up in the
-- AO profile long before it shows up in the grades. Seeding both is what makes
-- that visible instead of anecdotal.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE fv uuid; m_total uuid; rule uuid;
BEGIN
  PERFORM pg_temp.f_scale('UK_MARKS_0_64', 'Exam paper, 64 marks', 'ratio_marks', 0, 64, 1);
  PERFORM pg_temp.f_scale('UK_MARKS_0_96', 'Exam paper, 96 marks', 'ratio_marks', 0, 96, 1);

  SELECT fv2.id INTO fv FROM ref.framework_version fv2
    JOIN ref.framework f ON f.id = fv2.framework_id
   WHERE f.code = 'UK_EDEXCEL' AND f.owner_tenant_id = app.global_tenant()
     AND fv2.label = 'Pearson Edexcel GCSE English Language 1EN0 (first assessment 2017)';

  -- The constructs for these two papers do not exist yet: they are genuinely
  -- new pedagogical identities, not the AQA ones renamed.
  PERFORM pg_temp.f_construct((SELECT framework_id FROM ref.framework_version WHERE id = fv),
    'ENGLANG_P1', 'GCSE English Language Paper 1 — Fiction and imaginative writing', 'component', 'unspecified');
  PERFORM pg_temp.f_construct((SELECT framework_id FROM ref.framework_version WHERE id = fv),
    'ENGLANG_P2', 'GCSE English Language Paper 2 — Non-fiction and transactional writing', 'component', 'unspecified');

  PERFORM pg_temp.f_measure(fv, 'ENGLANG_P1', 'UK_MARKS_0_64', 'P1',
    'Paper 1 — Fiction and imaginative writing (64 marks, 40%)', 'observed', 'ENGLISH_LANGUAGE', NULL, 1, 1);
  PERFORM pg_temp.f_measure(fv, 'ENGLANG_P2', 'UK_MARKS_0_96', 'P2',
    'Paper 2 — Non-fiction and transactional writing (96 marks, 60%)', 'observed', 'ENGLISH_LANGUAGE', NULL, 1, 2);

  m_total := pg_temp.f_mid(fv, 'TOTAL', 'ENGLISH_LANGUAGE');
  rule := pg_temp.f_rule(m_total, 'sum', NULL,
    'Raw total = Paper 1 (64) + Paper 2 (96). A plain sum, not a weighted one: the weighting is already built into the mark allocation.', false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P1', 'ENGLISH_LANGUAGE'), 1, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv, 'P2', 'ENGLISH_LANGUAGE'), 1, false);
END $seed$;

-- ===========================================================================
-- 7. BTEC — a qualification that is accumulated, not marked
--
-- Everything above this line is "mark a paper, add up, cut with boundaries".
-- BTEC is not that, and it is the strongest test in this file of whether a
-- grading system really is just configuration.
--
-- HOW IT WORKS. A BTEC Level 3 National Extended Certificate is 360 guided
-- learning hours made up of four units. Each unit is assessed against published
-- criteria and graded U / Pass / Merit / Distinction — there is no mark, and no
-- boundary table, because a criterion is either met or it is not. Each unit is
-- then worth POINTS in proportion to its size:
--
--     unit size      U     Pass   Merit   Distinction
--      60 GLH        0      6      10      16
--      90 GLH        0      9      15      24
--     120 GLH        0     12      20      32
--
-- The unit points are summed, and the total is cut into the qualification
-- grade: (for the 360-GLH Extended Certificate) Pass 36, Merit 52,
-- Distinction 74, Distinction* 90, out of a possible 96.
-- BELIEVED to match the Pearson 2016 specification's "calculation of
-- qualification grade" tables; flagged as uncertain and to be verified.
--
-- HOW IT IS ENCODED, using nothing new:
--   unit grade      role='observed',  scale BTEC_UNIT_U_P_M_D
--        |          weighted_sum with a single input and weight = the unit's
--        v          maximum points; the unit grade's pct_anchor (0 / 0.375 /
--   unit points     0.625 / 1.0, section 1.5) multiplies out to exactly the
--        |          published tariff. THIS is why that scale had to be
--        v          anchored to the tariff instead of left equally spaced.
--   total points    role='derived',   method='sum' over the four unit points
--        |
--        v
--   qualification   role='derived',   method='boundary' over the points total
--       grade
--
-- Three things worth noticing:
--   * requires_all_inputs = TRUE on the points total, unlike every exam total
--     in this file. A partial BTEC points total is not a provisional estimate
--     of anything — a learner who has completed two units of four has not
--     under-performed, they are mid-course, and showing them a "provisional
--     Pass" would be actively misleading. Same column, opposite value, for a
--     real pedagogical reason.
--   * the grading is CONTINUOUS, not terminal: points accrue as units are
--     completed, so the "current grade" is meaningful all year — which makes
--     BTEC the one qualification here where a live tracker genuinely predicts
--     the final award.
--   * a unit can be resubmitted and regraded, so the same measure legitimately
--     changes value upward over time. gradebook.result_version keeps the
--     history without the current value ever being ambiguous.
-- ===========================================================================

DO $seed$
DECLARE
  fw uuid; fv uuid; u record;
  m_grade uuid; m_pts uuid; m_total uuid; m_qual uuid; bt uuid; rule uuid; sum_rule uuid;
BEGIN
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_BTEC';
  SELECT id INTO fv FROM ref.framework_version
   WHERE framework_id = fw AND label = 'BTEC Level 3 National Extended Certificate in Applied Science (2016 specification)';

  PERFORM pg_temp.f_construct(fw, 'BTEC_POINTS', 'BTEC qualification points total', 'overall', 'unspecified');
  PERFORM pg_temp.f_construct(fw, 'BTEC_QUAL',   'BTEC qualification grade',        'overall', 'unspecified');

  m_total := pg_temp.f_measure(fv, 'BTEC_POINTS', 'BTEC_POINTS_0_120', 'POINTS_TOTAL',
    'Qualification points total (maximum 96 for this 360-GLH qualification)', 'derived', 'APPLIED_SCIENCE', NULL, NULL, 90);
  sum_rule := pg_temp.f_rule(m_total, 'sum', NULL,
    'Total = the sum of the unit points. requires_all_inputs = true: an incomplete BTEC has no meaningful points total, unlike an incomplete exam total.',
    true);

  FOR u IN SELECT * FROM (VALUES
      -- unit code, title, GLH, assessment mode, maximum points (= 16 x GLH/60)
      ('U1', 'Unit 1 — Principles and Applications of Science I',    90,  'external', 24::numeric),
      ('U2', 'Unit 2 — Practical Scientific Procedures and Techniques', 90, 'internal', 24::numeric),
      ('U3', 'Unit 3 — Science Investigation Skills',               120,  'external', 32::numeric),
      ('U8', 'Unit 8 — Physiology of Human Body Systems',            60,  'internal', 16::numeric)
    ) AS x(code, title, glh, mode, max_pts)
  LOOP
    PERFORM pg_temp.f_construct(fw, u.code, u.title, 'component', 'unspecified');

    -- The unit grade, as marked. subject_group_code carries the assessment
    -- mode because it changes what the data MEANS: an externally assessed unit
    -- is a Pearson-set task, an internally assessed one is the teacher's own
    -- judgement against the criteria, and mixing them in a "grade profile"
    -- without being able to tell them apart hides the only place where
    -- internal standards can drift.
    m_grade := pg_temp.f_measure(fv, u.code, 'BTEC_UNIT_U_P_M_D', u.code || '_GRADE',
      u.title || ' — unit grade (' || u.glh || ' GLH, ' || u.mode || ')',
      'observed', upper(u.mode), NULL, NULL, 10);

    -- The unit's points. weighted_sum over a single input, with the weight set
    -- to the unit's maximum points: U -> 0, P -> 0.375 x max, M -> 0.625 x max,
    -- D -> 1.0 x max, which reproduces the published tariff exactly.
    m_pts := pg_temp.f_measure(fv, u.code, 'BTEC_POINTS_0_120', u.code || '_POINTS',
      u.title || ' — unit points (maximum ' || u.max_pts || ')',
      'derived', upper(u.mode), NULL, u.max_pts, 20);

    rule := pg_temp.f_rule(m_pts, 'weighted_sum', NULL,
      'Unit points = unit grade position on the tariff x maximum points for the unit size. The tariff lives in ref.scale_point.pct_anchor for BTEC_UNIT_U_P_M_D.',
      true);
    PERFORM pg_temp.f_input(rule, m_grade, u.max_pts, true);

    PERFORM pg_temp.f_input(sum_rule, m_pts, 1, true);
  END LOOP;

  -- The qualification grade. A boundary table over POINTS, not over marks —
  -- the same mechanism doing a completely different job, which is the point.
  m_qual := pg_temp.f_measure(fv, 'BTEC_QUAL', 'BTEC_QUAL_U_P_M_D_DS', 'QUAL_GRADE',
    'Qualification grade U / P / M / D / D*', 'derived', 'APPLIED_SCIENCE', NULL, NULL, 95);

  bt := pg_temp.f_bt(m_qual, 'BTEC_POINTS_0_120', 'BTEC_QUAL_U_P_M_D_DS',
                     '2016 specification (points thresholds)', DATE '2016-09-01',
                     'Pearson BTEC Nationals 2016 specification, calculation of qualification grade — BELIEVED CORRECT, NOT VERIFIED against the published table',
                     true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','P','M','D','D*'],
                         ARRAY[36,52,74,90]::numeric[], 0, 121);
  -- Unlike every exam boundary in this file, these thresholds do NOT move
  -- between series. They are printed in the specification and hold for its
  -- lifetime, which is why the session_label names the specification rather
  -- than a month. The same table, used two ways, because the vocabulary
  -- ('session') was chosen to be about VERSIONS rather than about exams.
  rule := pg_temp.f_rule(m_qual, 'boundary', bt,
    'Qualification grade = the points total cut at 36 / 52 / 74 / 90.', true);
  PERFORM pg_temp.f_input(rule, m_total, 1, true);
END $seed$;

-- ===========================================================================
-- 8. KEY STAGE 3 — a SCHOOL-OWNED framework
--
-- THIS SECTION IS THE TEMPLATE. Copy it for any school's internal scheme.
--
-- Why it matters more than it looks. Between the end of primary school and the
-- start of GCSE courses there are three years with no national qualification,
-- no national scale, and — since National Curriculum levels were withdrawn in
-- 2014 — no shared vocabulary whatsoever. Every secondary school in England
-- invented its own scheme. They are all different, they change every few years
-- when a new deputy head arrives, and they generate the MAJORITY of the marks a
-- secondary school records. A platform that only understands qualifications
-- understands nothing about half its own data.
--
-- Everything below is owned by ONE TENANT, not by app.global_tenant():
--   ref.framework.owner_tenant_id   = the school
--   ref.scale.owner_tenant_id       = the school
--   ref.boundary_table.owner_tenant_id = the school
--   ref.conversion_rule.owner_tenant_id = the school
--   ref.benchmark.owner_tenant_id   = the school
-- The RLS policies in 009_rls.sql make these rows invisible to every other
-- tenant while platform rows stay readable by all, so a school can invent
-- whatever it likes without polluting anyone else's configuration and without
-- anyone at the platform ever seeing it.
--
-- Note the mixed ownership in what follows: a school-owned framework whose
-- measures sit on a school-owned scale, but whose flight-path target sits on
-- the PLATFORM'S GCSE 9-1 scale. That is the intended shape. The school owns
-- its vocabulary; the national qualification it is aiming at stays national,
-- so the school's targets remain comparable with everyone else's outcomes.
-- ===========================================================================

DO $seed$
DECLARE
  t uuid; fw uuid; fv uuid; s_mastery uuid; s_points uuid;
  m_strand uuid; m_overall uuid; m_pred uuid; bt uuid; rule uuid; st record;
BEGIN
  SELECT id INTO t FROM platform.tenant WHERE slug = 'greenfield-academy';

  fw := pg_temp.f_framework('KS3_INTERNAL', 'Greenfield Academy — Key Stage 3 mastery scheme', 'GB',
                            'Greenfield Academy (internal)', t);
  fv := pg_temp.f_version(fw, 'Greenfield Academy KS3 assessment policy, 2024-25', DATE '2024-09-01');

  -- The school's own scale. Four named steps, the commonest shape of the
  -- post-levels schemes: a statement about SECURITY of understanding rather
  -- than a mark.
  s_mastery := pg_temp.f_scale('GFA_KS3_MASTERY', 'Greenfield KS3 mastery step', 'ordinal_grade',
                               NULL, NULL, 0, t);
  PERFORM ref.seed_scale_points(s_mastery, ARRAY['EMERGING','DEVELOPING','SECURE','MASTERED']);
  UPDATE ref.scale_point SET label = x.lbl, is_pass = x.pass
    FROM (VALUES ('EMERGING','Emerging',false),('DEVELOPING','Developing',false),
                 ('SECURE','Secure',true),('MASTERED','Mastered',true)) AS x(code,lbl,pass)
   WHERE scale_id = s_mastery AND ref.scale_point.code = x.code;
  -- LEFT 'assumed_linear', AND THIS IS THE IMPORTANT PART OF THE WHOLE SECTION.
  -- The school has no idea, on day one, how far apart Developing and Secure
  -- are, or what proportion of its students should be at each step. Equal
  -- spacing is therefore the honest starting position and the scale must NOT
  -- be pooled with anything. The school can fix this itself, and section 12
  -- explains exactly how: after its first cohort reaches Year 11, regress the
  -- Year 9 mastery steps against the GCSE grades those same students actually
  -- got, set pct_anchor from the observed cumulative distribution, and only
  -- then set equating_status = 'anchored'. At that moment — and not before —
  -- "our Year 8 is a grade 5 cohort" becomes a defensible sentence instead of
  -- a staffroom guess.

  -- A numeric working scale so strand steps can be averaged into one number.
  s_points := pg_temp.f_scale('GFA_KS3_POINTS', 'Greenfield KS3 mean mastery points (1-4)',
                              'interval_points', 1, 4, 2, t);

  PERFORM pg_temp.f_construct(fw, 'KS3_OVERALL',  'KS3 overall attainment in the subject', 'overall', 'unspecified');
  PERFORM pg_temp.f_construct(fw, 'KS3_PRED_GCSE','KS3 flight path — projected GCSE grade', 'overall', 'unspecified');

  m_overall := pg_temp.f_measure(fv, 'KS3_OVERALL', 'GFA_KS3_POINTS', 'OVERALL',
    'Mean mastery across the strands', 'derived', 'MATHEMATICS', 'Y8', NULL, 50);
  rule := pg_temp.f_rule(m_overall, 'mean', NULL,
    'Mean of whichever strands have been assessed so far. requires_all_inputs = false: half the strands are untaught in September and a blank overall would make the tracker useless for two terms.',
    false, DATE '2024-09-01', NULL, t);

  -- The strands. Deliberately the National Curriculum KS3 mathematics
  -- headings, because even schools that invent their own scheme almost always
  -- keep the statutory strand names — which is what makes cross-school
  -- comparison of KS3 possible at all.
  FOR st IN SELECT * FROM (VALUES
      ('NUMBER',   'Number',                    1),
      ('ALGEBRA',  'Algebra',                   2),
      ('RATIO',    'Ratio, proportion and rates of change', 3),
      ('GEOMETRY', 'Geometry and measures',     4),
      ('STATS',    'Probability and statistics',5)
    ) AS x(code, label, ord)
  LOOP
    PERFORM pg_temp.f_construct(fw, 'KS3_' || st.code, 'KS3 ' || st.label, 'skill', 'unspecified');
    m_strand := pg_temp.f_measure(fv, 'KS3_' || st.code, 'GFA_KS3_MASTERY', st.code,
      st.label || ' — mastery step', 'observed', 'MATHEMATICS', 'Y8', 1, st.ord);
    PERFORM pg_temp.f_input(rule, m_strand, 1, false);

    -- Band descriptors, so the marking screen shows the school's own wording
    -- inline. This is the single biggest speed-up in step-based marking: the
    -- teacher stops opening the policy document in another tab.
    -- NOTE A SCHEMA COMPROMISE: ref.measure_band.bounds is a numrange, but this
    -- measure's values are CODES. The bands are therefore expressed over
    -- ordinal_rank (1 = Emerging ... 4 = Mastered) and the UI has to know that.
    PERFORM pg_temp.f_band(m_strand, 1, 2, 'Emerging',
      'Recalls isolated facts and procedures in ' || lower(st.label) || ' with prompting; cannot yet apply them to an unfamiliar question.');
    PERFORM pg_temp.f_band(m_strand, 2, 3, 'Developing',
      'Applies standard ' || lower(st.label) || ' methods correctly in familiar contexts; errors appear when the context changes.');
    PERFORM pg_temp.f_band(m_strand, 3, 4, 'Secure',
      'Applies ' || lower(st.label) || ' reliably in unfamiliar contexts and explains the reasoning.');
    PERFORM pg_temp.f_band(m_strand, 4, 5, 'Mastered',
      'Selects and combines ' || lower(st.label) || ' methods in multi-step problems and generalises the result.');
  END LOOP;

  ---------------------------------------------------------------------------
  -- The flight path: the school's own mapping from KS3 attainment to a
  -- projected GCSE grade. role='predicted', on the PLATFORM's GCSE scale.
  --
  -- This is where an internal scheme earns its keep, and also where it is most
  -- dangerous. The mapping below is the school's professional judgement, not
  -- evidence. It is marked ILLUSTRATIVE and provisional, and the school should
  -- replace it with its own regression the moment it has one cohort of
  -- KS3-to-GCSE data — at which point this becomes the most valuable table in
  -- the school's database, because it is the only one derived from ITS OWN
  -- students rather than from a national average.
  ---------------------------------------------------------------------------
  m_pred := pg_temp.f_measure(fv, 'KS3_PRED_GCSE', 'UK_GCSE_9_1', 'PRED_GCSE',
    'Projected GCSE grade from KS3 mastery (school flight path)', 'predicted', 'MATHEMATICS', 'Y8', NULL, 60);

  bt := pg_temp.f_bt(m_pred, 'GFA_KS3_POINTS', 'UK_GCSE_9_1', 'Greenfield flight path 2024-25',
                     DATE '2024-09-01',
                     'ILLUSTRATIVE — the school''s professional judgement, NOT a regression on outcome data. Replace after the first cohort completes GCSE.',
                     true, t);
  PERFORM pg_temp.f_bset(bt, ARRAY['2','3','4','5','6','7','8','9'],
                         ARRAY[1.5,2.0,2.4,2.8,3.2,3.5,3.8]::numeric[], 1, 4.01);
  rule := pg_temp.f_rule(m_pred, 'boundary', bt,
    'School flight path: mean KS3 mastery points -> projected GCSE grade. School-owned, invisible to other tenants.',
    true, DATE '2024-09-01', NULL, t);
  PERFORM pg_temp.f_input(rule, m_overall, 1, true);
  -- The bottom band is grade 2, not U: a Year 8 student at Emerging across the
  -- board is not predicted to be ungraded three years later, they are predicted
  -- to need intervention. A flight path that predicts U for eleven-year-olds
  -- is a flight path that gets switched off within a week — and rightly so.
END $seed$;

-- ===========================================================================
-- 9. BASELINES, PREDICTIONS AND TARGET GRADES
--
-- A UK secondary school runs on the gap between three numbers for every
-- student: where they started, where they are predicted to end up, and what
-- they are being asked to aim at. Those are not annotations on a grade; they
-- are measures in their own right, and this section makes them so.
--
--   BASELINE      a standardised cognitive test taken on entry — CAT4 (GL
--                 Assessment) or MidYIS (CEM). Reported as a standardised age
--                 score with a national mean of 100 and a standard deviation
--                 of 15, so 115 is one SD above the national average for the
--                 student's exact age in months. role='awarded': it is a
--                 result issued by an external body, not a prediction.
--
--   PREDICTION    what the evidence says is likely. Either computed here from
--                 a baseline (an indicative-grade lookup) or imported from a
--                 provider's own model. role='predicted'.
--
--   TARGET        what the student is being asked to achieve. Not a
--                 prediction: a target is a DECISION, usually deliberately set
--                 above the prediction, and the two must never be conflated.
--                 role='predicted' as well, because the schema's role
--                 vocabulary has no 'target' value — but gradebook.outcome
--                 does distinguish them, with kind='target' against
--                 kind='predicted_model' / 'predicted_teacher'. See the misfit
--                 note in section 12.
--
-- SOME PREDICTED MEASURES HAVE A CONVERSION RULE AND SOME DO NOT, on purpose:
--   * CAT4 indicative GCSE grade — computed here, from a lookup table, so the
--     rule exists and the derivation is inspectable;
--   * FFT and Alps targets — IMPORTED. FFT estimates come from a national
--     value-added model over prior attainment and pupil characteristics; Alps
--     minimum expected grades come from a subject-by-subject grid over mean
--     GCSE score. Neither is a lookup this platform can or should reproduce,
--     and pretending otherwise in a conversion_rule would be a fabrication.
--     They arrive as gradebook.outcome rows with kind='target' and
--     determination_method='external_import'. ref.v_config_errors does not
--     demand a rule for role='predicted', which is exactly right.
-- ===========================================================================

DO $seed$
DECLARE
  fw uuid; fv uuid; b record;
  m_cat4 uuid; m_mean_gcse uuid; m_pred uuid; m_meg uuid; bt uuid; rule uuid;
  m_src uuid;
BEGIN
  SELECT id INTO fw FROM ref.framework WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_BASELINE_TARGET';
  SELECT id INTO fv FROM ref.framework_version WHERE framework_id = fw AND label = 'Baseline and target grade model (generic)';

  ------------------------------------------------------------- baselines ----
  -- CAT4 reports four battery scores plus a mean. The batteries matter
  -- individually and not only in aggregate: a student with a verbal score 20
  -- points below their quantitative and non-verbal scores is the classic
  -- profile of an EAL learner or an undiagnosed language difficulty, and that
  -- is invisible in the mean. Seeding the batteries as separate measures is
  -- what lets the platform surface it.
  PERFORM pg_temp.f_construct(fw, 'CAT4_MEAN',      'CAT4 mean standardised age score',        'overall', 'unspecified');
  PERFORM pg_temp.f_construct(fw, 'CAT4_VERBAL',    'CAT4 verbal reasoning',                   'skill',   'knowledge');
  PERFORM pg_temp.f_construct(fw, 'CAT4_QUANT',     'CAT4 quantitative reasoning',             'skill',   'application');
  PERFORM pg_temp.f_construct(fw, 'CAT4_NONVERBAL', 'CAT4 non-verbal reasoning',               'skill',   'analysis');
  PERFORM pg_temp.f_construct(fw, 'CAT4_SPATIAL',   'CAT4 spatial ability',                    'skill',   'analysis');
  PERFORM pg_temp.f_construct(fw, 'MIDYIS',         'MidYIS overall standardised score',       'overall', 'unspecified');
  PERFORM pg_temp.f_construct(fw, 'MEAN_GCSE',      'Mean GCSE points score (prior attainment)','overall','unspecified');
  PERFORM pg_temp.f_construct(fw, 'TARGET_GCSE',    'Target / expected GCSE grade',            'overall', 'unspecified');
  PERFORM pg_temp.f_construct(fw, 'TARGET_ALEVEL',  'Target / minimum expected A-Level grade', 'overall', 'unspecified');

  m_cat4 := pg_temp.f_measure(fv, 'CAT4_MEAN', 'UK_SAS_60_140', 'CAT4_MEAN',
    'CAT4 mean SAS (national mean 100, SD 15)', 'awarded', NULL, NULL, NULL, 1);
  FOR b IN SELECT * FROM (VALUES
      ('CAT4_VERBAL','CAT4_VERBAL','CAT4 verbal reasoning SAS',2),
      ('CAT4_QUANT','CAT4_QUANT','CAT4 quantitative reasoning SAS',3),
      ('CAT4_NONVERBAL','CAT4_NONVERBAL','CAT4 non-verbal reasoning SAS',4),
      ('CAT4_SPATIAL','CAT4_SPATIAL','CAT4 spatial ability SAS',5)
    ) AS x(con, code, label, ord)
  LOOP
    PERFORM pg_temp.f_measure(fv, b.con, 'UK_SAS_60_140', b.code, b.label, 'awarded', NULL, NULL, NULL, b.ord);
  END LOOP;
  PERFORM pg_temp.f_measure(fv, 'MIDYIS', 'UK_SAS_60_140', 'MIDYIS',
    'MidYIS overall standardised score (national mean 100, SD 15)', 'awarded', NULL, NULL, NULL, 6);

  --------------------------------------------------- prior attainment -------
  -- Mean GCSE points score: the input to every sixth-form target model in the
  -- country. Computed as the mean of the student's awarded GCSE grades read as
  -- points, ACROSS BOARDS — which is a genuine cross-framework computation and
  -- the cleanest demonstration in this file that conversion_input is not
  -- restricted to one framework.
  m_mean_gcse := pg_temp.f_measure(fv, 'MEAN_GCSE', 'UK_MEAN_GCSE_0_9', 'MEAN_GCSE',
    'Mean GCSE points score across all subjects taken', 'derived', NULL, NULL, NULL, 10);
  rule := pg_temp.f_rule(m_mean_gcse, 'mean', NULL,
    'Mean of the awarded GCSE grades this student actually holds, read as points 9..1. '
    'THE INPUT LIST BELOW IS ILLUSTRATIVE AND STRUCTURALLY INCOMPLETE: a student takes eight to eleven GCSEs '
    'chosen individually, so the true input set is per-student and cannot be enumerated in configuration. '
    'Every input is therefore is_required = false and requires_all_inputs = false, and the application must '
    'compute this over whatever awarded GCSE outcomes the student has. See the schema misfit note in section 12.',
    false);
  FOR b IN SELECT m.id AS mid FROM ref.measure m
             JOIN ref.framework_version fv2 ON fv2.id = m.framework_version_id
             JOIN ref.framework f ON f.id = fv2.framework_id
            WHERE f.owner_tenant_id = app.global_tenant()
              AND f.code IN ('UK_AQA','UK_EDEXCEL','UK_OCR')
              AND m.code = 'GRADE_AWARDED'
  LOOP
    PERFORM pg_temp.f_input(rule, b.mid, 1, false);
  END LOOP;

  ------------------------------------------------- computed prediction ------
  -- CAT4 indicative GCSE grade. GL Assessment publishes indicative GCSE grade
  -- tables against CAT4 scores; the mapping below has the right SHAPE (a
  -- roughly one-grade step per 6-7 SAS points through the middle of the range)
  -- but the numbers are ILLUSTRATIVE.
  m_pred := pg_temp.f_measure(fv, 'TARGET_GCSE', 'UK_GCSE_9_1', 'CAT4_INDICATIVE_GCSE',
    'Indicative GCSE grade from CAT4 mean SAS', 'predicted', NULL, NULL, NULL, 20);
  bt := pg_temp.f_bt(m_pred, 'UK_SAS_60_140', 'UK_GCSE_9_1', 'CAT4 indicative grades (generic)',
                     DATE '2016-09-01',
                     'ILLUSTRATIVE — shaped like a GL Assessment indicative grade table, NOT transcribed from one',
                     true);
  PERFORM pg_temp.f_bset(bt, ARRAY['1','2','3','4','5','6','7','8','9'],
                         ARRAY[78,85,92,98,104,110,116,124]::numeric[], 60, 141);
  rule := pg_temp.f_rule(m_pred, 'boundary', bt,
    'A cognitive baseline predicts an attainment band, not a grade. Treat the output as the CENTRE of a range '
    'roughly plus or minus one grade wide; presenting it as a single confident number is the commonest abuse '
    'of baseline data in English schools.', true);
  PERFORM pg_temp.f_input(rule, m_cat4, 1, true);

  -- Alps-style minimum expected grade at A-Level from mean GCSE score.
  -- ILLUSTRATIVE, and simplified in a way worth naming: the real Alps grids are
  -- SUBJECT SPECIFIC (the same mean GCSE score implies a different MEG in
  -- further maths than in drama, because the subjects have different national
  -- value-added profiles). A faithful seeding would be one boundary table per
  -- subject; this is one generic table, and a school using it must not report
  -- it as an Alps figure.
  m_meg := pg_temp.f_measure(fv, 'TARGET_ALEVEL', 'UK_ALEVEL_A_E', 'ALPS_STYLE_MEG',
    'Minimum expected A-Level grade from mean GCSE score (generic, subject-blind)', 'predicted', NULL, NULL, NULL, 21);
  bt := pg_temp.f_bt(m_meg, 'UK_MEAN_GCSE_0_9', 'UK_ALEVEL_A_E', 'Generic MEG grid',
                     DATE '2016-09-01',
                     'ILLUSTRATIVE — shaped like an Alps minimum expected grade grid, NOT an Alps table, and subject-blind where the real ones are subject-specific',
                     true);
  PERFORM pg_temp.f_bset(bt, ARRAY['U','E','D','C','B','A','A*'],
                         ARRAY[3.5,4.3,5.0,5.7,6.4,7.3]::numeric[], 0, 9.01);
  rule := pg_temp.f_rule(m_meg, 'boundary', bt,
    'Mean GCSE score -> minimum expected A-Level grade. Minimum EXPECTED, not target: the point of the Alps '
    'methodology is that the MEG is the floor a typical student with that prior attainment reaches, and the '
    'school target should sit above it.', true);
  PERFORM pg_temp.f_input(rule, m_mean_gcse, 1, true);

  ------------------------------------------------- imported predictions -----
  -- No conversion rule. These arrive from the provider as gradebook.outcome
  -- rows. They are measures so that they can be compared, trended and charted
  -- against actual outcomes on identical footing with everything else.
  PERFORM pg_temp.f_measure(fv, 'TARGET_GCSE', 'UK_GCSE_9_1', 'FFT20_GCSE',
    'FFT20 estimate — the grade achieved by pupils with similar prior attainment in the top 20% of schools nationally (imported)',
    'predicted', NULL, NULL, NULL, 30);
  PERFORM pg_temp.f_measure(fv, 'TARGET_GCSE', 'UK_GCSE_9_1', 'FFT50_GCSE',
    'FFT50 estimate — the national average outcome for pupils with similar prior attainment (imported)',
    'predicted', NULL, NULL, NULL, 31);
  PERFORM pg_temp.f_measure(fv, 'TARGET_GCSE', 'UK_GCSE_9_1', 'SCHOOL_TARGET_GCSE',
    'School aspirational target grade — a professional decision, not a prediction',
    'predicted', NULL, NULL, NULL, 32);
  PERFORM pg_temp.f_measure(fv, 'TARGET_GCSE', 'UK_GCSE_9_1', 'TEACHER_PREDICTED_GCSE',
    'Teacher predicted grade (the number that goes on a sixth-form or UCAS reference)',
    'predicted', NULL, NULL, NULL, 33);
END $seed$;

-- ---------------------------------------------------------------------------
-- 9.1 THE FLIGHT PATH, as a query. Nothing to insert; this is the payoff.
--
-- Because baseline, prediction, target and actual are all measures on the same
-- anchored GCSE scale, "expected versus actual" is one join and needs no
-- special-case code anywhere:
--
--   SELECT p.display_name,
--          tgt.value_code  AS target,
--          pred.value_code AS teacher_predicted,
--          act.value_code  AS actual,
--          act.pct - tgt.pct AS gap_on_the_anchored_axis
--   FROM org.person p
--   LEFT JOIN gradebook.outcome tgt  ON tgt.student_id  = p.id AND tgt.kind = 'target'
--   LEFT JOIN gradebook.outcome pred ON pred.student_id = p.id AND pred.kind = 'predicted_teacher'
--   LEFT JOIN gradebook.outcome act  ON act.student_id  = p.id AND act.kind = 'awarded_official'
--   WHERE p.tenant_id = :tenant;
--
-- gap_on_the_anchored_axis is only meaningful BECAUSE section 1.1 anchored the
-- GCSE scale. Under equal spacing, "missed target by 0.11" would be the same
-- number whether the student missed a 9 or missed a 2, which is exactly the
-- distortion that makes crude flight-path reporting untrustworthy: the
-- anchored axis says missing a 9 by one grade is a gap of 0.058 and missing a 2
-- by one grade is a gap of 0.083, because grades are not equally rare.
--
-- And the honest caveat that belongs on the same screen: a target is a
-- decision, a prediction is a model output, and a CAT4 indicative grade is a
-- band. Rendering all three as one confident letter is how schools end up
-- arguing about a number none of them believes.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- 10. TAXONOMIES — what a question was actually about
--
-- Rungs 1-3 of the tagging ladder in 004_curriculum.sql. Nothing here is
-- mandatory: a department that tags nothing still gets trajectory analytics.
-- A department that picks one dropdown per assessment gets topic analytics.
--
-- The UK is unusually well placed for this compared with the IB, and it is
-- worth saying why. The subject content for GCSE mathematics is set
-- NATIONALLY, in six named areas with mandated mark weightings that differ by
-- tier. So the topic taxonomy below is not one board's invention — it applies
-- identically to AQA, Edexcel and OCR, and a school switching board keeps its
-- entire tagging history. That is a real, durable asset and the reason this
-- taxonomy is attached to no framework_id at all.
-- ===========================================================================

DO $seed$
DECLARE tx uuid; t record;
BEGIN
  INSERT INTO curric.taxonomy (code, name, axis, framework_id, source_ref)
  VALUES ('UK_GCSE_MATHS_CONTENT',
          'GCSE Mathematics subject content areas (national, board-independent)',
          'topic', NULL,
          'DfE GCSE mathematics subject content and assessment objectives (2013), applied by all English boards')
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  SELECT id INTO tx FROM curric.taxonomy
   WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_GCSE_MATHS_CONTENT';

  -- nominal_minutes is ILLUSTRATIVE, and it is doing a job worth explaining.
  -- The national specification states each area's share of the MARKS, per tier
  -- (Higher: number 15%, algebra 30%, ratio 20%, geometry 20%, probability and
  -- statistics 15% — APPROX, verify against the subject content document).
  -- curric.tag has no column for a mark weighting, only nominal_minutes, so
  -- the weighting is expressed as indicative teaching time over a 280-hour Key
  -- Stage 4 course. That is a lossy encoding and it is named as such in this
  -- file's schema misfit list — but it does buy the comparison the platform
  -- actually needs: nominal minutes against delivered minutes from org.lesson,
  -- which is what separates "taught badly" from "never got the hours".
  FOR t IN SELECT * FROM (VALUES
      ('N',  'Number',                                  1, 2520),
      ('A',  'Algebra',                                 2, 5040),
      ('R',  'Ratio, proportion and rates of change',   3, 3360),
      ('G',  'Geometry and measures',                   4, 3360),
      ('P',  'Probability',                             5, 1260),
      ('S',  'Statistics',                              6, 1260)
    ) AS x(code, label, ord, mins)
  LOOP
    INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf, nominal_minutes)
    VALUES (tx, NULL, t.code, t.label, t.ord, false, t.mins)
    ON CONFLICT (taxonomy_id, code) DO NOTHING;
  END LOOP;

  -- A second level under algebra, because "we are weak at algebra" is not
  -- actionable and "we are weak at solving simultaneous equations" is. Rung 2
  -- of the ladder: tag the question group, not every question.
  FOR t IN SELECT * FROM (VALUES
      ('A_NOTATION',   'Notation, vocabulary and manipulation', 1),
      ('A_GRAPHS',     'Graphs of equations and functions',     2),
      ('A_SOLVING',    'Solving equations and inequalities',    3),
      ('A_SEQUENCES',  'Sequences',                             4)
    ) AS x(code, label, ord)
  LOOP
    INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf)
    SELECT tx, p.id, t.code, t.label, t.ord, true
      FROM curric.tag p WHERE p.taxonomy_id = tx AND p.code = 'A'
    ON CONFLICT (taxonomy_id, code) DO NOTHING;
  END LOOP;
END $seed$;

-- Command words. A GCSE mark scheme is built on them, and they map cleanly
-- onto the assessment objectives: "work out" is AO1, "show that" is AO2,
-- "prove" is AO2 leaning AO3. Tagging by command word answers a question no
-- total can — "our students can calculate and cannot justify" — and costs one
-- dropdown at question level.
DO $seed$
DECLARE tx uuid; t record;
BEGIN
  INSERT INTO curric.taxonomy (code, name, axis, framework_id, source_ref)
  VALUES ('UK_GCSE_MATHS_COMMAND', 'GCSE Mathematics command words', 'command_term', NULL,
          'Common to the English boards'' mark schemes')
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  SELECT id INTO tx FROM curric.taxonomy
   WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_GCSE_MATHS_COMMAND';

  FOR t IN SELECT * FROM (VALUES
      ('WORK_OUT',  'Work out / calculate — apply a standard technique (mostly AO1)', 1),
      ('SOLVE',     'Solve — form and solve, often multi-step (AO1/AO3)',             2),
      ('SHOW_THAT', 'Show that — construct a chain of reasoning to a given result (AO2)', 3),
      ('PROVE',     'Prove — construct a general argument (AO2/AO3)',                 4),
      ('EXPLAIN',   'Explain / give a reason — justify in words (AO2)',               5),
      ('INTERPRET', 'Interpret — read meaning from a representation (AO2)',           6),
      ('CRITICISE', 'Criticise / comment on — evaluate someone else''s reasoning (AO3)', 7)
    ) AS x(code, label, ord)
  LOOP
    INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf)
    VALUES (tx, NULL, t.code, t.label, t.ord, true)
    ON CONFLICT (taxonomy_id, code) DO NOTHING;
  END LOOP;
END $seed$;

-- Examinable scope. UK specifications DO drop and restore content — most
-- visibly in 2022, when advance information and reduced content were issued
-- for the post-pandemic series. A trend across that year that does not know
-- content was removed will read a topic collapse where there was none.
DO $seed$
DECLARE tx uuid; tg uuid;
BEGIN
  SELECT id INTO tx FROM curric.taxonomy
   WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_GCSE_MATHS_CONTENT';
  SELECT id INTO tg FROM curric.tag WHERE taxonomy_id = tx AND code = 'S';
  INSERT INTO curric.tag_inclusion (tenant_id, tag_id, academic_year_label, is_examinable, source_ref)
  VALUES (NULL, tg, '2021-22', true,
          'ILLUSTRATIVE placeholder. In 2022 the boards issued advance information narrowing what would be '
          'assessed; record the real effect here, per topic, per year, so a 2022 dip is attributable rather '
          'than mysterious.')
  ON CONFLICT DO NOTHING;
END $seed$;

-- ===========================================================================
-- 11. BENCHMARKS — the external anchor
--
-- The single thing a within-school model structurally cannot do is notice that
-- the whole school is weak. Every residual model centres on the cohort mean,
-- so a uniformly badly-taught cohort produces residuals summing to zero and
-- raises no flag whatsoever. Only an external distribution can see it, which
-- is why ref.benchmark is a first-class table and not a config blob.
--
-- The UK is the best-served country in this database for external data:
--   * JCQ and Ofqual publish national cumulative grade outcomes every August,
--     by subject, by board, by age;
--   * each board gives centres an item-level analysis of their own candidates
--     against national means (AQA Enhanced Results Analysis, Pearson
--     ResultsPlus, OCR Active Results);
--   * DfE publishes Progress 8, Attainment 8 and national transition matrices.
-- A UK school therefore has no excuse for judging itself only against itself —
-- and this table is where that evidence lands.
-- ===========================================================================

DO $seed$
DECLARE s_gcse uuid; s_al uuid; m uuid; r record; t uuid;
BEGIN
  SELECT id INTO s_gcse FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_GCSE_9_1';
  SELECT id INTO s_al   FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_ALEVEL_A_E';

  -- THE DISTRIBUTION THAT ANCHORED THE SCALES IN SECTION 1, stored as data so
  -- that the anchors are auditable rather than magic numbers in a comment.
  -- statistic = 'cutoff' is the closest available term and it is NOT a good
  -- fit: what is being stored is a CUMULATIVE PROPORTION at or above a grade,
  -- and the statistic vocabulary has no value for that. Named in the schema
  -- misfit list; scope_label carries the grade so the rows stay distinct.
  FOR r IN SELECT * FROM (VALUES
      ('9', 0.045), ('8', 0.115), ('7', 0.207), ('6', 0.320), ('5', 0.470),
      ('4', 0.670), ('3', 0.815), ('2', 0.910), ('1', 0.980)
    ) AS x(grade, cum)
  LOOP
    PERFORM pg_temp.f_bench(NULL, s_gcse, 'national',
      'England, all entries, all ages — proportion awarded grade ' || r.grade || ' or above',
      'cutoff', r.cum, 2019,
      'APPROX — JCQ/Ofqual summer 2019 GCSE cumulative outcomes, recalled to about a percentage point. '
      'These nine rows are the evidence base for the pct_anchor values on UK_GCSE_9_1; replace them and the '
      'anchors together, never separately.');
  END LOOP;

  -- Quartiles of the national grade distribution. Expressible here only
  -- because GCSE grade CODES are numeric.
  PERFORM pg_temp.f_bench(NULL, s_gcse, 'national', 'England, all entries', 'p25', 3, 2019,
    'APPROX — derived from the cumulative outcomes above: the 25th percentile of the national distribution falls in grade 3.');
  PERFORM pg_temp.f_bench(NULL, s_gcse, 'national', 'England, all entries', 'p50', 4, 2019,
    'APPROX — the national median GCSE grade is a 4. Worth remembering before describing a grade 4 as a poor outcome.');
  PERFORM pg_temp.f_bench(NULL, s_gcse, 'national', 'England, all entries', 'p75', 6, 2019,
    'APPROX — the 75th percentile falls in grade 6.');

  -- A-Level, same treatment.
  FOR r IN SELECT * FROM (VALUES
      ('A*', 0.078), ('A', 0.255), ('B', 0.511), ('C', 0.758), ('D', 0.916), ('E', 0.976)
    ) AS x(grade, cum)
  LOOP
    PERFORM pg_temp.f_bench(NULL, s_al, 'national',
      'England, all A-Level entries — proportion awarded grade ' || r.grade || ' or above',
      'cutoff', r.cum, 2019,
      'APPROX — JCQ summer 2019 A-Level cumulative outcomes, recalled to about a percentage point. Evidence base for the UK_ALEVEL_A_E anchors.');
  END LOOP;
  -- No p25/p50/p75 rows for A-Level: ref.benchmark.value is numeric and the
  -- A-Level grade codes are letters, so "the median grade is a B" has nowhere
  -- to go without inventing an encoding. The cumulative rows above carry the
  -- same information in a form the column type can hold. Named as a misfit.

  ---------------------------------------------------------------------------
  -- Subject-level national outcomes, attached to a MEASURE rather than a scale.
  -- This is the row that lets a maths department discover that its grade 4+
  -- rate of 55% is below the national 59.6% even though every class looks
  -- normal against the school mean.
  ---------------------------------------------------------------------------
  SELECT mm.id INTO m FROM ref.measure mm
    JOIN ref.framework_version fv ON fv.id = mm.framework_version_id
    JOIN ref.framework f ON f.id = fv.framework_id
   WHERE f.code = 'UK_AQA' AND mm.code = 'GRADE_AWARDED'
     AND mm.subject_group_code = 'MATHEMATICS' AND mm.level_code = 'H';
  PERFORM pg_temp.f_bench(m, NULL, 'national',
    'England, GCSE mathematics, all entries — proportion awarded grade 4 or above',
    'cutoff', 0.596, 2019,
    'APPROX — GCSE mathematics all-ages 4+ rate, England 2019. The 16-year-old rate is substantially higher '
    '(the all-ages figure includes post-16 resit candidates); always check which population a headline figure '
    'describes before comparing a school to it.', NULL);

  -- Paper-level national mean, ILLUSTRATIVE. Boards give centres exactly this
  -- (and more) through their results analysis services.
  SELECT mm.id INTO m FROM ref.measure mm
    JOIN ref.framework_version fv ON fv.id = mm.framework_version_id
    JOIN ref.framework f ON f.id = fv.framework_id
   WHERE f.code = 'UK_AQA' AND mm.code = 'P1'
     AND mm.subject_group_code = 'MATHEMATICS' AND mm.level_code = 'H';
  PERFORM pg_temp.f_bench(m, NULL, 'national', 'England — mean mark, AQA 8300 Paper 1 Higher',
    'mean', 38.4, 2024, 'ILLUSTRATIVE — replace with the national mean from AQA Enhanced Results Analysis.', NULL);
  PERFORM pg_temp.f_bench(m, NULL, 'national', 'England — mark standard deviation, AQA 8300 Paper 1 Higher',
    'sd', 16.2, 2024, 'ILLUSTRATIVE — replace with the national figure from AQA Enhanced Results Analysis.', NULL);

  ---------------------------------------------------------------------------
  -- Baseline test norms. Unlike everything else in this section these are not
  -- estimates at all: a standardised age score is DEFINED to have a national
  -- mean of 100 and a standard deviation of 15 in the standardisation sample.
  ---------------------------------------------------------------------------
  SELECT mm.id INTO m FROM ref.measure mm
    JOIN ref.framework_version fv ON fv.id = mm.framework_version_id
    JOIN ref.framework f ON f.id = fv.framework_id
   WHERE f.code = 'UK_BASELINE_TARGET' AND mm.code = 'CAT4_MEAN';
  PERFORM pg_temp.f_bench(m, NULL, 'national', 'UK standardisation sample', 'mean', 100, NULL,
    'Definitional property of a standardised age score (GL Assessment CAT4).', NULL);
  PERFORM pg_temp.f_bench(m, NULL, 'national', 'UK standardisation sample', 'sd', 15, NULL,
    'Definitional property of a standardised age score (GL Assessment CAT4).', NULL);

  SELECT mm.id INTO m FROM ref.measure mm
    JOIN ref.framework_version fv ON fv.id = mm.framework_version_id
    JOIN ref.framework f ON f.id = fv.framework_id
   WHERE f.code = 'UK_BASELINE_TARGET' AND mm.code = 'MIDYIS';
  PERFORM pg_temp.f_bench(m, NULL, 'national', 'UK standardisation sample', 'mean', 100, NULL,
    'Definitional property of a standardised score (CEM MidYIS).', NULL);
  PERFORM pg_temp.f_bench(m, NULL, 'national', 'UK standardisation sample', 'sd', 15, NULL,
    'Definitional property of a standardised score (CEM MidYIS).', NULL);

  ---------------------------------------------------------------------------
  -- A SCHOOL-OWNED benchmark: the demo school's own prior-year outcome, stored
  -- under its own tenant. This is how a department answers "are we better than
  -- we were?" — which is a different and often more useful question than "are
  -- we better than the country?", and it needs the same table.
  ---------------------------------------------------------------------------
  SELECT id INTO t FROM platform.tenant WHERE slug = 'greenfield-academy';
  SELECT id INTO s_gcse FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = 'UK_GCSE_9_1';
  PERFORM pg_temp.f_bench(NULL, s_gcse, 'school', 'Greenfield Academy — all GCSE entries', 'p50', 5, 2024,
    'ILLUSTRATIVE demo figure. A real school computes this from its own gradebook.outcome rows each August.',
    182, t);
END $seed$;

COMMIT;

-- ===========================================================================
-- 12. WHAT THIS FILE COULD NOT SAY, AND WHAT A SCHOOL MUST DO NEXT
--
-- ---------------------------------------------------------------------------
-- 12.1 WHERE THE SCHEMA AND THE UK SYSTEM DO NOT QUITE MEET
--
-- Every one of these has a faithful-enough encoding above. None of them
-- needed a new table, which is the claim holding. They are recorded because a
-- seed file that pretends the fit was perfect is not evidence of anything.
--
--  * ref.scale_point.is_pass is ONE boolean and GCSE has TWO national
--    thresholds — grade 4 (standard pass) and grade 5 (strong pass). is_pass
--    is set from grade 4; any report meaning 5+ must use ordinal_rank or
--    pct_anchor. A report that quietly uses is_pass for the Basics measure
--    will overstate it by about 20 percentage points.
--
--  * ref.scale.equating_status cannot distinguish "anchored to an outcome
--    distribution" (GCSE, A-Level) from "anchored to an arithmetic tariff"
--    (BTEC unit points). Both read 'anchored', but only the first licenses
--    comparing against a population. Two BTEC/GCSE scales both marked
--    'anchored' will pass any gate that checks only that word.
--
--  * ref.benchmark.statistic has no value for a CUMULATIVE PROPORTION at or
--    above a grade, which is the form every UK national outcome table takes.
--    Encoded as 'cutoff' with the grade in scope_label. And because
--    benchmark.value is numeric, "the national median A-Level grade is a B"
--    cannot be stored at all — only GCSE, whose codes happen to be digits,
--    gets p25/p50/p75 rows.
--
--  * ref.benchmark keys to a measure or a scale, never to an ITEM. The boards'
--    results-analysis services give centres per-QUESTION national facility
--    values, which is the richest external data available to a UK school and
--    has no home here short of creating a measure per exam question. Encoded
--    at paper level instead, losing the question-level detail.
--
--  * ref.conversion_input is a STATIC list of measures, but "mean GCSE score"
--    is the mean over whichever eight to eleven GCSEs a particular student
--    happens to have taken. The rule in section 9 lists illustrative inputs
--    with is_required = false and relies on the application to compute over
--    the student's actual awarded outcomes. Any per-student set — GCSE
--    baskets, A-Level option blocks, BTEC optional units — has this shape.
--
--  * ref.measure.role has no 'target' value, so a school's aspirational
--    target and a model's prediction are both role='predicted' and are only
--    distinguishable downstream, by gradebook.outcome.kind. Given that the
--    difference between a target and a prediction is the single most common
--    misunderstanding in English school data, that distinction is carrying a
--    lot of weight in a column the config layer cannot see.
--
--  * ref.measure_band.bounds is a numrange, but a mastery step or a BTEC unit
--    grade is a CODE. Section 8's band descriptors are expressed over
--    ordinal_rank, which the UI must know to interpret.
--
--  * curric.tag can hold nominal MINUTES but not a mark WEIGHTING, and UK
--    subject content is specified in weightings. Section 10 converts to
--    indicative minutes over a 280-hour course, which is lossy and loses the
--    per-tier difference entirely.
--
-- ---------------------------------------------------------------------------
-- 12.2 WHAT A UK SCHOOL MUST DO BEFORE TRUSTING ANY OF THIS
--
--  1. REPLACE EVERY BOUNDARY TABLE. All of them are ILLUSTRATIVE. Take the
--     published boundaries for the series, the specification and the tier, add
--     a NEW ref.boundary_table row per series, and set supersedes_id. Never
--     edit an old table: last year's grades must keep resolving against last
--     year's boundaries forever.
--
--  2. REPLACE THE NATIONAL DISTRIBUTIONS WITH THE JCQ TABLES, then recompute
--     the pct_anchor values on UK_GCSE_9_1 and UK_ALEVEL_A_E from them:
--
--       anchor(grade) = 1 - (cum_at_or_above(grade) + cum_at_or_above(next))/2
--
--     Do the benchmark rows and the anchors in ONE transaction. An anchor set
--     that no longer matches its benchmark rows is worse than no anchor,
--     because it looks audited.
--
--  3. DECIDE, DELIBERATELY, WHICH POPULATION TO ANCHOR TO. The anchors here
--     are all-ages England. A selective school, a sixth-form college with a
--     large resit cohort, and an international school sitting Cambridge papers
--     each need a different reference population, and Cambridge already has
--     its own unanchored scales waiting for one.
--
--  4. VERIFY THE BTEC POINTS TARIFF against the Pearson specification before
--     any BTEC points total is shown to a learner. Section 7's tariff is
--     believed correct and is not verified; it is also load-bearing, because
--     the unit-grade anchors are derived from it.
--
--  5. POINT EACH org.teaching_group AT A SPECIFICATION, not a subject: the
--     ref.framework_version row for AQA 8300 or Edexcel 1MA1, whichever that
--     class is actually entered for. Everything else in this file keys off it.
--
--  6. FOR KEY STAGE 3, ANCHOR THE SCHOOL'S OWN SCALE once one cohort has
--     reached GCSE. Until then it stays 'assumed_linear' and must not be
--     averaged with anything national. That is not a limitation of the
--     platform; it is the platform declining to make something up.
--
-- ---------------------------------------------------------------------------
-- 12.3 VERIFICATION — run these after loading. "No error" is not proof.
--
--   SELECT code, name, awarding_body FROM ref.framework ORDER BY code;
--   SELECT count(*) FROM ref.measure;
--   SELECT s.code, s.equating_status, count(p.*) AS points
--     FROM ref.scale s LEFT JOIN ref.scale_point p ON p.scale_id = s.id
--    GROUP BY s.code, s.equating_status ORDER BY s.code;
--   SELECT bt.session_label, count(*) FROM ref.boundary_table bt
--     JOIN ref.boundary_row br ON br.boundary_table_id = bt.id
--    GROUP BY 1 ORDER BY 1;
--   SELECT * FROM ref.v_config_errors;          -- MUST return zero rows
--
--   -- and the one that proves the Foundation cap is real:
--   SELECT ref.apply_boundary(bt.id, 239) AS grade_for_a_near_perfect_foundation_paper
--     FROM ref.boundary_table bt
--     JOIN ref.measure m ON m.id = bt.measure_id
--    WHERE m.level_code = 'F' AND m.code = 'GRADE' AND bt.session_label = 'June 2024'
--    LIMIT 1;                                    -- returns 5, not 9
-- ===========================================================================
