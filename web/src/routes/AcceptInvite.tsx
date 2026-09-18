import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { api } from '../lib/api'

/**
 * Accepting an invitation. The only way into this product other than first-run
 * setup — nobody self-registers into a database of children.
 *
 * The failure case matters more than the happy one: an expired or already-used
 * link is the single most likely thing a new member of staff meets, and if it
 * reads like a crash they email the head of IT instead of asking for another
 * invitation.
 */

const MIN_PASSWORD = 12

type Invite = {
  email: string
  display_name: string | null
  tenant_name: string
  roles: string[]
}

const ROLE_WORDS: Record<string, string> = {
  school_admin: 'school administrator',
  head_of_dept: 'head of department',
  teacher: 'teacher',
  tutor: 'tutor',
  dpo: 'data protection officer',
}

function humanRoles(roles: string[]): string {
  const words = roles.map((r) => ROLE_WORDS[r] ?? r.replace(/_/g, ' '))
  if (words.length <= 1) return words[0] ?? 'member of staff'
  return `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`
}

export default function AcceptInvite({ onAccepted }: { onAccepted?: () => void }) {
  const [params] = useSearchParams()
  const token = params.get('token') ?? ''

  const [invite, setInvite] = useState<Invite | null>(null)
  const [status, setStatus] = useState<'loading' | 'ready' | 'unusable' | 'done'>('loading')
  const [problem, setProblem] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const [name, setName] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [showPassword, setShowPassword] = useState(false)

  useEffect(() => {
    if (!token) {
      setProblem('This link has no invitation code in it.')
      setStatus('unusable')
      return
    }
    api.get<Invite>(`/invites/preview?token=${encodeURIComponent(token)}`)
      .then((inv) => {
        setInvite(inv)
        setName(inv.display_name ?? '')
        setStatus('ready')
      })
      .catch((e) => {
        setProblem((e as Error).message)
        setStatus('unusable')
      })
  }, [token])

  const longEnough = password.length >= MIN_PASSWORD
  const matches = password !== '' && password === confirm
  const canSubmit = longEnough && matches && name.trim().length >= 2

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (!canSubmit) return
    setBusy(true); setErr(null)
    try {
      await api.post('/invites/accept', { token, password, display_name: name.trim() })
      setStatus('done')
      if (onAccepted) onAccepted()
      else window.location.assign('/')
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }

  if (status === 'loading') return <div className="empty">Checking your invitation…</div>

  if (status === 'unusable') {
    return (
      <div className="main" style={{ maxWidth: 520 }}>
        <div className="card">
          <header><h1>This invitation can’t be used</h1></header>
          <p className="secondary" style={{ marginTop: 0 }}>
            {problem ?? 'That invitation has expired or has already been used.'}
          </p>
          <p className="secondary">
            Invitations are single-use and expire, which is deliberate: a link that opens an
            account in a school’s student records should not sit working in an inbox for months.
          </p>
          <p className="note">
            Ask whoever invited you to send a new one — they can do it in seconds from the staff
            list. If you have already set your password, you don’t need this link at all:{' '}
            <a href="/">sign in</a>.
          </p>
        </div>
      </div>
    )
  }

  if (status === 'done') {
    return (
      <div className="main" style={{ maxWidth: 520 }}>
        <div className="card">
          <header><h1>Welcome</h1></header>
          <p className="secondary">Signing you in…</p>
        </div>
      </div>
    )
  }

  return (
    <div className="main" style={{ maxWidth: 520 }}>
      <form className="card" onSubmit={submit}>
        <header>
          <h1>{invite?.display_name ? `Hello, ${invite.display_name}` : 'Set up your account'}</h1>
          <span className="sub">{invite?.email}</span>
        </header>

        <p className="secondary" style={{ marginTop: 0 }}>
          <strong>{invite?.tenant_name}</strong> has invited you to join as{' '}
          {humanRoles(invite?.roles ?? [])}. Choose a password and you’re in.
        </p>

        {err && <p className="err" role="alert">{err}</p>}

        <div className="stack" style={{ gap: 14 }}>
          <label className="stack" style={{ gap: 5 }}>
            <span className="secondary">Your name, as colleagues will see it</span>
            <input value={name} required autoComplete="name" autoFocus
                   onChange={(e) => setName(e.target.value)} />
          </label>

          {/* Stated before it can be failed. People expect to be nagged for a
              symbol; silence where they expect nagging reads as a broken form. */}
          <p className="note" style={{ margin: 0 }}>
            <strong>Your password needs {MIN_PASSWORD} characters. That is the whole rule.</strong>
            <br />
            No capital, no digit, no symbol required — length beats character classes, and a
            passphrase you can actually remember beats one you write down.
          </p>

          <label className="stack" style={{ gap: 5 }}>
            <span className="secondary">Password</span>
            <input type={showPassword ? 'text' : 'password'} value={password} required
                   autoComplete="new-password" onChange={(e) => setPassword(e.target.value)} />
          </label>
          <label className="stack" style={{ gap: 5 }}>
            <span className="secondary">Password again</span>
            <input type={showPassword ? 'text' : 'password'} value={confirm} required
                   autoComplete="new-password" onChange={(e) => setConfirm(e.target.value)} />
          </label>

          <div className="row">
            <button type="button" className="ghost" onClick={() => setShowPassword((v) => !v)}>
              {showPassword ? 'Hide password' : 'Show password'}
            </button>
            <span className="spacer" style={{ marginLeft: 'auto' }} />
            {password === '' ? null : longEnough ? (
              <span className="pill good">
                <span className="glyph" aria-hidden="true">✓</span>Long enough
              </span>
            ) : (
              <span className="pill critical">
                <span className="glyph" aria-hidden="true">▲</span>
                {MIN_PASSWORD - password.length} more character(s)
              </span>
            )}
            {confirm !== '' && !matches && (
              <span className="pill critical">
                <span className="glyph" aria-hidden="true">▲</span>The two do not match
              </span>
            )}
          </div>

          <button className="primary" type="submit" disabled={busy || !canSubmit}>
            {busy ? 'Creating your account…' : 'Create my account'}
          </button>

          <p className="muted" style={{ margin: 0, fontSize: 'var(--t-small)' }}>
            What you can see is decided by the database, not by this screen: as a teacher you get
            the students you teach, and nobody else’s.
          </p>
        </div>
      </form>
    </div>
  )
}
