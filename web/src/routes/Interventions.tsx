import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { api, fmtDate, type Group, type Student } from '../lib/api'

/**
 * Interventions: what was actually done, and whether anything got better.
 *
 * The school's question at renewal is not "did you flag them early" but "did
 * anything change". analytics.v_intervention_effect answers it as honestly as
 * a before-and-after comparison can, and its own status column decides what may
 * be shown:
 *
 *   measurable        — enough marks either side to quote a difference
 *   too_early_to_tell — fewer than three marks since it started
 *   no_baseline       — fewer than three marks before it started
 *   (no row at all)   — the view could not score it: a class-level intervention,
 *                       or no residual series on that topic for that student
 *
 * A delta is rendered ONLY for 'measurable'. In every other state the number
 * exists in the database and is meaningless, and printing it would be exactly
 * the overclaim this product is sold on not making.
 */

type Effect = {
  status: string | null
  n_before: string | null
  n_after: string | null
  mean_residual_before: string | null
  mean_residual_after: string | null
  delta: string | null
}

type Intervention = Effect & {
  id: string
  kind: string
  description: string | null
  started_on: string
  ended_on: string | null
  created_at: string
  student_id: string | null
  teaching_group_id: string | null
  tag_id: string | null
  raised_by_alert_id: string | null
  student_name: string | null
  group_label: string | null
  subject_name: string | null
  tag_label: string | null
  alert_headline: string | null
  is_mine: boolean | null
}

type AlertLite = {
  id: string
  kind: string
  headline: string
  student_id: string | null
  teaching_group_id: string | null
  tag_id: string | null
  group_label: string | null
  tag_label: string | null
}

type Tag = { id: string; code: string; label: string; axis: string }

const KINDS = [
  { key: 'reteach', label: 'Reteach', hint: 'Taught the topic again, to the whole class.' },
  { key: 'small_group', label: 'Small group', hint: 'A group pulled out for targeted work.' },
  { key: 'one_to_one', label: 'One to one', hint: 'Individual teaching time.' },
  { key: 'differentiated_task', label: 'Differentiated task', hint: 'Different work set for this student or group.' },
  { key: 'parent_contact', label: 'Parent contact', hint: 'Spoke to home about it.' },
  { key: 'timetable_change', label: 'Timetable change', hint: 'More contact time, a moved lesson, a set change.' },
  { key: 'curriculum_change', label: 'Curriculum change', hint: 'The scheme of work itself changed.' },
  { key: 'other', label: 'Other', hint: 'Something else — say what in the note.' },
] as const

const kindLabel = (k: string) => KINDS.find((x) => x.key === k)?.label ?? k.replace(/_/g, ' ')
const today = () => new Date().toISOString().slice(0, 10)

/**
 * Status badge. Same contract as Pill.tsx: a status colour never travels
 * without a glyph and a word.
 */
function EffectPill({ tone, glyph, label, title }: {
  tone: string; glyph: string; label: string; title: string
}) {
  return (
    <span className={`pill ${tone}`} title={title}>
      <span className="glyph" aria-hidden="true">{glyph}</span>
      {label}
    </span>
  )
}

function effectPill(i: Intervention) {
  if (i.status === null) {
    return <EffectPill tone="neutral" glyph="·" label="Not measured"
      title="The effect view could not score this one. Absence of a measurement is not an absence of effect." />
  }
  if (i.status === 'too_early_to_tell') {
    return <EffectPill tone="neutral" glyph="◷" label="Too early"
      title="Fewer than three marks on this topic since it started. Nothing honest to report yet." />
  }
  if (i.status === 'no_baseline') {
    return <EffectPill tone="neutral" glyph="·" label="No baseline"
      title="Fewer than three marks on this topic before it started, so there is nothing to compare against." />
  }
  const d = i.delta == null ? null : Number(i.delta)
  if (d == null) {
    return <EffectPill tone="neutral" glyph="·" label="No figure" title="No difference was returned." />
  }
  if (Math.abs(d) < 0.01) {
    return <EffectPill tone="neutral" glyph="→" label="Unchanged"
      title="Residuals sit within 0.01 of where they were. No movement either way." />
  }
  return d > 0
    ? <EffectPill tone="good" glyph="↑" label="Higher after"
        title="Work on this topic sits above the student's own adjusted baseline more than it did before. A before-and-after comparison, not a controlled trial." />
    : <EffectPill tone="warning" glyph="↓" label="Lower after"
        title="Work on this topic sits below where it did before. A before-and-after comparison, not a controlled trial." />
}

