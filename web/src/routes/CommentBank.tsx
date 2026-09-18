import { useEffect, useMemo, useRef, useState } from 'react'
import { api } from '../lib/api'
import './reports.css'

/* ---------------------------------------------------------------------------
 * Types for this slice. teach.comment_bank as the API returns it.
 * ------------------------------------------------------------------------- */
export type Band = 'excellent' | 'secure' | 'developing' | 'concern'

export type BankComment = {
  id: string
  owner_id: string | null
  subject_id: string | null
  subject_name: string | null
  band: Band | null
  body: string
  times_used: number
  is_shared: boolean
  created_at: string
  is_mine: boolean
  owner_name: string | null
}

export type SubjectOption = { id: string; name: string; code: string }

export const BANDS: Band[] = ['excellent', 'secure', 'developing', 'concern']

/**
 * The placeholders teach.merge_comment() understands.
 *
 * The pronoun three are filled from teach.student_pronoun, and default to
 * they/them where a school has not recorded a student's pronouns. That default
 * is stated everywhere it can bite, because the failure mode — a report card
 * that misgenders a child — is not one a teacher should discover in print.
 */
export const PLACEHOLDERS: { token: string; fills: string }[] = [
  { token: '{first_name}', fills: 'preferred name, else given name' },
  { token: '{they}', fills: 'subject pronoun — they by default' },
  { token: '{them}', fills: 'object pronoun — them by default' },
  { token: '{their}', fills: 'possessive — their by default' },
  { token: '{grade}', fills: 'you supply this when inserting' },
  { token: '{topic}', fills: 'you supply this when inserting' },
]

/**
 * Attainment band badge.
 *
 * Same contract as components/Pill.tsx: the colour never carries the meaning on
 * its own — every badge ships a glyph and the word, so it survives
 * colour-blindness, a greyscale report print and forced-colors mode.
 */
const BAND_STYLE: Record<Band, { tone: string; glyph: string; title: string }> = {
  excellent: { tone: 'good', glyph: '✓', title: 'For work comfortably above expectation.' },
  secure: { tone: 'neutral', glyph: '●', title: 'For work meeting expectation.' },
  developing: { tone: 'warning', glyph: '◐', title: 'For work approaching expectation.' },
  concern: { tone: 'critical', glyph: '▲', title: 'For work that needs a conversation.' },
}

export function BandPill({ band }: { band: Band | string | null | undefined }) {
  if (!band) return null
  const b = BAND_STYLE[band as Band]
  if (!b) return <span className="pill neutral"><span className="glyph" aria-hidden="true">·</span>{band}</span>
  return (
    <span className={`pill ${b.tone}`} title={b.title}>
      <span className="glyph" aria-hidden="true">{b.glyph}</span>
      {band}
    </span>
  )
}

type Draft = {
  id: string | null
  body: string
  subject_id: string
  band: '' | Band
  is_shared: boolean
}

const EMPTY: Draft = { id: null, body: '', subject_id: '', band: '', is_shared: false }

