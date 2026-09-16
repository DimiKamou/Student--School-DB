import crypto from 'node:crypto'
import type { FastifyRequest } from 'fastify'
import { sql, type Session } from './db.js'

const SECRET = process.env.SESSION_SECRET ?? 'dev-only-insecure-secret-change-me'
const COOKIE = 'sdb_session'

/**
 * Stateless signed session cookie. Deliberately small: the only thing we trust
 * from the client is (tenantId, userId), and every authorisation decision after
 * that is made by RLS in the database, not here.
 *
 * Production swaps sign/verify for a real IdP (magic link or school SSO). The
 * rest of the codebase depends only on the Session shape, so nothing else moves.
 */
export function signSession(s: Session): string {
  const body = Buffer.from(JSON.stringify(s)).toString('base64url')
  const mac = crypto.createHmac('sha256', SECRET).update(body).digest('base64url')
  return `${body}.${mac}`
}

export function verifySession(token: string | undefined): Session | null {
  if (!token) return null
  const [body, mac] = token.split('.')
  if (!body || !mac) return null
  const expected = crypto.createHmac('sha256', SECRET).update(body).digest('base64url')
  // Constant-time compare; lengths must match first or timingSafeEqual throws.
  const a = Buffer.from(mac)
  const b = Buffer.from(expected)
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null
  try {
    return JSON.parse(Buffer.from(body, 'base64url').toString()) as Session
  } catch {
    return null
  }
}

export const SESSION_COOKIE = COOKIE

export function sessionFrom(req: FastifyRequest): Session | null {
  return verifySession(req.cookies?.[COOKIE])
}

export class Unauthorized extends Error {
  statusCode = 401
  constructor(msg = 'not signed in') {
    super(msg)
  }
}

export function requireSession(req: FastifyRequest): Session {
  const s = sessionFrom(req)
  if (!s) throw new Unauthorized()
  return s
}

/** Look up a user's roles so the cookie carries them for UI gating only. */
export async function rolesFor(tenantId: string, userId: string): Promise<string[]> {
  const rows = await sql<{ role: string }[]>`
    SELECT role FROM platform.user_role
    WHERE tenant_id = ${tenantId} AND user_id = ${userId}`
  return rows.map((r) => r.role)
}
