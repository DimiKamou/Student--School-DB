import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams, Link } from 'react-router-dom'
import { api, type Group } from '../lib/api'

/**
 * CREATING AN ASSESSMENT.
 *
 * Until now this could only be done through the API, which means the entry
 * grid — the screen the whole product rests on — had no front door.
 *
 * The screen is built around two things from ARCHITECTURE.md:
 *
 *  1. THE LAZY PATH STAYS ONE CLICK. "A quiz out of 20 on Tuesday" must be
 *     expressible with no framework, no blueprint, no criteria and no tagging.
 *     So the form opens pre-filled — this class, today, a total out of 20, a
 *     title already written — and the primary button is immediately usable.
 *     Every other control is an optional upgrade on top of that.
 *
 *  2. RUNG 1 OF THE TAGGING LADDER IS THE PRIZE. One topic from one dropdown
 *     is the difference between topic-level analysis existing for this teacher
 *     and not existing. It is a single nullable column, never a join table,
 *     and it is never mandatory — a required tag is how a teacher learns to
 *     pick the first option in the list, which is worse than no tag at all.
 */

type Tag = {
  id: string
  code: string
  label: string
  parent_id: string | null
  axis: string
}

type BlueprintRow = {
  id: string
  name: string
  subject_id: string | null
  subject_name: string | null
  is_shared: boolean
  times_used: number
  n_items: string
  n_items_tagged: string
  total_marks: string | null
}

type Mode = 'total' | 'questions' | 'blueprint'

type QuestionRow = {
  key: number
  label: string
  max_value: string
  topic_tag_id: string
  skill_tag_id: string
}

const KINDS: { value: string; label: string }[] = [
  { value: 'formative', label: 'Formative' },
  { value: 'summative', label: 'Summative' },
  { value: 'mock', label: 'Mock' },
  { value: 'exam', label: 'Exam' },
  { value: 'homework', label: 'Homework' },
  { value: 'oral', label: 'Oral' },
  { value: 'practical', label: 'Practical' },
  { value: 'project', label: 'Project' },
  { value: 'external', label: 'External' },
]

