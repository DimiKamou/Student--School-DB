-- ============================================================================
-- 006_write_path.sql — how marks actually get in, and what teachers get back
--
-- One RPC, one transaction, one round trip for a whole class. Entry cost is the
-- binding constraint on this product: if a teacher cannot finish a class in
-- about two minutes, no data accumulates and every analytic downstream is a
-- decoration on an empty table.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Create an assessment and, if no items are given, a single synthetic item so
-- the fact table has exactly one shape. "A quiz out of 20 on Tuesday" must be
-- expressible with no framework, no blueprint, no criteria and no tagging.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gradebook.create_assessment(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid := app.require_tenant();
  v_id uuid;
  v_item jsonb;
  v_seq smallint := 0;
  v_term uuid;
BEGIN
  -- Snap to the term containing the date, so the teacher never picks one.
  SELECT t.id INTO v_term
  FROM org.term t
  WHERE t.tenant_id = v_tenant
    AND coalesce((p->>'occurred_on')::date, current_date) BETWEEN t.starts_on AND t.ends_on
  ORDER BY t.seq LIMIT 1;

  INSERT INTO gradebook.assessment
    (tenant_id, teaching_group_id, term_id, title, kind, occurred_on,
     topic_tag_id, max_total, weight, blueprint_id, created_by)
  VALUES
    (v_tenant,
     (p->>'teaching_group_id')::uuid,
     coalesce((p->>'term_id')::uuid, v_term),
     coalesce(p->>'title', 'Untitled'),
     coalesce(p->>'kind', 'summative'),
     coalesce((p->>'occurred_on')::date, current_date),
     (p->>'topic_tag_id')::uuid,
     (p->>'max_total')::numeric,
     coalesce((p->>'weight')::numeric, 1),
     (p->>'blueprint_id')::uuid,
     app.current_user_id())
  RETURNING id INTO v_id;

  IF p ? 'items' AND jsonb_array_length(p->'items') > 0 THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p->'items') LOOP
      v_seq := v_seq + 1;
      INSERT INTO gradebook.item
        (tenant_id, assessment_id, seq, label, max_value, scale_id, measure_id,
         topic_tag_id, skill_tag_id, source, external_ref, is_anchor)
      VALUES
        (v_tenant, v_id, coalesce((v_item->>'seq')::smallint, v_seq),
         coalesce(v_item->>'label', 'Q' || v_seq),
         (v_item->>'max_value')::numeric,
         (v_item->>'scale_id')::uuid,
         (v_item->>'measure_id')::uuid,
         (v_item->>'topic_tag_id')::uuid,
         (v_item->>'skill_tag_id')::uuid,
         coalesce(v_item->>'source', 'teacher'),
         v_item->>'external_ref',
         coalesce((v_item->>'is_anchor')::boolean, false));
    END LOOP;
  ELSE
    -- The lazy path, which must always work: one total, no structure.
    INSERT INTO gradebook.item (tenant_id, assessment_id, seq, label, max_value, topic_tag_id)
    VALUES (v_tenant, v_id, 0, 'Total', (p->>'max_total')::numeric, (p->>'topic_tag_id')::uuid);
  END IF;

  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- Clone a blueprint into a live assessment. The cheapest tagging is tagging you
