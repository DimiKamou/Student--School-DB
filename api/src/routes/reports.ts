import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { withTenant } from '../db.js'
import { requireSession, HttpError } from '../auth.js'
import type postgres from 'postgres'

/**
 * Reports, comments and parents' evening.
 *
 * Report writing — not mark entry — is the largest recurring time sink for a
 * teacher, so this is the surface that buys tolerance for everything else. It
 * is also the surface where overclaiming is most tempting: a comment box next
 * to a number invites the number to be asserted. Every endpoint here therefore
 * hands the client the verdict AND the evidence count, and never silently
 * converts "we don't know" into a figure.
 *
 * Every handler runs inside withTenant(): RLS is what keeps one school's
 * children out of another school's report run, and a query issued on the bare
 * sql client would bypass it.
 */

const uuidParam = z.object({ id: z.string().uuid() })
const BANDS = ['excellent', 'secure', 'developing', 'concern'] as const

/** Placeholders teach.merge_comment() fills from the student record itself. */
const AUTO_PLACEHOLDERS = ['first_name', 'they', 'them', 'their']

/**
 * Anything still wearing braces after the merge is a hole the teacher must
 * fill. Returning it is the difference between a report that reads oddly and
 * one that ships "{grade}" to a parent.
 */
function unfilledPlaceholders(text: string): string[] {
  return [...new Set((text.match(/\{([a-z_]+)\}/g) ?? []).map((m) => m.slice(1, -1)))]
}

/**
 * A class LABEL is not student data, and org.teaching_group carries no
 * per-teacher RLS policy, so "is this my class" is enforced here — exactly as
 * analytics.class_heatmap does it in 011_serving_api.sql. Without it a teacher
 * could open the report run for a colleague's class and see an empty grid
 * (RLS would hide the children) that reads as "nobody has any data".
 */
async function requireMyGroup(tx: postgres.TransactionSql, groupId: string) {
  const [g] = await tx<{
    id: string; label: string; year_level: string | null
    subject_id: string; subject_name: string; academic_year: string
  }[]>`
    SELECT tg.id, tg.label, tg.year_level,
           sub.id AS subject_id, sub.name AS subject_name, ay.label AS academic_year
    FROM org.teaching_group tg
    JOIN org.subject sub ON sub.id = tg.subject_id
    JOIN org.academic_year ay ON ay.id = tg.academic_year_id
    WHERE tg.id = ${groupId}
      AND (app.is_school_wide() OR EXISTS (
        SELECT 1 FROM org.teaching_assignment ta
        JOIN org.person staff ON staff.id = ta.staff_id
        WHERE ta.teaching_group_id = tg.id AND ta.to_date IS NULL
          AND staff.user_id = app.current_user_id()))`
  if (!g) throw new HttpError(404, 'class not found, or not one of yours')
  return g
}

type TermRow = {
  id: string; label: string; seq: number
  starts_on: string; ends_on: string; is_reporting: boolean
}

/** Reporting terms of the current academic year, earliest first. */
async function reportingTerms(tx: postgres.TransactionSql): Promise<TermRow[]> {
  return tx<TermRow[]>`
    SELECT t.id, t.label, t.seq, t.starts_on, t.ends_on, t.is_reporting
    FROM org.term t
    JOIN org.academic_year ay ON ay.id = t.academic_year_id
    WHERE ay.is_current AND t.is_reporting
    ORDER BY t.seq`
}

/** The term a teacher is most likely writing for: the one we are in, else the last. */
function defaultTerm(terms: TermRow[]): TermRow | null {
  const today = new Date().toISOString().slice(0, 10)
  const live = terms.find((t) => String(t.starts_on).slice(0, 10) <= today
    && today <= String(t.ends_on).slice(0, 10))
  return live ?? terms[terms.length - 1] ?? null
}

const rosterSql = (tx: postgres.TransactionSql, groupId: string) => tx`
  SELECT p.id, p.given_name, p.family_name, p.preferred_name, p.external_ref,
         EXISTS (SELECT 1 FROM teach.student_pronoun sp WHERE sp.student_id = p.id)
           AS pronoun_recorded
  FROM org.enrolment e
  JOIN org.person p ON p.id = e.student_id
  WHERE e.teaching_group_id = ${groupId} AND e.to_date IS NULL AND p.deleted_at IS NULL
  ORDER BY p.family_name, p.given_name`

/**
 * Topic verdicts for every student in the class, in one round trip.
 *
 * analytics.student_gaps is SECURITY DEFINER and re-applies app.can_see_student
 * per student (011_serving_api.sql), so calling it through a LATERAL does not
 * widen scope: a student this user may not see contributes no rows.
 */
