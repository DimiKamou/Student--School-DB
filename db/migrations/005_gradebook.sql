-- ============================================================================
-- 005_gradebook.sql — assessments, items, and the two fact tables
--
-- gradebook.result   OBSERVED: a mark a teacher put on a thing a student did.
-- gradebook.outcome  DERIVED/AWARDED: a grade computed or issued (MYP level,
--                    DP subject grade, μόρια projection, predicted GCSE).
--
-- They are separate tables, not one table with a `derivation` column, because
-- the single most dangerous query in this domain is the one that sums a
-- student's question marks together with the total derived from them. Here that
-- query cannot be written by accident.
--
-- There is NO draft/published state gate. A mark counts the moment it is typed.
-- A gate whose default value excludes data from analytics produces a product
-- that silently does nothing, and the teacher gets no error to report.
-- ============================================================================

CREATE TABLE gradebook.assessment (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  teaching_group_id uuid NOT NULL REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  term_id           uuid REFERENCES org.term(id) ON DELETE SET NULL,
  title             text NOT NULL,
  kind              text NOT NULL DEFAULT 'summative' CHECK (kind IN
                      ('formative','summative','mock','exam','homework','oral',
                       'practical','project','external')),
  occurred_on       date NOT NULL DEFAULT current_date,
  -- RUNG 1 OF THE TAGGING LADDER: one dropdown, one column, no join table.
  -- This single nullable FK is the difference between topic analytics existing
  -- and not existing for the median teacher.
  topic_tag_id      uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  -- Total available, when the teacher enters one number instead of per-question
  -- marks. Nullable: MYP criterion entry has no single max.
  max_total         numeric(10,4) CHECK (max_total IS NULL OR max_total > 0),
  weight            numeric(8,5) NOT NULL DEFAULT 1 CHECK (weight >= 0),
  blueprint_id      uuid REFERENCES curric.blueprint(id) ON DELETE SET NULL,
  -- Set once the teacher says "I'm done marking this". Purely informational:
  -- analytics NEVER filter on it. It drives the "what do I still owe" list.
  marking_closed_at timestamptz,
  created_by        uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz
);
CREATE INDEX assessment_group_ix ON gradebook.assessment (tenant_id, teaching_group_id, occurred_on);
CREATE INDEX assessment_topic_ix ON gradebook.assessment (tenant_id, topic_tag_id)
  WHERE topic_tag_id IS NOT NULL;
CREATE INDEX assessment_open_marking_ix ON gradebook.assessment (tenant_id, teaching_group_id)
  WHERE marking_closed_at IS NULL AND deleted_at IS NULL;

-- A question, a criterion, a component. One row per scored slot.
-- An assessment with NO items is legal and normal: the teacher entered a single
-- total. In that case a synthetic item is created (seq 0) so the fact table has
-- exactly one shape.
CREATE TABLE gradebook.item (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  assessment_id uuid NOT NULL REFERENCES gradebook.assessment(id) ON DELETE CASCADE,
  seq           smallint NOT NULL,
  label         text NOT NULL,
  max_value     numeric(10,4) CHECK (max_value IS NULL OR max_value > 0),
  scale_id      uuid REFERENCES ref.scale(id) ON DELETE RESTRICT,
  measure_id    uuid REFERENCES ref.measure(id) ON DELETE RESTRICT,
  -- RUNG 2/3: per-item tagging, always optional, inherits from the assessment.
  topic_tag_id  uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  skill_tag_id  uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  -- Item-bank provenance, for anchor equating and ΤΘΔΔ difficulty.
  source        text NOT NULL DEFAULT 'teacher'
                  CHECK (source IN ('teacher','trapeza','past_paper','textbook','shared')),
  external_ref  text,
  external_difficulty numeric(6,4),
  is_anchor     boolean NOT NULL DEFAULT false,
  UNIQUE (assessment_id, seq)
);
CREATE INDEX item_assessment_ix ON gradebook.item (tenant_id, assessment_id);
CREATE INDEX item_topic_ix ON gradebook.item (tenant_id, topic_tag_id) WHERE topic_tag_id IS NOT NULL;
CREATE INDEX item_skill_ix ON gradebook.item (tenant_id, skill_tag_id) WHERE skill_tag_id IS NOT NULL;

