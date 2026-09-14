-- ============================================================================
-- 12_gr_panhellenic.sql — Πανελλαδικές Εξετάσεις ΓΕΛ, as CONFIGURATION
--
-- Greek national university-entrance examinations for General Lyceum (ΓΕΛ),
-- run by the Υπουργείο Παιδείας, Θρησκευμάτων και Αθλητισμού (ΥΠΑΙΘΑ, still
-- widely written ΥΠΑΙΘ). Everything below is INSERTs into ref.* and curric.*.
-- No DDL, no migration, no code path. If this file runs clean and
-- ref.v_config_errors is empty, the claim holds for a system that is about as
-- far from the IB as a grading system can get.
--
-- ---------------------------------------------------------------------------
-- HOW THE GREEK SYSTEM ACTUALLY WORKS (for the developer who has never seen it)
-- ---------------------------------------------------------------------------
-- There are TWO grading systems bolted together, and confusing them is the
-- single most common modelling error:
--
--   (A) ο ενδοσχολικός βαθμός — the school's own mark. Every subject in every
--       one of the three Lyceum years (Α΄, Β΄, Γ΄ Λυκείου) gets a προφορικός
--       βαθμός per τετράμηνο (term) and a γραπτός βαθμός from the end-of-year
--       written exams. These produce the ετήσιος βαθμός, the promotion
--       decision and finally the Απολυτήριο Λυκείου.
--       SINCE 2016 THIS CONTRIBUTES EXACTLY NOTHING TO UNIVERSITY ADMISSION.
--
--   (B) οι Πανελλαδικές Εξετάσεις — a single national written examination in
--       FOUR subjects, sat in late May / June of Γ΄ Λυκείου, marked centrally
--       and anonymously by two βαθμολογητές in a βαθμολογικό κέντρο. Admission
--       to every Greek public university department is decided by the μόρια
--       computed from those four marks and nothing else (plus ειδικά μαθήματα
--       where the department requires them).
--
-- Because of (A)+(B), a Greek school's internal data and its external data are
-- almost disjoint — which is precisely why a platform that holds both is worth
-- building here. The ΥΠΑΙΘ publishes per-candidate subject grades and national
-- summary statistics, but NOTHING at question or topic level. A school that
-- wants to know WHY its cohort lost 1.8 βαθμούς in Χημεία has to have marked
-- and tagged its own διαγωνίσματα and προσομοιώσεις. That is this product.
--
-- ---------------------------------------------------------------------------
-- THE ARITHMETIC, ONCE, IN FULL (verified against the ΥΠΑΙΘ formula below)
-- ---------------------------------------------------------------------------
-- Every written paper is marked out of 100 by two independent examiners. The
-- candidate's mark is the mean of the two, divided by 5, giving a grade on the
-- 0-20 scale to one decimal. (If the two examiners differ by more than 12
-- units out of 100 a third examiner — αναβαθμολόγηση — is used and the mean of
-- the two closest marks is taken.)
--
-- REGIME 1 — Ν.4327/2015, exams 2016 to 2021 inclusive
--   Each ΕΠΙΣΤΗΜΟΝΙΚΟ ΠΕΔΙΟ (scientific field) names two of its four subjects
--   as μαθήματα αυξημένης βαρύτητας, with συντελεστές 1,3 and 0,7. Then:
--
--     μόρια = [ (Β1+Β2+Β3+Β4)/4 x 8  +  Βα x 1,3  +  Ββ x 0,7 ] x 100
--
--   which is a plain weighted sum of the four 0-20 grades, because
--   (Β1+Β2+Β3+Β4)/4 x 8 = 2 x (Β1+Β2+Β3+Β4). So with every grade at 20:
--     [ 20x2 + 20x2 + 20x2 + 20x2 + 20x1,3 + 20x0,7 ] x 100
--   = [ 160 + 26 + 14 ] x 100 = 200 x 100 = 20.000 μόρια.   <-- the famous cap
--
--   Stored here as ref.conversion_input.weight already multiplied by 100:
--     ordinary subject         weight 200
--     μάθημα με συντ. 1,3      weight 200 + 130 = 330
--     μάθημα με συντ. 0,7      weight 200 +  70 = 270
--   Σ weights = 1000, and 20 x 1000 = 20.000. The engine's weighted_sum is
--   therefore literally Σ(βαθμός_i x weight_i) with no post-multiplier.
--
-- REGIME 2 — Ν.4777/2021, exams 2022 onwards
--   The συντελεστές stop being a property of the ΠΕΔΙΟ and become a property
--   of the TΜΗΜΑ (the individual university department). Each department
--   publishes four συντελεστές βαρύτητας, each between 20% and 30%, summing to
--   100%, one per examined subject of its field. Then:
--
--     μόρια = ( Β1 x σ1 + Β2 x σ2 + Β3 x σ3 + Β4 x σ4 ) x 1000 ,  Σσ = 1
--
--   Max is still 20 x 1 x 1000 = 20.000. Stored here as weight = σ x 1000, so
--   a 30% coefficient is weight 300 and Σ weights = 1000 again. Same engine,
--   same units, different rows. THIS IS THE WHOLE THESIS CLAIM IN ONE PLACE:
--   a change of regulatory regime that rewrote every university's admission
--   arithmetic is, here, a different set of ref.conversion_input rows under a
--   different ref.conversion_rule.valid_from.
--
-- ΕΙΔΙΚΑ ΜΑΘΗΜΑΤΑ (both regimes)
--   Departments that need a language, drawing, or music skill require one or
--   two additional special examinations, graded 0-20 like everything else,
--   each with a department-set συντελεστής of 1 or 2:
--     μόρια += Βαθμός_ειδικού x συντελεστής x 100
--   so weight = συντελεστής x 100 (i.e. 100 or 200) on the SAME weighted_sum.
--   A department with one ειδικό μάθημα at coefficient 2 therefore tops out at
--   20.000 + 20x200 = 24.000 μόρια; Αρχιτεκτόνων, which needs BOTH Ελεύθερο
--   and Γραμμικό Σχέδιο at coefficient 2, tops out at 28.000.
--
-- ΕΒΕ — ΕΛΑΧΙΣΤΗ ΒΑΣΗ ΕΙΣΑΓΩΓΗΣ (Ν.4777/2021, first applied to exams 2021)
--   A minimum-qualification floor, and a genuinely new kind of object: it is
--   RELATIVE TO THE NATIONAL COHORT, not absolute.
--     ΕΒΕ(τμήματος) = Μ.Ο. των βαθμών όλων των υποψηφίων του πεδίου
--                     x συντελεστής ΕΒΕ που ορίζει το τμήμα (0,80 - 1,20)
--   A candidate whose mean of the four subject grades is below a department's
--   ΕΒΕ cannot be admitted there at any μόρια. There is a separate ΕΒΕ per
--   ειδικό μάθημα, computed the same way from that paper's national mean.
--   This is exactly the "external reference distribution" case ref.benchmark
--   exists for, and it is load-bearing: a uniformly weak Greek cohort raises no
--   internal flag anywhere, but it moves the national mean, and therefore moves
--   every ΕΒΕ in the country. Without ref.benchmark rows this platform cannot
--   even represent the question.
--
-- ---------------------------------------------------------------------------
-- HONESTY MARKERS USED IN THIS FILE
-- ---------------------------------------------------------------------------
--   source_ref LIKE 'ILLUSTRATIVE%'   -> plausible, NOT published. Replace it.
--   is_provisional = true             -> same, on boundary tables.
--   note LIKE 'ΕΠΑΛΗΘΕΥΣΗ%'           -> structure believed correct, the exact
--                                        figure or ΦΕΚ reference is unverified.
--
-- Grade boundaries, ΕΒΕ values, βάσεις εισαγωγής and national means are the
-- four things a Greek user will trust instantly and that are most dangerous to
-- guess. Every one of them in this file is marked. The STRUCTURE (which
-- subjects, which weights shape, which regime) is asserted; the NUMBERS
-- attached to a named department or a named year are not, except where the
-- comment says so explicitly.
--
-- No ref.scale in this file is marked 'anchored'. See section 1.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Session-local helpers. pg_temp dies with the psql session, so this file adds
-- no functions to the database. Same shape as 11_ib_dp.sql, plus effective
-- dating on f_rule (Greece needs two live regimes on one output measure).
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

CREATE FUNCTION pg_temp.f_sid(p_code text) RETURNS uuid LANGUAGE sql STABLE AS $fn$
  SELECT id FROM ref.scale WHERE owner_tenant_id = app.global_tenant() AND code = p_code
$fn$;

CREATE FUNCTION pg_temp.f_fw() RETURNS uuid LANGUAGE sql STABLE AS $fn$
  SELECT id FROM ref.framework
   WHERE owner_tenant_id = app.global_tenant() AND code = 'GR_PANHELLENIC'
$fn$;

CREATE FUNCTION pg_temp.f_fv(p_label text) RETURNS uuid LANGUAGE sql STABLE AS $fn$
  SELECT id FROM ref.framework_version
   WHERE framework_id = pg_temp.f_fw() AND label = p_label
$fn$;