const gapsSql = (tx: postgres.TransactionSql, groupId: string) => tx`
  SELECT e.student_id, g.tag_id, g.tag_label, g.verdict, g.time_context,
         g.n_responses, g.n_assessments, g.mean_pct, g.mean_pct_recent,
         g.mean_residual, g.residual_ci_upper, g.cohort_mean_pct, g.missed_ratio
  FROM org.enrolment e
  JOIN org.person p ON p.id = e.student_id AND p.deleted_at IS NULL
  CROSS JOIN LATERAL analytics.student_gaps(e.student_id) g
  WHERE e.teaching_group_id = ${groupId} AND e.to_date IS NULL
    AND g.teaching_group_id = ${groupId}`

const trajectorySql = (tx: postgres.TransactionSql, groupId: string) => tx`
  SELECT e.student_id, t.trajectory, t.shift, t.n_recent, t.n_prior, t.model_kind
  FROM org.enrolment e
  JOIN org.person p ON p.id = e.student_id AND p.deleted_at IS NULL
  CROSS JOIN LATERAL analytics.student_trajectory(e.student_id) t
  WHERE e.teaching_group_id = ${groupId} AND e.to_date IS NULL
    AND t.teaching_group_id = ${groupId}`

export async function registerReportsRoutes(app: FastifyInstance) {
  // -------------------------------------------------------------------------
  // COMMENT BANK
  // -------------------------------------------------------------------------

  /**
   * Your comments plus anything your department shared. owner_id IS NULL means
   * a comment that belongs to the school rather than a person (006).
   *
   * teach.comment_bank carries tenant isolation but no per-owner RLS policy, so
   * "mine or shared" is enforced in the query. A colleague's unshared draft is
   * not secret data, but showing it would make the bank unusable.
   */
  app.get('/comment-bank', async (req) => {
    const s = requireSession(req)
    const q = z.object({
      subject_id: z.string().uuid().optional(),
      band: z.enum(BANDS).optional(),
      scope: z.enum(['all', 'mine', 'shared']).default('all'),
      q: z.string().max(200).optional(),
    }).parse(req.query)

    return withTenant(s, async (tx) => tx`
      SELECT cb.id, cb.owner_id, cb.subject_id, cb.band, cb.body, cb.times_used,
             cb.is_shared, cb.created_at,
             sub.name AS subject_name,
             cb.owner_id = app.current_user_id() AS is_mine,
             u.display_name AS owner_name
      FROM teach.comment_bank cb
      LEFT JOIN org.subject sub ON sub.id = cb.subject_id
      LEFT JOIN platform.app_user u ON u.id = cb.owner_id
      WHERE (cb.owner_id = app.current_user_id() OR cb.is_shared OR cb.owner_id IS NULL)
        ${q.scope === 'mine' ? tx`AND cb.owner_id = app.current_user_id()` : tx``}
        ${q.scope === 'shared' ? tx`AND (cb.is_shared OR cb.owner_id IS NULL)` : tx``}
        ${q.subject_id ? tx`AND cb.subject_id = ${q.subject_id}` : tx``}
        ${q.band ? tx`AND cb.band = ${q.band}` : tx``}
        ${q.q ? tx`AND cb.body ILIKE ${'%' + q.q + '%'}` : tx``}
      ORDER BY cb.times_used DESC, cb.created_at DESC
      LIMIT 400`)
  })

  /** Subjects this user actually teaches — the only useful filter list. */
  app.get('/comment-bank/subjects', async (req) => {
    const s = requireSession(req)
    return withTenant(s, async (tx) => tx`
      SELECT DISTINCT sub.id, sub.name, sub.code
      FROM org.teaching_group tg
      JOIN org.subject sub ON sub.id = tg.subject_id
      JOIN org.academic_year ay ON ay.id = tg.academic_year_id AND ay.is_current
      WHERE app.is_school_wide() OR EXISTS (
        SELECT 1 FROM org.teaching_assignment ta
        JOIN org.person staff ON staff.id = ta.staff_id
        WHERE ta.teaching_group_id = tg.id AND ta.to_date IS NULL
          AND staff.user_id = app.current_user_id())
      ORDER BY sub.name`)
  })

  const commentBody = z.object({
    body: z.string().min(1).max(4000),
    subject_id: z.string().uuid().nullish(),
    band: z.enum(BANDS).nullish(),
    is_shared: z.boolean().default(false),
  })

  app.post('/comment-bank', async (req) => {
    const s = requireSession(req)
    const b = commentBody.parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO teach.comment_bank
          (tenant_id, owner_id, subject_id, band, body, is_shared)
        VALUES (${s.tenantId}, ${s.userId}, ${b.subject_id ?? null},
                ${b.band ?? null}, ${b.body}, ${b.is_shared})
        RETURNING id`
      return { id: row!.id }
    })
  })

  /**
   * Edit. Only your own: a shared comment stays the author's to change.
   * The client sends the whole comment, so this is a replace rather than a
   * patch — a half-applied edit is worse than an obvious one.
   */
  app.post('/comment-bank/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const b = commentBody.parse(req.body)
    return withTenant(s, async (tx) => {
      const rows = await tx<{ id: string }[]>`
        UPDATE teach.comment_bank SET
          body       = ${b.body},
          subject_id = ${b.subject_id ?? null},
          band       = ${b.band ?? null},
          is_shared  = ${b.is_shared}
        WHERE id = ${id} AND owner_id = app.current_user_id()
        RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such comment of yours')
      return { ok: true }
    })
  })

  app.post('/comment-bank/:id/delete', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const rows = await tx<{ id: string }[]>`
        DELETE FROM teach.comment_bank
        WHERE id = ${id} AND owner_id = app.current_user_id()
        RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'no such comment of yours')
      return { ok: true }
    })
  })

  /**
   * Merge preview.
   *
   * teach.merge_comment() defaults to they/them when the school has not
   * recorded a student's pronouns. That default is a deliberate choice, not a
   * gap, so this endpoint reports whether it was used and the UI says so out
   * loud rather than letting a teacher discover it in a printed report.
   */
  const mergeInput = z.object({
    comment_id: z.string().uuid().optional(),
    body: z.string().max(4000).optional(),
    student_id: z.string().uuid(),
    vars: z.record(z.string().max(200)).default({}),
  })

  async function merge(
    tx: postgres.TransactionSql,
    input: z.infer<typeof mergeInput>,
    countUse: boolean,
  ) {
    let body = input.body
    if (input.comment_id) {
      const [c] = await tx<{ body: string }[]>`
        SELECT body FROM teach.comment_bank
        WHERE id = ${input.comment_id}
          AND (owner_id = app.current_user_id() OR is_shared OR owner_id IS NULL)`
      if (!c) throw new HttpError(404, 'no such comment')
      body = c.body
    }
    if (body === undefined) throw new HttpError(400, 'give a comment_id or a body')

    const [row] = await tx<{ merged: string; pronoun_recorded: boolean; name: string | null }[]>`
      SELECT teach.merge_comment(${body}, ${input.student_id}::uuid,
                                 ${tx.json(input.vars)}::jsonb) AS merged,
             EXISTS (SELECT 1 FROM teach.student_pronoun sp
                      WHERE sp.student_id = ${input.student_id}) AS pronoun_recorded,
             (SELECT coalesce(p.preferred_name, p.given_name) FROM org.person p
               WHERE p.id = ${input.student_id}) AS name`
    // RLS on org.person hides a student outside this user's scope; merge_comment
    // then falls back to 'the student', which would be a silent wrong answer.
    if (!row || row.name === null) throw new HttpError(404, 'student not found, or not one of yours')

    if (countUse && input.comment_id) {
      await tx`UPDATE teach.comment_bank SET times_used = times_used + 1
               WHERE id = ${input.comment_id}`
    }
    return {
      merged: row.merged,
      pronoun_recorded: row.pronoun_recorded,
      /** True when the they/them default supplied the pronouns in this text. */
      pronoun_defaulted: !row.pronoun_recorded
        && AUTO_PLACEHOLDERS.slice(1).some((p) => body!.includes(`{${p}}`)),
      unfilled: unfilledPlaceholders(row.merged),
    }
  }

  app.post('/comment-bank/preview', async (req) => {
    const s = requireSession(req)
    const input = mergeInput.parse(req.body)
    return withTenant(s, async (tx) => merge(tx, input, false))
  })

  /** Insert into a report: same merge, but this one counts towards times_used. */
  app.post('/comment-bank/:id/use', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const input = mergeInput.omit({ comment_id: true }).parse(req.body)
    return withTenant(s, async (tx) => merge(tx, { ...input, comment_id: id }, true))
  })

  // -------------------------------------------------------------------------
  // REPORT WRITING
  // -------------------------------------------------------------------------

  app.get('/reports/terms', async (req) => {
    const s = requireSession(req)
    return withTenant(s, async (tx) => {
      const terms = await reportingTerms(tx)
      return { terms, default_term_id: defaultTerm(terms)?.id ?? null }
    })
  })

  /**
   * Everything the report-writing pass needs in ONE round trip: the roster,
   * each student's topic verdicts and trajectory, and whatever has already been
   * written. Four requests here would be four chances for the screen to render
   * a comment box beside the wrong child's evidence.
   */
  app.get('/reports/groups/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const { term_id } = z.object({ term_id: z.string().uuid().optional() }).parse(req.query)

    return withTenant(s, async (tx) => {
      const group = await requireMyGroup(tx, id)
      const terms = await reportingTerms(tx)
      const term = term_id ? terms.find((t) => t.id === term_id) ?? null : defaultTerm(terms)

      const [students, gaps, trajectory, comments] = await Promise.all([
        rosterSql(tx, id),
        gapsSql(tx, id),
        trajectorySql(tx, id),
        term
          ? tx`SELECT rc.id, rc.student_id, rc.body, rc.is_final, rc.drafted_from,
                      rc.updated_at
               FROM teach.report_comment rc
               WHERE rc.teaching_group_id = ${id} AND rc.term_id = ${term.id}`
          : Promise.resolve([] as unknown[]),
      ])

      return { group, term, terms, students, gaps, trajectory, comments }
    })
  })

  /**
   * Save one report comment. Upsert on the natural key from 006 so a second
   * save from a reopened tab edits the comment rather than raising a conflict
   * the teacher cannot act on.
   */
  app.post('/reports/comments', async (req) => {
    const s = requireSession(req)
    const b = z.object({
      student_id: z.string().uuid(),
      teaching_group_id: z.string().uuid(),
      term_id: z.string().uuid(),
      body: z.string().max(8000),
      drafted_from: z.string().uuid().nullish(),
      is_final: z.boolean().default(false),
    }).parse(req.body)

    return withTenant(s, async (tx) => {
      await requireMyGroup(tx, b.teaching_group_id)
      const [row] = await tx<{ id: string; updated_at: string }[]>`
        INSERT INTO teach.report_comment
          (tenant_id, student_id, teaching_group_id, term_id, body, drafted_from,
           is_final, author_id)
        VALUES (${s.tenantId}, ${b.student_id}, ${b.teaching_group_id}, ${b.term_id},
                ${b.body}, ${b.drafted_from ?? null}, ${b.is_final}, ${s.userId})
        ON CONFLICT (tenant_id, student_id, teaching_group_id, term_id) DO UPDATE SET
          body         = EXCLUDED.body,
          drafted_from = coalesce(EXCLUDED.drafted_from, teach.report_comment.drafted_from),
          is_final     = EXCLUDED.is_final,
          author_id    = EXCLUDED.author_id,
          updated_at   = now()
        RETURNING id, updated_at`
      if (!row) throw new HttpError(404, 'student not found, or not one of yours')
      return { id: row.id, updated_at: row.updated_at }
    })
  })

  // -------------------------------------------------------------------------
  // PARENTS' EVENING
  // -------------------------------------------------------------------------

  /**
   * One prep sheet per student for a class, in the order you will meet them.
   *
   * Attendance is returned as tracked/missed counts rather than a percentage,
   * and as null where no register exists for the group. org.lesson_attendance
   * records only what a school actually takes: an absent row means "not
   * tracked", never "present" (002_org.sql), so a computed 100% would be a
   * fabrication.
   */
  app.get('/parents-evening/groups/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)

    return withTenant(s, async (tx) => {
      const group = await requireMyGroup(tx, id)

      const [students, gaps, trajectory, attendance, lessons] = await Promise.all([
        rosterSql(tx, id),
        gapsSql(tx, id),
        trajectorySql(tx, id),
        tx`SELECT la.student_id,
                  count(*)                                              AS lessons_tracked,
                  count(*) FILTER (WHERE la.status = 'absent')           AS lessons_missed,
                  count(*) FILTER (WHERE la.status = 'late')             AS lessons_late
           FROM org.lesson l
           JOIN org.lesson_attendance la ON la.lesson_id = l.id
           JOIN org.person p ON p.id = la.student_id AND p.deleted_at IS NULL
           WHERE l.teaching_group_id = ${id} AND NOT l.was_cancelled
           GROUP BY la.student_id`,
        tx<{ n: string }[]>`SELECT count(*)::text AS n FROM org.lesson
           WHERE teaching_group_id = ${id} AND NOT was_cancelled`,
      ])

      return {
        group,
        students,
        gaps,
        trajectory,
        attendance,
        lessons_held: Number(lessons[0]?.n ?? 0),
        generated_on: new Date().toISOString().slice(0, 10),
      }
    })
  })
}
