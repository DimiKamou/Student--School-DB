import Fastify from 'fastify'
import cookie from '@fastify/cookie'
import cors from '@fastify/cors'
import { closeDb, type Session } from './db.js'
import { loadSession } from './auth.js'
import { registerAuthRoutes } from './routes/auth.js'
import { registerTeachingRoutes } from './routes/teaching.js'
import { registerMarksRoutes } from './routes/marks.js'
import { registerInsightRoutes } from './routes/insights.js'

const app = Fastify({
  logger: { level: process.env.LOG_LEVEL ?? 'info' },
  // Marks arrive in batches of a few hundred cells; the default 1MB is ample
  // but we state it rather than leave it implicit.
  bodyLimit: 2 * 1024 * 1024,
})

await app.register(cors, {
  origin: process.env.WEB_ORIGIN ?? 'http://localhost:5173',
  credentials: true,
})
await app.register(cookie)

// Validate the session ONCE per request and hand it to every handler, so no
// route can forget to check and no route pays for checking twice.
app.decorateRequest('session', null)
app.addHook('preHandler', async (req) => {
  ;(req as typeof req & { session: Session | null }).session = await loadSession(req)
})

app.setErrorHandler((err, _req, reply) => {
  const status = (err as { statusCode?: number }).statusCode ?? 500
  if (status >= 500) app.log.error(err)
  reply.status(status).send({ error: err.message ?? 'internal error' })
})

app.get('/health', async () => ({ ok: true }))

await registerAuthRoutes(app)
await registerTeachingRoutes(app)
await registerMarksRoutes(app)
await registerInsightRoutes(app)

const port = Number(process.env.PORT ?? 3001)
await app.listen({ port, host: '0.0.0.0' })

for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, async () => {
    await app.close()
    await closeDb()
    process.exit(0)
  })
}
