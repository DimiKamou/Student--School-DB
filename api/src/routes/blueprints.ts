import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { withTenant } from '../db.js'
import { requireSession, HttpError } from '../auth.js'

/**
 * Blueprints, and the assessment list behind the creation screens.
 *
 * A blueprint is last year's paper with its tagging already done. That is the
 * whole argument for the table existing: tagging is the make-or-break of this
 * product (ARCHITECTURE §2), and the cheapest tagging is tagging you did once
 * and never repeat. `times_used` is therefore not decoration — it is the
 * measure of how much tagging work a school has stopped paying for.
 *
 * Cloning a blueprint into a live assessment is NOT reimplemented here:
 * gradebook.assessment_from_blueprint() in 006_write_path.sql already does it
 * in one transaction, including dropping the synthetic total item and bumping
 * times_used. Two implementations of that would drift.
 *
 * Every handler runs inside withTenant(): RLS on curric.blueprint and
 * curric.blueprint_item is the only thing standing between two schools' item
 * banks, and it reads the transaction-local settings that withTenant sets.
 */

const uuidParam = z.object({ id: z.string().uuid() })

/** A blueprint item, and the two optional tag columns that make it worth saving. */
const blueprintItem = z.object({
  seq: z.number().int().min(0).max(999).optional(),
  label: z.string().min(1).max(80),
  max_value: z.number().positive().nullish(),
  measure_id: z.string().uuid().nullish(),
  topic_tag_id: z.string().uuid().nullish(),
  skill_tag_id: z.string().uuid().nullish(),
})

const blueprintBody = z.object({
  name: z.string().min(1).max(200),
  description: z.string().max(2000).nullish(),
  subject_id: z.string().uuid().nullish(),
  framework_version_id: z.string().uuid().nullish(),
  is_shared: z.boolean().default(false),
  items: z.array(blueprintItem).max(400).default([]),
})

type ItemRow = z.infer<typeof blueprintItem>

/** seq is UNIQUE per blueprint; never trust the client to keep it dense. */
function numberItems(items: ItemRow[]) {
  return items.map((it, i) => ({
    seq: it.seq ?? i + 1,
    label: it.label,
    max_value: it.max_value ?? null,
    measure_id: it.measure_id ?? null,
    topic_tag_id: it.topic_tag_id ?? null,
    skill_tag_id: it.skill_tag_id ?? null,
  }))
}

