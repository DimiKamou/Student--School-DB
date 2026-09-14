-- ============================================================================
-- 008_alerts.sql — alerts that measure themselves, and interventions that close
--
-- A noisy classifier destroys adoption faster than any keystroke cost. So every
-- alert here is budgeted, rate-limited, and — critically — ADJUDICATED: the
-- teacher marks it useful or not, and the system reports its own precision.
-- An early-warning product that cannot state its false-positive rate is a
-- horoscope with a database behind it.
--
-- The school's question at renewal is not "did you flag them early" but "did
-- anything get better". intervention + intervention_outcome are how that gets
-- answered.
-- ============================================================================

CREATE TABLE analytics.alert (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN
                      ('individual_topic_gap','systemic_topic_gap','trajectory_decline',
                       'period_effect','prediction_miss','coverage_low','under_taught_topic')),
  student_id        uuid REFERENCES org.person(id) ON DELETE CASCADE,   -- NULL for cohort alerts
  teaching_group_id uuid REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  tag_id            uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  term_id           uuid REFERENCES org.term(id) ON DELETE SET NULL,

  -- Who this is FOR. A systemic flag about a class belongs to its teacher first.
  owner_user_id     uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  visibility_scope  text NOT NULL DEFAULT 'teacher'
                      CHECK (visibility_scope IN ('teacher','department','leadership')),
  -- Right of first sight. Leadership sees it only after the teacher has had a
  -- chance to look. Without this the product reads as surveillance and teachers
  -- quietly stop entering the data it runs on.
  visible_to_leadership_after timestamptz,

  effect_size       numeric(10,5),
  p_value           numeric(10,8),
  evidence_count    integer,
  headline          text NOT NULL,
  detail            jsonb NOT NULL DEFAULT '{}'::jsonb,

  rule_version      text NOT NULL DEFAULT 'v1',
  raised_at         timestamptz NOT NULL DEFAULT now(),
  -- Snapshot of the evidence available when raised, so precision can be scored
  -- prospectively rather than with hindsight.
  evidence_as_of    timestamptz NOT NULL DEFAULT now(),

  acknowledged_at   timestamptz,
  acknowledged_by   uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  -- The adjudication that makes precision measurable.
  feedback          text CHECK (feedback IN ('useful','not_useful','already_knew','wrong')),
  feedback_note     text,
  suppressed_until  date
);
CREATE INDEX alert_owner_ix ON analytics.alert (tenant_id, owner_user_id, raised_at DESC);
CREATE INDEX alert_student_ix ON analytics.alert (tenant_id, student_id, raised_at DESC);
-- Refractory support: the same finding must not be re-raised every night.
CREATE INDEX alert_refractory_ix ON analytics.alert
  (tenant_id, kind, student_id, teaching_group_id, tag_id, raised_at DESC);

-- ---------------------------------------------------------------------------
-- Raise alerts under a budget. Ranking by effect size within each owner means a
-- teacher gets their five most important findings, not the five that happened
-- to sort first.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.fire_alerts(p_tenant uuid, p_refractory_days integer DEFAULT 21)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_budget integer; v_delay integer; v_n integer;
BEGIN
  SELECT alert_budget_weekly, leadership_delay_days INTO v_budget, v_delay
  FROM platform.tenant WHERE id = p_tenant;

  WITH candidate AS (
    SELECT
      g.tenant_id, g.student_id, g.teaching_group_id, g.tag_id,
      CASE WHEN g.verdict = 'systemic' THEN 'systemic_topic_gap'
           ELSE 'individual_topic_gap' END                    AS kind,
      abs(g.mean_residual)                                    AS effect_size,
      g.n_responses                                           AS evidence_count,
      (SELECT ta.staff_id FROM org.teaching_assignment ta
        WHERE ta.teaching_group_id = g.teaching_group_id AND ta.to_date IS NULL
        ORDER BY (ta.role = 'primary') DESC LIMIT 1)          AS staff_id,
      t.label                                                 AS tag_label,
      p.given_name || ' ' || p.family_name                    AS student_name
    FROM analytics.mv_gap_signal g
    JOIN curric.tag t ON t.id = g.tag_id
    JOIN org.person p ON p.id = g.student_id
    WHERE g.tenant_id = p_tenant
      AND g.verdict IN ('individual','systemic_and_individual','systemic')
      -- Effect gate BEFORE ranking: statistical significance on a trivial
      -- effect is not a finding worth a teacher's attention.
      AND abs(g.mean_residual) >= 0.08
      AND g.n_responses >= 5
  ), fresh AS (
    SELECT c.* FROM candidate c
    WHERE NOT EXISTS (
      SELECT 1 FROM analytics.alert a
      WHERE a.tenant_id = c.tenant_id AND a.kind = c.kind
        AND a.student_id IS NOT DISTINCT FROM c.student_id
        AND a.teaching_group_id = c.teaching_group_id
        AND a.tag_id IS NOT DISTINCT FROM c.tag_id
        AND a.raised_at > now() - make_interval(days => p_refractory_days))
  ), ranked AS (
    SELECT f.*, row_number() OVER (PARTITION BY f.staff_id ORDER BY f.effect_size DESC) AS rk
    FROM fresh f
  )
  INSERT INTO analytics.alert
    (tenant_id, kind, student_id, teaching_group_id, tag_id, owner_user_id,
     visibility_scope, visible_to_leadership_after, effect_size, evidence_count, headline)
  SELECT
    r.tenant_id, r.kind, r.student_id, r.teaching_group_id, r.tag_id,
    (SELECT user_id FROM org.person WHERE id = r.staff_id),
    'teacher',
    now() + make_interval(days => coalesce(v_delay, 7)),
    r.effect_size, r.evidence_count,
    CASE WHEN r.kind = 'systemic_topic_gap'
         THEN 'Cohort is underperforming on ' || r.tag_label
         ELSE r.student_name || ' is behind their own baseline on ' || r.tag_label END
  FROM ranked r
  WHERE r.rk <= coalesce(v_budget, 5);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- The product's own honesty metric, and a genuine thesis result.
