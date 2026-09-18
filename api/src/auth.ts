import crypto from 'node:crypto'
import { promisify } from 'node:util'
import type { FastifyReply, FastifyRequest } from 'fastify'
import { sql, type Session } from './db.js'

const scrypt = promisify(crypto.scrypt) as (
  pw: crypto.BinaryLike, salt: crypto.BinaryLike, keylen: number, opts: crypto.ScryptOptions,
) => Promise<Buffer>

const SECRET = process.env.SESSION_SECRET ?? ''
const DEV = process.env.NODE_ENV !== 'production'
export const SESSION_COOKIE = 'sdb_session'

if (!DEV && (!SECRET || SECRET.includes('dev-only'))) {
  // Fail at boot, loudly. A production deploy running on the placeholder secret
  // is one forged cookie away from being any user in any school.
  throw new Error('SESSION_SECRET must be set to a real secret in production')
}
const KEY = SECRET || 'dev-only-insecure-secret-change-me'

// ---------------------------------------------------------------------------
// Password hashing. scrypt from node's own crypto: no dependency to audit, and
// memory-hard, so a leaked hash table is expensive to attack offline.
// ---------------------------------------------------------------------------
const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 32 } as const

export async function hashPassword(pw: string): Promise<string> {
  const salt = crypto.randomBytes(16)
  const hash = await scrypt(pw.normalize('NFKC'), salt, SCRYPT.keylen,
    { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p, maxmem: 64 * 1024 * 1024 })
  return ['scrypt', SCRYPT.N, SCRYPT.r, SCRYPT.p,
    salt.toString('base64url'), hash.toString('base64url')].join('$')
}

export async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [scheme, N, r, p, saltB64, hashB64] = stored.split('$')
  if (scheme !== 'scrypt' || !saltB64 || !hashB64) return false
  const expected = Buffer.from(hashB64, 'base64url')
  const actual = await scrypt(pw.normalize('NFKC'), Buffer.from(saltB64, 'base64url'),
    expected.length, { N: Number(N), r: Number(r), p: Number(p), maxmem: 64 * 1024 * 1024 })
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected)
}

export function passwordProblem(pw: string): string | null {
  if (pw.length < 12) return 'Use at least 12 characters.'
  if (pw.length > 200) return 'That is too long.'
  // Length beats character classes. A long passphrase is stronger than P@ssw0rd!
  // and far likelier to be remembered rather than written on a monitor.
  if (/^(.)\1+$/.test(pw)) return 'That is a single repeated character.'
  const common = ['password', '123456', 'qwerty', 'letmein', 'welcome', 'schooldb']
  if (common.some((c) => pw.toLowerCase().includes(c))) return 'That contains a very common word.'
  return null
}

// ---------------------------------------------------------------------------
// Tokens for invites and resets: random, and only the hash is ever stored.
// ---------------------------------------------------------------------------
export function newToken(): { token: string; hash: string } {
  const token = crypto.randomBytes(32).toString('base64url')
  return { token, hash: hashToken(token) }
}
export function hashToken(token: string): string {
  return crypto.createHash('sha256').update(token).digest('base64url')
}

// ---------------------------------------------------------------------------
// Session cookie
// ---------------------------------------------------------------------------
type Cookie = Session & { epoch: number; iat: number }

export function signSession(s: Cookie): string {
  const body = Buffer.from(JSON.stringify(s)).toString('base64url')
  const mac = crypto.createHmac('sha256', KEY).update(body).digest('base64url')
  return `${body}.${mac}`
}

function verifyCookie(token: string | undefined): Cookie | null {
  if (!token) return null
  const [body, mac] = token.split('.')
  if (!body || !mac) return null
  const expected = crypto.createHmac('sha256', KEY).update(body).digest('base64url')
  const a = Buffer.from(mac), b = Buffer.from(expected)
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null
  try {
    const c = JSON.parse(Buffer.from(body, 'base64url').toString()) as Cookie
    // 12 hours. A school laptop in a shared staffroom should not stay signed in
    // for a fortnight.
    if (!c.iat || Date.now() - c.iat > 12 * 3600 * 1000) return null
    return c
  } catch { return null }
}

export function setSessionCookie(reply: FastifyReply, s: Cookie) {
  reply.setCookie(SESSION_COOKIE, signSession(s), {
    httpOnly: true, sameSite: 'lax', path: '/', secure: !DEV, maxAge: 12 * 3600,
  })
}

export class HttpError extends Error {
  constructor(public statusCode: number, msg: string) { super(msg) }
}

/**
 * Validate the cookie against the database on every request.
 *
 * The epoch check is the cost of instant revocation: bumping app_user
 * .session_epoch signs that user out everywhere, immediately, with no
 * server-side session store to keep consistent. One indexed lookup per request
 * is a fair price for being able to lock an account and have it mean something.
 */
export async function loadSession(req: FastifyRequest): Promise<Session | null> {
  const c = verifyCookie(req.cookies?.[SESSION_COOKIE])
  if (!c) return null
  const [row] = await sql<{ session_epoch: number; is_active: boolean }[]>`
    SELECT session_epoch, is_active FROM platform.app_user WHERE id = ${c.userId}`
  if (!row || !row.is_active || row.session_epoch !== c.epoch) return null
  return { tenantId: c.tenantId, userId: c.userId, roles: c.roles }
}

export function requireSession(req: FastifyRequest): Session {
  const s = (req as FastifyRequest & { session?: Session }).session
  if (!s) throw new HttpError(401, 'not signed in')
  return s
}

/** Roles that operate the school-facing app. A student or guardian is not staff. */
export const STAFF_ROLES = ['school_admin', 'head_of_dept', 'teacher', 'tutor', 'dpo']
export const isStaff = (roles: string[]) => roles.some((r) => STAFF_ROLES.includes(r))

export function requireRole(req: FastifyRequest, ...roles: string[]): Session {
  const s = requireSession(req)
  if (!roles.some((r) => s.roles.includes(r))) {
    throw new HttpError(403, `requires one of: ${roles.join(', ')}`)
  }
  return s
}

export async function rolesFor(tenantId: string, userId: string): Promise<string[]> {
  const rows = await sql<{ role: string }[]>`
    SELECT role FROM platform.user_role WHERE tenant_id = ${tenantId} AND user_id = ${userId}`
  return rows.map((r) => r.role)
}

export async function issueSession(reply: FastifyReply, userId: string): Promise<Session> {
  const [u] = await sql<{ tenant_id: string; session_epoch: number }[]>`
    SELECT tenant_id, session_epoch FROM platform.app_user WHERE id = ${userId}`
  if (!u) throw new HttpError(404, 'no such user')
  const roles = await rolesFor(u.tenant_id, userId)
  setSessionCookie(reply, {
    tenantId: u.tenant_id, userId, roles, epoch: u.session_epoch, iat: Date.now(),
  })
  return { tenantId: u.tenant_id, userId, roles }
}
