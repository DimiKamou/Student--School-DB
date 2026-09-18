import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import type postgres from 'postgres'
import { withTenant } from '../db.js'
import { HttpError, requireSession } from '../auth.js'

/**
 * The student and guardian portal.
 *
 * This is the surface where this product could do actual harm, so it is the
 * most conservative file in the API. Three rules shaped every query below.
 *
 * 1. THE SUBJECT IS RESOLVED FROM THE SESSION, NEVER FROM THE REQUEST.
 *    A client-supplied student_id is only ever used to PICK from the set this
 *    user already provably owns (themselves, via org.person.user_id, or their
 *    children, via org.guardian_link). It is never trusted as an identity.
 *    withTenant() means RLS and app.can_see_student() back this up, but the
 *    explicit check is deliberate duplication: this is children's data, and a
 *    single policy between a stranger and a 14-year-old's record is not enough.
 *
 * 2. ALERTS ARE NOT READ HERE, AT ALL.
 *    009_rls.sql blocks students and guardians from analytics.alert by policy,
 *    on purpose: an "at risk" label reflected back at a child is a
 *    self-fulfilling prophecy the product should not manufacture. This file
 *    does not query that table, does not join it, and does not work around it.
 *
 * 3. THE WIRE FORMAT CARRIES NO PROFESSIONAL VERDICT.
 *    Residuals, z-scores, confidence intervals, cohort means, rank and the
 *    verdict vocabulary ('individual', 'systemic', ...) stay on the server.
 *    What crosses the wire is a category the screen can phrase as an action.
 *    A field that never leaves the API cannot be leaked by a future UI change.
 */

const uuid = z.string().uuid()

/** What the portal is willing to say about a topic. Deliberately not a verdict. */
type Focus = 'going_well' | 'work_on' | 'class_and_you' | 'class_working_on' | 'catch_up'

/**
 * The mapping from the analytics verdict to what a child is shown.
 *
 * 'insufficient_evidence' and 'assessment_artefact' map to nothing: the first
 * is the schema saying it does not know, and the second is a finding about the
 * question paper. Neither is something to hand a student as feedback.
 *
 * 'systemic_and_individual' gets its own category rather than being folded into
 * either neighbour. Folding it into 'work_on' would hand a child the blame for
 * a class-wide problem; folding it into 'class_working_on' would tell them
 * there is nothing of their own to do when the data says there is. Both are
 * dishonest, in opposite directions.
 */
const FOCUS_OF: Record<string, Focus | undefined> = {
  ok: 'going_well',
  individual: 'work_on',
  systemic_and_individual: 'class_and_you',
  systemic: 'class_working_on',
  explained_by_absence: 'catch_up',
  insufficient_evidence: undefined,
  assessment_artefact: undefined,
}

export type PortalChild = {
  student_id: string
  display_name: string
  relation: string
  is_self: boolean
}

type GapRow = {
  subject_name: string
  group_label: string
  tag_id: string
  tag_label: string
  verdict: string
  mean_pct: string | null
  n_responses: string
}

type OutcomeRow = {
  id: string
  measure_id: string | null
  teaching_group_id: string | null
  subject_name: string | null
  group_label: string | null
  measure_label: string | null
  term_label: string | null
  scale_name: string | null
  value_code: string | null
  raw_value: string | null
  pct: string | null
  observed_on: string
  determination_method: string | null
  confidence: string | null
}

/**
 * Every student this signed-in user is allowed to be shown, resolved entirely
 * from the database.
 *
 * Note what is NOT here: a school_admin gets an empty list. The portal is the
 * child's own view of their own record, not a second route into everybody's.
 * Staff have their own screens, with their own audit trail.
 */
async function viewableStudents(tx: postgres.TransactionSql): Promise<PortalChild[]> {
  return tx<PortalChild[]>`
    SELECT p.id AS student_id,
           coalesce(p.preferred_name, p.given_name) || ' ' || p.family_name AS display_name,
           'self'::text AS relation,
           true AS is_self
    FROM org.person p
    WHERE p.tenant_id = app.current_tenant()
      AND p.user_id = app.current_user_id()
      AND p.is_student AND p.deleted_at IS NULL
    UNION ALL
    SELECT p.id,
           coalesce(p.preferred_name, p.given_name) || ' ' || p.family_name,
           coalesce(gl.relation, 'child'),
           false
    FROM org.guardian_link gl
    JOIN org.person g ON g.id = gl.guardian_id
    JOIN org.person p ON p.id = gl.student_id
    WHERE gl.tenant_id = app.current_tenant()
      AND g.user_id = app.current_user_id()
      AND g.deleted_at IS NULL
      AND p.is_student AND p.deleted_at IS NULL
    ORDER BY 4 DESC, 2`
}