CREATE FUNCTION pg_temp.f_construct(p_code text, p_label text, p_kind text, p_axis text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; fw uuid := pg_temp.f_fw();
BEGIN
  INSERT INTO ref.construct (framework_id, code, label, kind, semantic_axis)
  VALUES (fw, p_code, p_label, p_kind, p_axis)
  ON CONFLICT (framework_id, code) DO NOTHING;
  SELECT id INTO v FROM ref.construct WHERE framework_id = fw AND code = p_code;
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
                                  p_weight numeric DEFAULT NULL, p_sort int DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid; v_con uuid; v_scale uuid;
BEGIN
  v := pg_temp.f_mid(p_fv, p_code, p_subj, p_level);
  IF v IS NOT NULL THEN RETURN v; END IF;

  SELECT id INTO v_con FROM ref.construct
   WHERE framework_id = pg_temp.f_fw() AND code = p_construct_code;
  IF v_con IS NULL THEN
    RAISE EXCEPTION 'unknown construct %', p_construct_code;
  END IF;
  v_scale := pg_temp.f_sid(p_scale_code);
  IF v_scale IS NULL THEN RAISE EXCEPTION 'unknown scale %', p_scale_code; END IF;

  INSERT INTO ref.measure (framework_version_id, construct_id, scale_id, code, label,
                           role, subject_group_code, level_code, weight, sort_order)
  VALUES (p_fv, v_con, v_scale, p_code, p_label, p_role, p_subj, p_level, p_weight, p_sort)
  RETURNING id INTO v;
  RETURN v;
END $fn$;

-- Effective-dated rule. Keyed on (output, method, valid_from) so the pre- and
-- post-Ν.4777/2021 formulae for the SAME department coexist as two rows.
CREATE FUNCTION pg_temp.f_rule(p_out uuid, p_method text,
                               p_from date DEFAULT DATE '1900-01-01',
                               p_to date DEFAULT NULL,
                               p_note text DEFAULT NULL,
                               p_bt uuid DEFAULT NULL,
                               p_requires_all boolean DEFAULT false,
                               p_eval_order int DEFAULT 100)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM ref.conversion_rule
   WHERE output_measure_id = p_out AND method = p_method AND valid_from = p_from;
  IF v IS NULL THEN
    INSERT INTO ref.conversion_rule (output_measure_id, method, boundary_table_id,
                                     valid_from, valid_to, note, requires_all_inputs,
                                     eval_order)
    VALUES (p_out, p_method, p_bt, p_from, p_to, p_note, p_requires_all, p_eval_order)
    RETURNING id INTO v;
  END IF;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_input(p_rule uuid, p_in uuid, p_w numeric DEFAULT 1,
                                p_required boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF p_in IS NULL THEN RAISE EXCEPTION 'null input measure for rule %', p_rule; END IF;
  INSERT INTO ref.conversion_input (rule_id, input_measure_id, weight, is_required)
  VALUES (p_rule, p_in, p_w, p_required)
  ON CONFLICT (rule_id, input_measure_id)
  DO UPDATE SET weight = EXCLUDED.weight, is_required = EXCLUDED.is_required;
END $fn$;

CREATE FUNCTION pg_temp.f_bt(p_measure uuid, p_in_scale text, p_out_scale text,
                             p_session text, p_from date, p_src text,
                             p_provisional boolean DEFAULT true)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM ref.boundary_table
   WHERE owner_tenant_id = app.global_tenant()
     AND measure_id = p_measure AND session_label = p_session;
  IF v IS NOT NULL THEN RETURN v; END IF;
  INSERT INTO ref.boundary_table (measure_id, in_scale_id, out_scale_id, session_label,
                                  valid_from, source_ref, is_provisional)
  VALUES (p_measure, pg_temp.f_sid(p_in_scale), pg_temp.f_sid(p_out_scale),
          p_session, p_from, p_src, p_provisional)
  RETURNING id INTO v;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_brow(p_bt uuid, p_out text, p_lo numeric, p_hi numeric)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ref.boundary_row
                  WHERE boundary_table_id = p_bt AND out_code = p_out) THEN
    INSERT INTO ref.boundary_row (boundary_table_id, out_code, bounds)
    VALUES (p_bt, p_out, numrange(p_lo, p_hi, '[)'));
  END IF;
END $fn$;

CREATE FUNCTION pg_temp.f_bench(p_measure uuid, p_scale uuid, p_scope text,
                                p_scope_label text, p_stat text, p_value numeric,
                                p_year int, p_src text, p_n int DEFAULT NULL)
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

-- Curriculum helpers (ΙΕΠ ύλη trees).
CREATE FUNCTION pg_temp.f_tax(p_code text, p_name text, p_axis text, p_src text)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  INSERT INTO curric.taxonomy (code, name, axis, framework_id, source_ref)
  VALUES (p_code, p_name, p_axis, pg_temp.f_fw(), p_src)
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  SELECT id INTO v FROM curric.taxonomy
   WHERE owner_tenant_id = app.global_tenant() AND code = p_code;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_tag(p_tax uuid, p_parent uuid, p_code text, p_label text,
                              p_sort int DEFAULT 0, p_leaf boolean DEFAULT true,
                              p_minutes int DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v uuid;
BEGIN
  INSERT INTO curric.tag (taxonomy_id, parent_id, code, label, sort_order, is_leaf,
                          nominal_minutes)
  VALUES (p_tax, p_parent, p_code, p_label, p_sort, p_leaf, p_minutes)
  ON CONFLICT (taxonomy_id, code) DO NOTHING;
  SELECT id INTO v FROM curric.tag WHERE taxonomy_id = p_tax AND code = p_code;
  RETURN v;
END $fn$;

CREATE FUNCTION pg_temp.f_incl(p_tag uuid, p_year text, p_examinable boolean, p_src text)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  INSERT INTO curric.tag_inclusion (tenant_id, tag_id, academic_year_label,
                                    is_examinable, source_ref)
  VALUES (NULL, p_tag, p_year, p_examinable, p_src)
  ON CONFLICT DO NOTHING;
END $fn$;


-- ===========================================================================
-- 1. SCALES
--
-- A NOTE ON equating_status, LEFT 'assumed_linear' EVERYWHERE IN THIS FILE:
--
-- For the numeric scales (0-20, 0-100, μόρια) equal spacing of pct_anchor is
-- not an assumption at all — these are arithmetic axes and a grade of 10 IS
-- exactly half of 20 by construction. The controlled vocabulary has no value
-- meaning "linear by definition", so they read 'assumed_linear'. That is a
-- vocabulary gap, not a modelling error, and it has the correct practical
-- effect: cross-framework pooling stays blocked, because a Greek 15/20 and an
-- IB 5/7 are NOT comparable however linear each axis is internally.
--
-- For the one genuinely ordinal scale here — ο χαρακτηρισμός του απολυτηρίου
-- (Άριστα / Λίαν Καλώς / ...) — the pct_anchors ARE overridden below, from the
-- midpoints of the numeric bands that define each label. That is strictly
-- better than equal spacing. It still does NOT earn 'anchored', because
-- (a) the band cut-offs themselves are marked ILLUSTRATIVE in this file and
-- (b) 'anchored' in this schema means "set from a real OUTCOME DISTRIBUTION",
-- and a band midpoint is a definition, not a distribution. Anchoring the 0-20
-- scale honestly would need the ΥΠΑΙΘ κατανομή βαθμολογίας table (how many
-- candidates scored in each 1-point band, per subject, per year). This seed
-- does not ship one. Setting 'anchored' from a remembered approximate
-- distribution would silently corrupt every Panhellenic-vs-IB-vs-A-Level
-- comparison downstream, which is far worse than an honest 'assumed_linear'.
-- ===========================================================================

DO $seed$
DECLARE
  s20 uuid; s100 uuid; s_sch uuid; s_mo uuid; s_char uuid;
  s_m20k uuid; s_m24k uuid; s_m28k uuid;
BEGIN
  -- Η ΒΑΘΜΟΛΟΓΙΚΗ ΚΛΙΜΑΚΑ 0-20 — the one number every Greek understands.
  -- Decimals: the Panhellenic grade is (mean of two 0-100 marks) / 5, so it
  -- lands on tenths (a pair of marks 74 and 75 gives 74,5/5 = 14,9). One
  -- decimal is therefore exact for a reported subject grade, and it is what
  -- appears on the βεβαίωση συμμετοχής.
  s20 := pg_temp.f_scale('GR_0_20', 'Βαθμολογική κλίμακα 0-20 (0-20 grade scale)',
                         'interval_points', 0, 20, 1);
  PERFORM ref.seed_scale_points(s20, ARRAY(SELECT i::text FROM generate_series(0,20) AS i));
  -- is_pass is set at 10 ONLY as the classical «βάση του 10». It is NOT a
  -- Panhellenic pass mark: since Ν.4777/2021 eligibility is decided by the ΕΒΕ
  -- (see section 8), which floats with the national cohort and is frequently
  -- BELOW 10. Reporting "pass rate" off this flag for Panhellenic data is
  -- wrong; it is kept because it is correct for ενδοσχολικές εξετάσεις, where
  -- 9,5 rounds to 10 and 10 is genuinely the promotion threshold.
  UPDATE ref.scale_point SET is_pass = (code::numeric >= 10)
   WHERE scale_id = s20 AND is_pass IS NULL;

  -- Η κλίμακα των βαθμολογητών. Each script is marked out of 100, twice,
  -- blind. Held separately from GR_0_20 because a school that photocopies a
  -- past paper and marks it to the official mark scheme is working in THIS
  -- scale, and the /5 must be an explicit, auditable conversion rule rather
  -- than a division buried in a UI.
  s100 := pg_temp.f_scale('GR_0_100', 'Κλίμακα βαθμολόγησης γραπτού 0-100 (script marking scale)',
                          'ratio_marks', 0, 100, 1);

  -- Ο ενδοσχολικός βαθμός. Οι τετραμηνιαίοι προφορικοί βαθμοί και ο γραπτός
  -- βαθμός των προαγωγικών/απολυτηρίων εξετάσεων καταχωρίζονται ως ΑΚΕΡΑΙΟΙ.
  -- (Recorded as whole numbers; only the computed averages carry decimals.)
  s_sch := pg_temp.f_scale('GR_SCHOOL_0_20', 'Ενδοσχολικός βαθμός 0-20, ακέραιος (school term/exam mark)',
                           'interval_points', 0, 20, 0);
  PERFORM ref.seed_scale_points(s_sch, ARRAY(SELECT i::text FROM generate_series(0,20) AS i));
  UPDATE ref.scale_point SET is_pass = (code::numeric >= 10)
   WHERE scale_id = s_sch AND is_pass IS NULL;

  -- Οι υπολογιζόμενοι μέσοι όροι (ετήσιος βαθμός, γενικός μέσος όρος,
  -- βαθμός απολυτηρίου). Δύο δεκαδικά, όπως τυπώνονται στον έλεγχο.
  s_mo := pg_temp.f_scale('GR_MO_0_20', 'Μέσος όρος 0-20 (computed average, 2 dp)',
                          'interval_points', 0, 20, 2);

  -- Ο χαρακτηρισμός επίδοσης που τυπώνεται στον τίτλο σπουδών.
  -- Ordinal: "Λίαν Καλώς" is better than "Καλώς", but the gap between them is
  -- a property of the band widths, not of the labels.
  s_char := pg_temp.f_scale('GR_XARAKTIRISMOS',
                            'Χαρακτηρισμός επίδοσης απολυτηρίου (award classification)',
                            'ordinal_grade');
  PERFORM ref.seed_scale_points(s_char,
          ARRAY['ANEPARKOS','SXEDON_KALOS','KALOS','LIAN_KALOS','ARISTA']);
  UPDATE ref.scale_point SET label = x.lbl, is_pass = x.pass
    FROM (VALUES ('ANEPARKOS','Ανεπαρκώς', false),
                 ('SXEDON_KALOS','Σχεδόν Καλώς', true),
                 ('KALOS','Καλώς', true),
                 ('LIAN_KALOS','Λίαν Καλώς', true),
                 ('ARISTA','Άριστα', true)) AS x(code,lbl,pass)
   WHERE scale_id = s_char AND ref.scale_point.code = x.code;
  -- pct_anchor overridden to the MIDPOINT of each band on the 0-20 axis
  -- (bands as in section 9's boundary table): 0-9,5 / 9,5-12,1 / 12,1-15,1 /
  -- 15,1-18,1 / 18,1-20. Midpoint / 20 gives the anchor. Equal spacing would
  -- have put "Ανεπαρκώς" at 0,000 and "Καλώς" at 0,500; the truth is that the
  -- failing band is enormous and the three passing bands are narrow and
  -- crowded into the top third. equating_status STAYS 'assumed_linear' — see
  -- the section header for why band midpoints do not make a scale anchored.
  UPDATE ref.scale_point SET pct_anchor = x.a
    FROM (VALUES ('ANEPARKOS',    0.23750),   -- midpoint  4,75 / 20
                 ('SXEDON_KALOS', 0.54000),   -- midpoint 10,80 / 20
                 ('KALOS',        0.68000),   -- midpoint 13,60 / 20
                 ('LIAN_KALOS',   0.83000),   -- midpoint 16,60 / 20
                 ('ARISTA',       0.95250))   -- midpoint 19,05 / 20
      AS x(code,a)
   WHERE scale_id = s_char AND ref.scale_point.code = x.code;

  -- ΟΙ ΚΛΙΜΑΚΕΣ ΜΟΡΙΩΝ.
  -- Deliberately NO scale_points: 20.001 rows of integer labels would be
  -- absurd, and ref.v_config_errors only requires points on ordinal/nominal
  -- scales. min/max are enough for gradebook's normalisation trigger.
  -- Three scales, because the ceiling genuinely differs by department:
  s_m20k := pg_temp.f_scale('GR_MORIA_0_20000',
              'Μόρια εισαγωγής 0-20.000 (τμήματα χωρίς ειδικό μάθημα)',
              'interval_points', 0, 20000, 0);
  s_m24k := pg_temp.f_scale('GR_MORIA_0_24000',
              'Μόρια εισαγωγής 0-24.000 (ένα ειδικό μάθημα με συντελεστή 2)',
              'interval_points', 0, 24000, 0);
  s_m28k := pg_temp.f_scale('GR_MORIA_0_28000',
              'Μόρια εισαγωγής 0-28.000 (δύο ειδικά μαθήματα με συντελεστή 2 — Αρχιτεκτονική)',
              'interval_points', 0, 28000, 0);

  PERFORM pg_temp.f_tr('scale_point', sp.id, 'en', x.en)
    FROM ref.scale_point sp
    JOIN (VALUES ('ANEPARKOS','Insufficient'), ('SXEDON_KALOS','Almost good'),
                 ('KALOS','Good'), ('LIAN_KALOS','Very good'), ('ARISTA','Excellent'))
         AS x(code,en) ON x.code = sp.code
   WHERE sp.scale_id = s_char;
END $seed$;


-- ===========================================================================
-- 2. FRAMEWORK AND VERSIONS
--
-- A ref.framework_version here is A LEGISLATIVE REGIME, not a school year and
-- not a syllabus. That is the right grain for Greece because the law is what
-- changes the examined subject list and the arithmetic, both at once, for
-- everybody, on a announced date. When a teaching group's results cross a
-- version boundary, the trend is not a trend.
--
-- The fourth version is the SCHOOL-INTERNAL system, which is not Panhellenic
-- at all but belongs to the same framework: it is the same ministry, the same
-- 0-20 scale, the same students, and a school needs its Γ΄ Λυκείου internal
-- marks joinable to its Panhellenic outcomes. Keeping it as a separate version
-- of the same framework rather than a separate framework is what makes that
-- join a construct join instead of a guess.
-- ===========================================================================

DO $seed$
DECLARE fw uuid;
BEGIN
  INSERT INTO ref.framework (code, name, country_code, awarding_body)
  VALUES ('GR_PANHELLENIC', 'Πανελλαδικές Εξετάσεις — Γενικό Λύκειο (ΓΕΛ)', 'GR', 'ΥΠΑΙΘ')
  ON CONFLICT (owner_tenant_id, code) DO NOTHING;
  fw := pg_temp.f_fw();

  INSERT INTO ref.framework_version (framework_id, label, valid_from, valid_to) VALUES
    (fw, 'Ν.4327/2015 — εξετάσεις 2016-2019 (3 Ομάδες Προσανατολισμού)',
         DATE '2015-09-01', DATE '2019-08-31'),
    (fw, 'Ν.4610/2019 — εξετάσεις 2020-2021 (4 Ομάδες Προσανατολισμού)',
         DATE '2019-09-01', DATE '2021-08-31'),
    (fw, 'Ν.4777/2021 — εξετάσεις 2022- (ΕΒΕ, συντελεστές βαρύτητας ανά τμήμα)',
         DATE '2021-09-01', NULL),
    (fw, 'Ενδοσχολική αξιολόγηση ΓΕΛ (Α΄/Β΄/Γ΄ Λυκείου)',
         DATE '2019-09-01', NULL)
  ON CONFLICT (framework_id, label) DO NOTHING;

  -- Supersession chain. A cohort whose Β΄ Λυκείου sat under 4610 and whose
  -- Γ΄ Λυκείου sat under 4777 crossed a line here; analytics that trends μόρια
  -- across it without saying so is lying.
  UPDATE ref.framework_version o SET superseded_by = pg_temp.f_fv(
           'Ν.4610/2019 — εξετάσεις 2020-2021 (4 Ομάδες Προσανατολισμού)')
   WHERE o.framework_id = fw AND o.superseded_by IS NULL
     AND o.label = 'Ν.4327/2015 — εξετάσεις 2016-2019 (3 Ομάδες Προσανατολισμού)';
  UPDATE ref.framework_version o SET superseded_by = pg_temp.f_fv(
           'Ν.4777/2021 — εξετάσεις 2022- (ΕΒΕ, συντελεστές βαρύτητας ανά τμήμα)')
   WHERE o.framework_id = fw AND o.superseded_by IS NULL
     AND o.label = 'Ν.4610/2019 — εξετάσεις 2020-2021 (4 Ομάδες Προσανατολισμού)';

  PERFORM pg_temp.f_tr('framework', fw, 'en',
    'Greek Panhellenic university entrance examinations (General Lyceum)');
END $seed$;


-- ===========================================================================
-- 3. CONSTRUCTS — the pedagogically stable identities
--
-- A construct here is A SUBJECT AS A THING THAT IS EXAMINED, surviving every
-- change of law. «Χημεία» is one construct; "Χημεία as examined in 2019 under
-- Ν.4327/2015" is a measure and dies with that law. Without the construct, a
-- school's 2019 and 2023 Χημεία cohorts are unjoinable — and in Greece the law
-- changes roughly every four years, so this is not hypothetical.
--
-- semantic_axis is the coarse cross-framework bucket. It is filled honestly and
-- conservatively: it says what kind of demand the paper mainly makes, and it is
-- NOT a claim that Greek Ιστορία Προσανατολισμού equals IB History HL Paper 3.
-- ===========================================================================

DO $seed$
BEGIN
  -- ---- Πανελλαδικά εξεταζόμενα μαθήματα κορμού και προσανατολισμού --------
  PERFORM pg_temp.f_construct('SUBJ_NEOEL_GLOSSA', 'Νεοελληνική Γλώσσα (Έκθεση) — έως 2019',
                              'subject', 'communication');
  PERFORM pg_temp.f_construct('SUBJ_LOGOTEXNIA',   'Νεοελληνική Λογοτεχνία — έως 2019',
                              'subject', 'analysis');
  -- Από το 2019-20 τα δύο παραπάνω εξετάζονται ως ΕΝΑ μάθημα. Η συγχώνευση
  -- είναι πραγματική αλλαγή αντικειμένου, όχι μετονομασία — δες τα
  -- construct_transition παρακάτω.
  PERFORM pg_temp.f_construct('SUBJ_NEOEL_GL',
      'Νεοελληνική Γλώσσα και Λογοτεχνία (Modern Greek language & literature)',
      'subject', 'communication');
  PERFORM pg_temp.f_construct('SUBJ_ARXAIA',
      'Αρχαία Ελληνικά Προσανατολισμού (Ancient Greek)', 'subject', 'analysis');
  PERFORM pg_temp.f_construct('SUBJ_ISTORIA',
      'Ιστορία Προσανατολισμού (History)', 'subject', 'evaluation');
  PERFORM pg_temp.f_construct('SUBJ_LATINIKA',
      'Λατινικά Προσανατολισμού (Latin)', 'subject', 'knowledge');
  PERFORM pg_temp.f_construct('SUBJ_KOINONIOLOGIA',
      'Κοινωνιολογία (Sociology)', 'subject', 'evaluation');
  PERFORM pg_temp.f_construct('SUBJ_MATHIMATIKA',
      'Μαθηματικά Προσανατολισμού (Mathematics)', 'subject', 'application');
  PERFORM pg_temp.f_construct('SUBJ_FYSIKI',
      'Φυσική Προσανατολισμού (Physics)', 'subject', 'application');
  PERFORM pg_temp.f_construct('SUBJ_XIMEIA',
      'Χημεία Προσανατολισμού (Chemistry)', 'subject', 'application');
  PERFORM pg_temp.f_construct('SUBJ_VIOLOGIA',
      'Βιολογία Προσανατολισμού (Biology)', 'subject', 'knowledge');
  PERFORM pg_temp.f_construct('SUBJ_PLIROFORIKI',
      'Πληροφορική / Ανάπτυξη Εφαρμογών σε Προγραμματιστικό Περιβάλλον (Computer science)',
      'subject', 'synthesis');
  PERFORM pg_temp.f_construct('SUBJ_OIKONOMIA',
      'Οικονομία / Αρχές Οικονομικής Θεωρίας (Economics)', 'subject', 'application');

  -- ---- Ειδικά μαθήματα ---------------------------------------------------
  -- Sat by candidates applying to departments that require a specific skill.
  -- Graded 0-20 exactly like everything else; they do not replace any of the
  -- four subjects, they are ADDED to the μόρια.
  PERFORM pg_temp.f_construct('EID_AGGLIKA',   'Ειδικό μάθημα: Αγγλικά (English)',
                              'subject', 'communication');
  PERFORM pg_temp.f_construct('EID_GALLIKA',   'Ειδικό μάθημα: Γαλλικά (French)',
                              'subject', 'communication');
  PERFORM pg_temp.f_construct('EID_GERMANIKA', 'Ειδικό μάθημα: Γερμανικά (German)',
                              'subject', 'communication');
  PERFORM pg_temp.f_construct('EID_EL_SXEDIO', 'Ειδικό μάθημα: Ελεύθερο Σχέδιο (Freehand drawing)',
                              'subject', 'skill_practical');
  PERFORM pg_temp.f_construct('EID_GR_SXEDIO', 'Ειδικό μάθημα: Γραμμικό Σχέδιο (Technical drawing)',
                              'subject', 'skill_practical');
  PERFORM pg_temp.f_construct('EID_ARMONIA',   'Ειδικό μάθημα: Αρμονία (Harmony)',
                              'subject', 'application');
  PERFORM pg_temp.f_construct('EID_EMAI',
      'Ειδικό μάθημα: Έλεγχος Μουσικών Ακουστικών Ικανοτήτων (aural skills test)',
      'subject', 'skill_practical');

  -- ---- Συγκεντρωτικά μεγέθη ----------------------------------------------
  PERFORM pg_temp.f_construct('MORIA_PEDIO',
      'Μόρια εισαγωγής υπολογισμένα με συντελεστές ΠΕΔΙΟΥ (pre-Ν.4777/2021)',
      'overall', 'unspecified');
  PERFORM pg_temp.f_construct('MORIA_TMIMA',
      'Μόρια εισαγωγής υπολογισμένα με συντελεστές ΤΜΗΜΑΤΟΣ (Ν.4777/2021)',
      'overall', 'unspecified');
  PERFORM pg_temp.f_construct('MO_PEDIOU',
      'Μέσος όρος των τεσσάρων πανελλαδικά εξεταζόμενων μαθημάτων (ΕΒΕ comparand)',
      'overall', 'unspecified');

  -- ---- Ενδοσχολικά -------------------------------------------------------
  PERFORM pg_temp.f_construct('SCH_PROFORIKOS',
      'Προφορικός βαθμός τετραμήνου (continuous/oral term mark)', 'component', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_GRAPTOS',
      'Γραπτός βαθμός προαγωγικών/απολυτηρίων εξετάσεων (written promotion exam)',
      'component', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_ETISIOS',
      'Ετήσιος βαθμός μαθήματος (annual subject grade)', 'overall', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_GENIKOS_MO',
      'Γενικός μέσος όρος τάξης (year general average)', 'overall', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_APOLYTIRIO',
      'Βαθμός Απολυτηρίου Λυκείου (Lyceum leaving certificate grade)',
      'overall', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_DIAGONISMA',
      'Διαγώνισμα / επαναληπτική γραπτή δοκιμασία (major in-class test)',
      'component', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_ORIAIA',
      'Ωριαία γραπτή δοκιμασία (announced one-period test)', 'component', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_TEST',
      'Ολιγόλεπτη γραπτή δοκιμασία / τεστ (short unannounced test)',
      'component', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_PROSOMOIOSI',
      'Προσομοίωση πανελλαδικών εξετάσεων (mock Panhellenic paper)',
      'component', 'unspecified');
  PERFORM pg_temp.f_construct('SCH_MORIA_PRED',
      'Προβλεπόμενα μόρια από προσομοιώσεις (projected μόρια)', 'overall', 'unspecified');
END $seed$;

-- ---------------------------------------------------------------------------
-- Construct transitions. These are the rows that stop a five-year trend line
-- from being a lie.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE fw uuid := pg_temp.f_fw();
BEGIN
  INSERT INTO ref.construct_transition (from_construct_id, to_construct_id,
                                        transition, trend_safe, note)
  SELECT f.id, t.id, x.tr, x.safe, x.note
  FROM (VALUES
    -- Από το 2019-20 η Έκθεση και η Λογοτεχνία εξετάζονται σε ενιαίο γραπτό.
    ('SUBJ_NEOEL_GLOSSA','SUBJ_NEOEL_GL','merged', false,
     'Ν.4610/2019: η Νεοελληνική Γλώσσα και η Λογοτεχνία συγχωνεύθηκαν σε ένα '
     || 'πανελλαδικά εξεταζόμενο μάθημα. Νέα δομή γραπτού, νέα ύλη — ο βαθμός '
     || 'ΔΕΝ είναι συγκρίσιμος με τον προ του 2020 βαθμό Έκθεσης.'),
    ('SUBJ_LOGOTEXNIA','SUBJ_NEOEL_GL','merged', false,
     'Ν.4610/2019: η Λογοτεχνία έπαψε να είναι αυτοτελές εξεταζόμενο μάθημα.'),
    -- Η τέταρτη θέση του Πεδίου 1 άλλαξε δύο φορές μέσα σε τρία χρόνια.
    ('SUBJ_LATINIKA','SUBJ_KOINONIOLOGIA','rescoped', false,
     'Ν.4610/2019: στην Ομάδα Ανθρωπιστικών Σπουδών η Κοινωνιολογία '
     || 'αντικατέστησε τα Λατινικά ως τέταρτο εξεταζόμενο μάθημα. Εντελώς '
     || 'διαφορετικό γνωστικό αντικείμενο στην ίδια θέση του τύπου μορίων.'),
    ('SUBJ_KOINONIOLOGIA','SUBJ_LATINIKA','rescoped', false,
     'Ν.4777/2021: επαναφορά των Λατινικών στη θέση της Κοινωνιολογίας. '
     || 'ΕΠΑΛΗΘΕΥΣΗ: το ακριβές έτος πρώτης εφαρμογής (εξετάσεις 2022) να '
     || 'επιβεβαιωθεί από την οικεία ΥΑ πριν χρησιμοποιηθεί σε αναφορά.'),
    -- The one that matters most for analytics.
    ('MORIA_PEDIO','MORIA_TMIMA','rescoped', false,
     'Ν.4777/2021: οι συντελεστές βαρύτητας μετακινήθηκαν από το ΕΠΙΣΤΗΜΟΝΙΚΟ '
     || 'ΠΕΔΙΟ στο ΤΜΗΜΑ. Δύο υποψήφιοι με ταυτόσημους βαθμούς παίρνουν πλέον '
     || 'ΔΙΑΦΟΡΕΤΙΚΑ μόρια για διαφορετικά τμήματα. Χρονοσειρά μορίων που '
     || 'διασχίζει το 2021 δεν έχει νόημα χωρίς ρητή επισήμανση.')
  ) AS x(fc, tc, tr, safe, note)
  JOIN ref.construct f ON f.framework_id = fw AND f.code = x.fc
  JOIN ref.construct t ON t.framework_id = fw AND t.code = x.tc
  ON CONFLICT (from_construct_id, to_construct_id) DO NOTHING;
END $seed$;


-- ===========================================================================
-- 4. ΟΙ ΟΜΑΔΕΣ ΠΡΟΣΑΝΑΤΟΛΙΣΜΟΥ ΚΑΙ ΤΑ ΕΠΙΣΤΗΜΟΝΙΚΑ ΠΕΔΙΑ
--
-- Two different things that developers constantly conflate:
--
--   ΟΜΑΔΑ ΠΡΟΣΑΝΑΤΟΛΙΣΜΟΥ (orientation group) — what the student STUDIES in
--   Γ΄ Λυκείου. It determines the four subjects examined. Chosen once.
--
--   ΕΠΙΣΤΗΜΟΝΙΚΟ ΠΕΔΙΟ (scientific field) — which pool of university
--   departments the student APPLIES to. It determines the συντελεστές (pre-
--   2021) and the ΕΒΕ base (always). Chosen at μηχανογραφικό time, AFTER the
--   exams, and a student may be eligible for more than one.
--
-- Since 2019-20 there are FOUR groups and FOUR fields, and the mapping is
-- nearly but NOT quite one-to-one: Θετικών Σπουδών serves Πεδίο 2, Σπουδών
-- Υγείας serves Πεδίο 3, and a candidate from either can reach Πεδίο 4 by the
-- Μαθηματικά route — the ministry publishes the eligibility table each year.
--
--   Πεδίο 1  Ανθρωπιστικές, Νομικές και Κοινωνικές Επιστήμες
--   Πεδίο 2  Θετικές και Τεχνολογικές Επιστήμες
--   Πεδίο 3  Επιστήμες Υγείας και Ζωής
--   Πεδίο 4  Επιστήμες Οικονομίας και Πληροφορικής
--
-- EXAMINED SUBJECTS PER ORIENTATION (regime of Ν.4777/2021, exams 2022 -> )
--   Ανθρωπιστικών Σπουδών ...... Νεοελληνική Γλώσσα και Λογοτεχνία,
--                                Αρχαία Ελληνικά, Ιστορία, Λατινικά
--   Θετικών Σπουδών ............ Νεοελληνική Γλώσσα και Λογοτεχνία,
--                                Μαθηματικά, Φυσική, Χημεία
--   Σπουδών Υγείας ............. Νεοελληνική Γλώσσα και Λογοτεχνία,
--                                Βιολογία, Φυσική, Χημεία
--   Σπουδών Οικονομίας και
--   Πληροφορικής ............... Νεοελληνική Γλώσσα και Λογοτεχνία,
--                                Μαθηματικά, Πληροφορική, Οικονομία
--
-- Under Ν.4610/2019 (exams 2020-2021) the list was identical EXCEPT that the
-- fourth Ανθρωπιστικών subject was Κοινωνιολογία, not Λατινικά.
--
-- THE SCHEMA MISFIT, STATED PLAINLY: there is no ref.* table for "ομάδα
-- προσανατολισμού" or "επιστημονικό πεδίο". They are encoded in
-- ref.measure.subject_group_code ('OP_ANTHR', 'PEDIO_1') and in
-- ref.benchmark.scope='field' + scope_label. That is a faithful-enough
-- encoding — the group IS the "which variant of this framework" axis the
-- column was designed for — but it means the set of groups is not itself a
-- queryable entity with a label and a validity period. Reported below.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 5. ΤΑ ΠΑΝΕΛΛΑΔΙΚΑ ΕΞΕΤΑΖΟΜΕΝΑ ΜΑΘΗΜΑΤΑ ΩΣ MEASURES
--
-- One measure per subject per regime. NOT one per orientation group: Φυσική is
-- the SAME paper, on the same day, marked by the same βαθμολογικό κέντρο, for
-- a Θετικών and a Υγείας candidate. Duplicating it per group would split one
-- national cohort into two smaller ones and destroy every benchmark join.
-- Which group a student belongs to is a property of the STUDENT
-- (org.teaching_group / org.enrolment), not of the exam.
--
-- role = 'awarded': these grades are issued by the ΥΠΑΙΘ, not marked by the
-- teacher. A school types them in (or imports them) after results day; they
-- land in gradebook.outcome with kind='awarded_official'.
--
-- ref.measure.weight is left NULL on every one of them, deliberately. A
-- subject has no intrinsic weight in Greece — the same Χημεία grade is worth
-- 200 μόρια-units to one department and 300 to another. Putting a number here
-- would be the single most tempting and most wrong thing in this file; the
-- weight belongs to the (rule, input) pair and lives in ref.conversion_input.
-- ---------------------------------------------------------------------------

DO $seed$
DECLARE
  fv16 uuid; fv19 uuid; fv21 uuid; r record; m uuid;
BEGIN
  fv16 := pg_temp.f_fv('Ν.4327/2015 — εξετάσεις 2016-2019 (3 Ομάδες Προσανατολισμού)');
  fv19 := pg_temp.f_fv('Ν.4610/2019 — εξετάσεις 2020-2021 (4 Ομάδες Προσανατολισμού)');
  fv21 := pg_temp.f_fv('Ν.4777/2021 — εξετάσεις 2022- (ΕΒΕ, συντελεστές βαρύτητας ανά τμήμα)');

  -- ---- Regime 1 (Ν.4327/2015): three orientation groups -------------------
  -- Note Νεοελληνική Γλώσσα and Λογοτεχνία are still two separate papers here,
  -- and Λατινικά is the fourth Ανθρωπιστικών subject.
  FOR r IN SELECT * FROM (VALUES
      ('SUBJ_NEOEL_GLOSSA','PAN_NEOEL_GLOSSA','Νεοελληνική Γλώσσα (Έκθεση)',           10),
      ('SUBJ_ARXAIA',      'PAN_ARXAIA',      'Αρχαία Ελληνικά Προσανατολισμού',       20),
      ('SUBJ_ISTORIA',     'PAN_ISTORIA',     'Ιστορία Προσανατολισμού',               30),
      ('SUBJ_LATINIKA',    'PAN_LATINIKA',    'Λατινικά Προσανατολισμού',              40),
      ('SUBJ_MATHIMATIKA', 'PAN_MATHIMATIKA', 'Μαθηματικά Προσανατολισμού',            50),
      ('SUBJ_FYSIKI',      'PAN_FYSIKI',      'Φυσική Προσανατολισμού',                60),
      ('SUBJ_XIMEIA',      'PAN_XIMEIA',      'Χημεία Προσανατολισμού',                70),
      ('SUBJ_VIOLOGIA',    'PAN_VIOLOGIA',    'Βιολογία Προσανατολισμού',              80),
      ('SUBJ_PLIROFORIKI', 'PAN_PLIROFORIKI', 'Ανάπτυξη Εφαρμογών σε Προγραμματιστικό Περιβάλλον', 90),
      ('SUBJ_OIKONOMIA',   'PAN_OIKONOMIA',   'Αρχές Οικονομικής Θεωρίας',            100)
    ) AS t(con, code, label, ord)
  LOOP
    PERFORM pg_temp.f_measure(fv16, r.con, 'GR_0_20', r.code,
                              r.label || ' — πανελλαδικά εξεταζόμενο', 'awarded',
                              NULL, NULL, NULL, r.ord);
  END LOOP;

  -- ---- Regimes 2 and 3: four orientation groups ---------------------------
  FOR r IN SELECT * FROM (VALUES
      ('SUBJ_NEOEL_GL',    'PAN_NEOEL_GL',    'Νεοελληνική Γλώσσα και Λογοτεχνία',     10),
      ('SUBJ_ARXAIA',      'PAN_ARXAIA',      'Αρχαία Ελληνικά Προσανατολισμού',       20),
      ('SUBJ_ISTORIA',     'PAN_ISTORIA',     'Ιστορία Προσανατολισμού',               30),
      ('SUBJ_MATHIMATIKA', 'PAN_MATHIMATIKA', 'Μαθηματικά Προσανατολισμού',            50),
      ('SUBJ_FYSIKI',      'PAN_FYSIKI',      'Φυσική Προσανατολισμού',                60),
      ('SUBJ_XIMEIA',      'PAN_XIMEIA',      'Χημεία Προσανατολισμού',                70),
      ('SUBJ_VIOLOGIA',    'PAN_VIOLOGIA',    'Βιολογία Προσανατολισμού',              80),
      ('SUBJ_PLIROFORIKI', 'PAN_PLIROFORIKI', 'Πληροφορική',                           90),
      ('SUBJ_OIKONOMIA',   'PAN_OIKONOMIA',   'Οικονομία',                            100)
    ) AS t(con, code, label, ord)
  LOOP
    PERFORM pg_temp.f_measure(fv19, r.con, 'GR_0_20', r.code,
                              r.label || ' — πανελλαδικά εξεταζόμενο', 'awarded',
                              NULL, NULL, NULL, r.ord);
    PERFORM pg_temp.f_measure(fv21, r.con, 'GR_0_20', r.code,
                              r.label || ' — πανελλαδικά εξεταζόμενο', 'awarded',
                              NULL, NULL, NULL, r.ord);
  END LOOP;
  -- Η τέταρτη θέση του Πεδίου 1: Κοινωνιολογία στο 4610, Λατινικά στο 4777.
  PERFORM pg_temp.f_measure(fv19, 'SUBJ_KOINONIOLOGIA', 'GR_0_20', 'PAN_KOINONIOLOGIA',
            'Κοινωνιολογία — πανελλαδικά εξεταζόμενο', 'awarded', NULL, NULL, NULL, 40);
  PERFORM pg_temp.f_measure(fv21, 'SUBJ_LATINIKA', 'GR_0_20', 'PAN_LATINIKA',
            'Λατινικά Προσανατολισμού — πανελλαδικά εξεταζόμενο', 'awarded', NULL, NULL, NULL, 40);

  -- ---- Ειδικά μαθήματα (regimes 2 and 3) ---------------------------------
  FOR r IN SELECT * FROM (VALUES
      ('EID_AGGLIKA',   'PAN_EID_AGGLIKA',   'Αγγλικά',                                        200),
      ('EID_GALLIKA',   'PAN_EID_GALLIKA',   'Γαλλικά',                                        210),
      ('EID_GERMANIKA', 'PAN_EID_GERMANIKA', 'Γερμανικά',                                      220),
      ('EID_EL_SXEDIO', 'PAN_EID_EL_SXEDIO', 'Ελεύθερο Σχέδιο',                                230),
      ('EID_GR_SXEDIO', 'PAN_EID_GR_SXEDIO', 'Γραμμικό Σχέδιο',                                240),
      ('EID_ARMONIA',   'PAN_EID_ARMONIA',   'Αρμονία',                                        250),
      ('EID_EMAI',      'PAN_EID_EMAI',      'Έλεγχος Μουσικών Ακουστικών Ικανοτήτων (Ε.Μ.Α.Ι.)', 260)
    ) AS t(con, code, label, ord)
  LOOP
    PERFORM pg_temp.f_measure(fv19, r.con, 'GR_0_20', r.code,
                              'Ειδικό μάθημα: ' || r.label, 'awarded', NULL, NULL, NULL, r.ord);
    PERFORM pg_temp.f_measure(fv21, r.con, 'GR_0_20', r.code,
                              'Ειδικό μάθημα: ' || r.label, 'awarded', NULL, NULL, NULL, r.ord);
  END LOOP;

  -- English glosses so a non-Greek-reading developer (or an international
  -- school's MIS) can render the same rows.
  PERFORM pg_temp.f_tr('measure', m2.id, 'en', x.en)
    FROM ref.measure m2
    JOIN (VALUES
      ('PAN_NEOEL_GL','Modern Greek Language and Literature (national exam)'),
      ('PAN_ARXAIA','Ancient Greek, orientation (national exam)'),
      ('PAN_ISTORIA','History, orientation (national exam)'),
      ('PAN_LATINIKA','Latin, orientation (national exam)'),
      ('PAN_KOINONIOLOGIA','Sociology (national exam)'),
      ('PAN_MATHIMATIKA','Mathematics, orientation (national exam)'),
      ('PAN_FYSIKI','Physics, orientation (national exam)'),
      ('PAN_XIMEIA','Chemistry, orientation (national exam)'),
      ('PAN_VIOLOGIA','Biology, orientation (national exam)'),
      ('PAN_PLIROFORIKI','Computer science (national exam)'),
      ('PAN_OIKONOMIA','Economics (national exam)'),
      ('PAN_EID_AGGLIKA','Special subject: English'),
      ('PAN_EID_GALLIKA','Special subject: French'),
      ('PAN_EID_GERMANIKA','Special subject: German'),
      ('PAN_EID_EL_SXEDIO','Special subject: Freehand drawing'),
      ('PAN_EID_GR_SXEDIO','Special subject: Technical/linear drawing'),
      ('PAN_EID_ARMONIA','Special subject: Harmony'),
      ('PAN_EID_EMAI','Special subject: Aural musical skills test')
    ) AS x(code,en) ON x.code = m2.code
   WHERE m2.framework_version_id = fv21;

  -- ---- Η βαθμολόγηση 0-100 -> 0-20 ---------------------------------------
  -- Not decoration: a school marking a past paper to the official mark scheme
  -- works in 0-100, and the /5 has to be a declared rule, not a hidden divide.
  -- Modelled as an observed 0-100 measure feeding the awarded 0-20 measure by
  -- weighted_sum with weight 0,2. (The two-marker mean itself is
  -- gradebook.result.marker_role = 'primary' / 'second' — the schema already
  -- carries double marking natively, which is exactly the Greek case.)
  FOR r IN SELECT * FROM (VALUES
      ('PAN_NEOEL_GL','SUBJ_NEOEL_GL'), ('PAN_ARXAIA','SUBJ_ARXAIA'),
      ('PAN_ISTORIA','SUBJ_ISTORIA'),   ('PAN_LATINIKA','SUBJ_LATINIKA'),
      ('PAN_MATHIMATIKA','SUBJ_MATHIMATIKA'), ('PAN_FYSIKI','SUBJ_FYSIKI'),
      ('PAN_XIMEIA','SUBJ_XIMEIA'),     ('PAN_VIOLOGIA','SUBJ_VIOLOGIA'),
      ('PAN_PLIROFORIKI','SUBJ_PLIROFORIKI'), ('PAN_OIKONOMIA','SUBJ_OIKONOMIA')
    ) AS t(code, con)
  LOOP
    m := pg_temp.f_measure(fv21, r.con, 'GR_0_100', r.code || '_RAW100',
           'Βαθμολογία γραπτού 0-100 (μ.ό. δύο βαθμολογητών) — ' || r.code,
           'observed', NULL, NULL, NULL, 300);
  END LOOP;
END $seed$;


-- ===========================================================================
-- 6. ΜΟΡΙΑ, ΡΕΖΙΜΕ 1 — ΣΥΝΤΕΛΕΣΤΕΣ ΑΝΑ ΠΕΔΙΟ (Ν.4327/2015, εξετάσεις 2016-2021)
--
-- Worked example a developer can check by hand. Candidate in Πεδίο 2 with
--   Νεοελληνική Γλώσσα και Λογοτεχνία 15,4
--   Μαθηματικά                        17,0   <- μάθημα αυξημένης βαρύτητας 1,3
--   Φυσική                            16,2   <- μάθημα αυξημένης βαρύτητας 0,7
--   Χημεία                            18,0
--
--   ministry formula:
--     Μ.Ο. = (15,4 + 17,0 + 16,2 + 18,0) / 4 = 66,6 / 4 = 16,65
--     μόρια = [ 16,65 x 8 + 17,0 x 1,3 + 16,2 x 0,7 ] x 100
--           = [ 133,20  +  22,10       +  11,34     ] x 100
--           = 166,64 x 100 = 16.664 μόρια
--
--   this table's weighted_sum, weights already x100:
--     15,4 x 200 + 17,0 x 330 + 16,2 x 270 + 18,0 x 200
--   =  3.080     +  5.610     +  4.374     +  3.600     = 16.664 μόρια   OK
--
-- The two agree exactly and always, because 8/4 = 2 distributes over the sum.
-- Any developer can rerun this check with:
--   SELECT sum(w.weight * v.grade)
--   FROM ref.conversion_input w JOIN (VALUES ...) v ON ...;
--
-- ΜΑΘΗΜΑΤΑ ΑΥΞΗΜΕΝΗΣ ΒΑΡΥΤΗΤΑΣ ΑΝΑ ΠΕΔΙΟ (regime 1)
--   Πεδίο 1   Αρχαία Ελληνικά 1,3   /  Ιστορία 0,7
--   Πεδίο 2   Μαθηματικά      1,3   /  Φυσική  0,7
--   Πεδίο 3   Βιολογία        1,3   /  Χημεία  0,7
--   Πεδίο 4   Μαθηματικά      1,3   /  Οικονομία 0,7
-- ΕΠΑΛΗΘΕΥΣΗ: the SHAPE (two subjects at 1,3 and 0,7, everything else at 1)
-- is the law; the assignment of which subject carries which coefficient is
-- stated here from the published πίνακες and should be re-checked against the
-- ΥΑ for the specific year before any report is issued.
-- ===========================================================================

DO $seed$
DECLARE
  fv19 uuid; fv21 uuid; mm uuid; rule uuid; r record;
  -- Effective dating. The COEFFICIENT regime of Ν.4327/2015 ran from the 2016
  -- exams to the 2021 exams inclusive, but the MEASURES these rules consume are
  -- the Ν.4610/2019 ones (Νεοελληνική Γλώσσα ΚΑΙ ΛΟΓΟΤΕΧΝΙΑ as a single paper,
  -- Κοινωνιολογία in the fourth Πεδίο-1 slot), and those did not exist before
  -- 2019-20. So the rule window is the intersection: the 4610 school years.
  -- The identical weight SHAPE applied to the 2016-2019 sessions over the
  -- Ν.4327/2015 measures seeded in section 5 (Νεοελληνική Γλώσσα, Λατινικά);
  -- adding those four rules is four more ref.conversion_rule rows and no code.
  d_from CONSTANT date := DATE '2019-09-01';
  d_to   CONSTANT date := DATE '2021-08-31';
BEGIN
  fv19 := pg_temp.f_fv('Ν.4610/2019 — εξετάσεις 2020-2021 (4 Ομάδες Προσανατολισμού)');
  fv21 := pg_temp.f_fv('Ν.4777/2021 — εξετάσεις 2022- (ΕΒΕ, συντελεστές βαρύτητας ανά τμήμα)');

  -- ---- Πεδίο 1 -----------------------------------------------------------
  mm := pg_temp.f_measure(fv19, 'MORIA_PEDIO', 'GR_MORIA_0_20000', 'MORIA_PEDIO_1',
          'Μόρια — 1ο Επιστημονικό Πεδίο (Ανθρωπιστικές, Νομικές, Κοινωνικές Επιστήμες)',
          'derived', 'PEDIO_1', NULL, NULL, 10);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_from, d_to,
          'Συντελεστές Ν.4327/2015, εφαρμοσμένοι στα μαθήματα του Ν.4610/2019 '
          || '(εξετάσεις 2020-2021). Βάρη = συντελεστής x 100· Σ βαρών = 1000, '
          || 'άρα μέγιστο 20 x 1000 = 20.000 μόρια.', NULL, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_NEOEL_GL'),     200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_ARXAIA'),       330);  -- 1,3
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_ISTORIA'),      270);  -- 0,7
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_KOINONIOLOGIA'),200);

  -- ---- Πεδίο 2 -----------------------------------------------------------
  mm := pg_temp.f_measure(fv19, 'MORIA_PEDIO', 'GR_MORIA_0_20000', 'MORIA_PEDIO_2',
          'Μόρια — 2ο Επιστημονικό Πεδίο (Θετικές και Τεχνολογικές Επιστήμες)',
          'derived', 'PEDIO_2', NULL, NULL, 20);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_from, d_to,
          'Συντελεστές Ν.4327/2015 (εξετάσεις 2020-2021). Μαθηματικά 1,3 · Φυσική 0,7.', NULL, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_NEOEL_GL'),    200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_MATHIMATIKA'), 330);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_FYSIKI'),      270);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_XIMEIA'),      200);

  -- ---- Πεδίο 3 -----------------------------------------------------------
  mm := pg_temp.f_measure(fv19, 'MORIA_PEDIO', 'GR_MORIA_0_20000', 'MORIA_PEDIO_3',
          'Μόρια — 3ο Επιστημονικό Πεδίο (Επιστήμες Υγείας και Ζωής)',
          'derived', 'PEDIO_3', NULL, NULL, 30);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_from, d_to,
          'Συντελεστές Ν.4327/2015 (εξετάσεις 2020-2021). Βιολογία 1,3 · Χημεία 0,7.', NULL, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_NEOEL_GL'), 200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_VIOLOGIA'), 330);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_XIMEIA'),   270);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_FYSIKI'),   200);

  -- ---- Πεδίο 4 -----------------------------------------------------------
  mm := pg_temp.f_measure(fv19, 'MORIA_PEDIO', 'GR_MORIA_0_20000', 'MORIA_PEDIO_4',
          'Μόρια — 4ο Επιστημονικό Πεδίο (Επιστήμες Οικονομίας και Πληροφορικής)',
          'derived', 'PEDIO_4', NULL, NULL, 40);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_from, d_to,
          'Συντελεστές Ν.4327/2015 (εξετάσεις 2020-2021). Μαθηματικά 1,3 · Οικονομία 0,7.', NULL, true);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_NEOEL_GL'),     200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_MATHIMATIKA'),  330);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_OIKONOMIA'),    270);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_PLIROFORIKI'),  200);

  -- ---- Ο Μ.Ο. των τεσσάρων μαθημάτων ανά πεδίο ---------------------------
  -- This is the number ΕΒΕ is compared against, so it is a first-class derived
  -- measure, not something computed on a report. It exists only in the 4777
  -- regime because ΕΒΕ did not exist before it.
  FOR r IN SELECT * FROM (VALUES
      ('MO_PEDIO_1','PEDIO_1','1ο Πεδίο', ARRAY['PAN_NEOEL_GL','PAN_ARXAIA','PAN_ISTORIA','PAN_LATINIKA']),
      ('MO_PEDIO_2','PEDIO_2','2ο Πεδίο', ARRAY['PAN_NEOEL_GL','PAN_MATHIMATIKA','PAN_FYSIKI','PAN_XIMEIA']),
      ('MO_PEDIO_3','PEDIO_3','3ο Πεδίο', ARRAY['PAN_NEOEL_GL','PAN_VIOLOGIA','PAN_XIMEIA','PAN_FYSIKI']),
      ('MO_PEDIO_4','PEDIO_4','4ο Πεδίο', ARRAY['PAN_NEOEL_GL','PAN_MATHIMATIKA','PAN_PLIROFORIKI','PAN_OIKONOMIA'])
    ) AS t(code, pedio, label, subjects)
  LOOP
    mm := pg_temp.f_measure(fv21, 'MO_PEDIOU', 'GR_MO_0_20', r.code,
            'Μέσος όρος τεσσάρων πανελλαδικά εξεταζόμενων μαθημάτων — ' || r.label,
            'derived', r.pedio, NULL, NULL, 50);
    rule := pg_temp.f_rule(mm, 'mean', DATE '2021-09-01', NULL,
            'Ο αριθμός που συγκρίνεται με την ΕΒΕ κάθε τμήματος του πεδίου. '
            || 'Απλός μέσος όρος — ΧΩΡΙΣ συντελεστές βαρύτητας: η ΕΒΕ αγνοεί '
            || 'εντελώς τους συντελεστές του τμήματος.', NULL, true);
    PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21, r.subjects[1]), 1);
    PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21, r.subjects[2]), 1);
    PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21, r.subjects[3]), 1);
    PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21, r.subjects[4]), 1);
  END LOOP;
