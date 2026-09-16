import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { withTenant } from '../db.js'
import { requireSession } from '../auth.js'

export async function registerTeachingRoutes(app: FastifyInstance) {
  /**
   * The teacher's own classes.
   *
   * NOTE: org.teaching_group carries tenant isolation but no per-teacher RLS
   * policy, because a class LABEL is not student data and heads of department
   * legitimately browse the list. So "mine" is enforced here, in the query.
   * The student data behind each class is still protected by RLS regardless of
   * what this endpoint returns.
   */
  app.get('/groups', async (req) => {
    const s = requireSession(req)
    return withTenant(s, async (tx) => tx`
      SELECT tg.id, tg.label, tg.year_level, tg.level_code,
             sub.name AS subject_name, sub.code AS subject_code,
             ay.label AS academic_year,
             (SELECT count(*) FROM org.enrolment e
               WHERE e.teaching_group_id = tg.id AND e.to_date IS NULL) AS n_students,
             fv.label AS framework
      FROM org.teaching_group tg
      JOIN org.subject sub ON sub.id = tg.subject_id
      JOIN org.academic_year ay ON ay.id = tg.academic_year_id
      LEFT JOIN ref.framework_version fv ON fv.id = tg.framework_version_id
      WHERE ay.is_current
        AND (app.is_school_wide() OR EXISTS (
          SELECT 1 FROM org.teaching_assignment ta
          JOIN org.person staff ON staff.id = ta.staff_id
          WHERE ta.teaching_group_id = tg.id AND ta.to_date IS NULL
            AND staff.user_id = app.current_user_id()))
      ORDER BY sub.name, tg.label`)
  })

  /** Roster for the entry grid. Ordered by family name: how a register reads. */
  app.get('/groups/:id/roster', async (req) => {
    const s = requireSession(req)
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    return withTenant(s, async (tx) => tx`
      SELECT p.id, p.given_name, p.family_name, p.preferred_name, p.external_ref,
             p.is_provisional
      FROM org.enrolment e
      JOIN org.person p ON p.id = e.student_id
      WHERE e.teaching_group_id = ${id} AND e.to_date IS NULL AND p.deleted_at IS NULL
      ORDER BY p.family_name, p.given_name`)
  })

  /**
   * "What do I still owe." The most-used screen in any gradebook teachers keep
   * using, and the reason absence of a result row is computed against enrolment
   * rather than guessed from row counts.
   */
  app.get('/todo', async (req) => {
    const s = requireSession(req)
    return withTenant(s, async (tx) => tx`
      SELECT * FROM teach.v_marking_todo
      WHERE NOT closed AND students_outstanding > 0
      ORDER BY days_since DESC, group_label
      LIMIT 50`)
  })

  /** Topic tags available for tagging an assessment, for one subject. */
  app.get('/groups/:id/tags', async (req) => {
    const s = requireSession(req)
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    return withTenant(s, async (tx) => tx`
      SELECT t.id, t.code, t.label, t.parent_id, tx2.axis
      FROM org.teaching_group tg
      JOIN curric.taxonomy tx2
        ON (tx2.subject_id = tg.subject_id OR tx2.subject_id IS NULL)
      JOIN curric.tag t ON t.taxonomy_id = tx2.id
      WHERE tg.id = ${id} AND tx2.axis IN ('topic', 'skill')
      ORDER BY tx2.axis, t.sort_order, t.label`)
  })
}
