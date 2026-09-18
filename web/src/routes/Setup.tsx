import { useEffect, useMemo, useState } from 'react'
import { api } from '../lib/api'

/**
 * First run. The screen that decides whether a school ever gets as far as
 * having data in this product, so it explains rather than validates: the slug
 * is described before it is demanded, and the password rule is stated BEFORE
 * anyone can fail it.
 */

const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,62}$/

/** Common markets first; the schema stores any ISO-3166 alpha-2. */
const COUNTRIES: [string, string][] = [
  ['GR', 'Greece'], ['GB', 'United Kingdom'], ['CY', 'Cyprus'], ['IE', 'Ireland'],
  ['DE', 'Germany'], ['FR', 'France'], ['NL', 'Netherlands'], ['CH', 'Switzerland'],
  ['ES', 'Spain'], ['IT', 'Italy'], ['AE', 'United Arab Emirates'], ['SG', 'Singapore'],
  ['US', 'United States'],
]

const MIN_PASSWORD = 12

function slugify(name: string): string {
  return name
    .normalize('NFD').replace(/[̀-ͯ]/g, '')   // strip accents, keep the letter
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 63)
}

/** September starts the year almost everywhere this product is sold. */
function defaultYear(): { label: string; start: string; end: string } {
  const now = new Date()
  const y = now.getMonth() >= 7 ? now.getFullYear() : now.getFullYear() - 1
  return { label: `${y}-${y + 1}`, start: `${y}-09-01`, end: `${y + 1}-06-30` }
}

function Ok({ children }: { children: React.ReactNode }) {
  return (
    <span className="pill good">
      <span className="glyph" aria-hidden="true">✓</span>{children}
    </span>
  )
}
function Problem({ children }: { children: React.ReactNode }) {
  return (
    <span className="pill critical">
      <span className="glyph" aria-hidden="true">▲</span>{children}
    </span>
  )
}

const STEPS = ['School', 'Academic year', 'Administrator']

