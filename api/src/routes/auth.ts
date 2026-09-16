import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { sql } from '../db.js'
import { SESSION_COOKIE, rolesFor, signSession, sessionFrom } from '../auth.js'

const DEV = process.env.NODE_ENV !== 'production'

export async function registerAuthRoutes(app: FastifyInstance) {
  /**
   * Dev sign-in. Lists real users so a demo needs no password plumbing.
   * Refuses to exist outside development — this is the single most dangerous
   * endpoint in the codebase and it should fail closed, loudly.
   */
  app.get('/auth/dev-users', async (_req, reply) => {
    if (!DEV) return reply.status(404).send({ error: 'not found' })
    const rows = await sql`
      SELECT u.id AS user_id, u.display_name, u.tenant_id, t.name AS tenant_name,
             coalesce(array_agg(ur.role) FILTER (WHERE ur.role IS NOT NULL), '{}') AS roles
      FROM platform.app_user u
      JOIN platform.tenant t ON t.id = u.tenant_id
      LEFT JOIN platform.user_role ur ON ur.user_id = u.id
      WHERE u.is_active AND t.id <> app.global_tenant()
      GROUP BY u.id, u.display_name, u.tenant_id, t.name
      ORDER BY t.name, u.display_name`
    return rows
  })

  app.post('/auth/dev-login', async (req, reply) => {
    if (!DEV) return reply.status(404).send({ error: 'not found' })
    const { userId } = z.object({ userId: z.string().uuid() }).parse(req.body)
    const [user] = await sql<{ tenant_id: string }[]>`
      SELECT tenant_id FROM platform.app_user WHERE id = ${userId} AND is_active`
    if (!user) return reply.status(404).send({ error: 'no such user' })

    const session = { tenantId: user.tenant_id, userId, roles: await rolesFor(user.tenant_id, userId) }
    reply.setCookie(SESSION_COOKIE, signSession(session), {
      httpOnly: true,
      sameSite: 'lax',
      path: '/',
      secure: !DEV,
      maxAge: 60 * 60 * 12,
    })
    return { ok: true, session }
  })

  app.post('/auth/logout', async (_req, reply) => {
    reply.clearCookie(SESSION_COOKIE, { path: '/' })
    return { ok: true }
  })

  app.get('/me', async (req, reply) => {
    const s = sessionFrom(req)
    if (!s) return reply.status(401).send({ error: 'not signed in' })
    const [row] = await sql<{ display_name: string; tenant_name: string; person_id: string | null }[]>`
      SELECT u.display_name, t.name AS tenant_name,
             (SELECT p.id FROM org.person p WHERE p.user_id = u.id LIMIT 1) AS person_id
      FROM platform.app_user u JOIN platform.tenant t ON t.id = u.tenant_id
      WHERE u.id = ${s.userId}`
    return { ...s, ...row }
  })
}