-- did once last year and never repeat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gradebook.assessment_from_blueprint(
  p_blueprint_id uuid, p_group_id uuid, p_title text DEFAULT NULL, p_date date DEFAULT current_date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid := app.require_tenant(); v_id uuid; v_name text;
BEGIN
  SELECT name INTO v_name FROM curric.blueprint WHERE id = p_blueprint_id AND tenant_id = v_tenant;
  IF v_name IS NULL THEN RAISE EXCEPTION 'blueprint % not found', p_blueprint_id; END IF;

  v_id := gradebook.create_assessment(jsonb_build_object(
    'teaching_group_id', p_group_id,
    'title', coalesce(p_title, v_name),
    'occurred_on', p_date,
    'blueprint_id', p_blueprint_id));

  DELETE FROM gradebook.item WHERE assessment_id = v_id;   -- drop the synthetic total

  INSERT INTO gradebook.item
    (tenant_id, assessment_id, seq, label, max_value, measure_id, topic_tag_id, skill_tag_id)
  SELECT v_tenant, v_id, bi.seq, bi.label, bi.max_value, bi.measure_id, bi.topic_tag_id, bi.skill_tag_id
  FROM curric.blueprint_item bi
  WHERE bi.blueprint_id = p_blueprint_id AND bi.tenant_id = v_tenant;

  UPDATE curric.blueprint SET times_used = times_used + 1 WHERE id = p_blueprint_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- THE BATCH WRITE. A whole class in one statement.
--
-- Idempotent on client_mutation_id so a phone that loses signal mid-save and
-- retries does not double-write. The dedupe key is the one the CLIENT generated
-- — never one the server recomputes from the payload, because a replay that
-- recomputes a different key inserts duplicates that no constraint catches.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gradebook.record_marks(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid := app.require_tenant();
  v_cmid text := p->>'client_mutation_id';
  v_prior jsonb;
  v_written integer;
BEGIN
  IF v_cmid IS NOT NULL THEN
    SELECT result_summary INTO v_prior
    FROM gradebook.idempotency WHERE tenant_id = v_tenant AND client_mutation_id = v_cmid;
    IF v_prior IS NOT NULL THEN
      RETURN v_prior || jsonb_build_object('replayed', true);
    END IF;
  END IF;

  WITH incoming AS (
    SELECT
      (m->>'item_id')::uuid                        AS item_id,
      (m->>'student_id')::uuid                     AS student_id,
      coalesce(m->>'marker_role', 'primary')       AS marker_role,
      (m->>'raw_value')::numeric                   AS raw_value,
      m->>'value_code'                             AS value_code,
      coalesce(m->>'status', 'scored')             AS status,
      coalesce((m->>'is_defaulted')::boolean, false)  AS is_defaulted,
      coalesce((m->>'submitted_late')::boolean, false) AS submitted_late,
      m->>'comment'                                AS comment
    FROM jsonb_array_elements(p->'marks') m
  ), resolved AS (
    SELECT i.*,
           coalesce(it.max_value, a.max_total)      AS max_value,
           coalesce(it.scale_id,
                    (SELECT me.scale_id FROM ref.measure me WHERE me.id = it.measure_id)) AS scale_id,
           a.occurred_on
    FROM incoming i
    JOIN gradebook.item it ON it.id = i.item_id AND it.tenant_id = v_tenant
    JOIN gradebook.assessment a ON a.id = it.assessment_id
  )
  INSERT INTO gradebook.result
    (tenant_id, item_id, student_id, marker_role, raw_value, value_code, max_value,
     scale_id, status, is_defaulted, submitted_late, comment, observed_on, marked_by,
     source)
  SELECT v_tenant, r.item_id, r.student_id, r.marker_role, r.raw_value, r.value_code,
         r.max_value, r.scale_id, r.status, r.is_defaulted, r.submitted_late, r.comment,
         r.occurred_on, app.current_user_id(), coalesce(p->>'source', 'manual')
  FROM resolved r
  ON CONFLICT (item_id, student_id, marker_role) DO UPDATE SET
    raw_value      = EXCLUDED.raw_value,
    value_code     = EXCLUDED.value_code,
    max_value      = EXCLUDED.max_value,
    scale_id       = EXCLUDED.scale_id,
    status         = EXCLUDED.status,
    is_defaulted   = EXCLUDED.is_defaulted,
    submitted_late = EXCLUDED.submitted_late,
    comment        = EXCLUDED.comment,
    marked_by      = EXCLUDED.marked_by,
    updated_at     = now();

  GET DIAGNOSTICS v_written = ROW_COUNT;

  IF v_cmid IS NOT NULL THEN
    INSERT INTO gradebook.idempotency (tenant_id, client_mutation_id, result_summary)
    VALUES (v_tenant, v_cmid, jsonb_build_object('written', v_written))
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN jsonb_build_object('written', v_written, 'replayed', false);
END $$;

-- ---------------------------------------------------------------------------
-- "Everyone got it, tap the exceptions." The fastest formative capture there
-- is. Everything it writes is flagged is_defaulted so the analytics layer can
-- weight it as the weak evidence it is.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gradebook.record_default_then_exceptions(
  p_item_id uuid, p_default_value numeric, p_exceptions jsonb DEFAULT '[]'::jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid := app.require_tenant(); v_n integer; v_group uuid; v_on date;
BEGIN
  SELECT a.teaching_group_id, a.occurred_on INTO v_group, v_on
  FROM gradebook.item it JOIN gradebook.assessment a ON a.id = it.assessment_id
  WHERE it.id = p_item_id AND it.tenant_id = v_tenant;

  INSERT INTO gradebook.result
    (tenant_id, item_id, student_id, raw_value, max_value, scale_id, is_defaulted,
     observed_on, marked_by, source)
  SELECT v_tenant, p_item_id, e.student_id, p_default_value,
         it.max_value, it.scale_id, true, v_on, app.current_user_id(), 'manual'
  FROM org.enrolment e
  JOIN gradebook.item it ON it.id = p_item_id
  WHERE e.tenant_id = v_tenant AND e.teaching_group_id = v_group AND e.to_date IS NULL
  ON CONFLICT (item_id, student_id, marker_role) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF jsonb_array_length(p_exceptions) > 0 THEN
    PERFORM gradebook.record_marks(jsonb_build_object('marks',
      (SELECT jsonb_agg(x || jsonb_build_object('item_id', p_item_id))
       FROM jsonb_array_elements(p_exceptions) x)));
  END IF;
  RETURN v_n;
END $$;

-- ============================================================================
-- TEACHER AFFORDANCES — what the product gives BACK, so it reads as help
-- ============================================================================

-- ---------------------------------------------------------------------------
-- "What do I still owe." The single most-used screen in every gradebook that
-- teachers keep using. Absence of a result row is ambiguous — it means both
-- "not marked yet" and "nothing to mark" — so it has to be computed against
-- the enrolment, not guessed from row counts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW teach.v_marking_todo AS
SELECT
  a.tenant_id,
  a.id                       AS assessment_id,
  a.title,
  a.occurred_on,
  tg.id                      AS teaching_group_id,
  tg.label                   AS group_label,
  s.name                     AS subject_name,
  count(DISTINCT e.student_id)                                        AS students_expected,
  count(DISTINCT r.student_id) FILTER (WHERE r.status IS NOT NULL)     AS students_marked,
  count(DISTINCT e.student_id) - count(DISTINCT r.student_id)
    FILTER (WHERE r.status IS NOT NULL)                                AS students_outstanding,
  (current_date - a.occurred_on)                                       AS days_since,
  a.marking_closed_at IS NOT NULL                                      AS closed
FROM gradebook.assessment a
JOIN org.teaching_group tg ON tg.id = a.teaching_group_id
JOIN org.subject s ON s.id = tg.subject_id
JOIN org.enrolment e ON e.teaching_group_id = tg.id AND e.to_date IS NULL
LEFT JOIN gradebook.item it ON it.assessment_id = a.id
LEFT JOIN gradebook.result r ON r.item_id = it.id AND r.student_id = e.student_id
WHERE a.deleted_at IS NULL
GROUP BY a.tenant_id, a.id, a.title, a.occurred_on, tg.id, tg.label, s.name, a.marking_closed_at;

-- ---------------------------------------------------------------------------
-- Comment bank. Report writing, not mark entry, is the largest recurring time
-- sink for a teacher. This is the feature that buys tolerance for everything
-- else in the product.
-- ---------------------------------------------------------------------------
CREATE TABLE teach.comment_bank (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  owner_id     uuid REFERENCES platform.app_user(id) ON DELETE CASCADE,  -- NULL = shared
  subject_id   uuid REFERENCES org.subject(id) ON DELETE CASCADE,
  measure_id   uuid REFERENCES ref.measure(id) ON DELETE SET NULL,
  tag_id       uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  band         text,                     -- 'excellent','secure','developing','concern'
  locale       text NOT NULL DEFAULT 'en',
  -- Placeholders the merge fills: {first_name} {they} {their} {them} {grade} {topic}
  body         text NOT NULL,
  times_used   integer NOT NULL DEFAULT 0,
  is_shared    boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX comment_bank_lookup_ix ON teach.comment_bank (tenant_id, subject_id, band);

-- Pronoun-safe merge. Students whose pronouns the school has not recorded get
-- they/them rather than a guess from the name.
CREATE TABLE teach.student_pronoun (
  tenant_id  uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  student_id uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  subject    text NOT NULL DEFAULT 'they',   -- they / she / he / ...
  object     text NOT NULL DEFAULT 'them',
  possessive text NOT NULL DEFAULT 'their',
  PRIMARY KEY (tenant_id, student_id)
);

CREATE OR REPLACE FUNCTION teach.merge_comment(p_body text, p_student_id uuid, p_vars jsonb DEFAULT '{}'::jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v_out text := p_body; v_p teach.student_pronoun%ROWTYPE; v_name text; k text;
BEGIN
  SELECT coalesce(preferred_name, given_name) INTO v_name FROM org.person WHERE id = p_student_id;
  SELECT * INTO v_p FROM teach.student_pronoun WHERE student_id = p_student_id;
  v_out := replace(v_out, '{first_name}', coalesce(v_name, 'the student'));
  v_out := replace(v_out, '{they}',  coalesce(v_p.subject, 'they'));
  v_out := replace(v_out, '{them}',  coalesce(v_p.object, 'them'));
  v_out := replace(v_out, '{their}', coalesce(v_p.possessive, 'their'));
  FOR k IN SELECT jsonb_object_keys(p_vars) LOOP
    v_out := replace(v_out, '{' || k || '}', p_vars->>k);
  END LOOP;
  RETURN v_out;
END $$;

CREATE TABLE teach.report_comment (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  student_id  uuid NOT NULL REFERENCES org.person(id) ON DELETE CASCADE,
  teaching_group_id uuid REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  term_id     uuid REFERENCES org.term(id) ON DELETE SET NULL,
  body        text NOT NULL,
  drafted_from uuid REFERENCES teach.comment_bank(id) ON DELETE SET NULL,
  is_final    boolean NOT NULL DEFAULT false,
  author_id   uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, student_id, teaching_group_id, term_id)
);
