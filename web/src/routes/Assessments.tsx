import { useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { api, fmtDate, type Group } from '../lib/api'

/**
 * EVERY ASSESSMENT THIS TEACHER OWNS, AND HOW FAR THROUGH MARKING IT IS.
 *
 * "Still to mark" on Today is deliberately short — a capped list of what is
 * urgent. This is the full ledger behind it, and it answers the other question
 * a teacher actually has in June: what did I set this year, and did I finish it.
 *
 * Progress is counted against the REGISTER, not against rows in the marks
 * table, for the same reason teach.v_marking_todo does: with no result rows an
 * assessment would otherwise report itself complete, and a screen that says
 * "nothing outstanding" because nothing was ever entered is worse than no
 * screen at all.
 */

type AssessmentRow = {
  id: string
  title: string
  kind: string
  occurred_on: string
  max_total: string | null
  teaching_group_id: string
  marking_closed_at: string | null
  closed: boolean
  group_label: string
  subject_name: string
  topic_label: string | null
  blueprint_name: string | null
  days_since: number
  n_items: string
  students_expected: string
  students_marked: string
}

type Filter = 'all' | 'outstanding' | 'done'

type Progress = {
  expected: number
  marked: number
  outstanding: number
  /** No register, no denominator. Reported, never guessed at. */
  measurable: boolean
}

function progressOf(a: AssessmentRow): Progress {
  const expected = Number(a.students_expected)
  const marked = Number(a.students_marked)
  return {
    expected,
    marked,
    outstanding: Math.max(0, expected - marked),
    measurable: expected > 0,
  }
}

/**
 * A status chip. Colour never carries the meaning on its own: glyph, word and
 * colour always travel together, exactly as in Pill.tsx.
 */
function MarkingStatus({ a }: { a: AssessmentRow }) {
  const p = progressOf(a)
  const spec = !p.measurable
    ? { tone: 'neutral', glyph: '·', label: 'No one enrolled',
        title: 'This class has no current enrolments, so there is no denominator to measure marking against.' }
    : a.closed
      ? { tone: 'neutral', glyph: '✓', label: 'Closed',
          title: 'You marked this finished. Purely informational — no analytic filters on it.' }
      : p.outstanding === 0
        ? { tone: 'good', glyph: '✓', label: 'Fully marked',
            title: 'Every student on the register has a mark.' }
        : p.marked === 0
          ? { tone: 'warning', glyph: '○', label: 'Not started',
              title: 'No marks entered yet.' }
          : { tone: 'warning', glyph: '◐', label: `${p.outstanding} outstanding`,
              title: `${p.marked} of ${p.expected} students marked.` }
  return (
    <span className={`pill ${spec.tone}`} title={spec.title}>
      <span className="glyph" aria-hidden="true">{spec.glyph}</span>
      {spec.label}
    </span>
  )
}

/** Magnitude only, one hue, and always beside the figures it encodes. */
function ProgressBar({ p }: { p: Progress }) {
  if (!p.measurable) return <span className="muted">—</span>
  const frac = Math.max(0, Math.min(1, p.marked / p.expected))
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
      <span aria-hidden="true" style={{
        display: 'inline-block', width: 56, height: 6, borderRadius: 2,
        background: 'var(--surface-2)', border: '1px solid var(--rule)', overflow: 'hidden',
      }}>
        <span style={{
          display: 'block', height: '100%', width: `${frac * 100}%`,
          background: frac === 1 ? 'var(--seq-600)' : 'var(--seq-400)',
        }} />
      </span>
      <span className="num">
        {p.marked}<span className="unit"> of {p.expected}</span>
      </span>
    </span>
  )
}

