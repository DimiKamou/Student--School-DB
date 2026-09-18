import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { sql, asOwner, withTenant } from '../db.js'
import {
  HttpError, SESSION_COOKIE, hashPassword, hashToken, issueSession, newToken,
  passwordProblem, requireRole, requireSession, rolesFor, verifyPassword,
} from '../auth.js'

const email = z.string().email().max(254)
const password = z.string().min(1).max(200)

/** Constant-ish work on a miss, so timing does not reveal whether an account exists. */
const DUMMY_HASH =
  'scrypt$16384$8$1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

export async function registerAuthRoutes(app: FastifyInstance) {
  // -------------------------------------------------------------------------
  // First run. Available only while the installation has no schools at all, so
  // it closes itself the moment it has been used once.
  // -------------------------------------------------------------------------
  app.get('/setup/needed', async () => {
    const [row] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM platform.tenant
      WHERE id <> app.global_tenant() AND NOT is_reference`
    return { needed: (row?.n ?? 0) === 0 }
  })

  app.post('/setup', async (req, reply) => {
    const body = z.object({
      school_name: z.string().min(2).max(120),
      slug: z.string().regex(/^[a-z0-9][a-z0-9-]{1,62}$/),
      country_code: z.string().length(2).default('GR'),
      admin_name: z.string().min(2).max(120),
      admin_email: email,
      admin_password: password,
      academic_year: z.string().default('2025-2026'),
      year_start: z.string().date().default('2025-09-01'),
      year_end: z.string().date().default('2026-06-30'),
    }).parse(req.body)

    const [existing] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM platform.tenant
      WHERE id <> app.global_tenant() AND NOT is_reference`
    if ((existing?.n ?? 0) > 0) throw new HttpError(409, 'setup has already been completed')

    const problem = passwordProblem(body.admin_password)
    if (problem) throw new HttpError(400, problem)

    const hash = await hashPassword(body.admin_password)
    const userId = await asOwner(async (tx) => {
      const [tenant] = await tx<{ id: string }[]>`
        INSERT INTO platform.tenant (slug, name, country_code)
        VALUES (${body.slug}, ${body.school_name}, ${body.country_code.toUpperCase()})
        RETURNING id`
      const [user] = await tx<{ id: string }[]>`
        INSERT INTO platform.app_user (tenant_id, email, display_name)
        VALUES (${tenant!.id}, ${body.admin_email}, ${body.admin_name}) RETURNING id`
      for (const role of ['school_admin', 'teacher']) {
        await tx`INSERT INTO platform.user_role (tenant_id, user_id, role)
                 VALUES (${tenant!.id}, ${user!.id}, ${role})`
      }
      await tx`INSERT INTO platform.credential (user_id, password_hash)
               VALUES (${user!.id}, ${hash})`
      const [given, ...rest] = body.admin_name.split(' ')
      await tx`INSERT INTO org.person (tenant_id, given_name, family_name, is_staff, user_id)
               VALUES (${tenant!.id}, ${given ?? body.admin_name},
                       ${rest.join(' ') || '·'}, true, ${user!.id})`
      await tx`INSERT INTO org.academic_year (tenant_id, label, starts_on, ends_on, is_current)
               VALUES (${tenant!.id}, ${body.academic_year}, ${body.year_start},
                       ${body.year_end}, true)`
      return user!.id
    })

    const session = await issueSession(reply, userId)
    return { ok: true, session }
  })

  // -------------------------------------------------------------------------
  // Sign in
  // -------------------------------------------------------------------------
  app.post('/auth/login', async (req, reply) => {
    const body = z.object({ email, password }).parse(req.body)
    const id = body.email.toLowerCase()

    const [fails] = await sql<{ n: number }[]>`SELECT platform.recent_failures(${id}) AS n`
    if ((fails?.n ?? 0) >= 8) {
      throw new HttpError(429, 'Too many failed attempts. Try again in 15 minutes.')
    }

    const [user] = await sql<{ id: string; password_hash: string; is_active: boolean;
                              locked_until: Date | null; must_change: boolean }[]>`
      SELECT u.id, c.password_hash, u.is_active, c.locked_until, c.must_change
      FROM platform.app_user u
      JOIN platform.credential c ON c.user_id = u.id
      WHERE lower(u.email::text) = ${id}`

    // Always do the scrypt work, even with no such user: a fast rejection is a
    // free oracle for which staff addresses exist at a school.
    const ok = await verifyPassword(body.password, user?.password_hash ?? DUMMY_HASH)
    const allowed = ok && !!user && user.is_active &&
      (!user.locked_until || user.locked_until < new Date())

    await sql`INSERT INTO platform.login_attempt (identifier, succeeded) VALUES (${id}, ${allowed})`
    if (!allowed) throw new HttpError(401, 'Wrong email or password.')

    await sql`UPDATE platform.credential SET failed_attempts = 0, locked_until = NULL
              WHERE user_id = ${user!.id}`
    const session = await issueSession(reply, user!.id)
    return { ok: true, session, must_change_password: user!.must_change }
  })

  app.post('/auth/logout', async (_req, reply) => {
    reply.clearCookie(SESSION_COOKIE, { path: '/' })
    return { ok: true }
  })

  /** Sign out on every device: bump the epoch and every live cookie dies. */
  app.post('/auth/logout-everywhere', async (req, reply) => {
    const s = requireSession(req)
    await sql`UPDATE platform.app_user SET session_epoch = session_epoch + 1 WHERE id = ${s.userId}`
    reply.clearCookie(SESSION_COOKIE, { path: '/' })
    return { ok: true }
  })

  app.post('/auth/change-password', async (req, reply) => {
    const s = requireSession(req)
    const body = z.object({ current: password, next: password }).parse(req.body)
    const problem = passwordProblem(body.next)
    if (problem) throw new HttpError(400, problem)

    const [cred] = await sql<{ password_hash: string }[]>`
      SELECT password_hash FROM platform.credential WHERE user_id = ${s.userId}`
    if (!cred || !(await verifyPassword(body.current, cred.password_hash))) {
      throw new HttpError(401, 'Current password is wrong.')
    }
    const hash = await hashPassword(body.next)
    await sql`UPDATE platform.credential
              SET password_hash = ${hash}, must_change = false, updated_at = now()
              WHERE user_id = ${s.userId}`
    // Changing a password ends other sessions. If it was changed because of a
    // compromise, leaving the attacker signed in defeats the point.
    await sql`UPDATE platform.app_user SET session_epoch = session_epoch + 1 WHERE id = ${s.userId}`
    await issueSession(reply, s.userId)
    return { ok: true }
  })

  // -------------------------------------------------------------------------
  // Invitations. Nobody self-registers into a database of children.
  // -------------------------------------------------------------------------
  app.post('/invites', async (req) => {
    const s = requireRole(req, 'school_admin')
    const body = z.object({
      email,
      display_name: z.string().max(120).optional(),
      roles: z.array(z.enum(['school_admin','head_of_dept','teacher','tutor','dpo']))
        .min(1).default(['teacher']),
      person_id: z.string().uuid().nullish(),
    }).parse(req.body)

    const { token, hash } = newToken()
    const [row] = await sql<{ id: string; expires_at: Date }[]>`
      INSERT INTO platform.invite (tenant_id, email, display_name, roles, token_hash,
                                   invited_by, person_id)
      VALUES (${s.tenantId}, ${body.email}, ${body.display_name ?? null},
              ${body.roles}, ${hash}, ${s.userId}, ${body.person_id ?? null})
      RETURNING id, expires_at`
    // Returned once, never stored in plaintext. If email is not configured the
    // admin copies this link; if it is, it is mailed and this is still the
    // fallback for the address that bounces.
    return {
      id: row!.id, expires_at: row!.expires_at,
      accept_url: `${process.env.WEB_ORIGIN ?? 'http://localhost:5173'}/accept?token=${token}`,
    }
  })

  app.get('/invites', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT i.id, i.email, i.display_name, i.roles, i.created_at, i.expires_at, i.accepted_at
      FROM platform.invite i WHERE i.tenant_id = ${s.tenantId}
      ORDER BY i.accepted_at NULLS FIRST, i.created_at DESC LIMIT 100`)
  })

  app.delete('/invites/:id', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    await sql`DELETE FROM platform.invite WHERE id = ${id} AND tenant_id = ${s.tenantId}
              AND accepted_at IS NULL`
    return { ok: true }
  })

  /** Look up an invite without consuming it, so the accept page can greet them. */
  app.get('/invites/preview', async (req) => {
    const { token } = z.object({ token: z.string().min(10) }).parse(req.query)
    const [row] = await sql<{ email: string; display_name: string | null;
                             tenant_name: string; roles: string[] }[]>`
      SELECT i.email, i.display_name, t.name AS tenant_name, i.roles
      FROM platform.invite i JOIN platform.tenant t ON t.id = i.tenant_id
      WHERE i.token_hash = ${hashToken(token)} AND i.accepted_at IS NULL AND i.expires_at > now()`
    if (!row) throw new HttpError(404, 'That invitation has expired or already been used.')
    return row
  })

  app.post('/invites/accept', async (req, reply) => {
    const body = z.object({
      token: z.string().min(10), password, display_name: z.string().max(120).optional(),
    }).parse(req.body)
    const problem = passwordProblem(body.password)
    if (problem) throw new HttpError(400, problem)

    const hash = await hashPassword(body.password)
    const userId = await asOwner(async (tx) => {
      const [inv] = await tx<{ id: string; tenant_id: string; email: string;
                              display_name: string | null; roles: string[];
                              person_id: string | null }[]>`
        SELECT id, tenant_id, email, display_name, roles, person_id
        FROM platform.invite
        WHERE token_hash = ${hashToken(body.token)}
          AND accepted_at IS NULL AND expires_at > now()
        FOR UPDATE`
      if (!inv) throw new HttpError(404, 'That invitation has expired or already been used.')

      const [user] = await tx<{ id: string }[]>`
        INSERT INTO platform.app_user (tenant_id, email, display_name)
        VALUES (${inv.tenant_id}, ${inv.email},
                ${body.display_name ?? inv.display_name ?? inv.email})
        RETURNING id`
      for (const role of inv.roles) {
        await tx`INSERT INTO platform.user_role (tenant_id, user_id, role)
                 VALUES (${inv.tenant_id}, ${user!.id}, ${role})
                 ON CONFLICT DO NOTHING`
      }
      await tx`INSERT INTO platform.credential (user_id, password_hash) VALUES (${user!.id}, ${hash})`
      if (inv.person_id) {
        await tx`UPDATE org.person SET user_id = ${user!.id} WHERE id = ${inv.person_id}`
      } else {
        const name = body.display_name ?? inv.display_name ?? inv.email
        const [given, ...rest] = name.split(' ')
        await tx`INSERT INTO org.person (tenant_id, given_name, family_name, is_staff, user_id)
                 VALUES (${inv.tenant_id}, ${given ?? name}, ${rest.join(' ') || '·'},
                         true, ${user!.id})`
      }
      await tx`UPDATE platform.invite SET accepted_at = now(), accepted_user_id = ${user!.id}
               WHERE id = ${inv.id}`
      return user!.id
    })
    const session = await issueSession(reply, userId)
    return { ok: true, session }
  })

  // -------------------------------------------------------------------------
  // Who am I
  // -------------------------------------------------------------------------
  app.get('/me', async (req) => {
    const s = requireSession(req)
    const [row] = await sql<{ display_name: string; email: string | null;
                             tenant_name: string; tenant_slug: string;
                             person_id: string | null }[]>`
      SELECT u.display_name, u.email::text AS email, t.name AS tenant_name, t.slug AS tenant_slug,
             (SELECT p.id FROM org.person p WHERE p.user_id = u.id LIMIT 1) AS person_id
      FROM platform.app_user u JOIN platform.tenant t ON t.id = u.tenant_id
      WHERE u.id = ${s.userId}`
    await sql`UPDATE platform.app_user SET last_seen_at = now() WHERE id = ${s.userId}`
    return { ...s, ...row }
  })

  /** Staff directory and role management. */
  app.get('/users', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT u.id, u.display_name, u.email::text AS email, u.is_active, u.last_seen_at,
             coalesce(array_agg(ur.role) FILTER (WHERE ur.role IS NOT NULL), '{}') AS roles,
             (SELECT count(*) FROM org.teaching_assignment ta
               JOIN org.person p ON p.id = ta.staff_id
               WHERE p.user_id = u.id AND ta.to_date IS NULL) AS n_classes
      FROM platform.app_user u
      LEFT JOIN platform.user_role ur ON ur.user_id = u.id
      WHERE u.tenant_id = ${s.tenantId}
      GROUP BY u.id ORDER BY u.display_name`)
  })

  app.post('/users/:id/roles', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    const { roles } = z.object({
      roles: z.array(z.enum(['school_admin','head_of_dept','teacher','tutor','dpo'])),
    }).parse(req.body)
    if (id === s.userId && !roles.includes('school_admin')) {
      // Locking yourself out of your own school needs a second admin to undo.
      throw new HttpError(400, 'You cannot remove your own admin role.')
    }
    await asOwner(async (tx) => {
      await tx`DELETE FROM platform.user_role WHERE tenant_id = ${s.tenantId} AND user_id = ${id}`
      for (const r of roles) {
        await tx`INSERT INTO platform.user_role (tenant_id, user_id, role)
                 VALUES (${s.tenantId}, ${id}, ${r}) ON CONFLICT DO NOTHING`
      }
      await tx`UPDATE platform.app_user SET session_epoch = session_epoch + 1 WHERE id = ${id}`
    })
    return { ok: true, roles: await rolesFor(s.tenantId, id) }
  })

  app.post('/users/:id/deactivate', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    if (id === s.userId) throw new HttpError(400, 'You cannot deactivate yourself.')
    await sql`UPDATE platform.app_user
              SET is_active = false, session_epoch = session_epoch + 1
              WHERE id = ${id} AND tenant_id = ${s.tenantId}`
    return { ok: true }
  })
}