/** The measured difference, in words, and ONLY when the view says it is real. */
function effectDetail(i: Intervention) {
  if (i.status === 'measurable' && i.delta != null) {
    const d = Number(i.delta)
    return (
      <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
        <span className="num">{d > 0 ? '+' : ''}{d.toFixed(3)}</span>
        <span className="unit"> residual, from </span>
        <span className="num">{i.mean_residual_before == null ? '—' : Number(i.mean_residual_before).toFixed(3)}</span>
        <span className="unit"> to </span>
        <span className="num">{i.mean_residual_after == null ? '—' : Number(i.mean_residual_after).toFixed(3)}</span>
        {' · '}<span className="num">{i.n_before}</span><span className="unit"> marks before</span>
        {', '}<span className="num">{i.n_after}</span><span className="unit"> after</span>
      </div>
    )
  }
  if (i.status === 'too_early_to_tell') {
    return (
      <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
        <span className="num">{i.n_after ?? 0}</span> mark{Number(i.n_after ?? 0) === 1 ? '' : 's'} on this
        topic since it started; three are needed before a difference is quoted.
      </div>
    )
  }
  if (i.status === 'no_baseline') {
    return (
      <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
        Only <span className="num">{i.n_before ?? 0}</span> mark{Number(i.n_before ?? 0) === 1 ? '' : 's'} before
        it started. Without a baseline, “it worked” is not a claim this data can support.
      </div>
    )
  }
  return (
    <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
      {i.student_id
        ? 'No marks on this topic tie to this student yet, so there is nothing to compare.'
        : 'Recorded against a class rather than a student. The effect view follows one student’s residuals, so it cannot score a class-wide action — look at the class topic table instead.'}
    </div>
  )
}