END $seed$;


-- ===========================================================================
-- 7. ΜΟΡΙΑ, ΡΕΖΙΜΕ 2 — ΣΥΝΤΕΛΕΣΤΕΣ ΑΝΑ ΤΜΗΜΑ (Ν.4777/2021, εξετάσεις 2022- )
--
-- The unit of configuration stops being the field and becomes the department.
-- Each τμήμα publishes four συντελεστές βαρύτητας in [20%, 30%] summing to
-- 100%, plus a συντελεστής for each ειδικό μάθημα it requires, plus its
-- συντελεστής ΕΒΕ. Roughly 500 departments x 4 coefficients, republished every
-- year. THIS IS THE CASE THAT WOULD BE A NIGHTMARE AS CODE and is trivial as
-- rows: adding a department is one ref.measure and five ref.conversion_input.
--
-- Below: nine well-known departments, chosen to exercise every shape —
-- one per field, one with a language ειδικό μάθημα, one with two drawing
-- ειδικά μαθήματα (the 28.000 ceiling), one with two music ειδικά μαθήματα.
--
-- !!! EVERY COEFFICIENT SET BELOW IS ILLUSTRATIVE. !!!
-- The real ones are published per department by the ΥΠΑΙΘ (ΦΕΚ, πίνακες
-- συντελεστών βαρύτητας) and change. They are plausible and they satisfy the
-- legal constraints (each in [0,20 , 0,30], sum exactly 1,00) — they are NOT
-- the published values for any named department in any named year. Replace
-- them before a single student sees a projection.
--
-- ΤΑ ΔΥΟ ΡΕΖΙΜΕ ΣΥΝΥΠΑΡΧΟΥΝ: for Νομική ΕΚΠΑ and Ιατρική ΕΚΠΑ below there are
-- TWO ref.conversion_rule rows against the SAME output measure with disjoint
-- valid_from/valid_to — the pre-2021 field formula and the post-2021
-- department formula. The engine picks by the date of the exam session, so a
-- 2020 leaver's μόρια and a 2023 leaver's μόρια are both computable, correctly,
-- forever, from the same configuration. No migration overwrote anything.
-- ===========================================================================