/**
 * Pick the student to show.
 *
 * A requested id that is not in the owned set is 403, not 404: answering
 * "no such student" for some ids and "not yours" for others turns this
 * endpoint into an oracle for which children a school has on roll.
 */
async function resolveSubject(tx: postgres.TransactionSql, requested?: string) {
  const children = await viewableStudents(tx)
  if (children.length === 0) {
    throw new HttpError(403, 'This area is for students and their guardians.')
  }
  if (requested) {
    const match = children.find((c) => c.student_id === requested)
    if (!match) throw new HttpError(403, 'This area is for students and their guardians.')
    return { subject: match, children }
  }
  return { subject: children[0]!, children }
}

export async function registerPortalRoutes(app: FastifyInstance) {
  /** Who this user may look at. A guardian with one child still gets a list. */
  app.get('/portal/children', async (req) => {
    const s = requireSession(req)
    return withTenant(s, async (tx) => ({ children: await viewableStudents(tx) }))
  })

  /**
   * Everything the portal screen renders, in one round trip.
   *
   * Reads the analytics matviews ONLY through the SECURITY DEFINER functions in
   * 011_serving_api.sql, which re-apply app.can_see_student(). The matviews
   * themselves are not granted to this role and are not touched here.
   */
  app.get('/portal/progress', async (req) => {
    const s = requireSession(req)
    const { student_id } = z.object({ student_id: uuid.optional() }).parse(req.query)

    return withTenant(s, async (tx) => {
      const { subject, children } = await resolveSubject(tx, student_id)
      const id = subject.student_id

      const [enrolments, timeline, gaps, pooling, targets, current] = await Promise.all([
        tx<{ teaching_group_id: string; group_label: string; subject_name: string
             year_level: string | null }[]>`
          SELECT tg.id AS teaching_group_id, tg.label AS group_label,
                 sub.name AS subject_name, tg.year_level
          FROM org.enrolment e
          JOIN org.teaching_group tg ON tg.id = e.teaching_group_id
          JOIN org.academic_year ay ON ay.id = tg.academic_year_id AND ay.is_current
          JOIN org.subject sub ON sub.id = tg.subject_id
          WHERE e.student_id = ${id} AND e.to_date IS NULL
          ORDER BY sub.name, tg.label`,

        // Own marks over time. mean_adj — the cohort-relative figure — is
        // deliberately not selected: it is a comparison against classmates
        // wearing a decimal point.
        tx<{ observed_on: string; subject_name: string; group_label: string
             assessment_title: string; mean_pct: string; n_responses: string }[]>`
          SELECT observed_on, subject_name, group_label, assessment_title,
                 mean_pct, n_responses
          FROM analytics.student_timeline(${id}::uuid)
          WHERE mean_pct IS NOT NULL
          ORDER BY observed_on`,

        // Topic picture. mean_residual, residual_ci_upper and cohort_mean_pct
        // are not selected for the same reason.
        tx<GapRow[]>`
          SELECT subject_name, group_label, tag_id, tag_label, verdict,
                 mean_pct, n_responses
          FROM analytics.student_gaps(${id}::uuid, 'topic')`,

        tx<{ pooling_verdict: string; n_frameworks: string }[]>`
          SELECT pooling_verdict, n_frameworks
          FROM analytics.v_pooling_check WHERE student_id = ${id}`,

        // A Panhellenic or DP student may have a target on file.
        tx<OutcomeRow[]>`
          SELECT o.id, o.measure_id, o.teaching_group_id,
                 sub.name AS subject_name, tg.label AS group_label,
                 m.label AS measure_label, tm.label AS term_label,
                 sc.name AS scale_name,
                 o.value_code, o.raw_value, o.pct, o.observed_on,
                 o.determination_method, o.confidence
          FROM gradebook.outcome o
          LEFT JOIN ref.measure m ON m.id = o.measure_id
          LEFT JOIN org.teaching_group tg ON tg.id = o.teaching_group_id
          LEFT JOIN org.subject sub ON sub.id = tg.subject_id
          LEFT JOIN org.term tm ON tm.id = o.term_id
          LEFT JOIN ref.scale sc ON sc.id = o.scale_id
          WHERE o.student_id = ${id} AND o.kind = 'target'
          ORDER BY o.observed_on DESC`,

        // Where they actually are, for each measure a target might name. Only
        // grades a human has stood behind or an authority has issued — never a
        // model prediction dressed up as a position.
        tx<OutcomeRow[]>`
          SELECT DISTINCT ON (o.measure_id, o.teaching_group_id)
                 o.id, o.measure_id, o.teaching_group_id,
                 sub.name AS subject_name, tg.label AS group_label,
                 m.label AS measure_label, tm.label AS term_label,
                 sc.name AS scale_name,
                 o.value_code, o.raw_value, o.pct, o.observed_on,
                 o.determination_method, o.confidence
          FROM gradebook.outcome o
          LEFT JOIN ref.measure m ON m.id = o.measure_id
          LEFT JOIN org.teaching_group tg ON tg.id = o.teaching_group_id
          LEFT JOIN org.subject sub ON sub.id = tg.subject_id
          LEFT JOIN org.term tm ON tm.id = o.term_id
          LEFT JOIN ref.scale sc ON sc.id = o.scale_id
          WHERE o.student_id = ${id}
            AND o.kind IN ('reported', 'teacher_determined', 'awarded_official')
          ORDER BY o.measure_id, o.teaching_group_id, o.observed_on DESC`,
      ])

      // ---------------------------------------------------------------------
      // Topics, reduced to something that can be phrased as an action.
      // ---------------------------------------------------------------------
      const topics = gaps.flatMap((g) => {
        const focus = FOCUS_OF[g.verdict]
        if (!focus) return []
        // A "going well" row is only worth saying when the work is actually
        // strong. 'ok' on 52% means "no gap detected", not "well done".
        if (focus === 'going_well' && (g.mean_pct == null || Number(g.mean_pct) < 0.7)) return []
        return [{
          tag_id: g.tag_id,
          tag_label: g.tag_label,
          subject_name: g.subject_name,
          group_label: g.group_label,
          focus,
          // Their own average on their own work. Not a comparison.
          own_mean_pct: g.mean_pct,
          evidence: g.n_responses,
        }]
      })

      // ---------------------------------------------------------------------
      // Targets. A target with nothing to measure it against says so, rather
      // than borrowing a number from somewhere it does not belong.
      // ---------------------------------------------------------------------
      const key = (o: OutcomeRow) => `${o.measure_id ?? ''}|${o.teaching_group_id ?? ''}`
      const byKey = new Map(current.map((o) => [key(o), o]))
      const targetCards = targets.map((t) => {
        const now = byKey.get(key(t)) ?? null
        // The schema is allowed to say "not enough to judge". When it does, the
        // screen repeats that instead of rendering the number anyway.
        const usable = now != null
          && now.determination_method !== 'insufficient_evidence'
          && now.confidence !== 'insufficient'
        return {
          id: t.id,
          subject_name: t.subject_name,
          group_label: t.group_label,
          measure_label: t.measure_label,
          term_label: t.term_label,
          scale_name: t.scale_name,
          target_label: t.value_code ?? t.raw_value,
          target_pct: t.pct,
          current_label: usable ? (now!.value_code ?? now!.raw_value) : null,
          current_pct: usable ? now!.pct : null,
          current_on: usable ? now!.observed_on : null,
          // Why the current figure is missing, so the UI can say which it is.
          current_status: now == null ? 'nothing_recorded'
            : usable ? 'recorded' : 'insufficient_evidence',
        }
      })

      // A guardian reading a child's record is exactly the access a school gets
      // asked about later. Log it; a student reading their own is not an event.
      if (!subject.is_self) {
        await tx`
          INSERT INTO platform.access_log (tenant_id, user_id, action, subject_kind, subject_id)
          VALUES (app.current_tenant(), app.current_user_id(),
                  'portal.view', 'student', ${id})`
      }

      return {
        subject,
        children,
        enrolments,
        timeline,
        topics,
        targets: targetCards,
        // Two frameworks with unequated scales must not be drawn as one line.
        pooling: pooling[0] ?? null,
      }
    })
  })
}
