import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, fmtDate } from '../lib/api'

/**
 * THE BLUEPRINT LIBRARY.
 *
 * Tagging is the make-or-break of this product: with no tags there is no
 * content-level diagnosis and the thesis has nothing to say, and with heavy
 * tagging teachers quit in week three. A blueprint is the way out of that
 * trade-off — the cheapest tagging is tagging you did once and never repeat.
 *
 * So this screen is judged on one number per row: times_used. A library of
 * beautifully tagged templates nobody clones is a museum.
 *
 * Cloning is not done here. gradebook.assessment_from_blueprint() does it in
 * one transaction, and "Use" hands off to the creation screen so the teacher
 * still picks the class and the date.
 */

type BlueprintRow = {
  id: string
  name: string
  description: string | null
  subject_id: string | null
  subject_name: string | null
  is_shared: boolean
  is_mine: boolean
  times_used: number
  created_at: string
  created_by_name: string | null
  n_items: string
  n_items_tagged: string
  total_marks: string | null
}

type BlueprintItem = {
  id: string
  seq: number
  label: string
  max_value: string | null
  topic_tag_id: string | null
  skill_tag_id: string | null
  topic_label: string | null
  skill_label: string | null
  measure_label: string | null
}

type Detail = { blueprint: BlueprintRow; items: BlueprintItem[] }

type Subject = { id: string; code: string; name: string }
type Tag = { id: string; code: string; label: string; parent_id: string | null; axis: string }

type AssessmentRow = {
  id: string
  title: string
  occurred_on: string
  group_label: string
  subject_name: string
  topic_label: string | null
  n_items: string
}

type DraftItem = {
  key: number
  label: string
  max_value: string
  topic_tag_id: string
  skill_tag_id: string
}

/** numeric(10,4) arrives as "10.0000". A mark book shows 10. */
function marks(v: string | null | undefined): string {
  if (v == null || v === '') return ''
  const n = Number(v)
  return Number.isFinite(n) ? String(Math.round(n * 1e4) / 1e4) : String(v)
}

let nextKey = 1
function blankItem(n: number): DraftItem {
  return { key: nextKey++, label: `Q${n}`, max_value: '1', topic_tag_id: '', skill_tag_id: '' }
}

function TaggedPill({ tagged, total }: { tagged: number; total: number }) {
  const spec = total === 0
    ? { tone: 'neutral', glyph: '·', label: 'No questions',
        title: 'This blueprint has no items yet, so it clones into an empty paper.' }
    : tagged === total
      ? { tone: 'good', glyph: '✓', label: 'Fully tagged',
          title: 'Every question carries a topic or a skill. Cloning this buys rung 2/3 analysis for free.' }
      : tagged === 0
        ? { tone: 'neutral', glyph: '○', label: 'Untagged',
            title: 'Structure only. Still saves typing, but buys no extra analysis over a plain total.' }
        : { tone: 'warning', glyph: '◐', label: `${tagged} of ${total} tagged`,
            title: 'Partly tagged. The untagged questions inherit whatever the assessment is tagged with.' }
  return (
    <span className={`pill ${spec.tone}`} title={spec.title}>
      <span className="glyph" aria-hidden="true">{spec.glyph}</span>
      {spec.label}
    </span>
  )
}

