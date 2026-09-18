import type { FastifyInstance } from 'fastify'
import type postgres from 'postgres'
import { z } from 'zod'
import { withTenant } from '../db.js'
import { HttpError, requireSession } from '../auth.js'

/**
 * Alerts and interventions.
 *
 * Two rules shape every query below.
 *
 * 1. analytics.alert carries its own RESTRICTIVE policy (009): students and
 *    guardians never see raw alerts, a student-scoped alert needs
 *    app.can_see_student(), and a 'leadership' alert stays invisible until
 *    visible_to_leadership_after has passed. So the alert queries can be plain
 *    SQL inside withTenant() and the database does the hard part.
 *
 * 2. analytics.intervention carries tenant isolation but NO per-student scope
 *    policy, so every read and write here re-applies app.can_see_student() by
 *    hand. Without that, a teacher could list interventions naming children in
 *    another department's cohort.
 *
 * The effect of an intervention is read through analytics.intervention_effects()
 * (013), because analytics.v_intervention_effect resolves through matviews that
 * app_rw is deliberately not granted.
 */

const uuidParam = z.object({ id: z.string().uuid() })

const listAlertsQuery = z.object({
  state: z.enum(['open', 'snoozed', 'adjudicated', 'acknowledged', 'all']).default('open'),
  mine: z.enum(['true', 'false']).default('true'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
})

const feedbackBody = z.object({
  feedback: z.enum(['useful', 'not_useful', 'already_knew', 'wrong']),
  feedback_note: z.string().max(2000).nullish(),
})

const snoozeBody = z.object({
  // null clears a snooze; 0 would be a snooze that expires today, which reads
  // as a no-op and is better expressed as null.
  days: z.number().int().min(1).max(365).nullable(),
})

const INTERVENTION_KINDS = [
  'reteach', 'small_group', 'one_to_one', 'differentiated_task',
  'parent_contact', 'timetable_change', 'curriculum_change', 'other',
] as const

const createIntervention = z.object({
  kind: z.enum(INTERVENTION_KINDS),
  student_id: z.string().uuid().nullish(),
  teaching_group_id: z.string().uuid().nullish(),
  tag_id: z.string().uuid().nullish(),
  raised_by_alert_id: z.string().uuid().nullish(),
  description: z.string().max(4000).nullish(),
  started_on: z.string().date().optional(),
  ended_on: z.string().date().nullish(),
}).refine((v) => Boolean(v.student_id || v.teaching_group_id), {
  message: 'an intervention must name a student or a class',
})

const updateIntervention = z.object({
  kind: z.enum(INTERVENTION_KINDS).optional(),
  tag_id: z.string().uuid().nullish(),
  description: z.string().max(4000).nullish(),
  started_on: z.string().date().optional(),
  ended_on: z.string().date().nullish(),
})

/** The alert columns every screen needs, with the labels resolved once. */
const ALERT_COLUMNS = `
  a.id, a.kind, a.headline, a.detail, a.rule_version,
  a.student_id, a.teaching_group_id, a.tag_id, a.term_id,
  a.effect_size, a.p_value, a.evidence_count,
  a.raised_at, a.evidence_as_of,
  a.acknowledged_at, a.feedback, a.feedback_note, a.suppressed_until,
  a.visibility_scope, a.visible_to_leadership_after,
  (a.owner_user_id = app.current_user_id()) AS is_mine,
  coalesce(p.preferred_name, p.given_name) || ' ' || p.family_name AS student_name,
  tg.label AS group_label, sub.name AS subject_name,
  t.label AS tag_label, tm.label AS term_label,
  (SELECT count(*) FROM analytics.intervention iv
    WHERE iv.raised_by_alert_id = a.id) AS n_interventions`

export async function registerAlertRoutes(app: FastifyInstance) {
  // -------------------------------------------------------------------------
  // The inbox
  // -------------------------------------------------------------------------

  /**
   * Alerts for the signed-in user.
   *
   * 'open' deliberately excludes snoozed and already-adjudicated alerts: an
   * inbox that never empties is one a teacher stops opening, and the whole
   * budget/refractory design in 008 exists to keep it finite.
   */
  app.get('/alerts', async (req) => {
    const s = requireSession(req)
    const { state, mine, limit } = listAlertsQuery.parse(req.query)
    const onlyMine = mine === 'true'
    return withTenant(s, async (tx) => tx`
      SELECT ${tx.unsafe(ALERT_COLUMNS)}
      FROM analytics.alert a
      LEFT JOIN org.person p ON p.id = a.student_id
      LEFT JOIN org.teaching_group tg ON tg.id = a.teaching_group_id
      LEFT JOIN org.subject sub ON sub.id = tg.subject_id
      LEFT JOIN curric.tag t ON t.id = a.tag_id
      LEFT JOIN org.term tm ON tm.id = a.term_id
      WHERE (NOT ${onlyMine}::boolean OR a.owner_user_id = app.current_user_id())
        AND (
          ${state}::text = 'all'
          OR (${state}::text = 'open'
              AND a.feedback IS NULL
              AND (a.suppressed_until IS NULL OR a.suppressed_until <= current_date))
          OR (${state}::text = 'snoozed' AND a.suppressed_until > current_date)
          OR (${state}::text = 'adjudicated' AND a.feedback IS NOT NULL)
          OR (${state}::text = 'acknowledged' AND a.acknowledged_at IS NOT NULL))
      ORDER BY (a.acknowledged_at IS NOT NULL), a.raised_at DESC
      LIMIT ${limit}`)
  })

  /** One alert, for the "record what you did about this" flow. */
  app.get('/alerts/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [row] = await tx`
        SELECT ${tx.unsafe(ALERT_COLUMNS)}
        FROM analytics.alert a
        LEFT JOIN org.person p ON p.id = a.student_id
        LEFT JOIN org.teaching_group tg ON tg.id = a.teaching_group_id
        LEFT JOIN org.subject sub ON sub.id = tg.subject_id
        LEFT JOIN curric.tag t ON t.id = a.tag_id
        LEFT JOIN org.term tm ON tm.id = a.term_id
        WHERE a.id = ${id}`
      if (!row) throw new HttpError(404, 'alert not found')
      return row
    })
  })

  /**
   * Acknowledge. coalesce() keeps the FIRST time it was seen: overwriting it on
   * every visit would quietly inflate mean_hours_to_ack in v_alert_precision.
   */
  app.post('/alerts/:id/acknowledge', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string; acknowledged_at: string }[]>`
        UPDATE analytics.alert
        SET acknowledged_at = coalesce(acknowledged_at, now()),
            acknowledged_by = coalesce(acknowledged_by, app.current_user_id())
        WHERE id = ${id}
          AND (owner_user_id IS NULL
               OR owner_user_id = app.current_user_id()
               OR app.is_school_wide())
        RETURNING id, acknowledged_at`
      if (!row) throw new HttpError(404, 'alert not found, or not yours to act on')
      return row
    })
  })

  /**
   * ADJUDICATE — the endpoint this whole slice exists for.
   *
   * analytics.v_alert_precision turns these four words into a measured
   * precision figure. An early-warning product that cannot state its own
   * false-positive rate is a horoscope with a database behind it.
   *
   * Adjudicating implies having seen it, so acknowledged_at is stamped here
   * too; otherwise the mean-time-to-acknowledge column is silently biased by
   * teachers who skip straight to a verdict.
   */
  app.post('/alerts/:id/feedback', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const body = feedbackBody.parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string; feedback: string }[]>`
        UPDATE analytics.alert
        SET feedback = ${body.feedback},
            feedback_note = ${body.feedback_note ?? null},
            acknowledged_at = coalesce(acknowledged_at, now()),
            acknowledged_by = coalesce(acknowledged_by, app.current_user_id())
        WHERE id = ${id}
          AND (owner_user_id IS NULL
               OR owner_user_id = app.current_user_id()
               OR app.is_school_wide())
        RETURNING id, feedback`
      if (!row) throw new HttpError(404, 'alert not found, or not yours to adjudicate')
      return row
    })
  })

  /** Snooze, or clear a snooze with days: null. */
  app.post('/alerts/:id/snooze', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const { days } = snoozeBody.parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string; suppressed_until: string | null }[]>`
        UPDATE analytics.alert
        SET suppressed_until = CASE WHEN ${days}::integer IS NULL THEN NULL
                                    ELSE current_date + ${days}::integer END
        WHERE id = ${id}
          AND (owner_user_id IS NULL
               OR owner_user_id = app.current_user_id()
               OR app.is_school_wide())
        RETURNING id, suppressed_until`
      if (!row) throw new HttpError(404, 'alert not found, or not yours to act on')
      return row
    })
  })

  /**
   * The product's own honesty metric.
   *
   * Two things come back, because one of them alone misleads:
   *   by_kind  — analytics.v_alert_precision as the schema defines it, where
   *              precision counts ONLY feedback='useful' over everything
   *              adjudicated. 'already_knew' therefore counts AGAINST it.
   *   totals   — the raw adjudication counts, so the screen can say how much
   *              of the inbox has been judged at all. A precision of 1.00 on
   *              three adjudications out of ninety alerts is not a result, and
   *              the UI cannot say so without these numbers.
   *
   * Both are read under RLS, so a teacher sees the precision of the alerts they
   * can see and leadership sees the school's.
   */
  app.get('/alerts/precision', async (req) => {
    const s = requireSession(req)
    return withTenant(s, async (tx) => {
      const [by_kind, totals] = await Promise.all([
        tx`SELECT kind, rule_version, raised, adjudicated, useful,
                  precision, mean_hours_to_ack
           FROM analytics.v_alert_precision
           ORDER BY raised DESC, kind`,
        tx`SELECT
             count(*)                                            AS raised,
             count(*) FILTER (WHERE acknowledged_at IS NOT NULL) AS acknowledged,
             count(*) FILTER (WHERE feedback IS NOT NULL)        AS adjudicated,
             count(*) FILTER (WHERE feedback = 'useful')         AS useful,
             count(*) FILTER (WHERE feedback = 'already_knew')   AS already_knew,
             count(*) FILTER (WHERE feedback = 'not_useful')     AS not_useful,
             count(*) FILTER (WHERE feedback = 'wrong')          AS wrong,
             count(*) FILTER (WHERE suppressed_until > current_date) AS snoozed
           FROM analytics.alert`,
      ])
      return { by_kind, totals: totals[0] ?? null }
    })
  })

  // -------------------------------------------------------------------------
  // Interventions — what was actually done, and whether it worked
  // -------------------------------------------------------------------------

  const INTERVENTION_COLUMNS = `
    i.id, i.kind, i.description, i.started_on, i.ended_on, i.created_at,
    i.student_id, i.teaching_group_id, i.tag_id, i.raised_by_alert_id,
    coalesce(p.preferred_name, p.given_name) || ' ' || p.family_name AS student_name,
    tg.label AS group_label, sub.name AS subject_name,
    t.label AS tag_label, al.headline AS alert_headline,
    (i.created_by = app.current_user_id()) AS is_mine,
    e.status, e.n_before, e.n_after,
    e.mean_residual_before, e.mean_residual_after, e.delta`

  const INTERVENTION_FROM = `
    FROM analytics.intervention i
    LEFT JOIN org.person p ON p.id = i.student_id
    LEFT JOIN org.teaching_group tg ON tg.id = i.teaching_group_id
    LEFT JOIN org.subject sub ON sub.id = tg.subject_id
    LEFT JOIN curric.tag t ON t.id = i.tag_id
    LEFT JOIN analytics.alert al ON al.id = i.raised_by_alert_id
    LEFT JOIN analytics.intervention_effects() e ON e.intervention_id = i.id`

  /**
   * List. The scope predicate is written here rather than relied on from RLS:
   * analytics.intervention has tenant isolation only, and an intervention row
   * names a child.
   */
  app.get('/interventions', async (req) => {
    const s = requireSession(req)
    const q = z.object({
      group_id: z.string().uuid().optional(),
      student_id: z.string().uuid().optional(),
      open: z.enum(['true', 'false']).default('false'),
      limit: z.coerce.number().int().min(1).max(200).default(100),
    }).parse(req.query)
    const openOnly = q.open === 'true'
    return withTenant(s, async (tx) => tx`
      SELECT ${tx.unsafe(INTERVENTION_COLUMNS)}
      ${tx.unsafe(INTERVENTION_FROM)}
      WHERE (i.student_id IS NULL OR app.can_see_student(i.student_id))
        AND (${q.group_id ?? null}::uuid IS NULL OR i.teaching_group_id = ${q.group_id ?? null}::uuid)
        AND (${q.student_id ?? null}::uuid IS NULL OR i.student_id = ${q.student_id ?? null}::uuid)
        AND (NOT ${openOnly}::boolean OR i.ended_on IS NULL)
      ORDER BY i.started_on DESC, i.created_at DESC
      LIMIT ${q.limit}`)
  })

  /** One intervention with its effect, for a detail pane. */
  app.get('/interventions/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [row] = await tx`
        SELECT ${tx.unsafe(INTERVENTION_COLUMNS)}
        ${tx.unsafe(INTERVENTION_FROM)}
        WHERE i.id = ${id}
          AND (i.student_id IS NULL OR app.can_see_student(i.student_id))`
      if (!row) throw new HttpError(404, 'intervention not found')
      return row
    })
  })

  app.post('/interventions', async (req) => {
    const s = requireSession(req)
    const body = createIntervention.parse(req.body)
    return withTenant(s, async (tx) => {
      await assertCanTarget(tx, body.student_id ?? null, body.teaching_group_id ?? null)
      if (body.raised_by_alert_id) {
        // RLS decides this: an alert you cannot read is an alert you cannot
        // attach work to.
        const [a] = await tx`SELECT 1 FROM analytics.alert WHERE id = ${body.raised_by_alert_id}`
        if (!a) throw new HttpError(404, 'alert not found')
      }
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO analytics.intervention
          (tenant_id, student_id, teaching_group_id, tag_id, raised_by_alert_id,
           kind, description, started_on, ended_on, created_by)
        VALUES (app.current_tenant(), ${body.student_id ?? null}, ${body.teaching_group_id ?? null},
                ${body.tag_id ?? null}, ${body.raised_by_alert_id ?? null},
                ${body.kind}, ${body.description ?? null},
                coalesce(${body.started_on ?? null}::date, current_date),
                ${body.ended_on ?? null}::date, app.current_user_id())
        RETURNING id`
      return { id: row!.id }
    })
  })

  /**
   * Edit. Only the person who recorded it, or a school admin.
   *
   * An omitted field means "leave it alone" and an explicit null means "clear
   * it". coalesce() cannot express that difference — with coalesce, closing an
   * intervention by sending only ended_on would silently wipe its topic — so
   * each nullable field is gated on whether the client actually sent it.
   */
  app.post('/interventions/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const body = updateIntervention.parse(req.body)
    const sentTag = body.tag_id !== undefined
    const sentDesc = body.description !== undefined
    const sentEnd = body.ended_on !== undefined
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string }[]>`
        UPDATE analytics.intervention SET
          kind        = coalesce(${body.kind ?? null}, kind),
          tag_id      = CASE WHEN ${sentTag}::boolean
                             THEN ${body.tag_id ?? null}::uuid ELSE tag_id END,
          description = CASE WHEN ${sentDesc}::boolean
                             THEN ${body.description ?? null}::text ELSE description END,
          started_on  = coalesce(${body.started_on ?? null}::date, started_on),
          ended_on    = CASE WHEN ${sentEnd}::boolean
                             THEN ${body.ended_on ?? null}::date ELSE ended_on END
        WHERE id = ${id}
          AND (student_id IS NULL OR app.can_see_student(student_id))
          AND (created_by = app.current_user_id() OR app.is_school_wide())
        RETURNING id`
      if (!row) throw new HttpError(404, 'intervention not found, or not yours to edit')
      return { id: row.id }
    })
  })

  app.post('/interventions/:id/delete', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string }[]>`
        DELETE FROM analytics.intervention
        WHERE id = ${id}
          AND (student_id IS NULL OR app.can_see_student(student_id))
          AND (created_by = app.current_user_id() OR app.is_school_wide())
        RETURNING id`
      if (!row) throw new HttpError(404, 'intervention not found, or not yours to delete')
      return { ok: true }
    })
  })

  /**
   * Did it work? Straight from analytics.intervention_effects(), status and
   * all. No row means the view could not score it — a class-level intervention,
   * or a student with no residual series on that tag. That is 'unmeasured',
   * never 'no effect', and the screen says so.
   */
  app.get('/interventions/:id/effect', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [own] = await tx`
        SELECT i.id, i.student_id
        FROM analytics.intervention i
        WHERE i.id = ${id} AND (i.student_id IS NULL OR app.can_see_student(i.student_id))`
      if (!own) throw new HttpError(404, 'intervention not found')
      const [effect] = await tx`
        SELECT * FROM analytics.intervention_effects() WHERE intervention_id = ${id}`
      return { intervention_id: id, effect: effect ?? null }
    })
  })
}

/**
 * Writes carry their own scope check, because analytics.intervention's RLS
 * stops at the tenant. A teacher may record work against a child they can see
 * or a class they are attached to; school-wide roles may do either.
 */
async function assertCanTarget(
  tx: postgres.TransactionSql,
  studentId: string | null,
  groupId: string | null,
): Promise<void> {
  if (studentId) {
    const [ok] = await tx<{ allowed: boolean }[]>`
      SELECT app.can_see_student(${studentId}::uuid) AS allowed`
    if (!ok?.allowed) throw new HttpError(403, 'that student is outside your scope')
  }
  if (groupId) {
    const [ok] = await tx<{ allowed: boolean }[]>`
      SELECT (app.is_school_wide() OR EXISTS (
        SELECT 1 FROM org.teaching_assignment ta
        JOIN org.person staff ON staff.id = ta.staff_id
        WHERE ta.teaching_group_id = ${groupId}::uuid AND ta.to_date IS NULL
          AND staff.user_id = app.current_user_id())) AS allowed`
    if (!ok?.allowed) throw new HttpError(403, 'that class is not one of yours')
  }
}
