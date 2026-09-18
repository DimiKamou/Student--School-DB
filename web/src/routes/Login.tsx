import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { api } from '../lib/api'

export default function Login({ onSignedIn }: { onSignedIn: (me: unknown) => void }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [setupNeeded, setSetupNeeded] = useState(false)
  const nav = useNavigate()

  useEffect(() => {
    api.get<{ needed: boolean }>('/setup/needed')
      .then((r) => setSetupNeeded(r.needed))
      .catch(() => {})
  }, [])

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true); setErr(null)
    try {
      await api.post('/auth/login', { email, password })
      onSignedIn(await api.get('/me'))
      nav('/')
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  if (setupNeeded) {
    return (
      <div className="main" style={{ maxWidth: 460, marginTop: 72 }}>
        <div className="card stack">
          <h1>No school set up yet</h1>
          <p className="secondary" style={{ margin: 0 }}>
            This installation is brand new. Create your school and the first administrator account.
          </p>
          <Link className="btn primary" to="/setup"
                style={{ textAlign: 'center', background: 'var(--series-1)',
                         borderColor: 'var(--series-1)', color: '#fff' }}>
            Set up your school
          </Link>
        </div>
      </div>
    )
  }

  return (
    <div className="main" style={{ maxWidth: 420, marginTop: 72 }}>
      <form className="card stack" onSubmit={submit}>
        <h1>Sign in</h1>
        {err && <p className="err" role="alert" style={{ margin: 0 }}>{err}</p>}
        <label className="stack" style={{ gap: 5 }}>
          <span className="secondary">Email</span>
          <input type="email" autoComplete="username" required value={email}
                 onChange={(e) => setEmail(e.target.value)} autoFocus />
        </label>
        <label className="stack" style={{ gap: 5 }}>
          <span className="secondary">Password</span>
          <input type="password" autoComplete="current-password" required value={password}
                 onChange={(e) => setPassword(e.target.value)} />
        </label>
        <button className="primary" type="submit" disabled={busy || !email || !password}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        <p className="muted" style={{ margin: 0, fontSize: 12 }}>
          Accounts are created by invitation from your school administrator. There is no public
          sign-up — this database holds information about children.
        </p>
      </form>
    </div>
  )
}