export default function Blueprints() {
  const [rows, setRows] = useState<BlueprintRow[]>([])
  const [subjects, setSubjects] = useState<Subject[]>([])
  const [assessments, setAssessments] = useState<AssessmentRow[]>([])
  const [openId, setOpenId] = useState<string | null>(null)
  const [detail, setDetail] = useState<Detail | null>(null)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  // --- the editor -----------------------------------------------------------
  const [editing, setEditing] = useState<'closed' | 'new' | string>('closed')
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [subjectId, setSubjectId] = useState('')
  const [isShared, setIsShared] = useState(false)
  const [items, setItems] = useState<DraftItem[]>([])
  const [tags, setTags] = useState<Tag[]>([])
  const [busy, setBusy] = useState(false)

  // --- save-an-assessment-as-a-blueprint -----------------------------------
  const [fromId, setFromId] = useState('')
  const [fromName, setFromName] = useState('')
  const [fromShared, setFromShared] = useState(false)

  function reload() {
    setLoading(true)
    api.get<BlueprintRow[]>('/blueprints')
      .then(setRows)
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false))
  }

  useEffect(() => {
    reload()
    api.get<Subject[]>('/blueprints/subjects').then(setSubjects).catch(() => setSubjects([]))
    api.get<AssessmentRow[]>('/assessments').then(setAssessments).catch(() => setAssessments([]))
  }, [])

  useEffect(() => {
    if (!openId) { setDetail(null); return }
    api.get<Detail>(`/blueprints/${openId}`).then(setDetail).catch((e) => setErr(e.message))
  }, [openId])

  useEffect(() => {
    if (editing === 'closed') return
    api.get<Tag[]>(`/blueprints/tags${subjectId ? `?subject_id=${subjectId}` : ''}`)
      .then(setTags).catch(() => setTags([]))
  }, [editing, subjectId])

  const topicTags = useMemo(() => tags.filter((t) => t.axis === 'topic'), [tags])
  const skillTags = useMemo(() => tags.filter((t) => t.axis === 'skill'), [tags])

  const totalUses = rows.reduce((n, r) => n + r.times_used, 0)

  function startNew() {
    setEditing('new')
    setName('')
    setDescription('')
    setSubjectId('')
    setIsShared(false)
    setItems([blankItem(1)])
    setMsg(null)
  }

  async function startEdit(id: string) {
    setMsg(null)
    try {
      const d = await api.get<Detail>(`/blueprints/${id}`)
      setEditing(id)
      setName(d.blueprint.name)
      setDescription(d.blueprint.description ?? '')
      setSubjectId(d.blueprint.subject_id ?? '')
      setIsShared(d.blueprint.is_shared)
      setItems(d.items.map((it) => ({
        key: nextKey++,
        label: it.label,
        max_value: marks(it.max_value),
        topic_tag_id: it.topic_tag_id ?? '',
        skill_tag_id: it.skill_tag_id ?? '',
      })))
    } catch (e) {
      setErr((e as Error).message)
    }
  }

  async function saveEditor(e: React.FormEvent) {
    e.preventDefault()
    if (!name.trim() || busy) return
    setBusy(true)
    setErr(null)
    const payload = {
      name: name.trim(),
      description: description.trim() || null,
      subject_id: subjectId || null,
      is_shared: isShared,
      items: items.map((it, i) => ({
        seq: i + 1,
        label: it.label.trim() || `Q${i + 1}`,
        max_value: Number(it.max_value) > 0 ? Number(it.max_value) : null,
        topic_tag_id: it.topic_tag_id || null,
        skill_tag_id: it.skill_tag_id || null,
      })),
    }
    try {
      if (editing === 'new') {
        await api.post('/blueprints', payload)
        setMsg('Blueprint saved. Every future paper built from it arrives tagged.')
      } else {
        await api.post(`/blueprints/${editing}`, payload)
        setMsg('Blueprint updated. Assessments already cloned from it are untouched.')
      }
      setEditing('closed')
      setOpenId(null)
      reload()
    } catch (e2) {
      setErr((e2 as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function saveFromAssessment(e: React.FormEvent) {
    e.preventDefault()
    if (!fromId || busy) return
    setBusy(true)
    setErr(null)
    try {
      const res = await api.post<{ id: string; n_items: number }>('/blueprints/from-assessment', {
        assessment_id: fromId,
        name: fromName.trim() || undefined,
        is_shared: fromShared,
      })
      setMsg(`Saved, with ${res.n_items} question${res.n_items === 1 ? '' : 's'} copied. `
        + 'Marks and students were not: a blueprint is the paper, not the sitting of it.')
      setFromId('')
      setFromName('')
      reload()
    } catch (e2) {
      setErr((e2 as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function remove(b: BlueprintRow) {
    if (!confirm(`Delete “${b.name}”? Assessments already made from it keep their questions and marks.`)) return
    setErr(null)
    try {
      await api.post(`/blueprints/${b.id}/delete`)
      if (openId === b.id) setOpenId(null)
      if (editing === b.id) setEditing('closed')
      reload()
    } catch (e) {
      setErr((e as Error).message)
    }
  }

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <div className="row">
        <h1>Blueprints</h1>
        <span style={{ marginLeft: 'auto' }} />
        <Link className="btn" to="/assessments">Assessments</Link>
        <button type="button" className="primary" onClick={startNew}>New blueprint</button>
      </div>

      <section className="card">
        <header>
          <h2>Why these exist</h2>
          <span className="sub">The cheapest tagging is tagging you did once and never repeat.</span>
        </header>
        <p style={{ margin: 0, maxWidth: '62ch' }} className="secondary">
          Tagging questions to topics and skills is what turns “Maria dropped from 6 to 5” into
          “Maria loses 60% of the marks on integration items while her class loses 15%”. It is also
          the thing teachers abandon first, because doing it every term is unpaid work.
        </p>
        <p style={{ marginTop: 10, maxWidth: '62ch' }} className="secondary">
          A blueprint breaks that. You tag last year’s paper once — or save one you have already
          marked — and every future sitting arrives with its structure and its tags already in
          place. The column that matters below is <strong>used</strong>: a blueprint nobody clones
          saved nobody any work.
        </p>
        {rows.length > 0 && (
          <p className="note" style={{ marginTop: 12 }}>
            <span className="num">{rows.length}</span> blueprints have been cloned{' '}
            <span className="num">{totalUses}</span> times, so that tagging has been paid for once
            and reused <span className="num">{Math.max(0, totalUses - rows.length)}</span> times over.
          </p>
        )}
      </section>

      {msg && <p className="note">{msg}</p>}

      {/* --------------------------------------------------------------- */}
      {editing !== 'closed' && (
        <form className="card" onSubmit={saveEditor}>
          <header>
            <h2>{editing === 'new' ? 'New blueprint' : 'Edit blueprint'}</h2>
            <span className="sub">Structure and tagging. No students, no marks, no dates.</span>
          </header>

          <div style={{ display: 'grid', gap: 14, gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
            <label style={{ display: 'grid', gap: 4 }}>
              <span className="eyebrow">Name</span>
              <input value={name} maxLength={200} required
                     placeholder="e.g. Paper 1 — Mechanics, 2024"
                     onChange={(e) => setName(e.target.value)} />
            </label>
            <label style={{ display: 'grid', gap: 4 }}>
              <span className="eyebrow">Subject</span>
              <select value={subjectId} onChange={(e) => setSubjectId(e.target.value)}>
                <option value="">Any subject</option>
                {subjects.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </select>
            </label>
            <label style={{ display: 'grid', gap: 4 }}>
              <span className="eyebrow">Note to yourself</span>
              <input value={description} maxLength={2000}
                     placeholder="optional"
                     onChange={(e) => setDescription(e.target.value)} />
            </label>
          </div>

          <label className="row" style={{ marginTop: 12, gap: 8 }}>
            <input type="checkbox" checked={isShared} style={{ width: 'auto' }}
                   onChange={(e) => setIsShared(e.target.checked)} />
            <span>Share with the department — otherwise only you see it</span>
          </label>

          <div className="scroll-x" style={{ marginTop: 14 }}>
            <table>
              <thead>
                <tr>
                  <th>Question</th>
                  <th align="right">Out of</th>
                  <th>Topic</th>
                  <th>Skill</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {items.map((it, i) => (
                  <tr key={it.key}>
                    <td>
                      <input value={it.label} maxLength={80} style={{ width: 110 }}
                             aria-label={`Item ${i + 1} label`}
                             onChange={(e) => setItems((xs) =>
                               xs.map((x) => (x.key === it.key ? { ...x, label: e.target.value } : x)))} />
                    </td>
                    <td align="right">
                      <input className="num" style={{ width: 74 }} inputMode="decimal"
                             value={it.max_value} aria-label={`Item ${i + 1} marks`}
                             onChange={(e) => setItems((xs) =>
                               xs.map((x) => (x.key === it.key ? { ...x, max_value: e.target.value } : x)))} />
                    </td>
                    <td>
                      <select value={it.topic_tag_id} aria-label={`Item ${i + 1} topic`}
                              onChange={(e) => setItems((xs) =>
                                xs.map((x) => (x.key === it.key ? { ...x, topic_tag_id: e.target.value } : x)))}>
                        <option value="">—</option>
                        {topicTags.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
                      </select>
                    </td>
                    <td>
                      <select value={it.skill_tag_id} aria-label={`Item ${i + 1} skill`}
                              onChange={(e) => setItems((xs) =>
                                xs.map((x) => (x.key === it.key ? { ...x, skill_tag_id: e.target.value } : x)))}>
                        <option value="">—</option>
                        {skillTags.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
                      </select>
                    </td>
                    <td>
                      <button type="button" className="ghost" aria-label={`Remove item ${i + 1}`}
                              onClick={() => setItems((xs) => xs.filter((x) => x.key !== it.key))}>
                        Remove
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {topicTags.length === 0 && skillTags.length === 0 && (
            <p className="note" style={{ marginTop: 12 }}>
              No topic or skill list is configured for this subject, so there is nothing to tag
              with yet. The blueprint still saves the structure — and the moment tags exist you can
              come back and add them once.
            </p>
          )}

          <div className="row" style={{ marginTop: 12 }}>
            <button type="button" onClick={() => setItems((xs) => [...xs, blankItem(xs.length + 1)])}>
              Add question
            </button>
            <button type="button" onClick={() => setItems((xs) =>
              [...xs, ...Array.from({ length: 5 }, (_, i) => blankItem(xs.length + i + 1))])}>
              Add five
            </button>
            <span className="spacer" style={{ marginLeft: 'auto' }} />
            <button type="button" className="ghost" onClick={() => setEditing('closed')}>Cancel</button>
            <button type="submit" className="primary" disabled={!name.trim() || busy}>
              {busy ? 'Saving…' : 'Save blueprint'}
            </button>
          </div>
        </form>
      )}

      {/* --------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Your library</h2>
          <span className="sub">
            {loading ? 'Loading…' : `${rows.length} blueprint${rows.length === 1 ? '' : 's'}`}
          </span>
        </header>

        {rows.length === 0 ? (
          <div className="empty">
            {loading ? 'Loading…'
              : 'Nothing saved yet. Build one below from a paper you have already marked — that is the cheapest way in.'}
          </div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Blueprint</th>
                  <th>Subject</th>
                  <th align="right">Questions</th>
                  <th align="right">Marks</th>
                  <th>Tagging</th>
                  <th align="right">Used</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((b) => (
                  <tr key={b.id}>
                    <td>
                      <button type="button" className="ghost" style={{ padding: 0, textAlign: 'left' }}
                              aria-expanded={openId === b.id}
                              onClick={() => setOpenId(openId === b.id ? null : b.id)}>
                        <span style={{ color: 'var(--accent)' }}>
                          {openId === b.id ? '▾ ' : '▸ '}{b.name}
                        </span>
                      </button>
                      <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
                        {b.is_shared ? 'shared with the department' : 'only you'}
                        {b.created_by_name && ` · ${b.created_by_name}`}
                        {` · ${fmtDate(b.created_at)}`}
                      </div>
                      {b.description && (
                        <div className="secondary" style={{ fontSize: 'var(--t-small)' }}>{b.description}</div>
                      )}
                    </td>
                    <td className="secondary">{b.subject_name ?? 'any'}</td>
                    <td className="num">{b.n_items}</td>
                    <td className="num">
                      {b.total_marks ? marks(b.total_marks) : <span className="muted">—</span>}
                    </td>
                    <td><TaggedPill tagged={Number(b.n_items_tagged)} total={Number(b.n_items)} /></td>
                    <td className="num">
                      {b.times_used > 0
                        ? <>{b.times_used}<span className="unit">×</span></>
                        : <span className="muted">never</span>}
                    </td>
                    <td style={{ whiteSpace: 'nowrap' }}>
                      <Link to={`/assessments/new?blueprint=${b.id}`}>Use →</Link>
                      {b.is_mine && (
                        <>
                          {' · '}
                          <button type="button" className="ghost" onClick={() => startEdit(b.id)}>Edit</button>
                          <button type="button" className="ghost" onClick={() => remove(b)}>Delete</button>
                        </>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {detail && (
          <div style={{ marginTop: 14, borderTop: '1px solid var(--rule)', paddingTop: 12 }}>
            <h3>{detail.blueprint.name}</h3>
            {detail.items.length === 0 ? (
              <div className="empty">This blueprint has no questions, so it clones into an empty paper.</div>
            ) : (
              <div className="scroll-x">
                <table>
                  <thead>
                    <tr><th>#</th><th>Question</th><th align="right">Out of</th><th>Topic</th><th>Skill</th></tr>
                  </thead>
                  <tbody>
                    {detail.items.map((it) => (
                      <tr key={it.id}>
                        <td className="num muted">{it.seq}</td>
                        <td>{it.label}</td>
                        <td className="num">
                          {it.max_value ? marks(it.max_value) : <span className="muted">—</span>}
                        </td>
                        <td className="secondary">{it.topic_label ?? <span className="muted">—</span>}</td>
                        <td className="secondary">{it.skill_label ?? <span className="muted">—</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}
      </section>

      {/* --------------------------------------------------------------- */}
      <form className="card" onSubmit={saveFromAssessment}>
        <header>
          <h2>Save a paper you have already marked</h2>
          <span className="sub">The tagging is done. This stops it being done again.</span>
        </header>

        {assessments.length === 0 ? (
          <div className="empty">
            No assessments yet. <Link to="/assessments/new">Create one</Link> first.
          </div>
        ) : (
          <>
            <div style={{ display: 'grid', gap: 14, gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
              <label style={{ display: 'grid', gap: 4 }}>
                <span className="eyebrow">Assessment</span>
                <select value={fromId} onChange={(e) => setFromId(e.target.value)}>
                  <option value="">Choose one…</option>
                  {assessments.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.title} · {a.group_label} · {a.n_items} question{Number(a.n_items) === 1 ? '' : 's'}
                    </option>
                  ))}
                </select>
              </label>
              <label style={{ display: 'grid', gap: 4 }}>
                <span className="eyebrow">Call it</span>
                <input value={fromName} maxLength={200}
                       placeholder="same as the assessment"
                       onChange={(e) => setFromName(e.target.value)} />
              </label>
            </div>

            <label className="row" style={{ marginTop: 12, gap: 8 }}>
              <input type="checkbox" checked={fromShared} style={{ width: 'auto' }}
                     onChange={(e) => setFromShared(e.target.checked)} />
              <span>Share with the department</span>
            </label>

            {fromId && Number(assessments.find((a) => a.id === fromId)?.n_items ?? 0) <= 1 && (
              <p className="note" style={{ marginTop: 12 }}>
                This assessment is a single total, so the blueprint will be one column. That still
                saves typing, but it buys no more analysis than creating a total from scratch does.
              </p>
            )}

            <div className="row" style={{ marginTop: 12 }}>
              <button type="submit" className="primary" disabled={!fromId || busy}>
                {busy ? 'Saving…' : 'Save as blueprint'}
              </button>
              <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
                Questions, marks out of, and tags are copied. Student marks are not.
              </span>
            </div>
          </>
        )}
      </form>
    </div>
  )
}