export default function Assessments() {
  const [params, setParams] = useSearchParams()
  const [groups, setGroups] = useState<Group[]>([])
  const [rows, setRows] = useState<AssessmentRow[]>([])
  const [filter, setFilter] = useState<Filter>('all')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)

  const groupId = params.get('group') ?? ''

  useEffect(() => {
    api.get<Group[]>('/groups').then(setGroups).catch((e) => setErr(e.message))
  }, [])

  useEffect(() => {
    setLoading(true)
    api.get<AssessmentRow[]>(`/assessments${groupId ? `?group_id=${groupId}` : ''}`)
      .then(setRows)
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [groupId])

  const shown = useMemo(() => rows.filter((a) => {
    if (filter === 'all') return true
    const p = progressOf(a)
    const done = a.closed || (p.measurable && p.outstanding === 0)
    return filter === 'done' ? done : !done
  }), [rows, filter])

  const outstanding = rows.filter((a) => {
    const p = progressOf(a)
    return !a.closed && p.measurable && p.outstanding > 0
  }).length
  const untagged = rows.filter((a) => !a.topic_label).length

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <div className="row">
        <h1>Assessments</h1>
        <span style={{ marginLeft: 'auto' }} />
        <Link className="btn" to="/blueprints">Blueprints</Link>
        <Link className="btn primary" to={`/assessments/new${groupId ? `?group=${groupId}` : ''}`}>
          New assessment
        </Link>
      </div>

      <section className="card">
        <header>
          <h2>{groups.find((g) => g.id === groupId)?.label ?? 'All classes'}</h2>
          <span className="sub">
            {loading ? 'Loading…' : (
              <>
                <span className="num">{rows.length}</span> assessments ·{' '}
                <span className="num">{outstanding}</span> still have someone unmarked
                {rows.length > 0 && (
                  <> · <span className="num">{untagged}</span> carry no topic tag</>
                )}
              </>
            )}
          </span>
        </header>

        <div className="row" style={{ marginBottom: 12 }}>
          <select value={groupId} onChange={(e) => {
            const v = e.target.value
            setParams(v ? { group: v } : {}, { replace: true })
          }}>
            <option value="">Every class</option>
            {groups.map((g) => (
              <option key={g.id} value={g.id}>{g.subject_name} · {g.label}</option>
            ))}
          </select>

          <span role="group" aria-label="Filter by marking state" className="row" style={{ gap: 4 }}>
            {([['all', 'All'], ['outstanding', 'Outstanding'], ['done', 'Finished']] as const)
              .map(([v, label]) => (
                <button key={v} type="button" className={filter === v ? 'primary' : ''}
                        aria-pressed={filter === v} onClick={() => setFilter(v)}>
                  {label}
                </button>
              ))}
          </span>
        </div>

        {shown.length === 0 ? (
          <div className="empty">
            {loading ? 'Loading…'
              : rows.length === 0
                ? 'Nothing set yet. Create an assessment and the entry grid opens on it.'
                : 'Nothing in this filter.'}
          </div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Assessment</th>
                  <th>Class</th>
                  <th>Date</th>
                  <th>Topic</th>
                  <th align="right">Marked</th>
                  <th>State</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {shown.map((a) => {
                  const p = progressOf(a)
                  return (
                    <tr key={a.id}>
                      <td>
                        <Link to={`/assessments/${a.id}`}>{a.title}</Link>
                        <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
                          {a.kind}
                          {' · '}
                          <span className="num">{a.n_items}</span>
                          {Number(a.n_items) === 1 ? ' column' : ' columns'}
                          {a.blueprint_name && <> · from “{a.blueprint_name}”</>}
                        </div>
                      </td>
                      <td className="secondary">
                        <Link to={`/classes/${a.teaching_group_id}`}>{a.group_label}</Link>
                        <div className="muted" style={{ fontSize: 'var(--t-small)' }}>{a.subject_name}</div>
                      </td>
                      <td className="secondary" style={{ whiteSpace: 'nowrap' }}>
                        {fmtDate(a.occurred_on)}
                        <div className="muted num" style={{ fontSize: 'var(--t-small)' }}>
                          {a.days_since}d ago
                        </div>
                      </td>
                      <td>
                        {a.topic_label
                          ? <span className="secondary">{a.topic_label}</span>
                          : <span className="muted" title="Untagged marks still give you trajectory and individual-gap findings — just not topic-level ones.">
                              untagged
                            </span>}
                      </td>
                      <td align="right"><ProgressBar p={p} /></td>
                      <td><MarkingStatus a={a} /></td>
                      <td style={{ whiteSpace: 'nowrap' }}>
                        <Link to={`/assessments/${a.id}`}>
                          {p.outstanding > 0 && !a.closed ? 'Mark →' : 'Open →'}
                        </Link>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <p className="note">
        Marking is counted against the register, so an assessment nobody has touched reads as
        “not started” rather than quietly disappearing. Closing an assessment is a note to
        yourself: no analytic anywhere filters on it.
      </p>
    </div>
  )
}