DO $seed$
DECLARE
  fv19 uuid; fv21 uuid; mm uuid; rule uuid;
  d_new CONSTANT date := DATE '2021-09-01';
BEGIN
  fv19 := pg_temp.f_fv('Ν.4610/2019 — εξετάσεις 2020-2021 (4 Ομάδες Προσανατολισμού)');
  fv21 := pg_temp.f_fv('Ν.4777/2021 — εξετάσεις 2022- (ΕΒΕ, συντελεστές βαρύτητας ανά τμήμα)');

  -- ------------------------------------------------------------------ ΝΟΜΙΚΗ
  -- Νομική Σχολή ΕΚΠΑ — Πεδίο 1, χωρίς ειδικό μάθημα.
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_20000', 'MORIA_NOMIKI_EKPA',
          'Μόρια — Νομικής (ΕΚΠΑ)', 'derived', 'PEDIO_1', NULL, NULL, 110);
  -- regime 2: σ = 25% / 30% / 25% / 20%  ->  weights 250/300/250/200, Σ = 1000
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE συντελεστές. Ν.4777/2021: σ(ΝΓΛ)=25%, σ(Αρχαία)=30%, '
          || 'σ(Ιστορία)=25%, σ(Λατινικά)=20%. Βάρη = σ x 1000· μέγιστο 20.000.',
          NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),  250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ARXAIA'),    300);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ISTORIA'),   250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_LATINIKA'),  200);
  -- regime 1 for the SAME department, still live for pre-2022 leavers.
  rule := pg_temp.f_rule(mm, 'weighted_sum', DATE '2019-09-01', DATE '2021-08-31',
          'Ν.4327/2015: συντελεστές ΠΕΔΙΟΥ 1 (Αρχαία 1,3 · Ιστορία 0,7), '
          || 'τέταρτο μάθημα η Κοινωνιολογία. Διατηρείται ενεργός ώστε τα μόρια '
          || 'αποφοίτων 2020-2021 να παραμένουν υπολογίσιμα.', NULL, true, 200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_NEOEL_GL'),      200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_ARXAIA'),        330);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_ISTORIA'),       270);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_KOINONIOLOGIA'), 200);

  -- ----------------------------------------------------------------- ΙΑΤΡΙΚΗ
  -- Ιατρική ΕΚΠΑ — Πεδίο 3. The highest βάση in the country most years.
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_20000', 'MORIA_IATRIKI_EKPA',
          'Μόρια — Ιατρικής (ΕΚΠΑ)', 'derived', 'PEDIO_3', NULL, NULL, 120);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE συντελεστές. σ(ΝΓΛ)=20%, σ(Βιολογία)=30%, σ(Χημεία)=30%, '
          || 'σ(Φυσική)=20%.', NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'), 200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_VIOLOGIA'), 300);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_XIMEIA'),   300);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_FYSIKI'),   200);
  rule := pg_temp.f_rule(mm, 'weighted_sum', DATE '2019-09-01', DATE '2021-08-31',
          'Ν.4327/2015: συντελεστές ΠΕΔΙΟΥ 3 (Βιολογία 1,3 · Χημεία 0,7), '
          || 'εξετάσεις 2020-2021.', NULL, true, 200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_NEOEL_GL'), 200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_VIOLOGIA'), 330);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_XIMEIA'),   270);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv19,'PAN_FYSIKI'),   200);

  -- ------------------------------------------------------------------- ΣΗΜΜΥ
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_20000', 'MORIA_SIMMI_EMP',
          'Μόρια — Ηλεκτρολόγων Μηχανικών και Μηχανικών Υπολογιστών (ΕΜΠ)',
          'derived', 'PEDIO_2', NULL, NULL, 130);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE συντελεστές. σ(ΝΓΛ)=20%, σ(Μαθηματικά)=30%, σ(Φυσική)=30%, '
          || 'σ(Χημεία)=20%.', NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),    200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_MATHIMATIKA'), 300);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_FYSIKI'),      300);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_XIMEIA'),      200);

  -- -------------------------------------------------------------- ΠΛΗΡΟΦΟΡΙΚΗ
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_20000', 'MORIA_PLIR_OPA',
          'Μόρια — Πληροφορικής (Οικονομικό Πανεπιστήμιο Αθηνών)',
          'derived', 'PEDIO_4', NULL, NULL, 140);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE συντελεστές. σ(ΝΓΛ)=20%, σ(Μαθηματικά)=30%, '
          || 'σ(Πληροφορική)=30%, σ(Οικονομία)=20%.', NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),    200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_MATHIMATIKA'), 300);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_PLIROFORIKI'), 300);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_OIKONOMIA'),   200);

  -- ============ ΤΜΗΜΑΤΑ ΜΕ ΕΙΔΙΚΑ ΜΑΘΗΜΑΤΑ ================================
  -- μόρια += Βαθμός_ειδικού x συντελεστής x 100, δηλαδή weight = συντ. x 100.
  -- Ο συντελεστής ειδικού μαθήματος είναι 1 ή 2 και τον ορίζει το τμήμα.

  -- Αγγλικής Γλώσσας και Φιλολογίας ΕΚΠΑ — Πεδίο 1 + Αγγλικά (συντ. 2).
  -- Ceiling: 20 x 1000 + 20 x 200 = 20.000 + 4.000 = 24.000 μόρια.
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_24000', 'MORIA_AGGL_FIL_EKPA',
          'Μόρια — Αγγλικής Γλώσσας και Φιλολογίας (ΕΚΠΑ), με ειδικό μάθημα Αγγλικά',
          'derived', 'PEDIO_1', NULL, NULL, 150);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE. Τέσσερα μαθήματα πεδίου με σ=25% έκαστο (βάρη 250) '
          || 'και ειδικό μάθημα Αγγλικά με συντελεστή 2 (βάρος 200). '
          || 'Μέγιστο 20x1000 + 20x200 = 24.000.', NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),    250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ARXAIA'),      250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ISTORIA'),     250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_LATINIKA'),    250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_EID_AGGLIKA'), 200);

  -- Γαλλικής Γλώσσας και Φιλολογίας ΕΚΠΑ — Πεδίο 1 + Γαλλικά (συντ. 2).
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_24000', 'MORIA_GALL_FIL_EKPA',
          'Μόρια — Γαλλικής Γλώσσας και Φιλολογίας (ΕΚΠΑ), με ειδικό μάθημα Γαλλικά',
          'derived', 'PEDIO_1', NULL, NULL, 160);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE. Ίδια δομή με την Αγγλική Φιλολογία, ειδικό μάθημα Γαλλικά (συντ. 2).',
          NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),    250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ARXAIA'),      250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ISTORIA'),     250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_LATINIKA'),    250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_EID_GALLIKA'), 200);

  -- Γερμανικής Γλώσσας και Φιλολογίας ΑΠΘ — Πεδίο 1 + Γερμανικά (συντ. 2).
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_24000', 'MORIA_GERM_FIL_APTH',
          'Μόρια — Γερμανικής Γλώσσας και Φιλολογίας (ΑΠΘ), με ειδικό μάθημα Γερμανικά',
          'derived', 'PEDIO_1', NULL, NULL, 170);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE. Ειδικό μάθημα Γερμανικά (συντ. 2).', NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),      250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ARXAIA'),        250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ISTORIA'),       250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_LATINIKA'),      250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_EID_GERMANIKA'), 200);

  -- Αρχιτεκτόνων Μηχανικών ΕΜΠ — Πεδίο 2 + ΔΥΟ σχέδια, συντ. 2 το καθένα.
  -- Ceiling: 20 x 1000 + 20 x 200 + 20 x 200 = 28.000 μόρια. This is why
  -- GR_MORIA_0_28000 exists and why a single hardcoded "max μόρια = 20000"
  -- anywhere in an application is a bug waiting for an architecture candidate.
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_28000', 'MORIA_ARXITEKT_EMP',
          'Μόρια — Αρχιτεκτόνων Μηχανικών (ΕΜΠ), με Ελεύθερο και Γραμμικό Σχέδιο',
          'derived', 'PEDIO_2', NULL, NULL, 180);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE. Τέσσερα μαθήματα πεδίου 2 με σ=25% (βάρη 250) και δύο '
          || 'ειδικά μαθήματα σχεδίου με συντελεστή 2 (βάρη 200 έκαστο). '
          || 'Μέγιστο 20.000 + 4.000 + 4.000 = 28.000.', NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),      250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_MATHIMATIKA'),   250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_FYSIKI'),        250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_XIMEIA'),        250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_EID_EL_SXEDIO'), 200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_EID_GR_SXEDIO'), 200);

  -- Μουσικών Σπουδών ΕΚΠΑ — Πεδίο 1 + Αρμονία + Ε.Μ.Α.Ι.
  mm := pg_temp.f_measure(fv21, 'MORIA_TMIMA', 'GR_MORIA_0_28000', 'MORIA_MOUSIKON_EKPA',
          'Μόρια — Μουσικών Σπουδών (ΕΚΠΑ), με Αρμονία και Έλεγχο Μουσικών Ακουστικών Ικανοτήτων',
          'derived', 'PEDIO_1', NULL, NULL, 190);
  rule := pg_temp.f_rule(mm, 'weighted_sum', d_new, NULL,
          'ILLUSTRATIVE. Δύο ειδικά μαθήματα (Αρμονία, Ε.Μ.Α.Ι.) με συντελεστή 2. '
          || 'ΕΠΑΛΗΘΕΥΣΗ: από το 2019 ορισμένα μουσικά τμήματα εξετάζουν '
          || '«Μουσική Εκτέλεση και Ερμηνεία» και «Μουσική Αντίληψη και Γνώση» '
          || 'αντί των δύο κλασικών ειδικών μαθημάτων — ελέγξτε την ΥΑ του έτους.',
          NULL, true, 100);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_NEOEL_GL'),    250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ARXAIA'),      250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_ISTORIA'),     250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_LATINIKA'),    250);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_EID_ARMONIA'), 200);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fv21,'PAN_EID_EMAI'),    200);