export default function CommentBank() {
  const [items, setItems] = useState<BankComment[]>([])
  const [subjects, setSubjects] = useState<SubjectOption[]>([])
  const [subject, setSubject] = useState('')
  const [band, setBand] = useState<'' | Band>('')
  const [scope, setScope] = useState<'all' | 'mine' | 'shared'>('all')
  const [q, setQ] = useState('')
  const [draft, setDraft] = useState<Draft | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const bodyRef = useRef<HTMLTextAreaElement | null>(null)

  const query = useMemo(() => {
    const p = new URLSearchParams()
    if (subject) p.set('subject_id', subject)
    if (band) p.set('band', band)
    if (scope !== 'all') p.set('scope', scope)
    if (q.trim()) p.set('q', q.trim())
    const s = p.toString()
    return s ? `?${s}` : ''
  }, [subject, band, scope, q])

  async function load() {
    try {
      setItems(await api.get<BankComment[]>(`/comment-bank${query}`))
      setErr(null)
    } catch (e) { setErr((e as Error).message) }
  }

  useEffect(() => {
    api.get<SubjectOption[]>('/comment-bank/subjects').then(setSubjects).catch(() => setSubjects([]))
  }, [])
  // Debounced so typing in the search box does not fire a request per keystroke.
  useEffect(() => {
    const t = setTimeout(() => { void load() }, 180)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query])

  function insertToken(token: string) {
    const el = bodyRef.current
    setDraft((d) => {
      if (!d) return d
      if (!el) return { ...d, body: d.body + token }
      const start = el.selectionStart ?? d.body.length
      const end = el.selectionEnd ?? start
      const next = d.body.slice(0, start) + token + d.body.slice(end)
      // Put the caret after the token, so a teacher can keep typing.
      requestAnimationFrame(() => {
        el.focus()
        el.setSelectionRange(start + token.length, start + token.length)
      })
      return { ...d, body: next }
    })
  }

  async function save() {
    if (!draft || !draft.body.trim()) return
    setBusy(true)
    try {
      const payload = {
        body: draft.body.trim(),
        subject_id: draft.subject_id || null,
        band: draft.band || null,
        is_shared: draft.is_shared,
      }
      if (draft.id) await api.post(`/comment-bank/${draft.id}`, payload)
      else await api.post('/comment-bank', payload)
      setDraft(null)
      setFlash(draft.id ? 'Saved' : 'Added to your bank')
      setTimeout(() => setFlash(null), 2500)
      await load()
    } catch (e) { setErr((e as Error).message) } finally { setBusy(false) }
  }

  async function remove(c: BankComment) {
    if (!confirm('Delete this comment? Reports already written keep their text.')) return
    try {
      await api.post(`/comment-bank/${c.id}/delete`)
      await load()
    } catch (e) { setErr((e as Error).message) }
  }

  async function toggleShare(c: BankComment) {
    try {
      await api.post(`/comment-bank/${c.id}`, {
        body: c.body,
        subject_id: c.subject_id,
        band: c.band,
        is_shared: !c.is_shared,
      })
      await load()
    } catch (e) { setErr((e as Error).message) }
  }

  const mine = items.filter((c) => c.is_mine).length

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <div className="row">
        <h1>Comment bank</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        {flash && <span className="saved-flash">{flash}</span>}
        <button className="primary" onClick={() => setDraft({ ...EMPTY })}>New comment</button>
      </div>

      <div className="note">
        Placeholders are filled per student when you insert a comment into a report.
        Where a student’s pronouns have not been recorded, <strong>they/them is used</strong> —
        a deliberate default rather than a guess from the name, and the report screen says
        so on every comment it fills that way.
      </div>

      {draft && (
        <section className="card">
          <header>
            <h2>{draft.id ? 'Edit comment' : 'New comment'}</h2>
            <span className="sub">Write it once. It merges itself for every student afterwards.</span>
          </header>

          <div className="rep-box">
            <textarea
              ref={bodyRef}
              value={draft.body}
              placeholder="{first_name} has worked steadily this term. {they} handles {topic} with confidence and should now push {their} written explanations further."
              onChange={(e) => setDraft({ ...draft, body: e.target.value })}
            />
            <div className="row" style={{ gap: 6 }}>
              <span className="muted" style={{ fontSize: 'var(--t-micro)' }}>Insert:</span>
              {PLACEHOLDERS.map((p) => (
                <button key={p.token} type="button" className="ph" title={`Filled from: ${p.fills}`}
                        onClick={() => insertToken(p.token)}>
                  {p.token}
                </button>
              ))}
            </div>

            <div className="rep-toolbar">
              <label>
                Subject{' '}
                <select value={draft.subject_id}
                        onChange={(e) => setDraft({ ...draft, subject_id: e.target.value })}>
                  <option value="">Any subject</option>
                  {subjects.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </select>
              </label>
              <label>
                Band{' '}
                <select value={draft.band}
                        onChange={(e) => setDraft({ ...draft, band: e.target.value as '' | Band })}>
                  <option value="">No band</option>
                  {BANDS.map((b) => <option key={b} value={b}>{b}</option>)}
                </select>
              </label>
              <label style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                <input type="checkbox" checked={draft.is_shared}
                       onChange={(e) => setDraft({ ...draft, is_shared: e.target.checked })} />
                Share with the department
              </label>
              <span style={{ marginLeft: 'auto' }} />
              <button onClick={() => setDraft(null)}>Cancel</button>
              <button className="primary" disabled={busy || !draft.body.trim()} onClick={save}>
                {busy ? 'Saving…' : 'Save'}
              </button>
            </div>
          </div>
        </section>
      )}

      <section className="card">
        <header>
          <h2>Your comments</h2>
          <span className="sub">
            {items.length} visible · {mine} yours · the rest shared by colleagues
          </span>
        </header>

        <div className="rep-toolbar" style={{ marginBottom: 12 }}>
          <input value={q} onChange={(e) => setQ(e.target.value)}
                 placeholder="Search text…" style={{ flex: '1 1 180px', minWidth: 0 }} />
          <select value={subject} onChange={(e) => setSubject(e.target.value)}>
            <option value="">All subjects</option>
            {subjects.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
          <select value={band} onChange={(e) => setBand(e.target.value as '' | Band)}>
            <option value="">All bands</option>
            {BANDS.map((b) => <option key={b} value={b}>{b}</option>)}
          </select>
          <select value={scope} onChange={(e) => setScope(e.target.value as 'all' | 'mine' | 'shared')}>
            <option value="all">Mine and shared</option>
            <option value="mine">Mine only</option>
            <option value="shared">Shared only</option>
          </select>
        </div>

        {items.length === 0 ? (
          <div className="empty">
            Nothing here yet. Write one comment with placeholders and it fills itself
            for every student for the rest of the year.
          </div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Comment</th>
                  <th>Subject</th>
                  <th>Band</th>
                  <th align="right">Used</th>
                  <th>Shared</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {items.map((c) => (
                  <tr key={c.id}>
                    <td>
                      <div className="bank-body">{c.body}</div>
                      {!c.is_mine && (
                        <div className="muted" style={{ fontSize: 'var(--t-micro)', marginTop: 3 }}>
                          from {c.owner_name ?? 'the school'}
                        </div>
                      )}
                    </td>
                    <td className="secondary">{c.subject_name ?? 'Any'}</td>
                    <td><BandPill band={c.band} /></td>
                    <td className="num">{Number(c.times_used)}</td>
                    <td className="secondary" style={{ fontSize: 'var(--t-small)' }}>
                      {c.is_shared || c.owner_id === null ? 'Department' : 'Private'}
                    </td>
                    <td>
                      {c.is_mine ? (
                        <div className="row" style={{ gap: 4, flexWrap: 'nowrap' }}>
                          <button className="ghost" onClick={() => setDraft({
                            id: c.id, body: c.body, subject_id: c.subject_id ?? '',
                            band: c.band ?? '', is_shared: c.is_shared,
                          })}>Edit</button>
                          <button className="ghost" onClick={() => toggleShare(c)}>
                            {c.is_shared ? 'Unshare' : 'Share'}
                          </button>
                          <button className="ghost" onClick={() => remove(c)}>Delete</button>
                        </div>
                      ) : (
                        <span className="muted" style={{ fontSize: 'var(--t-micro)' }}>read-only</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="card">
        <header>
          <h2>What each placeholder fills with</h2>
        </header>
        <table>
          <thead><tr><th>Placeholder</th><th>Filled from</th></tr></thead>
          <tbody>
            {PLACEHOLDERS.map((p) => (
              <tr key={p.token}>
                <td><span className="ph" style={{ cursor: 'default' }}>{p.token}</span></td>
                <td className="secondary">{p.fills}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </div>
  )
}