-- A 16-mark essay is 6 marks AO1 + 10 marks AO2. This is a WEIGHTED many-to-
-- many; resolving it with "pick one, LIMIT 1" throws away the whole point.
CREATE TABLE gradebook.item_measure_alloc (
  tenant_id  uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  item_id    uuid NOT NULL REFERENCES gradebook.item(id) ON DELETE CASCADE,
  measure_id uuid NOT NULL REFERENCES ref.measure(id) ON DELETE CASCADE,
  marks      numeric(10,4) NOT NULL CHECK (marks > 0),
  PRIMARY KEY (tenant_id, item_id, measure_id)
);

-- ---------------------------------------------------------------------------
-- THE OBSERVED FACT TABLE
-- ---------------------------------------------------------------------------
CREATE TABLE gradebook.result (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  item_id       uuid NOT NULL REFERENCES gradebook.item(id) ON DELETE CASCADE,
  student_id    uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  -- Co-teaching and second marking are normal, not exotic. Two teachers marking
  -- the same class at the same time must not collide on a unique violation.
  marker_role   text NOT NULL DEFAULT 'primary'
                  CHECK (marker_role IN ('primary','second','moderated','self','peer')),

  raw_value     numeric(12,4),        -- numeric mark
  value_code    text,                 -- ordinal grade code ('7','A*','Μ')
  max_value     numeric(12,4),        -- denormalised from item/assessment: no join to normalise
  scale_id      uuid REFERENCES ref.scale(id) ON DELETE RESTRICT,

  -- pct is NULL unless status='scored'. An absence is not a zero, ever.
  pct           numeric(8,6) CHECK (pct IS NULL OR (pct >= 0 AND pct <= 1)),

  status        text NOT NULL DEFAULT 'scored' CHECK (status IN
                  ('scored','absent','not_submitted','exempt','pending','malpractice')),
  -- Marks a value produced by "everyone got this, tap the exceptions" bulk entry.
  -- 28 untouched positives are weak evidence; 28 deliberate ones are not.
  is_defaulted  boolean NOT NULL DEFAULT false,
  submitted_late boolean NOT NULL DEFAULT false,

  observed_on   date NOT NULL DEFAULT current_date,
  marked_by     uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  source        text NOT NULL DEFAULT 'manual'
                  CHECK (source IN ('manual','import','paste','ocr','api','derived_entry')),
  comment       text,
  recorded_at   timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT result_has_a_value CHECK (
    status <> 'scored' OR raw_value IS NOT NULL OR value_code IS NOT NULL)
);
CREATE UNIQUE INDEX result_cell_uq ON gradebook.result (item_id, student_id, marker_role);
CREATE INDEX result_student_ix ON gradebook.result (tenant_id, student_id, observed_on);
CREATE INDEX result_item_ix ON gradebook.result (tenant_id, item_id);
CREATE INDEX result_scored_ix ON gradebook.result (tenant_id, student_id) WHERE status = 'scored';