END $seed$;


-- ===========================================================================
-- 8. ΕΒΕ, ΕΘΝΙΚΟΙ ΜΕΣΟΙ ΟΡΟΙ ΚΑΙ ΒΑΣΕΙΣ ΕΙΣΑΓΩΓΗΣ  -> ref.benchmark
--
-- This is the section that makes the platform able to say something a school's
-- own data structurally cannot. Every within-cohort statistic centres on the
-- cohort: a class that was taught badly in EVERYTHING has residuals summing to
-- zero and raises no flag. The only things that can see it are on this page.
--
-- Three kinds of row, all external, all from the ΥΠΑΙΘ:
--
--   statistic='mean', scope='field'
--       Ο πανελλαδικός μέσος όρος των υποψηφίων ΤΟΥ ΠΕΔΙΟΥ στα τέσσερα
--       μαθήματά του. This is the BASE of the ΕΒΕ, published by the ministry
--       right after the marks. Attached to the MO_PEDIO_n measure.
--
--   statistic='ebe', scope='national', scope_label = <τμήμα>
--       ΕΒΕ = (the above) x συντελεστής ΕΒΕ του τμήματος, where the coefficient
--       is in [0,80 , 1,20]. A candidate below it is excluded from that
--       department NO MATTER HOW MANY ΜΟΡΙΑ they scored. Note the consequence
--       that surprises everyone: because the base is a cohort mean, a HARD
--       YEAR LOWERS EVERY ΕΒΕ IN THE COUNTRY. The floor moves with the cohort.
--
--   statistic='base_admission', scope='national', scope_label = <τμήμα>
--       Η βάση εισαγωγής: the μόρια of the last candidate admitted. Not set by
--       anyone — it falls out of the μηχανογραφικό. It is the single number a
--       Greek family actually plans around, and the reason a school wants
--       μόρια projections from its own προσομοιώσεις (section 10).
--
-- !!! EVERY VALUE IN THIS SECTION IS ILLUSTRATIVE. !!!
-- The magnitudes are right (Ιατρική sits near the top of the 20.000 scale,
-- national subject means sit in the low teens or below), the exact numbers are
-- not published fact and are not attributable to the year they are filed
-- under. ΥΠΑΙΘ publishes all of them: βάσεις εισαγωγής with the results,
-- στατιστικά στοιχεία βαθμολογίας per subject, and the ΕΒΕ tables per
-- department. Load those and delete these.
-- ===========================================================================

