import { useEffect, useState } from 'react'
import { api, type DevUser } from '../lib/api'

/** Development sign-in. Production swaps this for a magic link or school SSO. */
export default function Login({ onSignedIn }: { onSignedIn: (me: any) => void }) {
  const [users, setUsers] = useState<DevUser[]>([])
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    api.get<DevUser[]>('/auth/dev-users').then(setUsers).catch((e) => setErr(e.message))
  }, [])

  async function signIn(userId: string) {
    try {
      await api.post('/auth/dev-login', { userId })
      onSignedIn(await api.get('/me'))
    } catch (e) { setErr((e as Error).message) }
  }

  return (
    <div className="main" style={{ maxWidth: 480, marginTop: 64 }}>
      <div className="card stack">
        <header><h1>Sign in</h1></header>
        {err && <p className="err">{err}</p>}
        <p className="muted" style={{ marginTop: -6 }}>
          Development sign-in. Pick an account to see what that person is allowed to see —
          the database enforces it, not the UI.
        </p>
        {users.length === 0 && !err && <p className="muted">No accounts found. Has the database been seeded?</p>}
        <div className="stack" style={{ gap: 8 }}>
          {users.map((u) => (
            <button key={u.user_id} onClick={() => signIn(u.user_id)}
                    style={{ textAlign: 'left', padding: '10px 13px' }}>
              <strong>{u.display_name}</strong>
              <span className="muted"> · {u.roles.filter(Boolean).join(', ') || 'no roles'}</span>
              <div className="muted" style={{ fontSize: 12 }}>{u.tenant_name}</div>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}
