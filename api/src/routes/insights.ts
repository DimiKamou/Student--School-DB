import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { withTenant } from '../db.js'
import { requireSession } from '../auth.js'

const uuidParam = z.object({ id: z.string().uuid() })

export async function registerInsightRoutes(app: FastifyInstance) {
  /** The landing screen: what is worth this teacher's attention today. */
  app.get('/attention', async (req) => {
    const s = requireSession(req)
    const { limit } = z.object({ limit: z.coerce.number().int().min(1).max(20).default(5) })
      .parse(req.query)
    return withTenant(s, async (tx) => tx`SELECT * FROM analytics.attention_list(${limit})`)
  })

  app.get('/groups/:id/heatmap', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    const { axis } = z.object({ axis: z.string().default('topic') }).parse(req.query)
    return withTenant(s, async (tx) => tx`SELECT * FROM analytics.class_heatmap(${id}::uuid, ${axis})`)
  })

  app.get('/groups/:id/coverage', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => tx`SELECT * FROM analytics.group_coverage(${id}::uuid)`)
  })

  app.get('/students/:id', async (req) => {
    const s = requireSession(req)
    const { id } = uuidParam.parse(req.params)
    return withTenant(s, async (tx) => {
      const [student] = await tx`
        SELECT p.id, p.given_name, p.family_name, p.preferred_name, p.external_ref
        FROM org.person p WHERE p.id = ${id} AND p.deleted_at IS NULL`
      if (!student) throw Object.assign(new Error('student not found'), { statusCode: 404 })
      const [gaps, timeline, trajectory, pooling] = await Promise.all([
        tx`SELECT * FROM analytics.student_gaps(${id}::uuid)`,
        tx`SELECT * FROM analytics.student_timeline(${id}::uuid)`,
        tx`SELECT * FROM analytics.student_trajectory(${id}::uuid)`,
        tx`SELECT pooling_verdict, n_frameworks FROM analytics.v_pooling_check
           WHERE student_id = ${id}`,
      ])
      return { student, gaps, timeline, trajectory, pooling: pooling[0] ?? null }
    })
  })

  /** Refresh derived analytics. In production this is a scheduled job. */
  app.post('/admin/refresh-analytics', async (req) => {
    const s = requireSession(req)
    if (!s.roles.includes('school_admin')) {
      throw Object.assign(new Error('school_admin required'), { statusCode: 403 })
    }
    const started = Date.now()
    await withTenant(s, async (tx) => tx`SELECT analytics.refresh_all(true)`)
    return { ok: true, ms: Date.now() - started }
  })
}