DO $seed$
DECLARE
  fv21 uuid; s20 uuid; r record; mid uuid;
  SRC_I CONSTANT text := 'ILLUSTRATIVE — plausible magnitude only, NOT a published ΥΠΑΙΘ figure';
BEGIN
  fv21 := pg_temp.f_fv('Ν.4777/2021 — εξετάσεις 2022- (ΕΒΕ, συντελεστές βαρύτητας ανά τμήμα)');
  s20  := pg_temp.f_sid('GR_0_20');

  -- ---- Πανελλαδικοί μέσοι όροι ανά μάθημα --------------------------------
  -- The benchmark a department head actually wants: "our Χημεία mean was 11,8;
  -- the country's was 9,9". n_candidates is the order of magnitude of ΓΕΛ
  -- candidates sitting that paper.
  FOR r IN SELECT * FROM (VALUES
      ('PAN_NEOEL_GL',    12.60, 68000),
      ('PAN_ARXAIA',      10.20, 14000),
      ('PAN_ISTORIA',     11.40, 14000),
      ('PAN_LATINIKA',    10.80, 13500),
      ('PAN_MATHIMATIKA',  9.10, 26000),
      ('PAN_FYSIKI',       9.80, 30000),
      ('PAN_XIMEIA',      10.40, 30000),
      ('PAN_VIOLOGIA',    11.90, 16000),
      ('PAN_PLIROFORIKI', 11.20, 11000),
      ('PAN_OIKONOMIA',   11.60, 11000)
    ) AS t(code, mean, n)
  LOOP
    mid := pg_temp.f_mid(fv21, r.code);
    PERFORM pg_temp.f_bench(mid, NULL, 'national', 'ΓΕΛ — σύνολο υποψηφίων',
                            'mean', r.mean, 2024, SRC_I, r.n);
  END LOOP;
  -- One dispersion figure, because a mean without an sd cannot tell "we are
  -- 2 points below" from "we are two thirds of a standard deviation below",
  -- and only the second is a sentence a head of department can act on.
  PERFORM pg_temp.f_bench(pg_temp.f_mid(fv21,'PAN_MATHIMATIKA'), NULL, 'national',
          'ΓΕΛ — σύνολο υποψηφίων', 'sd', 5.60, 2024, SRC_I, 26000);
  PERFORM pg_temp.f_bench(pg_temp.f_mid(fv21,'PAN_MATHIMATIKA'), NULL, 'national',
          'ΓΕΛ — σύνολο υποψηφίων', 'p50', 8.40, 2024, SRC_I, 26000);

  -- ---- Η βάση της ΕΒΕ: μέσος όρος πεδίου ---------------------------------
  FOR r IN SELECT * FROM (VALUES
      ('MO_PEDIO_1','PEDIO_1','1ο Επιστημονικό Πεδίο', 11.25),
      ('MO_PEDIO_2','PEDIO_2','2ο Επιστημονικό Πεδίο',  9.85),
      ('MO_PEDIO_3','PEDIO_3','3ο Επιστημονικό Πεδίο', 10.55),
      ('MO_PEDIO_4','PEDIO_4','4ο Επιστημονικό Πεδίο', 11.05)
    ) AS t(code, pedio, label, mean)
  LOOP
    mid := pg_temp.f_mid(fv21, r.code, r.pedio);
    PERFORM pg_temp.f_bench(mid, NULL, 'field', r.label, 'mean', r.mean, 2024,
            SRC_I || ' — ο Μ.Ο. του πεδίου είναι η βάση υπολογισμού κάθε ΕΒΕ');
  END LOOP;

  -- ---- ΕΒΕ ανά τμήμα -----------------------------------------------------
  -- value = Μ.Ο. πεδίου x συντελεστής ΕΒΕ. The coefficient is shown in the
  -- source_ref so the arithmetic is checkable from the row alone.
  FOR r IN SELECT * FROM (VALUES
      ('MO_PEDIO_3','PEDIO_3','Ιατρικής (ΕΚΠΑ)',                                   1.20, 10.55),
      ('MO_PEDIO_1','PEDIO_1','Νομικής (ΕΚΠΑ)',                                    1.10, 11.25),
      ('MO_PEDIO_2','PEDIO_2','Ηλεκτρολόγων Μηχανικών και Μηχ. Υπολογιστών (ΕΜΠ)', 1.10,  9.85),
      ('MO_PEDIO_4','PEDIO_4','Πληροφορικής (ΟΠΑ)',                                1.00, 11.05),
      ('MO_PEDIO_1','PEDIO_1','Αγγλικής Γλώσσας και Φιλολογίας (ΕΚΠΑ)',            0.90, 11.25),
      ('MO_PEDIO_2','PEDIO_2','Αρχιτεκτόνων Μηχανικών (ΕΜΠ)',                      1.00,  9.85)
    ) AS t(mo_code, pedio, tmima, synt, base)
  LOOP
    mid := pg_temp.f_mid(fv21, r.mo_code, r.pedio);
    PERFORM pg_temp.f_bench(mid, NULL, 'national', r.tmima, 'ebe',
            round(r.base * r.synt, 2), 2024,
            SRC_I || ' — ΕΒΕ = Μ.Ο. πεδίου ' || r.base::text
                  || ' x συντελεστής ΕΒΕ τμήματος ' || r.synt::text);
  END LOOP;

  -- ΕΒΕ ειδικού μαθήματος: ίδιος μηχανισμός, βάση ο Μ.Ο. του ειδικού γραπτού.
  PERFORM pg_temp.f_bench(pg_temp.f_mid(fv21,'PAN_EID_AGGLIKA'), NULL, 'national',
          'ΓΕΛ — σύνολο υποψηφίων ειδικού μαθήματος', 'mean', 13.40, 2024, SRC_I);
  PERFORM pg_temp.f_bench(pg_temp.f_mid(fv21,'PAN_EID_AGGLIKA'), NULL, 'national',
          'Αγγλικής Γλώσσας και Φιλολογίας (ΕΚΠΑ)', 'ebe', 13.40, 2024,
          SRC_I || ' — ΕΒΕ ειδικού = Μ.Ο. ειδικού 13,40 x συντελεστής 1,00');
  PERFORM pg_temp.f_bench(pg_temp.f_mid(fv21,'PAN_EID_EL_SXEDIO'), NULL, 'national',
          'ΓΕΛ — σύνολο υποψηφίων ειδικού μαθήματος', 'mean', 14.10, 2024, SRC_I);

  -- ---- Βάσεις εισαγωγής --------------------------------------------------
  -- Attached to the DEPARTMENT'S OWN μόρια measure, which is the only place
  -- they can be compared to a projection without a units error: a βάση on the
  -- 24.000 scale must never be compared to a 20.000-scale projection.
  FOR r IN SELECT * FROM (VALUES
      ('MORIA_IATRIKI_EKPA',   'Ιατρικής (ΕΚΠΑ)',                                   18700, 2024),
      ('MORIA_IATRIKI_EKPA',   'Ιατρικής (ΕΚΠΑ)',                                   18550, 2023),
      ('MORIA_NOMIKI_EKPA',    'Νομικής (ΕΚΠΑ)',                                    18300, 2024),
      ('MORIA_SIMMI_EMP',      'Ηλεκτρολόγων Μηχανικών και Μηχ. Υπολογιστών (ΕΜΠ)', 18100, 2024),
      ('MORIA_PLIR_OPA',       'Πληροφορικής (ΟΠΑ)',                                16400, 2024),
      ('MORIA_AGGL_FIL_EKPA',  'Αγγλικής Γλώσσας και Φιλολογίας (ΕΚΠΑ)',            19600, 2024),
      ('MORIA_ARXITEKT_EMP',   'Αρχιτεκτόνων Μηχανικών (ΕΜΠ)',                      22500, 2024)
    ) AS t(code, tmima, base, yr)
  LOOP
    mid := pg_temp.f_mid(fv21, r.code,
             CASE r.code
               WHEN 'MORIA_IATRIKI_EKPA'  THEN 'PEDIO_3'
               WHEN 'MORIA_NOMIKI_EKPA'   THEN 'PEDIO_1'
               WHEN 'MORIA_SIMMI_EMP'     THEN 'PEDIO_2'
               WHEN 'MORIA_PLIR_OPA'      THEN 'PEDIO_4'
               WHEN 'MORIA_AGGL_FIL_EKPA' THEN 'PEDIO_1'
               WHEN 'MORIA_ARXITEKT_EMP'  THEN 'PEDIO_2'
             END);
    PERFORM pg_temp.f_bench(mid, NULL, 'national', r.tmima, 'base_admission',
            r.base, r.yr,
            SRC_I || ' — η βάση εισαγωγής προκύπτει από το μηχανογραφικό, '
                  || 'δεν ορίζεται· δημοσιεύεται από το ΥΠΑΙΘ με τα αποτελέσματα');
  END LOOP;
END $seed$;


-- ===========================================================================
-- 9. Ο ΕΝΔΟΣΧΟΛΙΚΟΣ ΜΗΧΑΝΙΣΜΟΣ — ΤΙ ΚΑΤΑΓΡΑΦΕΙ ΠΡΑΓΜΑΤΙΚΑ Ο ΚΑΘΗΓΗΤΗΣ
--
-- Everything above happens once, in June, to seventeen-year-olds. THIS section
-- is what a teacher touches every week, in all three years, and it is where
-- the product either gets used or does not.
--
-- Τι καταγράφεται, με τα πραγματικά ονόματα:
--
--   ΟΛΙΓΟΛΕΠΤΗ ΓΡΑΠΤΗ ΔΟΚΙΜΑΣΙΑ (τεστ) — up to ~15 minutes, unannounced,
--     covering the last lesson or two. Several per τετράμηνο. The teacher may
--     use them as they like; they feed the προφορικός βαθμός.
--   ΩΡΙΑΙΑ ΓΡΑΠΤΗ ΔΟΚΙΜΑΣΙΑ — one full period, announced, wider material.
--   ΔΙΑΓΩΝΙΣΜΑ / ΕΠΑΝΑΛΗΠΤΙΚΟ ΔΙΑΓΩΝΙΣΜΑ — the big one, usually 2-3 hours,
--     often outside timetable, on a whole ενότητα or a whole τετράμηνο.
--   ΠΡΟΣΟΜΟΙΩΣΗ — a full mock Panhellenic paper under exam conditions, Γ΄
--     Λυκείου only, typically February-April. Marked out of 100 like the real
--     thing, then divided by 5.
--   ΠΡΟΦΟΡΙΚΟΣ ΒΑΘΜΟΣ ΤΕΤΡΑΜΗΝΟΥ — the teacher's single integer 0-20 per
--     subject per term, the ONLY one of these that is legally recorded. It is
--     a professional judgement over everything above plus participation.
--   ΓΡΑΠΤΟΣ ΒΑΘΜΟΣ — the end-of-year written promotion/leaving exam.
--
-- ΤΟ ΚΡΙΣΙΜΟ ΣΗΜΕΙΟ ΓΙΑ ΤΟ ΠΡΟΪΟΝ: only the two προφορικοί and the γραπτός
-- ever leave the classroom. Every τεστ, διαγώνισμα and προσομοίωση — that is,
-- ALL of the evidence, all of the per-question detail, all of the topic
-- signal — currently lives in a paper notebook and is destroyed at the end of
-- the year. There is no national system that holds it. That gap is the
-- product. gradebook.item + curric.tag + gradebook.result are the shape of it,
-- and gradebook.item.source='trapeza' exists because since 2021-22 a
-- prescribed share of the Α΄ and Β΄ Λυκείου written exam topics is drawn from
-- the ΤΡΑΠΕΖΑ ΘΕΜΑΤΩΝ ΔΙΑΒΑΘΜΙΣΜΕΝΗΣ ΔΥΣΚΟΛΙΑΣ (ΙΕΠ), which gives those items
-- a stable external id and a published difficulty band — free anchor items for
-- equating a school's marking against the national item bank.
-- ΕΠΑΛΗΘΕΥΣΗ: the exact share (commonly cited as 50%) and the years/classes it
-- applies to are set by ΥΑ and have changed; check the current one.
--
-- Ο ΕΤΗΣΙΟΣ ΒΑΘΜΟΣ, as encoded below:
--   ετήσιος = ( (Α΄τετράμηνο + Β΄τετράμηνο) / 2  +  γραπτός ) / 2
--           = 0,25 x Α΄  +  0,25 x Β΄  +  0,50 x γραπτός
-- so the written exam is worth as much as both terms put together. Encoded as
-- a weighted_sum with weights 0,25 / 0,25 / 0,50 rather than as a nested mean,
-- because that is what it actually is and because a weighted_sum is the form
-- ref.conversion_input can express.
-- ΕΠΑΛΗΘΕΥΣΗ: the 1:1 split between προφορικά and γραπτά is the long-standing
-- ΓΕΛ rule, but promotion arithmetic has been amended repeatedly (Ν.4610/2019,
-- Ν.4692/2020 and later ΥΑ). Confirm against the current ΠΔ before reporting.
-- ===========================================================================

DO $seed$
DECLARE
  fvs uuid; taxi record; mm uuid; rule uuid; m_t1 uuid; m_t2 uuid; m_gr uuid;
  m_et uuid; m_mo uuid; r record;