export default function Interventions() {
  const [params, setParams] = useSearchParams()
  const fromAlert = params.get('from_alert')
  const alertFilter = params.get('alert')

  const [rows, setRows] = useState<Intervention[]>([])
  const [groups, setGroups] = useState<Group[]>([])
  const [roster, setRoster] = useState<Student[]>([])
  const [tags, setTags] = useState<Tag[]>([])
  const [alert, setAlert] = useState<AlertLite | null>(null)

  const [kind, setKind] = useState<string>('reteach')
  const [groupId, setGroupId] = useState('')
  const [studentId, setStudentId] = useState('')
  const [tagId, setTagId] = useState('')
  const [startedOn, setStartedOn] = useState(today())
  const [description, setDescription] = useState('')

  const [openOnly, setOpenOnly] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      setRows(await api.get<Intervention[]>(`/interventions?open=${openOnly}&limit=200`))
      setErr(null)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [openOnly])

  useEffect(() => { void load() }, [load])
  useEffect(() => { api.get<Group[]>('/groups').then(setGroups).catch(() => setGroups([])) }, [])

  // Prefill from the alert the teacher clicked through from.
  useEffect(() => {
    if (!fromAlert) return
    api.get<AlertLite>(`/alerts/${fromAlert}`)
      .then((a) => {
        setAlert(a)
        if (a.teaching_group_id) setGroupId(a.teaching_group_id)
        if (a.student_id) setStudentId(a.student_id)
        if (a.tag_id) setTagId(a.tag_id)
        // A whole-class finding is one action for everyone; an individual one
        // usually is not. Only a default — the teacher decides.
        setKind(a.kind === 'systemic_topic_gap' ? 'reteach' : 'one_to_one')
      })
      .catch((e) => setErr((e as Error).message))
  }, [fromAlert])

  useEffect(() => {
    if (!groupId) { setRoster([]); setTags([]); return }
    api.get<Student[]>(`/groups/${groupId}/roster`).then(setRoster).catch(() => setRoster([]))
    api.get<Tag[]>(`/groups/${groupId}/tags`).then(setTags).catch(() => setTags([]))
  }, [groupId])

  const topicTags = useMemo(() => tags.filter((t) => t.axis === 'topic'), [tags])

  const visible = useMemo(
    () => (alertFilter ? rows.filter((r) => r.raised_by_alert_id === alertFilter) : rows),
    [rows, alertFilter],
  )

  const submit = useCallback(async (e: React.FormEvent) => {
    e.preventDefault()
    if (!groupId && !studentId) { setErr('Name a class or a student.'); return }
    setSaving(true)
    try {
      await api.post('/interventions', {
        kind,
        teaching_group_id: groupId || null,
        student_id: studentId || null,
        tag_id: tagId || null,
        raised_by_alert_id: fromAlert ?? null,
        description: description.trim() || null,
        started_on: startedOn,
      })
      setDescription('')
      setStudentId('')
      setTagId('')
      setAlert(null)
      if (fromAlert) { params.delete('from_alert'); setParams(params, { replace: true }) }
      setErr(null)
      await load()
    } catch (e2) {
      setErr((e2 as Error).message)
    } finally {
      setSaving(false)
    }
  }, [kind, groupId, studentId, tagId, fromAlert, description, startedOn, load, params, setParams])

  const patch = useCallback(async (id: string, body: unknown) => {
    setBusy(id)
    try { await api.post(`/interventions/${id}`, body); await load() }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(null) }
  }, [load])

  const remove = useCallback(async (id: string) => {
    setBusy(id)
    try { await api.post(`/interventions/${id}/delete`); await load() }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(null) }
  }, [load])

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <div className="row">
        <h1>Interventions</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <Link className="btn" to="/alerts">← Alerts</Link>
      </div>

      {/* ------------------------------------------------------------------
          Record one.
         ------------------------------------------------------------------ */}
      <section className="card">
        <header>
          <h2>Record what you did</h2>
          <span className="sub">
            One line now is what makes “did anything get better” answerable in April.
          </span>
        </header>

        {alert && (
          <div className="note" style={{ marginBottom: 12 }}>
            <strong>About this alert:</strong> {alert.headline}
            {alert.group_label && <> · {alert.group_label}</>}
            {alert.tag_label && <> · {alert.tag_label}</>}
          </div>
        )}

        <form onSubmit={submit} className="stack" style={{ gap: 12 }}>
          <div className="row" style={{ gap: 12, alignItems: 'flex-end' }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span className="eyebrow">What you did</span>
              <select value={kind} onChange={(e) => setKind(e.target.value)}>
                {KINDS.map((k) => <option key={k.key} value={k.key} title={k.hint}>{k.label}</option>)}
              </select>
            </label>

            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span className="eyebrow">Class</span>
              <select value={groupId} onChange={(e) => { setGroupId(e.target.value); setStudentId('') }}>
                <option value="">Choose a class…</option>
                {groups.map((g) => (
                  <option key={g.id} value={g.id}>{g.subject_name} · {g.label}</option>
                ))}
              </select>
            </label>

            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span className="eyebrow">Student</span>
              <select value={studentId} onChange={(e) => setStudentId(e.target.value)} disabled={!groupId}>
                <option value="">Whole class</option>
                {roster.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.family_name}, {s.preferred_name ?? s.given_name}
                  </option>
                ))}
              </select>
            </label>

            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span className="eyebrow">Topic</span>
              <select value={tagId} onChange={(e) => setTagId(e.target.value)} disabled={!groupId}>
                <option value="">No topic</option>
                {topicTags.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
              </select>
            </label>

            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span className="eyebrow">Started</span>
              <input type="date" value={startedOn} onChange={(e) => setStartedOn(e.target.value)} />
            </label>
          </div>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <span className="eyebrow">Note</span>
            <textarea
              rows={2}
              value={description}
              placeholder="Two lines on what you actually changed. Future you will not remember."
              onChange={(e) => setDescription(e.target.value)}
            />
          </label>

          <div className="row">
            <button className="primary" type="submit" disabled={saving || (!groupId && !studentId)}>
              {saving ? 'Saving…' : 'Record it'}
            </button>
            <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
              Without a topic, the effect view has nothing specific to measure against —
              it will fall back to all of that student’s work.
            </span>
          </div>
        </form>
      </section>

      {/* ------------------------------------------------------------------
          Did it work.
         ------------------------------------------------------------------ */}
      <section className="card">
        <header>
          <h2>Did it work</h2>
          <span className="sub">
            Residuals on the targeted topic, before against after.
          </span>
        </header>

        <p className="note" style={{ marginBottom: 12 }}>
          This is a before-and-after comparison, not a randomised trial, and it is never presented
          as one: a term also passed, the class moved on and other things changed. Where the data
          cannot carry a conclusion the row says so rather than showing a number.
        </p>

        <div className="row" style={{ marginBottom: 12 }}>
          <label className="row" style={{ gap: 6 }}>
            <input
              type="checkbox"
              checked={openOnly}
              onChange={(e) => setOpenOnly(e.target.checked)}
              style={{ width: 'auto' }}
            />
            Still running only
          </label>
          {alertFilter && (
            <button className="ghost" onClick={() => { params.delete('alert'); setParams(params, { replace: true }) }}>
              Clear alert filter
            </button>
          )}
        </div>

        {loading ? (
          <div className="empty">Loading…</div>
        ) : visible.length === 0 ? (
          <div className="empty">
            Nothing recorded yet. An alert nobody acted on tells a school nothing at renewal.
          </div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>What</th>
                  <th>Who</th>
                  <th>Topic</th>
                  <th align="right">Started</th>
                  <th>Since then</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {visible.map((i) => (
                  <tr key={i.id}>
                    <td>
                      {kindLabel(i.kind)}
                      {i.description && (
                        <div className="secondary" style={{ fontSize: 'var(--t-small)' }}>{i.description}</div>
                      )}
                      {i.alert_headline && (
                        <div className="muted" style={{ fontSize: 'var(--t-micro)' }}>
                          from an alert: {i.alert_headline}
                        </div>
                      )}
                    </td>
                    <td>
                      {i.student_id
                        ? <Link to={`/students/${i.student_id}`}>{i.student_name ?? 'student'}</Link>
                        : <span className="secondary">whole class</span>}
                      <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
                        {[i.subject_name, i.group_label].filter(Boolean).join(' · ') || '—'}
                      </div>
                    </td>
                    <td className="secondary">{i.tag_label ?? <span className="muted">all work</span>}</td>
                    <td className="num" title={i.ended_on ? `ended ${fmtDate(i.ended_on)}` : 'still running'}>
                      {fmtDate(i.started_on)}
                      <div className="muted" style={{ fontSize: 'var(--t-micro)' }}>
                        {i.ended_on ? `ended ${fmtDate(i.ended_on)}` : 'running'}
                      </div>
                    </td>
                    <td>
                      {effectPill(i)}
                      {effectDetail(i)}
                    </td>
                    <td>
                      {i.is_mine && (
                        <div className="row" style={{ gap: 6 }}>
                          {i.ended_on ? (
                            <button
                              className="ghost"
                              disabled={busy === i.id}
                              onClick={() => void patch(i.id, { ended_on: null })}
                            >
                              Reopen
                            </button>
                          ) : (
                            <button
                              className="ghost"
                              disabled={busy === i.id}
                              onClick={() => void patch(i.id, { ended_on: today() })}
                            >
                              Close
                            </button>
                          )}
                          <button
                            className="ghost"
                            disabled={busy === i.id}
                            onClick={() => { if (confirm('Delete this intervention record?')) void remove(i.id) }}
                          >
                            Delete
                          </button>
                        </div>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  )
}