-- ---------------------------------------------------------------------------
-- Normalisation. pct is computed here, once, on write.
--   ratio/interval : (raw - min) / (max - min)
--   ordinal grade  : the scale point's pct_anchor  <- NOT (rank-1)/(n-1)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gradebook.tg_result_normalise() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s ref.scale%ROWTYPE; lo numeric; hi numeric;
BEGIN
  NEW.updated_at := now();

  IF NEW.status <> 'scored' THEN
    NEW.pct := NULL;                      -- absence is never a zero
    RETURN NEW;
  END IF;

  IF NEW.scale_id IS NOT NULL THEN
    SELECT * INTO s FROM ref.scale WHERE id = NEW.scale_id;
  END IF;

  IF NEW.value_code IS NOT NULL AND NEW.scale_id IS NOT NULL THEN
    SELECT sp.pct_anchor INTO NEW.pct
    FROM ref.scale_point sp WHERE sp.scale_id = NEW.scale_id AND sp.code = NEW.value_code;
    IF NEW.pct IS NULL THEN
      RAISE EXCEPTION 'value_code % is not a point on scale %', NEW.value_code, NEW.scale_id
        USING ERRCODE = 'check_violation';
    END IF;
    IF s.higher_is_better IS FALSE THEN NEW.pct := 1 - NEW.pct; END IF;
    RETURN NEW;
  END IF;

  IF NEW.raw_value IS NOT NULL THEN
    lo := coalesce(s.min_value, 0);
    hi := coalesce(NEW.max_value, s.max_value);
    IF hi IS NULL OR hi <= lo THEN
      NEW.pct := NULL;                    -- no denominator: keep the mark, skip normalisation
    ELSE
      NEW.pct := round(greatest(0, least(1, (NEW.raw_value - lo) / (hi - lo)))::numeric, 6);
      IF s.higher_is_better IS FALSE THEN NEW.pct := 1 - NEW.pct; END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER result_normalise
  BEFORE INSERT OR UPDATE ON gradebook.result
  FOR EACH ROW EXECUTE FUNCTION gradebook.tg_result_normalise();

-- ---------------------------------------------------------------------------
-- System-time history. Two jobs:
--   1. audit — who changed a mark, when, from what
--   2. AS-OF analytics — "were the students we flagged in October the ones who
--      actually declined, judged only on what we knew in October?" That is the
--      honest way to evaluate an early-warning system and the strongest
--      empirical claim the thesis can make. It is uncomputable without this.
-- ---------------------------------------------------------------------------
CREATE TABLE gradebook.result_version (
  id          bigserial PRIMARY KEY,
  result_id   uuid NOT NULL,
  tenant_id   uuid NOT NULL,
  item_id     uuid NOT NULL,
  student_id  uuid NOT NULL,
  marker_role text NOT NULL,
  raw_value   numeric(12,4),
  value_code  text,
  pct         numeric(8,6),
  status      text NOT NULL,
  changed_by  uuid,
  change_kind text NOT NULL CHECK (change_kind IN ('insert','update','delete')),
  valid_from  timestamptz NOT NULL,
  valid_to    timestamptz            -- NULL = current
);
CREATE INDEX result_version_asof_ix ON gradebook.result_version (tenant_id, student_id, valid_from, valid_to);
CREATE INDEX result_version_result_ix ON gradebook.result_version (result_id, valid_from DESC);

CREATE OR REPLACE FUNCTION gradebook.tg_result_history() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE ts timestamptz := clock_timestamp();
BEGIN
  IF TG_OP <> 'INSERT' THEN
    UPDATE gradebook.result_version SET valid_to = ts
    WHERE result_id = OLD.id AND valid_to IS NULL;
  END IF;
  IF TG_OP = 'DELETE' THEN
    INSERT INTO gradebook.result_version
      (result_id, tenant_id, item_id, student_id, marker_role, raw_value, value_code,
       pct, status, changed_by, change_kind, valid_from, valid_to)
    VALUES (OLD.id, OLD.tenant_id, OLD.item_id, OLD.student_id, OLD.marker_role,
            OLD.raw_value, OLD.value_code, OLD.pct, OLD.status, app.current_user_id(),
            'delete', ts, ts);
    RETURN OLD;
  END IF;
  INSERT INTO gradebook.result_version
    (result_id, tenant_id, item_id, student_id, marker_role, raw_value, value_code,
     pct, status, changed_by, change_kind, valid_from, valid_to)
  VALUES (NEW.id, NEW.tenant_id, NEW.item_id, NEW.student_id, NEW.marker_role,
          NEW.raw_value, NEW.value_code, NEW.pct, NEW.status, app.current_user_id(),
          lower(TG_OP), ts, NULL);
  RETURN NEW;
END $$;