BEGIN
  fvs := pg_temp.f_fv('Ενδοσχολική αξιολόγηση ΓΕΛ (Α΄/Β΄/Γ΄ Λυκείου)');

  -- level_code is the Lyceum year. subject_group_code is left NULL: these
  -- measures are SUBJECT-AGNOSTIC on purpose — "ο προφορικός βαθμός Α΄
  -- τετραμήνου" is one thing whose subject comes from the teaching group the
  -- assessment hangs off. Duplicating them per subject would multiply the
  -- config by 14 and buy nothing.
  FOR taxi IN SELECT * FROM (VALUES
      ('A', 'Α΄ Λυκείου'), ('B', 'Β΄ Λυκείου'), ('G', 'Γ΄ Λυκείου')) AS t(lvl, label)
  LOOP
    m_t1 := pg_temp.f_measure(fvs, 'SCH_PROFORIKOS', 'GR_SCHOOL_0_20',
              'PROF_T1', 'Προφορικός βαθμός Α΄ τετραμήνου — ' || taxi.label,
              'observed', NULL, taxi.lvl, NULL, 10);
    m_t2 := pg_temp.f_measure(fvs, 'SCH_PROFORIKOS', 'GR_SCHOOL_0_20',
              'PROF_T2', 'Προφορικός βαθμός Β΄ τετραμήνου — ' || taxi.label,
              'observed', NULL, taxi.lvl, NULL, 20);
    m_gr := pg_temp.f_measure(fvs, 'SCH_GRAPTOS', 'GR_SCHOOL_0_20',
              'GRAPTOS',
              CASE WHEN taxi.lvl = 'G'
                   THEN 'Γραπτός βαθμός απολυτηρίων εξετάσεων — Γ΄ Λυκείου'
                   ELSE 'Γραπτός βαθμός προαγωγικών εξετάσεων — ' || taxi.label END,
              'observed', NULL, taxi.lvl, NULL, 30);

    m_et := pg_temp.f_measure(fvs, 'SCH_ETISIOS', 'GR_MO_0_20',
              'ETISIOS', 'Ετήσιος βαθμός μαθήματος — ' || taxi.label,
              'derived', NULL, taxi.lvl, NULL, 40);
    rule := pg_temp.f_rule(m_et, 'weighted_sum', DATE '2019-09-01', NULL,
              'ετήσιος = ((Α΄τετρ + Β΄τετρ)/2 + γραπτός)/2 = 0,25Α + 0,25Β + 0,50Γ. '
              || 'requires_all_inputs = false ΕΠΙΤΗΔΕΣ: τον Ιανουάριο υπάρχει '
              || 'μόνο ο βαθμός του Α΄ τετραμήνου και ο καθηγητής θέλει να '
              || 'βλέπει την πρόβλεψη, όχι ένα κενό κελί.',
              NULL, false);
    PERFORM pg_temp.f_input(rule, m_t1, 0.25);
    PERFORM pg_temp.f_input(rule, m_t2, 0.25);
    PERFORM pg_temp.f_input(rule, m_gr, 0.50);

    m_mo := pg_temp.f_measure(fvs, 'SCH_GENIKOS_MO', 'GR_MO_0_20',
              'GENIKOS_MO', 'Γενικός μέσος όρος — ' || taxi.label,
              'derived', NULL, taxi.lvl, NULL, 50);
    rule := pg_temp.f_rule(m_mo, 'mean', DATE '2019-09-01', NULL,
              'Μ.Ο. των ετήσιων βαθμών όλων των μαθημάτων της τάξης. Ο κανόνας '
              || 'έχει ΕΝΑΝ input (τον ετήσιο βαθμό)· ο μέσος όρος παίρνεται '
              || 'πάνω στα instances του, ένα ανά μάθημα.', NULL, false);
    PERFORM pg_temp.f_input(rule, m_et, 1);

    -- Οι ενδοσχολικές δοκιμασίες. Scale GR_0_20 (με δεκαδικό): ο καθηγητής
    -- βάζει 14,5 σε διαγώνισμα — η ακεραιότητα απαιτείται μόνο στον επίσημο
    -- τετραμηνιαίο βαθμό.
    PERFORM pg_temp.f_measure(fvs, 'SCH_TEST', 'GR_0_20', 'TEST',
              'Ολιγόλεπτη γραπτή δοκιμασία (τεστ) — ' || taxi.label,
              'observed', NULL, taxi.lvl, NULL, 60);
    PERFORM pg_temp.f_measure(fvs, 'SCH_ORIAIA', 'GR_0_20', 'ORIAIA',
              'Ωριαία γραπτή δοκιμασία — ' || taxi.label,
              'observed', NULL, taxi.lvl, NULL, 70);
    PERFORM pg_temp.f_measure(fvs, 'SCH_DIAGONISMA', 'GR_0_20', 'DIAGONISMA',
              'Διαγώνισμα / επαναληπτικό διαγώνισμα — ' || taxi.label,
              'observed', NULL, taxi.lvl, NULL, 80);
  END LOOP;

  -- ---- Ο βαθμός του Απολυτηρίου -----------------------------------------
  -- Since 2016 this contributes NOTHING to university admission. It is kept
  -- because it is the legal leaving certificate, because it is what a parent
  -- sees, and because it is the school's only officially retained longitudinal
  -- number. Analytics must never add it to μόρια.
  mm := pg_temp.f_measure(fvs, 'SCH_APOLYTIRIO', 'GR_MO_0_20', 'APOLYTIRIO',
          'Βαθμός Απολυτηρίου Γενικού Λυκείου', 'derived', NULL, 'G', NULL, 90);
  rule := pg_temp.f_rule(mm, 'mean', DATE '2019-09-01', NULL,
          'Μ.Ο. των ετήσιων βαθμών όλων των μαθημάτων της Γ΄ Λυκείου. '
          || 'ΔΕΝ προσμετράται στα μόρια εισαγωγής από το 2016 και μετά.',
          NULL, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'ETISIOS', NULL, 'G'), 1);

  -- Ο χαρακτηρισμός που τυπώνεται στον τίτλο. A genuine boundary table:
  -- numeric average in, ordinal label out, bands that are NOT equal width.
  DECLARE bt uuid;
  BEGIN
    bt := pg_temp.f_bt(mm, 'GR_MO_0_20', 'GR_XARAKTIRISMOS',
            'Χαρακτηρισμός απολυτηρίου ΓΕΛ', DATE '2019-09-01',
            'ILLUSTRATIVE — τα όρια των χαρακτηρισμών ορίζονται σε ΠΔ/ΥΑ· '
            || 'τα παρακάτω είναι η συνήθως αναφερόμενη κλιμάκωση και ΔΕΝ '
            || 'έχουν επαληθευτεί από ΦΕΚ. Επαληθεύστε πριν εκτυπωθεί τίτλος.',
            true);
    -- Bottom band starts at the input scale minimum, which is what
    -- ref.v_config_errors checks for: a mark of 0 must resolve to something.
    PERFORM pg_temp.f_brow(bt, 'ANEPARKOS',     0,    9.5);
    PERFORM pg_temp.f_brow(bt, 'SXEDON_KALOS',  9.5, 12.1);
    PERFORM pg_temp.f_brow(bt, 'KALOS',        12.1, 15.1);
    PERFORM pg_temp.f_brow(bt, 'LIAN_KALOS',   15.1, 18.1);
    -- Top band runs past 20 so an exact 20,00 still resolves to Άριστα.
    PERFORM pg_temp.f_brow(bt, 'ARISTA',       18.1, 20.01);

    -- And the rule that applies it. method='boundary' with the table attached.
    PERFORM pg_temp.f_rule(mm, 'boundary', DATE '2019-09-01', NULL,
            'Εφαρμογή του πίνακα χαρακτηρισμών στον βαθμό απολυτηρίου.',
            bt, false, 200);
  END;
END $seed$;


-- ===========================================================================
-- 10. ΠΡΟΣΟΜΟΙΩΣΕΙΣ ΚΑΙ ΠΡΟΒΛΕΠΟΜΕΝΑ ΜΟΡΙΑ
--
-- The single most wanted screen in a Greek Γ΄ Λυκείου: "με τη σημερινή μου
-- επίδοση, πόσα μόρια πιάνω και σε ποια σχολή περνάω;". It is exactly the same
-- weighted_sum as section 7 with προσομοίωση marks substituted for the awarded
-- ones, compared against the base_admission benchmarks of section 8.
--
-- Modelled honestly as role='predicted', NOT 'derived': the inputs are mock
-- papers marked by the school's own teachers, which are systematically
-- different from a centrally-marked national paper (a school's προσομοίωση is
-- usually harsher in Μαθηματικά and kinder in Έκθεση). The projection is a
-- projection. Calling it 'derived' would put it next to real μόρια in every
-- list and someone would eventually compare the two.
--
-- Note the per-subject προσομοίωση measures carry subject_group_code, unlike
-- the generic διαγώνισμα above: here the subject identity is load-bearing,
-- because each one must land on a specific weight in the projection rule.
-- ===========================================================================

DO $seed$
DECLARE
  fvs uuid; fv21 uuid; r record; mm uuid; rule uuid;
BEGIN
  fvs  := pg_temp.f_fv('Ενδοσχολική αξιολόγηση ΓΕΛ (Α΄/Β΄/Γ΄ Λυκείου)');
  fv21 := pg_temp.f_fv('Ν.4777/2021 — εξετάσεις 2022- (ΕΒΕ, συντελεστές βαρύτητας ανά τμήμα)');

  FOR r IN SELECT * FROM (VALUES
      ('SUBJ_NEOEL_GL',   'PROSOM_NEOEL_GL',   'Νεοελληνική Γλώσσα και Λογοτεχνία', 10),
      ('SUBJ_ARXAIA',     'PROSOM_ARXAIA',     'Αρχαία Ελληνικά',                   20),
      ('SUBJ_ISTORIA',    'PROSOM_ISTORIA',    'Ιστορία',                           30),
      ('SUBJ_LATINIKA',   'PROSOM_LATINIKA',   'Λατινικά',                          40),
      ('SUBJ_MATHIMATIKA','PROSOM_MATHIMATIKA','Μαθηματικά',                        50),
      ('SUBJ_FYSIKI',     'PROSOM_FYSIKI',     'Φυσική',                            60),
      ('SUBJ_XIMEIA',     'PROSOM_XIMEIA',     'Χημεία',                            70),
      ('SUBJ_VIOLOGIA',   'PROSOM_VIOLOGIA',   'Βιολογία',                          80),
      ('SUBJ_PLIROFORIKI','PROSOM_PLIROFORIKI','Πληροφορική',                       90),
      ('SUBJ_OIKONOMIA',  'PROSOM_OIKONOMIA',  'Οικονομία',                        100)
    ) AS t(con, code, label, ord)
  LOOP
    PERFORM pg_temp.f_measure(fvs, r.con, 'GR_0_20', r.code,
              'Προσομοίωση πανελλαδικών — ' || r.label || ' (Γ΄ Λυκείου)',
              'observed', replace(r.con, 'SUBJ_', ''), 'G', NULL, r.ord);
  END LOOP;

  -- Προβολή μορίων προς ΙΑΤΡΙΚΗ ΕΚΠΑ, με τους (illustrative) συντελεστές του
  -- τμήματος. Ίδια βάρη με τον κανόνα του τμήματος στην ενότητα 7.
  mm := pg_temp.f_measure(fvs, 'SCH_MORIA_PRED', 'GR_MORIA_0_20000',
          'MORIA_PRED_IATRIKI_EKPA',
          'Προβλεπόμενα μόρια από προσομοιώσεις — Ιατρικής (ΕΚΠΑ)',
          'predicted', 'PEDIO_3', 'G', NULL, 200);
  rule := pg_temp.f_rule(mm, 'weighted_sum', DATE '2021-09-01', NULL,
          'Ίδιοι συντελεστές με τον κανόνα μορίων του τμήματος (ILLUSTRATIVE), '
          || 'με εισόδους τις προσομοιώσεις αντί των πανελλαδικών βαθμών. '
          || 'requires_all_inputs = false: τον Φεβρουάριο έχουν γίνει δύο στις '
          || 'τέσσερις προσομοιώσεις και η μερική προβολή είναι ακριβώς αυτό '
          || 'που ζητά ο μαθητής — σημειωμένη ως χαμηλής εμπιστοσύνης.',
          NULL, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_NEOEL_GL','NEOEL_GL','G'), 200, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_VIOLOGIA','VIOLOGIA','G'), 300, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_XIMEIA','XIMEIA','G'),     300, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_FYSIKI','FYSIKI','G'),     200, false);

  -- Προβολή μορίων προς ΣΗΜΜΥ ΕΜΠ.
  mm := pg_temp.f_measure(fvs, 'SCH_MORIA_PRED', 'GR_MORIA_0_20000',
          'MORIA_PRED_SIMMI_EMP',
          'Προβλεπόμενα μόρια από προσομοιώσεις — Ηλεκτρολόγων Μηχανικών (ΕΜΠ)',
          'predicted', 'PEDIO_2', 'G', NULL, 210);
  rule := pg_temp.f_rule(mm, 'weighted_sum', DATE '2021-09-01', NULL,
          'ILLUSTRATIVE συντελεστές τμήματος, είσοδοι οι προσομοιώσεις.', NULL, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_NEOEL_GL','NEOEL_GL','G'),       200, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_MATHIMATIKA','MATHIMATIKA','G'), 300, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_FYSIKI','FYSIKI','G'),           300, false);
  PERFORM pg_temp.f_input(rule, pg_temp.f_mid(fvs,'PROSOM_XIMEIA','XIMEIA','G'),           200, false);

  -- Η μετατροπή 0-100 -> 0-20 για ένα προσομοιωμένο γραπτό, δηλωμένη ρητά.
  -- Ο καθηγητής διορθώνει στα 100 με το επίσημο σχήμα· η πλατφόρμα διαιρεί.
  PERFORM pg_temp.f_tr('measure', mm, 'en',
    'Projected admission points from mock exams — Electrical & Computer Engineering, NTUA');
END $seed$;


-- ===========================================================================
-- 11. Η ΥΛΗ ΤΟΥ ΙΕΠ ΩΣ curric.taxonomy — ΙΣΤΟΡΙΑ ΠΡΟΣΑΝΑΤΟΛΙΣΜΟΥ
--
-- Γ΄ Λυκείου, Ομάδα Προσανατολισμού Ανθρωπιστικών Σπουδών, «Θέματα
-- Νεοελληνικής Ιστορίας». The book is organised into four ΕΝΟΤΗΤΕΣ, each into
-- numbered/lettered ΚΕΦΑΛΑΙΑ. Greek teachers think, plan, set διαγωνίσματα and
-- talk to each other exclusively in these units — "έπεσε στο προσφυγικό" is a
-- complete sentence in a Greek staffroom. So this is the tag tree that makes
-- rung 1 of the tagging ladder (one dropdown on the assessment) worth using:
-- the dropdown contains the words the teacher already uses.
--
-- The payoff is the thing the ΥΠΑΙΘ cannot give a school. The ministry
-- publishes a subject mean. It does not publish "the nation scored 42% on the
-- αγροτική μεταρρύθμιση". A school that tags its four Ιστορία διαγωνίσματα
-- against this tree gets, by April, a per-ενότητα profile of its own cohort,
-- which is the only content-level diagnosis that exists anywhere in the Greek
-- system.
--
-- ΕΠΑΛΗΘΕΥΣΗ: the four ενότητες and the chapter titles below are the standard
-- structure of the ΙΕΠ/ΙΤΥΕ textbook. The lettering of sub-sections within
-- Ενότητα Ι is reproduced from the printed table of contents and should be
-- checked against the current edition before it is shown to teachers; the ύλη
-- is re-issued by ΥΑ every year and sections move.
-- ===========================================================================

