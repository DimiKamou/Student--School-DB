import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { withTenant } from '../db.js'
import { requireSession } from '../auth.js'

const createAssessment = z.object({
  teaching_group_id: z.string().uuid(),
  title: z.string().min(1).max(200),
  kind: z.enum(['formative','summative','mock','exam','homework','oral','practical','project','external'])
    .default('summative'),
  occurred_on: z.string().date().optional(),
  topic_tag_id: z.string().uuid().nullish(),
  max_total: z.number().positive().nullish(),
  weight: z.number().min(0).default(1),
  items: z.array(z.object({
    seq: z.number().int().optional(),
    label: z.string().max(80).optional(),
    max_value: z.number().positive().nullish(),
    measure_id: z.string().uuid().nullish(),
    topic_tag_id: z.string().uuid().nullish(),
    skill_tag_id: z.string().uuid().nullish(),
  })).optional(),
})

const markBatch = z.object({
  client_mutation_id: z.string().max(100).optional(),
  source: z.enum(['manual','import','paste','ocr','api']).default('manual'),
  marks: z.array(z.object({
    item_id: z.string().uuid(),
    student_id: z.string().uuid(),
    raw_value: z.number().nullish(),
    value_code: z.string().max(20).nullish(),
    status: z.enum(['scored','absent','not_submitted','exempt','pending','malpractice']).default('scored'),
    is_defaulted: z.boolean().default(false),
    submitted_late: z.boolean().default(false),
    comment: z.string().max(2000).nullish(),
  })).min(1).max(5000),
})

export async function registerMarksRoutes(app: FastifyInstance) {
  app.post('/assessments', async (req) => {
    const s = requireSession(req)
    const body = createAssessment.parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string }[]>`
        SELECT gradebook.create_assessment(${tx.json(body)}::jsonb) AS id`
      return { id: row!.id }
    })
  })

  /**
   * Everything the entry grid needs in ONE round trip: the assessment, its
   * items, the roster, and any marks already recorded. Three requests here
   * would be three chances for the grid to render half-empty.
   */
  app.get('/assessments/:id/grid', async (req) => {
    const s = requireSession(req)
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    return withTenant(s, async (tx) => {
      const [assessment] = await tx`
        SELECT a.id, a.title, a.kind, a.occurred_on, a.max_total, a.weight,
               a.topic_tag_id, a.marking_closed_at, a.teaching_group_id,
               tg.label AS group_label, sub.name AS subject_name
        FROM gradebook.assessment a
        JOIN org.teaching_group tg ON tg.id = a.teaching_group_id
        JOIN org.subject sub ON sub.id = tg.subject_id
        WHERE a.id = ${id} AND a.deleted_at IS NULL`
      if (!assessment) throw Object.assign(new Error('assessment not found'), { statusCode: 404 })

      const [items, students, marks] = await Promise.all([
        tx`SELECT i.id, i.seq, i.label, i.max_value, i.scale_id, i.measure_id,
                  i.topic_tag_id, i.skill_tag_id,
                  t.label AS topic_label, m.label AS measure_label
           FROM gradebook.item i
           LEFT JOIN curric.tag t ON t.id = i.topic_tag_id
           LEFT JOIN ref.measure m ON m.id = i.measure_id
           WHERE i.assessment_id = ${id} ORDER BY i.seq`,
        tx`SELECT p.id, p.given_name, p.family_name, p.preferred_name, p.external_ref
           FROM org.enrolment e
           JOIN org.person p ON p.id = e.student_id
           WHERE e.teaching_group_id = ${assessment.teaching_group_id}
             AND e.to_date IS NULL AND p.deleted_at IS NULL
           ORDER BY p.family_name, p.given_name`,
        tx`SELECT r.item_id, r.student_id, r.raw_value, r.value_code, r.status,
                  r.is_defaulted, r.submitted_late, r.comment
           FROM gradebook.result r
           JOIN gradebook.item i ON i.id = r.item_id
           WHERE i.assessment_id = ${id} AND r.marker_role = 'primary'`,
      ])
      return { assessment, items, students, marks }
    })
  })

  /**
   * The batch write. A whole class in one statement, idempotent on
   * client_mutation_id so a phone that loses signal mid-save and retries does
   * not double-write.
   */
  app.post('/marks', async (req) => {
    const s = requireSession(req)
    const body = markBatch.parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ result: { written: number; replayed: boolean } }[]>`
        SELECT gradebook.record_marks(${tx.json(body)}::jsonb) AS result`
      return row!.result
    })
  })

  /** "Everyone got it, tap the exceptions." */
  app.post('/marks/default-then-exceptions', async (req) => {
    const s = requireSession(req)
    const body = z.object({
      item_id: z.string().uuid(),
      default_value: z.number(),
      exceptions: z.array(z.object({
        student_id: z.string().uuid(),
        raw_value: z.number().nullish(),
        status: z.string().optional(),
      })).default([]),
    }).parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ n: number }[]>`
        SELECT gradebook.record_default_then_exceptions(
          ${body.item_id}::uuid, ${body.default_value}::numeric,
          ${tx.json(body.exceptions)}::jsonb) AS n`
      return { defaulted: row!.n }
    })
  })

  app.post('/assessments/:id/close', async (req) => {
    const s = requireSession(req)
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    return withTenant(s, async (tx) => {
      await tx`UPDATE gradebook.assessment SET marking_closed_at = now() WHERE id = ${id}`
      return { ok: true }
    })
  })

  /**
   * Entry telemetry. The product's central claim is that entry under ~2 minutes
   * drives accumulation; without this the claim is untestable and a slow screen
   * is indistinguishable from an unpopular one.
   */
  app.post('/entry-sessions', async (req) => {
    const s = requireSession(req)
    const body = z.object({
      assessment_id: z.string().uuid().nullish(),
      screen: z.string().max(60),
      started_at: z.string(),
      first_value_at: z.string().nullish(),
      ended_at: z.string().nullish(),
      cells_expected: z.number().int().nullish(),
      cells_entered: z.number().int().nullish(),
      was_abandoned: z.boolean().default(false),
      device: z.enum(['desktop','tablet','phone']).default('desktop'),
    }).parse(req.body)
    return withTenant(s, async (tx) => {
      await tx`INSERT INTO gradebook.entry_session ${tx({
        tenant_id: s.tenantId, user_id: s.userId, assessment_id: body.assessment_id ?? null,
        screen: body.screen, started_at: body.started_at,
        first_value_at: body.first_value_at ?? null, ended_at: body.ended_at ?? null,
        cells_expected: body.cells_expected ?? null, cells_entered: body.cells_entered ?? null,
        was_abandoned: body.was_abandoned, device: body.device,
      })}`
      return { ok: true }
    })
  })
}