export default function Setup({ onDone }: { onDone?: () => void }) {
  const [state, setState] = useState<'checking' | 'needed' | 'done' | 'already'>('checking')
  const [step, setStep] = useState(0)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const year0 = useMemo(defaultYear, [])
  const [schoolName, setSchoolName] = useState('')
  const [slug, setSlug] = useState('')
  const [slugTouched, setSlugTouched] = useState(false)
  const [country, setCountry] = useState('GR')
  const [otherCountry, setOtherCountry] = useState('')
  const [yearLabel, setYearLabel] = useState(year0.label)
  const [yearStart, setYearStart] = useState(year0.start)
  const [yearEnd, setYearEnd] = useState(year0.end)
  const [adminName, setAdminName] = useState('')
  const [adminEmail, setAdminEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [showPassword, setShowPassword] = useState(false)

  useEffect(() => {
    api.get<{ needed: boolean }>('/setup/needed')
      .then((r) => setState(r.needed ? 'needed' : 'already'))
      .catch((e) => { setErr((e as Error).message); setState('needed') })
  }, [])

  // The slug follows the name until the moment someone edits it themselves.
  useEffect(() => { if (!slugTouched) setSlug(slugify(schoolName)) }, [schoolName, slugTouched])

  const countryCode = country === 'OTHER' ? otherCountry.toUpperCase() : country
  const slugValid = SLUG_RE.test(slug)
  const countryValid = /^[A-Z]{2}$/.test(countryCode)
  const datesValid = yearStart !== '' && yearEnd !== '' && yearEnd > yearStart
  const emailValid = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(adminEmail)
  const passwordLongEnough = password.length >= MIN_PASSWORD
  const passwordsMatch = password !== '' && password === confirm

  const stepOk = [
    schoolName.trim().length >= 2 && slugValid && countryValid,
    yearLabel.trim().length >= 4 && datesValid,
    adminName.trim().length >= 2 && emailValid && passwordLongEnough && passwordsMatch,
  ]

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (!stepOk[2]) return
    setBusy(true); setErr(null)
    try {
      await api.post('/setup', {
        school_name: schoolName.trim(),
        slug,
        country_code: countryCode,
        admin_name: adminName.trim(),
        admin_email: adminEmail.trim(),
        admin_password: password,
        academic_year: yearLabel.trim(),
        year_start: yearStart,
        year_end: yearEnd,
      })
      setState('done')
      // The response set a session cookie. A full navigation is the simplest
      // way to have every screen pick it up.
      if (onDone) onDone()
      else window.location.assign('/')
    } catch (e) {
      setErr((e as Error).message)
      setBusy(false)
    }
  }

  if (state === 'checking') return <div className="empty">Checking…</div>

  if (state === 'already') {
    return (
      <div className="main" style={{ maxWidth: 520 }}>
        <div className="card">
          <header><h1>Already set up</h1></header>
          <p className="secondary">
            This installation already has a school in it, so first-run setup is closed. It stays
            closed: it is the one screen that can create a school without being signed in.
          </p>
          <p><a href="/">Go to sign in</a></p>
        </div>
      </div>
    )
  }

  if (state === 'done') {
    return (
      <div className="main" style={{ maxWidth: 520 }}>
        <div className="card">
          <header><h1>{schoolName} is set up</h1></header>
          <p className="secondary">Signing you in…</p>
        </div>
      </div>
    )
  }

  return (
    <div className="main" style={{ maxWidth: 560 }}>
      <form className="card" onSubmit={submit}>
        <header>
          <h1>Set up your school</h1>
          <span className="sub">Step {step + 1} of 3 · {STEPS[step]}</span>
        </header>

        {/* Progress as three ruled segments: position is shown by form, not by
            colour alone, and each segment is named. */}
        <div className="row" style={{ gap: 6, marginBottom: 16 }} aria-hidden="true">
          {STEPS.map((s, i) => (
            <span key={s} style={{
              flex: 1, height: 3, borderRadius: 2,
              background: i <= step ? 'var(--accent)' : 'var(--rule)',
            }} />
          ))}
        </div>

        {err && <p className="err" role="alert">{err}</p>}

        {step === 0 && (
          <div className="stack" style={{ gap: 14 }}>
            <label className="stack" style={{ gap: 5 }}>
              <span className="secondary">School name</span>
              <input value={schoolName} autoFocus required
                     onChange={(e) => setSchoolName(e.target.value)}
                     placeholder="International Metropolitan School" />
            </label>

            <label className="stack" style={{ gap: 5 }}>
              <span className="secondary">Short name for web addresses</span>
              <input value={slug} spellCheck={false}
                     onChange={(e) => { setSlugTouched(true); setSlug(e.target.value) }} />
            </label>
            <p className="note" style={{ margin: 0 }}>
              This is the short version of your school’s name that appears in links and in
              exports — lower-case letters, numbers and hyphens only, no spaces. It is filled in
              from the name above; change it if you want something shorter. It cannot be changed
              afterwards, because other things will point at it.
              <br />
              {slug === '' ? (
                <span className="muted">Nothing yet.</span>
              ) : slugValid ? (
                <Ok>{slug}</Ok>
              ) : (
                <Problem>
                  {slug.length < 2 ? 'Too short — at least 2 characters'
                    : 'Use lower-case letters, numbers and hyphens; start with a letter or number'}
                </Problem>
              )}
            </p>

            <label className="stack" style={{ gap: 5 }}>
              <span className="secondary">Country</span>
              <select value={country} onChange={(e) => setCountry(e.target.value)}>
                {COUNTRIES.map(([code, name]) => <option key={code} value={code}>{name}</option>)}
                <option value="OTHER">Somewhere else…</option>
              </select>
            </label>
            {country === 'OTHER' && (
              <label className="stack" style={{ gap: 5 }}>
                <span className="secondary">Two-letter country code</span>
                <input value={otherCountry} maxLength={2} style={{ maxWidth: 90 }}
                       onChange={(e) => setOtherCountry(e.target.value.toUpperCase())}
                       placeholder="PT" />
              </label>
            )}
            <p className="muted" style={{ margin: 0, fontSize: 'var(--t-small)' }}>
              Used for date and grade conventions. It does not decide where the data is hosted.
            </p>
          </div>
        )}

        {step === 1 && (
          <div className="stack" style={{ gap: 14 }}>
            <label className="stack" style={{ gap: 5 }}>
              <span className="secondary">What this year is called</span>
              <input value={yearLabel} onChange={(e) => setYearLabel(e.target.value)} autoFocus />
            </label>
            <div className="row" style={{ gap: 14, alignItems: 'flex-start' }}>
              <label className="stack" style={{ gap: 5 }}>
                <span className="secondary">First day</span>
                <input type="date" value={yearStart} onChange={(e) => setYearStart(e.target.value)} />
              </label>
              <label className="stack" style={{ gap: 5 }}>
                <span className="secondary">Last day</span>
                <input type="date" value={yearEnd} onChange={(e) => setYearEnd(e.target.value)} />
              </label>
            </div>
            {!datesValid && (yearStart !== '' && yearEnd !== '') && (
              <Problem>The last day has to be after the first day</Problem>
            )}
            <p className="note" style={{ margin: 0 }}>
              Terms, half-terms and τετράμηνα are added later and are optional. Marks work from
              day one with nothing but a date — every layer of structure above that is something
              you can add when it earns its keep.
            </p>
          </div>
        )}

        {step === 2 && (
          <div className="stack" style={{ gap: 14 }}>
            <label className="stack" style={{ gap: 5 }}>
              <span className="secondary">Your name</span>
              <input value={adminName} autoFocus required autoComplete="name"
                     onChange={(e) => setAdminName(e.target.value)} placeholder="Dimitris Kamoutsis" />
            </label>
            <label className="stack" style={{ gap: 5 }}>
              <span className="secondary">Your email</span>
              <input type="email" value={adminEmail} required autoComplete="username"
                     onChange={(e) => setAdminEmail(e.target.value)} />
            </label>

            {/* The rule, stated before anyone can fail it. People expect to be
                nagged for a symbol; when nothing nags them they assume the
                field is broken. So say what the rule is and why. */}
            <p className="note" style={{ margin: 0 }}>
              <strong>Your password needs {MIN_PASSWORD} characters. That is the whole rule.</strong>
              <br />
              No capital, no digit, no symbol is required — length beats character classes, and a
              passphrase you can remember beats <span className="kbd">P@ssw0rd!</span> written on a
              monitor. Four ordinary words will do.
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
              <button type="button" className="ghost"
                      onClick={() => setShowPassword((v) => !v)}>
                {showPassword ? 'Hide password' : 'Show password'}
              </button>
              <span className="spacer" style={{ marginLeft: 'auto' }} />
              {password === '' ? null : passwordLongEnough
                ? <Ok>Long enough</Ok>
                : <Problem>{MIN_PASSWORD - password.length} more character(s)</Problem>}
              {confirm !== '' && !passwordsMatch && <Problem>The two do not match</Problem>}
            </div>

            <p className="muted" style={{ margin: 0, fontSize: 'var(--t-small)' }}>
              This account is the school administrator: it can invite staff, import data and see
              every student. Everyone else gets in by invitation — there is no public sign-up,
              because this database holds information about children.
            </p>
          </div>
        )}

        <div className="row" style={{ marginTop: 18 }}>
          {step > 0 && (
            <button type="button" onClick={() => { setErr(null); setStep(step - 1) }}>Back</button>
          )}
          <span className="spacer" style={{ marginLeft: 'auto' }} />
          {step < 2 ? (
            <button type="button" className="primary" disabled={!stepOk[step]}
                    onClick={() => { setErr(null); setStep(step + 1) }}>
              Next
            </button>
          ) : (
            <button type="submit" className="primary" disabled={busy || !stepOk[2]}>
              {busy ? 'Creating…' : `Create ${schoolName || 'school'}`}
            </button>
          )}
        </div>
      </form>
    </div>
  )
}