DO $seed$
DECLARE
  tx uuid; en uuid; kf uuid; r record;
  SRC CONSTANT text :=
    'ΙΕΠ / ΙΤΥΕ «Διόφαντος» — «Θέματα Νεοελληνικής Ιστορίας», Γ΄ ΓΕΛ, '
    || 'Ομάδα Προσανατολισμού Ανθρωπιστικών Σπουδών';
BEGIN
  tx := pg_temp.f_tax('GR_ISTORIA_PROS_YLI',
          'Ιστορία Προσανατολισμού Γ΄ ΓΕΛ — Θέματα Νεοελληνικής Ιστορίας (ύλη ΙΕΠ)',
          'topic', SRC);

  -- ================= ΕΝΟΤΗΤΑ Ι =================
  en := pg_temp.f_tag(tx, NULL, 'I',
          'Ι. Από την αγροτική οικονομία στην αστικοποίηση', 1, false);
  kf := pg_temp.f_tag(tx, en, 'I.1', 'Ι.1 Η ελληνική οικονομία μετά την Επανάσταση', 1, false);
  FOR r IN SELECT * FROM (VALUES
      ('I.1.A',  'Α. Τα δημογραφικά δεδομένα και οι εξελίξεις',                    1),
      ('I.1.B',  'Β. Η αγροτική οικονομία και η διανομή των εθνικών γαιών',        2),
      ('I.1.G',  'Γ. Η αγροτική μεταρρύθμιση (1917)',                              3),
      ('I.1.D',  'Δ. Η ελληνική βιομηχανία',                                       4),
      ('I.1.E',  'Ε. Τα δίκτυα συγκοινωνιών και μεταφορών',                        5),
      ('I.1.ST', 'ΣΤ. Το εμπόριο και η εμπορική ναυτιλία',                         6),
      ('I.1.Z',  'Ζ. Νομισματικό σύστημα, τράπεζες και δημόσια οικονομικά',        7)
    ) AS t(code, label, ord)
  LOOP
    PERFORM pg_temp.f_tag(tx, kf, r.code, r.label, r.ord, true, 90);
  END LOOP;

  -- ================= ΕΝΟΤΗΤΑ ΙΙ =================
  en := pg_temp.f_tag(tx, NULL, 'II',
          'ΙΙ. Η διαμόρφωση και λειτουργία των πολιτικών κομμάτων στην Ελλάδα (1821-1936)',
          2, false);
  FOR r IN SELECT * FROM (VALUES
      ('II.1', 'ΙΙ.1 Τα πρώτα πολιτικά κόμματα: αγγλικό, γαλλικό, ρωσικό (1821-1832)', 1),
      ('II.2', 'ΙΙ.2 Η οθωνική περίοδος (1833-1862)',                                  2),
      ('II.3', 'ΙΙ.3 Η περίοδος 1862-1871: το πελατειακό σύστημα',                     3),
      ('II.4', 'ΙΙ.4 Η αρχή της δεδηλωμένης και η αναμόρφωση του πολιτικού συστήματος (1875)', 4),
      ('II.5', 'ΙΙ.5 Το κίνημα στο Γουδί, ο Βενιζέλος και ο Εθνικός Διχασμός (1909-1922)', 5),
      ('II.6', 'ΙΙ.6 Από τη Μικρασιατική καταστροφή στη δικτατορία της 4ης Αυγούστου (1922-1936)', 6)
    ) AS t(code, label, ord)
  LOOP
    PERFORM pg_temp.f_tag(tx, en, r.code, r.label, r.ord, true, 120);
  END LOOP;

  -- ================= ΕΝΟΤΗΤΑ ΙΙΙ =================
  -- The one every Greek candidate expects and every teacher over-teaches.
  en := pg_temp.f_tag(tx, NULL, 'III',
          'ΙΙΙ. Το προσφυγικό ζήτημα στην Ελλάδα (1821-1930)', 3, false);
  FOR r IN SELECT * FROM (VALUES
      ('III.1', 'ΙΙΙ.1 Προσφυγικά ρεύματα κατά την περίοδο 1821-1922',            1),
      ('III.2', 'ΙΙΙ.2 Η Μικρασιατική καταστροφή και η έξοδος',                   2),
      ('III.3', 'ΙΙΙ.3 Η Σύμβαση της Λωζάννης και η υποχρεωτική ανταλλαγή πληθυσμών', 3),
      ('III.4', 'ΙΙΙ.4 Η Επιτροπή Αποκαταστάσεως Προσφύγων (ΕΑΠ) και η αγροτική αποκατάσταση', 4),
      ('III.5', 'ΙΙΙ.5 Η αστική αποκατάσταση των προσφύγων',                      5),
      ('III.6', 'ΙΙΙ.6 Η αποζημίωση των ανταλλαξίμων και η ελληνοτουρκική προσέγγιση', 6),
      ('III.7', 'ΙΙΙ.7 Η ένταξη των προσφύγων στην Ελλάδα: οικονομικές, κοινωνικές, πολιτισμικές συνέπειες', 7)
    ) AS t(code, label, ord)
  LOOP
    PERFORM pg_temp.f_tag(tx, en, r.code, r.label, r.ord, true, 120);
  END LOOP;

  -- ================= ΕΝΟΤΗΤΑ IV =================
  en := pg_temp.f_tag(tx, NULL, 'IV',
          'IV. Το Κρητικό Ζήτημα από διπλωματική άποψη κατά τον 19ο και τις αρχές του 20ού αιώνα',
          4, false);
  FOR r IN SELECT * FROM (VALUES
      ('IV.1', 'IV.1 Η Κρητική Επανάσταση 1866-1869 και ο Οργανικός Νόμος',       1),
      ('IV.2', 'IV.2 Η Σύμβαση της Χαλέπας (1878) και η περίοδος έως το 1895',    2),
      ('IV.3', 'IV.3 Η επανάσταση του 1896-1897 και η επέμβαση των Μ. Δυνάμεων',  3),
      ('IV.4', 'IV.4 Η Κρητική Πολιτεία (1898-1913)',                             4),
      ('IV.5', 'IV.5 Η ένωση της Κρήτης με την Ελλάδα (1913)',                    5)
    ) AS t(code, label, ord)
  LOOP
    PERFORM pg_temp.f_tag(tx, en, r.code, r.label, r.ord, true, 120);
  END LOOP;

  -- ---------------------------------------------------------------------
  -- ΕΞΕΤΑΣΤΕΑ ΥΛΗ ΑΝΑ ΕΤΟΣ — curric.tag_inclusion
  --
  -- Greek ύλη is re-defined by Υπουργική Απόφαση every single year and the
  -- reduction is often announced in autumn, after teaching has started. A
  -- multi-year comparison of "how did our cohorts do on το προσφυγικό" is
  -- meaningless unless the system knows which years it was examinable. Hence
  -- source_ref: the answer cites a document instead of asserting a fact.
  --
  -- tenant_id = NULL means these are PLATFORM-published rows: every school in
  -- the country is under the same ΥΑ. A school that legitimately deviates
  -- (e.g. ξένο σχολείο) writes its own rows with its own tenant_id, and the
  -- unique index keeps the two apart.
  -- ---------------------------------------------------------------------
  FOR r IN SELECT code FROM curric.tag WHERE taxonomy_id = tx AND parent_id IS NOT NULL
  LOOP
    PERFORM pg_temp.f_incl(
      (SELECT id FROM curric.tag WHERE taxonomy_id = tx AND code = r.code),
      '2023-2024', true,
      'ΕΠΑΛΗΘΕΥΣΗ ΑΠΑΙΤΕΙΤΑΙ — υποτίθεται πλήρης ύλη. Η εξεταστέα ύλη '
      || 'ορίζεται με ΥΑ (ΦΕΚ Β΄) ανά έτος· ο αριθμός ΦΕΚ ΔΕΝ έχει '
      || 'επαληθευτεί εδώ και πρέπει να συμπληρωθεί πριν χρησιμοποιηθεί.');
  END LOOP;

  -- Η μειωμένη ύλη της περιόδου COVID (σχολ. έτος 2020-2021) είναι το
  -- καθαρότερο παράδειγμα του γιατί υπάρχει αυτός ο πίνακας: ένα σχολείο που
  -- συγκρίνει τις επιδόσεις του 2021 με του 2019 στο ίδιο κεφάλαιο συγκρίνει
  -- δύο διαφορετικά πράγματα.
  -- ILLUSTRATIVE: ότι ΥΠΗΡΞΕ περικοπή ύλης το 2020-2021 είναι βέβαιο· ΠΟΙΑ
  -- κεφάλαια αφαιρέθηκαν από την Ιστορία Προσανατολισμού ΔΕΝ επαληθεύεται εδώ.
  FOR r IN SELECT code FROM curric.tag
            WHERE taxonomy_id = tx AND code LIKE 'IV.%'
  LOOP
    PERFORM pg_temp.f_incl(
      (SELECT id FROM curric.tag WHERE taxonomy_id = tx AND code = r.code),
      '2020-2021', false,
      'ILLUSTRATIVE — παράδειγμα περικομμένης ύλης COVID. Η ΥΑ/ΦΕΚ ΔΕΝ έχει '
      || 'επαληθευτεί· ΜΗΝ χρησιμοποιηθεί ως τεκμήριο. Αντικαταστήστε με την '
      || 'πραγματική ΥΑ εξεταστέας ύλης του έτους.');
  END LOOP;
END $seed$;

-- ---------------------------------------------------------------------------
-- Αρχαία Ελληνικά Προσανατολισμού — μικρότερο δέντρο, δεύτερο παράδειγμα.
--
-- Από το 2019-20 τα Αρχαία Προσανατολισμού διδάσκονται από «Φάκελο Υλικού»
-- του ΙΕΠ αντί για το παλαιό εγχειρίδιο, και το γραπτό έχει ΔΥΟ σκέλη:
-- διδαγμένο κείμενο (Πλάτων, Αριστοτέλης) και αδίδακτο κείμενο. Η διάκριση
-- είναι σημαντική για την ανάλυση: ένας μαθητής μπορεί να είναι άριστος στο
-- διδαγμένο (αποστήθιση + ερμηνεία) και αδύναμος στο αδίδακτο (συντακτικό),
-- και ο συνολικός βαθμός κρύβει ακριβώς αυτό.
-- ΕΠΑΛΗΘΕΥΣΗ: η σύνθεση του Φακέλου Υλικού και τα εξεταζόμενα χωρία αλλάζουν
-- με ΥΑ· ελέγξτε την τρέχουσα.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE tx uuid; did uuid; adid uuid; r record;
BEGIN
  tx := pg_temp.f_tax('GR_ARXAIA_PROS_YLI',
          'Αρχαία Ελληνικά Προσανατολισμού Γ΄ ΓΕΛ — Φάκελος Υλικού ΙΕΠ',
          'topic', 'ΙΕΠ — Φάκελος Υλικού Αρχαίων Ελληνικών Γ΄ ΓΕΛ (από 2019-20)');

  did  := pg_temp.f_tag(tx, NULL, 'DID',  'Διδαγμένο κείμενο', 1, false);
  adid := pg_temp.f_tag(tx, NULL, 'ADID', 'Αδίδακτο κείμενο',  2, false);

  FOR r IN SELECT * FROM (VALUES
      ('DID.PLAT.PROT', 'Πλάτων, Πρωταγόρας',        1),
      ('DID.PLAT.POL',  'Πλάτων, Πολιτεία',          2),
      ('DID.ARIST.HN',  'Αριστοτέλης, Ηθικά Νικομάχεια', 3),
      ('DID.ARIST.POL', 'Αριστοτέλης, Πολιτικά',     4)
    ) AS t(code, label, ord)
  LOOP
    PERFORM pg_temp.f_tag(tx, did, r.code, r.label, r.ord, true, 180);
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
      ('ADID.METAFRASI', 'Μετάφραση αδίδακτου κειμένου',                1),
      ('ADID.GRAM',      'Γραμματική (κλίση, ρηματικοί τύποι)',         2),
      ('ADID.SYNT',      'Συντακτικό (αναγνώριση και μετασχηματισμοί)', 3),
      ('ADID.LEX',       'Λεξιλογικές - ετυμολογικές ασκήσεις',         4)
    ) AS t(code, label, ord)
  LOOP
    PERFORM pg_temp.f_tag(tx, adid, r.code, r.label, r.ord, true, 90);
  END LOOP;
END $seed$;

COMMIT;

-- ===========================================================================
-- ΤΙ ΜΕΝΕΙ ΝΑ ΓΙΝΕΙ ΜΕΤΑ ΑΠΟ ΑΥΤΟ ΤΟ ΑΡΧΕΙΟ  /  WHAT IS STILL TO DO
--
--  1. Αντικαταστήστε ΚΑΘΕ γραμμή ref.benchmark με source_ref 'ILLUSTRATIVE…'
--     με τα δημοσιευμένα στοιχεία του ΥΠΑΙΘ: βάσεις εισαγωγής, στατιστικά
--     βαθμολογίας ανά μάθημα, πίνακες ΕΒΕ ανά τμήμα. Προσθέτετε ΝΕΑ γραμμή ανά
--     έτος· ποτέ μην επεξεργάζεστε παλιά — η βάση του 2023 πρέπει να μένει η
--     βάση του 2023.
--  2. Αντικαταστήστε τους συντελεστές βαρύτητας της ενότητας 7 με τους
--     δημοσιευμένους ανά τμήμα (ένα ref.conversion_input ανά μάθημα ανά
--     τμήμα). ~500 τμήματα x 4-6 γραμμές = μία φορά τον χρόνο, με φόρτωση
--     αρχείου, χωρίς ούτε μία γραμμή κώδικα.
--  3. Συμπληρώστε τα ΦΕΚ στα curric.tag_inclusion και διαγράψτε τις γραμμές
--     που φέρουν 'ILLUSTRATIVE'.
--  4. Επαληθεύστε τα όρια του πίνακα χαρακτηρισμών απολυτηρίου από το ΠΔ και
--     γυρίστε το boundary_table σε is_provisional = false.
--  5. Αν/όταν φορτωθεί η πραγματική κατανομή βαθμολογίας ανά μάθημα, ξανα-
--     υπολογίστε τα ref.scale_point.pct_anchor του GR_0_20 από αυτήν και
--     ΜΟΝΟ ΤΟΤΕ βάλτε ref.scale.equating_status = 'anchored'.
--  6. Δείξτε κάθε org.teaching_group στο ref.framework_version του ΡΕΖΙΜΕ υπό
--     το οποίο εξετάζεται, όχι σε ημερολογιακό έτος.
-- ===========================================================================
