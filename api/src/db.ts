import postgres from 'postgres'

/**
 * Connection pool. Note the deliberate absence of any per-connection tenant
 * state: tenant context is set per TRANSACTION via SET LOCAL (see withTenant),
 * so a pooled connection handed to the next request carries nothing over.
 */
const common = {
  max: Number(process.env.PG_POOL_MAX ?? 10),
  idle_timeout: 30,
  connect_timeout: 10,
  onnotice: () => {},
  transform: { undefined: null },
} as const

// DATABASE_URL when a host hands you one (Docker, Supabase, Neon); otherwise the
// standard PG* variables, which also covers unix sockets that no URL parses.
export const sql = process.env.DATABASE_URL
  ? postgres(process.env.DATABASE_URL, common)
  : postgres({
      host: process.env.PGHOST ?? 'localhost',
      port: Number(process.env.PGPORT ?? 5432),
      database: process.env.PGDATABASE ?? 'schooldb',
      username: process.env.PGUSER ?? 'postgres',
      password: process.env.PGPASSWORD,
      ...common,
    })

export type Session = {
  tenantId: string
  userId: string
  roles: string[]
}

/**
 * Run a unit of work with database-enforced tenant and user scope.
 *
 * SET LOCAL (never SET) is the whole point: it is scoped to the transaction and
 * dies with it, so it cannot leak across a pooled connection into the next
 * request. Every RLS policy in 009_rls.sql reads these two settings.
 *
 * The role used here (app_rw) is NOT the table owner and does NOT have BYPASSRLS,
 * so a bug in this file cannot read another school's rows.
 */
export async function withTenant<T>(
  session: Session,
  fn: (tx: postgres.TransactionSql) => Promise<T>,
): Promise<T> {
  return sql.begin(async (tx) => {
    await tx.unsafe(`SET LOCAL ROLE app_rw`)
    await tx`SELECT set_config('app.tenant_id', ${session.tenantId}, true)`
    await tx`SELECT set_config('app.user_id', ${session.userId}, true)`
    return fn(tx)
  }) as Promise<T>
}

/**
 * Privileged work: migrations, tenant provisioning, imports that must create the
 * tenant itself. Bypasses RLS, so every caller is a deliberate, audited choice.
 */
export async function asOwner<T>(fn: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  return sql.begin(async (tx) => fn(tx)) as Promise<T>
}

export async function closeDb() {
  await sql.end({ timeout: 5 })
}