CREATE OR REPLACE VIEW analytics.v_alert_precision AS
SELECT
  tenant_id, kind, rule_version,
  count(*)                                                   AS raised,
  count(*) FILTER (WHERE feedback IS NOT NULL)               AS adjudicated,
  count(*) FILTER (WHERE feedback = 'useful')                AS useful,
  round(count(*) FILTER (WHERE feedback = 'useful')::numeric
        / nullif(count(*) FILTER (WHERE feedback IS NOT NULL), 0), 3) AS precision,
  round(avg(EXTRACT(epoch FROM acknowledged_at - raised_at) / 3600.0)::numeric, 1)
                                                             AS mean_hours_to_ack
FROM analytics.alert
GROUP BY tenant_id, kind, rule_version;

-- ---------------------------------------------------------------------------
-- INTERVENTIONS — the closed loop.
-- ---------------------------------------------------------------------------
CREATE TABLE analytics.intervention (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id) ON DELETE CASCADE,
  student_id        uuid REFERENCES org.person(id) ON DELETE CASCADE,
  teaching_group_id uuid REFERENCES org.teaching_group(id) ON DELETE CASCADE,
  tag_id            uuid REFERENCES curric.tag(id) ON DELETE SET NULL,
  raised_by_alert_id uuid REFERENCES analytics.alert(id) ON DELETE SET NULL,
  kind              text NOT NULL CHECK (kind IN
                      ('reteach','small_group','one_to_one','differentiated_task',
                       'parent_contact','timetable_change','curriculum_change','other')),
  description       text,
  started_on        date NOT NULL DEFAULT current_date,
  ended_on          date,
  created_by        uuid REFERENCES platform.app_user(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX intervention_student_ix ON analytics.intervention (tenant_id, student_id, started_on);

-- Did it work? Residual on the targeted tag before vs after. Not a randomised
-- trial and never presented as one — but it is the difference between a product
-- that reports problems and one that can show a school what changed.
CREATE OR REPLACE VIEW analytics.v_intervention_effect AS
SELECT
  i.id AS intervention_id,
  i.tenant_id, i.student_id, i.teaching_group_id, i.tag_id, i.kind,
  i.started_on,
  count(*) FILTER (WHERE r.observed_on <  i.started_on) AS n_before,
  count(*) FILTER (WHERE r.observed_on >= i.started_on) AS n_after,
  avg(r.residual) FILTER (WHERE r.observed_on <  i.started_on) AS mean_residual_before,
  avg(r.residual) FILTER (WHERE r.observed_on >= i.started_on) AS mean_residual_after,
  avg(r.residual) FILTER (WHERE r.observed_on >= i.started_on)
    - avg(r.residual) FILTER (WHERE r.observed_on < i.started_on) AS delta,
  CASE
    WHEN count(*) FILTER (WHERE r.observed_on >= i.started_on) < 3 THEN 'too_early_to_tell'
    WHEN count(*) FILTER (WHERE r.observed_on <  i.started_on) < 3 THEN 'no_baseline'
    ELSE 'measurable'
  END AS status
FROM analytics.intervention i
JOIN analytics.v_residual r
  ON r.tenant_id = i.tenant_id AND r.student_id = i.student_id
LEFT JOIN analytics.mv_response_tag rt
  ON rt.tenant_id = r.tenant_id AND rt.result_id = r.result_id AND rt.tag_id = i.tag_id
WHERE i.tag_id IS NULL OR rt.tag_id IS NOT NULL
GROUP BY i.id, i.tenant_id, i.student_id, i.teaching_group_id, i.tag_id, i.kind, i.started_on;

-- ---------------------------------------------------------------------------
-- DELIBERATELY ABSENT: any view that groups outcomes BY TEACHER.
--
-- Not an oversight. The data would support it and the schema could express it,
-- and the moment a school can rank its staff on this database, teachers stop
-- entering honest formative marks and the whole instrument dies. Systemic
-- findings are scoped to a teaching group and owned by its teacher first.
-- If a customer asks for teacher league tables, the answer is no.
-- ---------------------------------------------------------------------------