export async function registerBlueprintRoutes(app: FastifyInstance) {
  // -------------------------------------------------------------------------
  // The assessment list. Counted against the register the same way
  // teach.v_marking_todo counts, so "no result rows yet" can never read as
  // "nothing left to mark".
  // -------------------------------------------------------------------------
  app.get('/assessments', async (req) => {
    const s = requireSession(req)
    const q = z.object({
      group_id: z.string().uuid().optional(),
      limit: z.coerce.number().int().min(1).max(500).default(200),
    }).parse(req.query)
    const gid = q.group_id ?? null

    return withTenant(s, async (tx) => tx`
      SELECT a.id, a.title, a.kind, a.occurred_on, a.max_total, a.weight,
             a.teaching_group_id, a.marking_closed_at,
             (a.marking_closed_at IS NOT NULL)        AS closed,
             tg.label                                  AS group_label,
             sub.name                                  AS subject_name,
             t.label                                   AS topic_label,
             bp.name                                   AS blueprint_name,
             (current_date - a.occurred_on)            AS days_since,
             (SELECT count(*) FROM gradebook.item i
               WHERE i.assessment_id = a.id)           AS n_items,
             (SELECT count(*) FROM org.enrolment e
               WHERE e.teaching_group_id = a.teaching_group_id
                 AND e.to_date IS NULL)                AS students_expected,
             (SELECT count(DISTINCT r.student_id)
                FROM gradebook.result r
                JOIN gradebook.item i2 ON i2.id = r.item_id
               WHERE i2.assessment_id = a.id
                 AND r.marker_role = 'primary')        AS students_marked
      FROM gradebook.assessment a
      JOIN org.teaching_group tg ON tg.id = a.teaching_group_id
      JOIN org.subject sub ON sub.id = tg.subject_id
      LEFT JOIN curric.tag t ON t.id = a.topic_tag_id
      LEFT JOIN curric.blueprint bp ON bp.id = a.blueprint_id
      WHERE a.deleted_at IS NULL
        AND (${gid}::uuid IS NULL OR a.teaching_group_id = ${gid}::uuid)
        -- Same "mine" rule as GET /groups: a class LABEL is not student data,
        -- so the filter lives here rather than in a policy. The marks behind it
        -- are protected by RLS regardless of what this returns.
        AND (app.is_school_wide() OR EXISTS (
          SELECT 1 FROM org.teaching_assignment ta
          JOIN org.person staff ON staff.id = ta.staff_id
          WHERE ta.teaching_group_id = tg.id AND ta.to_date IS NULL
            AND staff.user_id = app.current_user_id()))
      ORDER BY a.occurred_on DESC, a.created_at DESC
      LIMIT ${q.limit}`)
  })

  // -------------------------------------------------------------------------
  // Blueprint library
  // -------------------------------------------------------------------------

  /**
   * Mine, plus anything a colleague marked shared. is_shared is documented in
   * 004_curriculum.sql as "visible department-wide", so an unshared blueprint
   * is a private draft and is not listed to the rest of the school.
   */
  app.get('/blueprints', async (req) => {
    const s = requireSession(req)
    const q = z.object({ subject_id: z.string().uuid().optional() }).parse(req.query)
    const sid = q.subject_id ?? null

    return withTenant(s, async (tx) => tx`
      SELECT b.id, b.name, b.description, b.subject_id, b.framework_version_id,
             b.is_shared, b.times_used, b.created_at, b.created_by,
             sub.name AS subject_name,
             u.display_name AS created_by_name,
             (b.created_by = app.current_user_id()) AS is_mine,
             (SELECT count(*) FROM curric.blueprint_item bi
               WHERE bi.blueprint_id = b.id)                       AS n_items,
             (SELECT count(*) FROM curric.blueprint_item bi
               WHERE bi.blueprint_id = b.id
                 AND (bi.topic_tag_id IS NOT NULL
                      OR bi.skill_tag_id IS NOT NULL))             AS n_items_tagged,
             (SELECT sum(bi.max_value) FROM curric.blueprint_item bi
               WHERE bi.blueprint_id = b.id)                       AS total_marks
      FROM curric.blueprint b
      LEFT JOIN org.subject sub ON sub.id = b.subject_id
      LEFT JOIN platform.app_user u ON u.id = b.created_by
      WHERE (${sid}::uuid IS NULL OR b.subject_id = ${sid}::uuid)
        AND (b.is_shared OR b.created_by IS NULL
             OR b.created_by = app.current_user_id() OR app.is_school_wide())
      ORDER BY b.times_used DESC, b.created_at DESC`)
  })

  /** Subjects, for scoping a blueprint. A static segment, so it wins over /:id. */
  app.get('/blueprints/subjects', async (req) => {
    const s = requireSession(req)
    return withTenant(s, async (tx) => tx`
      SELECT sub.id, sub.code, sub.name
      FROM org.subject sub
      ORDER BY sub.name`)
  })

  /**
   * Tags for the blueprint editor, by subject rather than by class: a blueprint
   * outlives the group it was first used with.
   */
  app.get('/blueprints/tags', async (req) => {
    const s = requireSession(req)
    const q = z.object({ subject_id: z.string().uuid().optional() }).parse(req.query)
    const sid = q.subject_id ?? null
    return withTenant(s, async (tx) => tx`
      SELECT t.id, t.code, t.label, t.parent_id, tx2.axis
      FROM curric.taxonomy tx2
      JOIN curric.tag t ON t.taxonomy_id = tx2.id
      WHERE tx2.axis IN ('topic', 'skill')
        AND (${sid}::uuid IS NULL
             OR tx2.subject_id = ${sid}::uuid
             OR tx2.subject_id IS NULL)
      ORDER BY tx2.axis, t.sort_order, t.label`)
  })

  app.get('/blueprints/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [blueprint] = await tx`
        SELECT b.id, b.name, b.description, b.subject_id, b.framework_version_id,
               b.is_shared, b.times_used, b.created_at, b.created_by,
               sub.name AS subject_name,
               u.display_name AS created_by_name,
               (b.created_by = app.current_user_id()) AS is_mine
        FROM curric.blueprint b
        LEFT JOIN org.subject sub ON sub.id = b.subject_id
        LEFT JOIN platform.app_user u ON u.id = b.created_by
        WHERE b.id = ${id}`
      if (!blueprint) throw new HttpError(404, 'blueprint not found')

      const items = await tx`
        SELECT bi.id, bi.seq, bi.label, bi.max_value, bi.measure_id,
               bi.topic_tag_id, bi.skill_tag_id,
               t.label AS topic_label, sk.label AS skill_label,
               m.label AS measure_label
        FROM curric.blueprint_item bi
        LEFT JOIN curric.tag t ON t.id = bi.topic_tag_id
        LEFT JOIN curric.tag sk ON sk.id = bi.skill_tag_id
        LEFT JOIN ref.measure m ON m.id = bi.measure_id
        WHERE bi.blueprint_id = ${id}
        ORDER BY bi.seq`
      return { blueprint, items }
    })
  })

  app.post('/blueprints', async (req) => {
    const s = requireSession(req)
    const body = blueprintBody.parse(req.body)
    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string }[]>`
        INSERT INTO curric.blueprint ${tx({
          tenant_id: s.tenantId,
          subject_id: body.subject_id ?? null,
          framework_version_id: body.framework_version_id ?? null,
          name: body.name,
          description: body.description ?? null,
          is_shared: body.is_shared,
          created_by: s.userId,
        })} RETURNING id`
      const id = row!.id
      const items = numberItems(body.items)
      if (items.length > 0) {
        await tx`INSERT INTO curric.blueprint_item ${tx(
          items.map((it) => ({ tenant_id: s.tenantId, blueprint_id: id, ...it })),
        )}`
      }
      return { id, n_items: items.length }
    })
  })

  /**
   * Replace a blueprint wholesale. Items are replaced, never merged: a partial
   * update would leave a paper half last year's and half this year's.
   *
   * POST rather than PUT, and /delete rather than DELETE, to match the verbs
   * the rest of this API and the web client already speak.
   */
  app.post('/blueprints/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const body = blueprintBody.parse(req.body)
    return withTenant(s, async (tx) => {
      const [owned] = await tx<{ id: string }[]>`
        SELECT id FROM curric.blueprint WHERE id = ${id}`
      if (!owned) throw new HttpError(404, 'blueprint not found')

      await tx`
        UPDATE curric.blueprint
           SET name = ${body.name},
               description = ${body.description ?? null},
               subject_id = ${body.subject_id ?? null},
               framework_version_id = ${body.framework_version_id ?? null},
               is_shared = ${body.is_shared}
         WHERE id = ${id}`
      await tx`DELETE FROM curric.blueprint_item WHERE blueprint_id = ${id}`
      const items = numberItems(body.items)
      if (items.length > 0) {
        await tx`INSERT INTO curric.blueprint_item ${tx(
          items.map((it) => ({ tenant_id: s.tenantId, blueprint_id: id, ...it })),
        )}`
      }
      return { id, n_items: items.length }
    })
  })

  app.post('/blueprints/:id/delete', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      // Assessments already cloned from it keep working: assessment.blueprint_id
      // is ON DELETE SET NULL, and their items were copied, not referenced.
      const rows = await tx<{ id: string }[]>`
        DELETE FROM curric.blueprint WHERE id = ${id} RETURNING id`
      if (rows.length === 0) throw new HttpError(404, 'blueprint not found')
      return { ok: true }
    })
  })

  /**
   * Save an assessment you already tagged as a reusable blueprint. This is the
   * path that actually gets used: nobody sits down to author a blueprint, they
   * finish marking a paper and want next year to be free.
   */
  app.post('/blueprints/from-assessment', async (req) => {
    const s = requireSession(req)
    const body = z.object({
      assessment_id: z.string().uuid(),
      name: z.string().min(1).max(200).optional(),
      description: z.string().max(2000).nullish(),
      is_shared: z.boolean().default(false),
    }).parse(req.body)

    return withTenant(s, async (tx) => {
      const [a] = await tx<{ title: string; subject_id: string; framework_version_id: string | null }[]>`
        SELECT a.title, tg.subject_id, tg.framework_version_id
        FROM gradebook.assessment a
        JOIN org.teaching_group tg ON tg.id = a.teaching_group_id
        WHERE a.id = ${body.assessment_id} AND a.deleted_at IS NULL`
      if (!a) throw new HttpError(404, 'assessment not found')

      const [row] = await tx<{ id: string }[]>`
        INSERT INTO curric.blueprint ${tx({
          tenant_id: s.tenantId,
          subject_id: a.subject_id,
          framework_version_id: a.framework_version_id,
          name: body.name ?? a.title,
          description: body.description ?? null,
          is_shared: body.is_shared,
          created_by: s.userId,
        })} RETURNING id`
      const id = row!.id

      // Structure and tagging only. No marks, no students: a blueprint is the
      // paper, not the sitting of it.
      const [copied] = await tx<{ n: string }[]>`
        WITH copied AS (
          INSERT INTO curric.blueprint_item
            (tenant_id, blueprint_id, seq, label, max_value, measure_id,
             topic_tag_id, skill_tag_id)
          SELECT ${s.tenantId}::uuid, ${id}::uuid, i.seq, i.label, i.max_value,
                 i.measure_id,
                 -- Rung 1 inherits: an assessment tagged only at the top still
                 -- produces a topic-tagged blueprint, which is the whole point.
                 coalesce(i.topic_tag_id, asm.topic_tag_id), i.skill_tag_id
          FROM gradebook.item i
          JOIN gradebook.assessment asm ON asm.id = i.assessment_id
          WHERE i.assessment_id = ${body.assessment_id}
          RETURNING 1
        )
        SELECT count(*)::text AS n FROM copied`
      return { id, n_items: Number(copied?.n ?? 0) }
    })
  })

  /**
   * Clone a blueprint into a live assessment for a class.
   *
   * gradebook.assessment_from_blueprint() does the work: it creates the
   * assessment, drops the synthetic total, copies every tagged item and
   * increments times_used, all in one transaction.
   */
  app.post('/blueprints/:id/use', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const body = z.object({
      teaching_group_id: z.string().uuid(),
      title: z.string().min(1).max(200).optional(),
      occurred_on: z.string().date().optional(),
    }).parse(req.body)

    return withTenant(s, async (tx) => {
      const [row] = await tx<{ id: string }[]>`
        SELECT gradebook.assessment_from_blueprint(
          ${id}::uuid,
          ${body.teaching_group_id}::uuid,
          ${body.title ?? null}::text,
          coalesce(${body.occurred_on ?? null}::date, current_date)) AS id`
      return { id: row!.id }
    })
  })
}