CREATE TRIGGER result_history
  AFTER INSERT OR UPDATE OR DELETE ON gradebook.result
  FOR EACH ROW EXECUTE FUNCTION gradebook.tg_result_history();

-- ---------------------------------------------------------------------------
-- THE DERIVED / AWARDED FACT TABLE
-- ---------------------------------------------------------------------------
CREATE TABLE gradebook.outcome (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  student_id        uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  teaching_group_id uuid REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  term_id           uuid REFERENCES org.term(id) ON DELETE SET NULL,
  measure_id        uuid REFERENCES ref.measure(id) ON DELETE SET NULL,

  kind              text NOT NULL CHECK (kind IN
                      ('system_suggested',  -- what the engine computed
                       'teacher_determined',-- MYP best-fit: what the teacher decided
                       'reported',          -- what went on the report card
                       'awarded_official',  -- what the IB/ΥΠΑΙΘ/AQA actually issued
                       'predicted_teacher',
                       'predicted_model',
                       'target')),

  raw_value         numeric(12,4),
  value_code        text,
  scale_id          uuid REFERENCES ref.scale(id) ON DELETE RESTRICT,
  pct               numeric(8,6),

  -- The MYP best-fit override, in ONE row: "we suggested 6, you chose 7, here
  -- is why". Split across two rows it needs a self-join to render, and the
  -- override rate — a genuine analytic about teacher judgement — gets lost.
  suggested_value   numeric(12,4),
  overrides_suggestion boolean GENERATED ALWAYS AS
                      (suggested_value IS NOT NULL AND raw_value IS DISTINCT FROM suggested_value) STORED,
  determination_method text CHECK (determination_method IN
                      ('rule','best_fit_manual','suggestion_accepted',
                       'insufficient_evidence','carried_forward','external_import')),
  evidence_count    integer,
  confidence        text CHECK (confidence IN ('high','medium','low','insufficient')),
  rationale         text,

  computed_by_rule_id uuid REFERENCES ref.conversion_rule(id) ON DELETE SET NULL,
  decided_by        uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  observed_on       date NOT NULL DEFAULT current_date,
  recorded_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX outcome_uq ON gradebook.outcome
  (tenant_id, student_id, coalesce(measure_id, app.global_tenant()),
   coalesce(term_id, app.global_tenant()), kind);
CREATE INDEX outcome_student_ix ON gradebook.outcome (tenant_id, student_id, observed_on);
CREATE INDEX outcome_group_ix ON gradebook.outcome (tenant_id, teaching_group_id, kind);

-- ---------------------------------------------------------------------------
-- Idempotency for offline/flaky-network batch entry. Deliberately NOT keyed by
-- anything derived (academic year, partition): a client replaying a batch after
-- a tunnel drop must dedupe on the key it generated, not one it recomputes.
-- ---------------------------------------------------------------------------
CREATE TABLE gradebook.idempotency (
  tenant_id          uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  client_mutation_id text NOT NULL,
  applied_at         timestamptz NOT NULL DEFAULT now(),
  result_summary     jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (tenant_id, client_mutation_id)
);

-- ---------------------------------------------------------------------------
-- Entry telemetry. The thesis's central empirical claim is "under two minutes
-- drives accumulation". Without this table that claim is untestable, and the
-- product cannot tell a slow screen from an unpopular one.
-- ---------------------------------------------------------------------------
CREATE TABLE gradebook.entry_session (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  user_id         uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  assessment_id   uuid REFERENCES gradebook.assessment(id) ON DELETE CASCADE,
  screen          text NOT NULL,
  started_at      timestamptz NOT NULL DEFAULT now(),
  first_value_at  timestamptz,
  ended_at        timestamptz,
  cells_expected  integer,
  cells_entered   integer,
  was_abandoned   boolean NOT NULL DEFAULT false,
  device          text CHECK (device IN ('desktop','tablet','phone'))
);
CREATE INDEX entry_session_tenant_ix ON gradebook.entry_session (tenant_id, started_at DESC);