function today(): string {
  const d = new Date()
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

function defaultTitle(kind: string): string {
  const k = KINDS.find((x) => x.value === kind)?.label ?? 'Assessment'
  const d = new Date().toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
  return `${k} — ${d}`
}

let nextKey = 1
function blankQuestion(n: number): QuestionRow {
  return { key: nextKey++, label: `Q${n}`, max_value: '1', topic_tag_id: '', skill_tag_id: '' }
}

export default function NewAssessment() {
  const nav = useNavigate()
  const [params] = useSearchParams()

  const [groups, setGroups] = useState<Group[]>([])
  const [tags, setTags] = useState<Tag[]>([])
  const [blueprints, setBlueprints] = useState<BlueprintRow[]>([])

  const [groupId, setGroupId] = useState(params.get('group') ?? '')
  const [kind, setKind] = useState('summative')
  const [title, setTitle] = useState(defaultTitle('summative'))
  const [titleTouched, setTitleTouched] = useState(false)
  const [occurredOn, setOccurredOn] = useState(today())
  const [topicTagId, setTopicTagId] = useState('')

  const [mode, setMode] = useState<Mode>(params.get('blueprint') ? 'blueprint' : 'total')
  const [maxTotal, setMaxTotal] = useState('20')
  const [questions, setQuestions] = useState<QuestionRow[]>(() => [blankQuestion(1)])
  const [blueprintId, setBlueprintId] = useState(params.get('blueprint') ?? '')

  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    api.get<Group[]>('/groups')
      .then((g) => {
        setGroups(g)
        // One class, or one named in the link: choose it, so the form is ready.
        setGroupId((cur) => cur || (g.length === 1 ? (g[0]?.id ?? '') : ''))
      })
      .catch((e) => setErr(e.message))
    api.get<BlueprintRow[]>('/blueprints').then(setBlueprints).catch(() => setBlueprints([]))
  }, [])

  useEffect(() => {
    if (!groupId) { setTags([]); return }
    setTopicTagId('')
    api.get<Tag[]>(`/groups/${groupId}/tags`).then(setTags).catch(() => setTags([]))
  }, [groupId])

  const group = groups.find((g) => g.id === groupId)
  const topicTags = useMemo(() => tags.filter((t) => t.axis === 'topic'), [tags])
  const skillTags = useMemo(() => tags.filter((t) => t.axis === 'skill'), [tags])

  /** A blueprint for this subject first; the rest still listed, labelled. */
  const sortedBlueprints = useMemo(() => {
    if (!group) return blueprints
    return [...blueprints].sort((a, b) => {
      const am = a.subject_name === group.subject_name ? 0 : 1
      const bm = b.subject_name === group.subject_name ? 0 : 1
      return am - bm || b.times_used - a.times_used
    })
  }, [blueprints, group])

  const chosenBlueprint = blueprints.find((b) => b.id === blueprintId)

  function setKindAndTitle(k: string) {
    setKind(k)
    if (!titleTouched) setTitle(defaultTitle(k))
  }

  const totalMarks = questions.reduce((n, q) => n + (Number(q.max_value) || 0), 0)

  const problem = (() => {
    if (!groupId) return 'Choose a class.'
    if (!title.trim()) return 'Give it a title.'
    if (mode === 'total' && !(Number(maxTotal) > 0)) return 'A total has to be out of something.'
    if (mode === 'questions' && questions.length === 0) return 'Add at least one question.'
    if (mode === 'questions' && questions.some((q) => !q.label.trim()))
      return 'Every question needs a label.'
    if (mode === 'blueprint' && !blueprintId) return 'Choose a blueprint.'
    return null
  })()

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (problem || busy) return
    setBusy(true)
    setErr(null)
    try {
      let id: string
      if (mode === 'blueprint') {
        // The clone is done by gradebook.assessment_from_blueprint(), which
        // copies the blueprint's own tagging. Nothing is re-tagged here.
        const res = await api.post<{ id: string }>(`/blueprints/${blueprintId}/use`, {
          teaching_group_id: groupId,
          title: title.trim(),
          occurred_on: occurredOn,
        })
        id = res.id
      } else {
        const res = await api.post<{ id: string }>('/assessments', {
          teaching_group_id: groupId,
          title: title.trim(),
          kind,
          occurred_on: occurredOn,
          topic_tag_id: topicTagId || null,
          max_total: mode === 'total' ? Number(maxTotal) : null,
          items: mode === 'questions'
            ? questions.map((q, i) => ({
                seq: i + 1,
                label: q.label.trim(),
                max_value: Number(q.max_value) > 0 ? Number(q.max_value) : null,
                topic_tag_id: q.topic_tag_id || null,
                skill_tag_id: q.skill_tag_id || null,
              }))
            : undefined,
        })
        id = res.id
      }
      // Straight into the grid: creating an assessment is never the goal, it is
      // the thing standing between the teacher and entering marks.
      nav(`/assessments/${id}`)
    } catch (e2) {
      setErr((e2 as Error).message)
      setBusy(false)
    }
  }

  return (
    <form className="stack" onSubmit={submit}>
      <div className="row">
        <h1>New assessment</h1>
        <span style={{ marginLeft: 'auto' }} />
        <Link className="btn" to="/assessments">All assessments</Link>
      </div>

      {err && <p className="err">{err}</p>}

      <section className="card">
        <header>
          <h2>The basics</h2>
          <span className="sub">Everything here is pre-filled. Change what you need to.</span>
        </header>

        <div style={{ display: 'grid', gap: 14, gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
          <label style={{ display: 'grid', gap: 4 }}>
            <span className="eyebrow">Class</span>
            <select value={groupId} onChange={(e) => setGroupId(e.target.value)} required>
              <option value="">Choose a class…</option>
              {groups.map((g) => (
                <option key={g.id} value={g.id}>
                  {g.subject_name} · {g.label}
                </option>
              ))}
            </select>
          </label>

          <label style={{ display: 'grid', gap: 4 }}>
            <span className="eyebrow">Title</span>
            <input
              value={title}
              onChange={(e) => { setTitle(e.target.value); setTitleTouched(true) }}
              maxLength={200}
              required
            />
          </label>

          <label style={{ display: 'grid', gap: 4 }}>
            <span className="eyebrow">Date</span>
            <input type="date" value={occurredOn} onChange={(e) => setOccurredOn(e.target.value)} required />
          </label>

          <label style={{ display: 'grid', gap: 4 }}>
            <span className="eyebrow">Kind</span>
            <select value={kind} onChange={(e) => setKindAndTitle(e.target.value)}
                    disabled={mode === 'blueprint'}>
              {KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
            </select>
          </label>
        </div>

        <p className="note" style={{ marginTop: 14 }}>
          The term is worked out from the date. You never pick one.
        </p>
      </section>

      {/* ------------------------------------------------------------------
          RUNG 1. One dropdown, deliberately given a sheet of its own.
          ------------------------------------------------------------------ */}
      <section className="card">
        <header>
          <h2>Topic</h2>
          <span className="sub">Optional — and the single most valuable thing on this screen.</span>
        </header>

        {mode === 'blueprint' ? (
          <p className="note">
            A blueprint brings its own tagging, question by question. Nothing to pick here.
          </p>
        ) : (
          <>
            <label style={{ display: 'grid', gap: 4, maxWidth: 460 }}>
              <span className="eyebrow">What was this mostly about?</span>
              <select value={topicTagId} onChange={(e) => setTopicTagId(e.target.value)}
                      style={{ fontSize: 'var(--t-lead)', padding: '10px 10px' }}>
                <option value="">No topic — skip it</option>
                {topicTags.map((t) => (
                  <option key={t.id} value={t.id}>{t.label}</option>
                ))}
              </select>
            </label>
            <p className="note" style={{ marginTop: 12 }}>
              {topicTags.length === 0
                ? 'No topic list is configured for this subject yet, so there is nothing to pick. '
                  + 'Create the assessment anyway — marks with no tag still give you every trajectory finding.'
                : 'Marks with no tag still give you trajectory and individual-gap findings. '
                  + 'This one dropdown is what additionally buys topic-level analysis — for this class and '
                  + 'for every student in it. It takes about two seconds and you never have to do it again '
                  + 'for this paper.'}
            </p>
          </>
        )}
      </section>

      <section className="card">
        <header>
          <h2>What is being marked</h2>
          <span className="sub">A total is enough. The rest is optional structure.</span>
        </header>

        <div className="row" role="group" aria-label="Assessment structure">
          <button type="button" className={mode === 'total' ? 'primary' : ''}
                  aria-pressed={mode === 'total'} onClick={() => setMode('total')}>
            Just a total
          </button>
          <button type="button" className={mode === 'questions' ? 'primary' : ''}
                  aria-pressed={mode === 'questions'} onClick={() => setMode('questions')}>
            A list of questions
          </button>
          <button type="button" className={mode === 'blueprint' ? 'primary' : ''}
                  aria-pressed={mode === 'blueprint'} onClick={() => setMode('blueprint')}>
            From a blueprint
          </button>
        </div>

        {mode === 'total' && (
          <div style={{ marginTop: 14 }}>
            <label className="row" style={{ gap: 8 }}>
              <span>Out of</span>
              <input className="num" style={{ width: 90 }} inputMode="decimal"
                     value={maxTotal} onChange={(e) => setMaxTotal(e.target.value)} />
              <span className="muted">marks</span>
            </label>
            <p className="note" style={{ marginTop: 12 }}>
              One column in the grid, one number per student. You can add questions to a
              later paper without changing anything about this one.
            </p>
          </div>
        )}

        {mode === 'questions' && (
          <div style={{ marginTop: 14 }}>
            <div className="scroll-x">
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
                  {questions.map((q, i) => (
                    <tr key={q.key}>
                      <td>
                        <input value={q.label} maxLength={80} style={{ width: 110 }}
                               aria-label={`Question ${i + 1} label`}
                               onChange={(e) => setQuestions((qs) =>
                                 qs.map((x) => (x.key === q.key ? { ...x, label: e.target.value } : x)))} />
                      </td>
                      <td align="right">
                        <input className="num" style={{ width: 74 }} inputMode="decimal"
                               value={q.max_value} aria-label={`Question ${i + 1} marks`}
                               onChange={(e) => setQuestions((qs) =>
                                 qs.map((x) => (x.key === q.key ? { ...x, max_value: e.target.value } : x)))} />
                      </td>
                      <td>
                        <select value={q.topic_tag_id} aria-label={`Question ${i + 1} topic`}
                                onChange={(e) => setQuestions((qs) =>
                                  qs.map((x) => (x.key === q.key ? { ...x, topic_tag_id: e.target.value } : x)))}>
                          <option value="">—</option>
                          {topicTags.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
                        </select>
                      </td>
                      <td>
                        <select value={q.skill_tag_id} aria-label={`Question ${i + 1} skill`}
                                onChange={(e) => setQuestions((qs) =>
                                  qs.map((x) => (x.key === q.key ? { ...x, skill_tag_id: e.target.value } : x)))}>
                          <option value="">—</option>
                          {skillTags.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
                        </select>
                      </td>
                      <td>
                        <button type="button" className="ghost"
                                aria-label={`Remove question ${i + 1}`}
                                onClick={() => setQuestions((qs) => qs.filter((x) => x.key !== q.key))}>
                          Remove
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="row" style={{ marginTop: 12 }}>
              <button type="button" onClick={() => setQuestions((qs) => [...qs, blankQuestion(qs.length + 1)])}>
                Add question
              </button>
              <button type="button" onClick={() => setQuestions((qs) =>
                [...qs, ...Array.from({ length: 5 }, (_, i) => blankQuestion(qs.length + i + 1))])}>
                Add five
              </button>
              <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
                <span className="num">{questions.length}</span> questions,
                {' '}<span className="num">{totalMarks}</span> marks in total
              </span>
            </div>
            <p className="note" style={{ marginTop: 12 }}>
              Per-question tags are rungs 2 and 3: they buy content-level diagnosis and a skill
              profile. Leave them blank and the assessment still works — it simply inherits the
              one topic above.
            </p>
          </div>
        )}

        {mode === 'blueprint' && (
          <div style={{ marginTop: 14 }}>
            {blueprints.length === 0 ? (
              <div className="empty">
                No blueprints yet. <Link to="/blueprints">Make one</Link>, or save this paper as a
                blueprint once you have marked it.
              </div>
            ) : (
              <>
                <label style={{ display: 'grid', gap: 4, maxWidth: 520 }}>
                  <span className="eyebrow">Blueprint</span>
                  <select value={blueprintId} onChange={(e) => setBlueprintId(e.target.value)}>
                    <option value="">Choose a blueprint…</option>
                    {sortedBlueprints.map((b) => (
                      <option key={b.id} value={b.id}>
                        {b.name}
                        {b.subject_name ? ` · ${b.subject_name}` : ''}
                        {` · ${b.n_items} questions`}
                        {b.times_used > 0 ? ` · used ${b.times_used}×` : ''}
                      </option>
                    ))}
                  </select>
                </label>
                {chosenBlueprint && (
                  <p className="note" style={{ marginTop: 12 }}>
                    <span className="num">{chosenBlueprint.n_items}</span> questions arrive already
                    set up, <span className="num">{chosenBlueprint.n_items_tagged}</span> of them
                    tagged.
                    {chosenBlueprint.subject_name && group
                      && chosenBlueprint.subject_name !== group.subject_name && (
                      <> This blueprint was written for {chosenBlueprint.subject_name}, not{' '}
                        {group.subject_name}. Its tags will come across as they are.</>
                    )}
                  </p>
                )}
              </>
            )}
          </div>
        )}
      </section>

      <div className="row">
        <button type="submit" className="primary" disabled={!!problem || busy}>
          {busy ? 'Creating…' : 'Create and start marking'}
        </button>
        <Link className="btn" to="/assessments">Cancel</Link>
        {problem && <span className="muted" style={{ fontSize: 'var(--t-small)' }}>{problem}</span>}
      </div>
    </form>
  )
}
