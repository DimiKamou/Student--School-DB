import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../../lib/api'
import { AdminTabs } from './People'

/**
 * CURRICULUM — the topic and skill trees teachers tag against, and the
 * optional binding of a class to a grading framework.
 *
 * Two honesty constraints shape this screen.
 *
 * 1. nominal_minutes is what makes under-taught detection possible. Without a
 *    planned time for a topic there is nothing for delivered lesson minutes to
 *    fall short OF, so the analysis can only ever say "taught badly" and never
 *    "never got the hours" — which are findings about two different people.
 *    The screen says that where the field is, and shows which tags are missing
 *    it rather than leaving the consequence invisible.
 *
 * 2. The delivered figure here is a school-wide total across every class that
 *    recorded a lesson on the tag. That is NOT the per-class delivery ratio the
 *    analytics uses to flag under-teaching, and it is not presented as one. A
 *    ratio computed across classes with different timetables would be a
 *    confident number the data does not support.
 */

type Taxonomy = {
  id: string; code: string; name: string; axis: string; source_ref: string | null
  subject_id: string | null; subject_name: string | null
  is_editable: boolean; n_tags: string; n_tags_with_time: string
}
type Tag = {
  id: string; code: string; label: string; parent_id: string | null
  sort_order: number; is_leaf: boolean; nominal_minutes: number | null
  n_children: string; delivered_minutes: string; depth: string
}
type TagPayload = { taxonomy: { id: string; is_editable: boolean }; tags: Tag[] }
type FrameworkRow = {
  framework_id: string; code: string; name: string
  country_code: string | null; awarding_body: string | null
  is_school_authored: boolean
  framework_version_id: string; version_label: string
  valid_from: string; valid_to: string | null; n_groups: string
}
type GroupRow = {
  id: string; label: string; subject_name: string; year_level: string | null
  n_students: string; framework_version_id: string | null
  framework_version_label: string | null; framework_name: string | null
}
type Subject = { id: string; code: string; name: string }

const AXES: { code: string; label: string; help: string }[] = [
  { code: 'topic', label: 'Topic', help: 'What the content was about. The cheapest and most useful axis: one dropdown on an assessment buys topic analytics.' },
  { code: 'skill', label: 'Skill', help: 'What the student had to be able to do. Feeds the skill profile and the cross-framework view.' },
  { code: 'content_type', label: 'Content type', help: 'Calculation, essay, practical, and so on.' },
  { code: 'command_term', label: 'Command term', help: 'Describe, evaluate, justify — the instruction the question gave.' },
  { code: 'cognitive_level', label: 'Cognitive level', help: 'Recall against application against analysis.' },
  { code: 'key_concept', label: 'Key concept', help: 'MYP key and related concepts.' },
  { code: 'global_context', label: 'Global context', help: 'MYP global contexts.' },
  { code: 'atl', label: 'ATL skill', help: 'MYP approaches to learning.' },
]

function Flag({ tone, glyph, label, title }:
  { tone: 'good' | 'warning' | 'serious' | 'critical' | 'neutral'
    glyph: string; label: string; title: string }) {
  return (
    <span className={`pill ${tone}`} title={title}>
      <span className="glyph" aria-hidden="true">{glyph}</span>{label}
    </span>
  )
}

/** Flatten the tag tree depth-first so the table reads as an outline. */
function outline(tags: Tag[]): { tag: Tag; depth: number }[] {
  const byParent = new Map<string | null, Tag[]>()
  for (const t of tags) {
    const k = t.parent_id
    const list = byParent.get(k)
    if (list) list.push(t); else byParent.set(k, [t])
  }
  for (const list of byParent.values()) {
    list.sort((a, b) => a.sort_order - b.sort_order || a.label.localeCompare(b.label))
  }
  // A tag whose parent is not in this taxonomy's list would otherwise vanish.
  const known = new Set(tags.map((t) => t.id))
  const roots = tags.filter((t) => !t.parent_id || !known.has(t.parent_id))
    .sort((a, b) => a.sort_order - b.sort_order || a.label.localeCompare(b.label))

  const out: { tag: Tag; depth: number }[] = []
  const seen = new Set<string>()
  const walk = (t: Tag, depth: number) => {
    if (seen.has(t.id)) return
    seen.add(t.id)
    out.push({ tag: t, depth })
    for (const c of byParent.get(t.id) ?? []) walk(c, depth + 1)
  }
  for (const r of roots) walk(r, 0)
  return out
}

/** Every tag underneath this one — the set it may not be re-parented into. */
function descendantsOf(id: string, tags: Tag[]): Set<string> {
  const out = new Set<string>([id])
  let grew = true
  while (grew) {
    grew = false
    for (const t of tags) {
      if (t.parent_id && out.has(t.parent_id) && !out.has(t.id)) { out.add(t.id); grew = true }
    }
  }
  return out
}

type Draft = { label: string; parent_id: string; sort_order: string; nominal_minutes: string }

export default function Curriculum() {
  const [taxonomies, setTaxonomies] = useState<Taxonomy[]>([])
  const [subjects, setSubjects] = useState<Subject[]>([])
  const [frameworks, setFrameworks] = useState<FrameworkRow[]>([])
  const [groups, setGroups] = useState<GroupRow[]>([])
  const [selected, setSelected] = useState<string>('')
  const [detail, setDetail] = useState<TagPayload | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // New taxonomy
  const [nxCode, setNxCode] = useState('')
  const [nxName, setNxName] = useState('')
  const [nxAxis, setNxAxis] = useState('topic')
  const [nxSubject, setNxSubject] = useState('')

  // New tag
  const [ntCode, setNtCode] = useState('')
  const [ntLabel, setNtLabel] = useState('')
  const [ntParent, setNtParent] = useState('')
  const [ntMinutes, setNtMinutes] = useState('')

  // Inline edit
  const [editing, setEditing] = useState<string | null>(null)
  const [draft, setDraft] = useState<Draft>({
    label: '', parent_id: '', sort_order: '0', nominal_minutes: '',
  })

  const loadTop = useCallback(async () => {
    try {
      const [tx, fw, gs, school] = await Promise.all([
        api.get<Taxonomy[]>('/admin/taxonomies'),
        api.get<FrameworkRow[]>('/admin/frameworks'),
        api.get<GroupRow[]>('/admin/groups'),
        api.get<{ subjects: Subject[] }>('/admin/school'),
      ])
      setTaxonomies(tx); setFrameworks(fw); setGroups(gs); setSubjects(school.subjects)
      setErr(null)
    } catch (e) { setErr((e as Error).message) }
  }, [])

  const loadTags = useCallback(async (id: string) => {
    if (!id) { setDetail(null); return }
    try { setDetail(await api.get<TagPayload>(`/admin/taxonomies/${id}/tags`)) }
    catch (e) { setErr((e as Error).message) }
  }, [])

  useEffect(() => { void loadTop() }, [loadTop])
  useEffect(() => { void loadTags(selected) }, [selected, loadTags])

  async function run(fn: () => Promise<unknown>) {
    setBusy(true); setErr(null)
    try { await fn(); await loadTop(); await loadTags(selected) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  const tax = taxonomies.find((t) => t.id === selected)
  const tags = detail?.tags ?? []
  const rows = useMemo(() => outline(tags), [tags])
  const forbidden = editing ? descendantsOf(editing, tags) : new Set<string>()
  const untimed = tags.filter((t) => t.nominal_minutes == null && Number(t.n_children) === 0)

  // The ten seeded frameworks, grouped: a school picks a system, then a version.
  const byFramework = useMemo(() => {
    const m = new Map<string, FrameworkRow[]>()
    for (const f of frameworks) {
      const list = m.get(f.framework_id)
      if (list) list.push(f); else m.set(f.framework_id, [f])
    }
    return [...m.values()]
  }, [frameworks])

  return (
    <div className="stack">
      <div className="row">
        <h1>Curriculum</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <AdminTabs />
      </div>
      {err && <p className="err">{err}</p>}

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Taxonomies</h2>
          <span className="sub">
            The lists teachers choose from when they tag an assessment. One per subject and axis.
          </span>
        </header>
        <div className="scroll-x">
          <table>
            <thead>
              <tr>
                <th>Name</th><th>Axis</th><th>Subject</th>
                <th align="right">Tags</th><th align="right">With planned time</th>
                <th>Source</th><th />
              </tr>
            </thead>
            <tbody>
              {taxonomies.map((t) => (
                <tr key={t.id}>
                  <td>
                    <button className="ghost" style={{ padding: 0, border: 0 }}
                            onClick={() => setSelected(t.id)}>
                      <span style={{ color: 'var(--accent)' }}>{t.name}</span>
                    </button>
                    <div className="muted" style={{ fontSize: 'var(--t-micro)' }}>{t.code}</div>
                  </td>
                  <td className="secondary">
                    {AXES.find((a) => a.code === t.axis)?.label ?? t.axis}
                  </td>
                  <td className="secondary">{t.subject_name ?? 'all subjects'}</td>
                  <td className="num">{t.n_tags}</td>
                  <td className="num">{t.n_tags_with_time}</td>
                  <td className="muted" style={{ maxWidth: 220 }}>{t.source_ref ?? '—'}</td>
                  <td>
                    {t.is_editable
                      ? <Flag tone="good" glyph="✎" label="Yours"
                              title="Authored by this school. You can add, re-parent and time its tags." />
                      : <Flag tone="neutral" glyph="⚿" label="Published"
                              title="Published by the platform and shared by every school. Readable here, not editable." />}
                  </td>
                </tr>
              ))}
              {taxonomies.length === 0 && (
                <tr><td colSpan={7}>
                  <div className="empty">
                    No taxonomies. Marks and trajectory analytics still work without any —
                    what is missing is topic- and skill-level diagnosis.
                  </div>
                </td></tr>
              )}
            </tbody>
          </table>
        </div>

        <form className="row" style={{ alignItems: 'flex-end', gap: 10, marginTop: 14 }}
              onSubmit={(e) => {
                e.preventDefault()
                void run(async () => {
                  const r = await api.post<{ id: string }>('/admin/taxonomies', {
                    code: nxCode, name: nxName, axis: nxAxis,
                    subject_id: nxSubject || null,
                  })
                  setNxCode(''); setNxName(''); setSelected(r.id)
                })
              }}>
          <label style={{ display: 'grid', gap: 4 }}>
            Name
            <input required value={nxName} placeholder="MYP Sciences topics" style={{ width: 190 }}
                   onChange={(e) => setNxName(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Code
            <input required value={nxCode} placeholder="SCI_TOPICS" style={{ width: 130 }}
                   onChange={(e) => setNxCode(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Axis
            <select value={nxAxis} onChange={(e) => setNxAxis(e.target.value)}
                    title={AXES.find((a) => a.code === nxAxis)?.help}>
              {AXES.map((a) => <option key={a.code} value={a.code}>{a.label}</option>)}
            </select>
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Subject
            <select value={nxSubject} onChange={(e) => setNxSubject(e.target.value)}>
              <option value="">all subjects</option>
              {subjects.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </label>
          <button className="primary" type="submit" disabled={busy}>Create taxonomy</button>
        </form>
        <p className="muted" style={{ fontSize: 'var(--t-small)', marginBottom: 0 }}>
          {AXES.find((a) => a.code === nxAxis)?.help}
        </p>
      </section>

      {/* ---------------------------------------------------------------- */}
      {tax && (
        <section className="card">
          <header>
            <h2>{tax.name}</h2>
            <span className="sub">
              {tags.length} tags · {tax.is_editable
                ? 'yours to edit'
                : 'published by the platform — read only'}
            </span>
            <span className="spacer" style={{ marginLeft: 'auto' }} />
            <button className="ghost" onClick={() => setSelected('')}>Close</button>
          </header>

          <p className="muted" style={{ fontSize: 'var(--t-small)', maxWidth: 680 }}>
            <strong>Planned time</strong> is what makes under-taught detection possible. Compared
            against the minutes actually delivered in lessons, it separates “this was taught
            badly” from “this only ever got two lessons” — a teaching finding and a
            curriculum-design finding, for two different people. Leave it blank and the analysis
            can only reach the first conclusion.
          </p>

          {tags.length === 0 ? (
            <div className="empty">No tags yet.</div>
          ) : (
            <div className="scroll-x">
              <table>
                <thead>
                  <tr>
                    <th>Tag</th><th>Code</th>
                    <th align="right">Planned</th><th align="right">Delivered</th>
                    <th>Under-taught detection</th><th />
                  </tr>
                </thead>
                <tbody>
                  {rows.map(({ tag: t, depth }) => (
                    editing === t.id ? (
                      <tr key={t.id}>
                        <td colSpan={6}>
                          <form className="row" style={{ alignItems: 'flex-end', gap: 10 }}
                                onSubmit={(e) => {
                                  e.preventDefault()
                                  void run(async () => {
                                    await api.post(`/admin/tags/${t.id}/update`, {
                                      label: draft.label,
                                      parent_id: draft.parent_id || null,
                                      sort_order: Number(draft.sort_order) || 0,
                                      nominal_minutes: draft.nominal_minutes === ''
                                        ? null : Number(draft.nominal_minutes),
                                    })
                                    setEditing(null)
                                  })
                                }}>
                            <label style={{ display: 'grid', gap: 4 }}>
                              Label
                              <input required value={draft.label} style={{ width: 200 }}
                                     onChange={(e) =>
                                       setDraft({ ...draft, label: e.target.value })} />
                            </label>
                            <label style={{ display: 'grid', gap: 4 }}>
                              Sits under
                              <select value={draft.parent_id}
                                      onChange={(e) =>
                                        setDraft({ ...draft, parent_id: e.target.value })}>
                                <option value="">— top level —</option>
                                {tags.filter((x) => !forbidden.has(x.id)).map((x) => (
                                  <option key={x.id} value={x.id}>{x.label}</option>
                                ))}
                              </select>
                            </label>
                            <label style={{ display: 'grid', gap: 4 }}>
                              Planned minutes
                              <input type="number" min={0} value={draft.nominal_minutes}
                                     style={{ width: 110 }} placeholder="blank = unset"
                                     onChange={(e) =>
                                       setDraft({ ...draft, nominal_minutes: e.target.value })} />
                            </label>
                            <label style={{ display: 'grid', gap: 4 }}>
                              Order
                              <input type="number" min={0} value={draft.sort_order}
                                     style={{ width: 80 }}
                                     onChange={(e) =>
                                       setDraft({ ...draft, sort_order: e.target.value })} />
                            </label>
                            <button className="primary" type="submit" disabled={busy}>Save</button>
                            <button className="ghost" type="button"
                                    onClick={() => setEditing(null)}>Cancel</button>
                          </form>
                        </td>
                      </tr>
                    ) : (
                      <tr key={t.id}>
                        <td style={{ paddingLeft: 18 + depth * 20 }}>
                          {depth > 0 && <span className="muted" aria-hidden="true">└ </span>}
                          {t.label}
                        </td>
                        <td className="num muted">{t.code}</td>
                        <td className="num">
                          {t.nominal_minutes == null
                            ? <span className="muted">—</span>
                            : <>{t.nominal_minutes}<span className="unit"> min</span></>}
                        </td>
                        <td className="num">
                          {Number(t.delivered_minutes) === 0
                            ? <span className="muted">—</span>
                            : <>{t.delivered_minutes}<span className="unit"> min</span></>}
                        </td>
                        <td>
                          {t.nominal_minutes == null
                            ? <Flag tone="neutral" glyph="?" label="Not possible"
                                    title="No planned time on this tag, so delivered minutes have nothing to be short of. The analysis can only say “taught badly”, never “never got the hours”." />
                            : Number(t.delivered_minutes) === 0
                              ? <Flag tone="neutral" glyph="◷" label="No lessons recorded"
                                      title="Planned time is set, but no lesson has been recorded against this tag, so time can be neither ruled in nor out." />
                              : <Flag tone="good" glyph="✓" label="Possible"
                                      title="Planned time and delivered lessons both exist, so the per-class delivery ratio can be computed." />}
                        </td>
                        <td>
                          {tax.is_editable && (
                            <div className="row" style={{ gap: 4 }}>
                              <button className="ghost" disabled={busy} onClick={() => {
                                setEditing(t.id)
                                setDraft({
                                  label: t.label,
                                  parent_id: t.parent_id ?? '',
                                  sort_order: String(t.sort_order),
                                  nominal_minutes: t.nominal_minutes == null
                                    ? '' : String(t.nominal_minutes),
                                })
                              }}>Edit</button>
                              <button className="ghost" disabled={busy} onClick={() => {
                                if (!confirm(`Delete “${t.label}”?`)) return
                                void run(() => api.post(`/admin/tags/${t.id}/delete`))
                              }}>Delete</button>
                            </div>
                          )}
                        </td>
                      </tr>
                    )
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <p className="note">
            Delivered minutes are the school-wide total across every class that recorded a lesson
            on the tag. That is not the per-class delivery ratio the analysis uses to flag
            under-teaching — classes have different timetables, and a ratio pooled across them
            would be a number the data does not support. Use it to see whether lessons are being
            recorded at all.
            {untimed.length > 0 && (
              <> <span className="num">{untimed.length}</span> leaf {untimed.length === 1
                ? 'tag has' : 'tags have'} no planned time.</>
            )}
          </p>

          {tax.is_editable && (
            <form className="row" style={{ alignItems: 'flex-end', gap: 10 }}
                  onSubmit={(e) => {
                    e.preventDefault()
                    void run(async () => {
                      await api.post('/admin/tags', {
                        taxonomy_id: tax.id, code: ntCode, label: ntLabel,
                        parent_id: ntParent || null,
                        nominal_minutes: ntMinutes === '' ? null : Number(ntMinutes),
                      })
                      setNtCode(''); setNtLabel(''); setNtMinutes('')
                    })
                  }}>
              <label style={{ display: 'grid', gap: 4 }}>
                Tag
                <input required value={ntLabel} placeholder="Forces and motion"
                       style={{ width: 200 }}
                       onChange={(e) => setNtLabel(e.target.value)} />
              </label>
              <label style={{ display: 'grid', gap: 4 }}>
                Code
                <input required value={ntCode} placeholder="FORCES" style={{ width: 120 }}
                       onChange={(e) => setNtCode(e.target.value)} />
              </label>
              <label style={{ display: 'grid', gap: 4 }}>
                Sits under
                <select value={ntParent} onChange={(e) => setNtParent(e.target.value)}>
                  <option value="">— top level —</option>
                  {rows.map(({ tag, depth }) => (
                    <option key={tag.id} value={tag.id}>
                      {' '.repeat(depth * 2)}{tag.label}
                    </option>
                  ))}
                </select>
              </label>
              <label style={{ display: 'grid', gap: 4 }}>
                Planned minutes
                <input type="number" min={0} value={ntMinutes} style={{ width: 120 }}
                       placeholder="optional"
                       onChange={(e) => setNtMinutes(e.target.value)} />
              </label>
              <button className="primary" type="submit" disabled={busy}>Add tag</button>
            </form>
          )}
        </section>
      )}

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Grading frameworks</h2>
          <span className="sub">
            Already configured on this installation. Nothing here needs authoring.
          </span>
        </header>
        {frameworks.length === 0 ? (
          <div className="empty">No frameworks seeded.</div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Framework</th><th>Body</th><th>Version</th>
                  <th align="right">Classes bound</th><th />
                </tr>
              </thead>
              <tbody>
                {byFramework.map((versions) => versions.map((f, i) => (
                  <tr key={f.framework_version_id}>
                    <td>{i === 0 ? <strong>{f.name}</strong> : <span className="muted">↳</span>}</td>
                    <td className="secondary">{i === 0 ? (f.awarding_body ?? '—') : ''}</td>
                    <td>{f.version_label}</td>
                    <td className="num">{f.n_groups}</td>
                    <td>
                      {f.is_school_authored && (
                        <Flag tone="neutral" glyph="✎" label="Yours"
                              title="Authored by this school rather than published by the platform." />
                      )}
                    </td>
                  </tr>
                )))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Classes and their framework</h2>
          <span className="sub">Optional. A class with no framework is not broken.</span>
        </header>
        <p className="muted" style={{ fontSize: 'var(--t-small)', maxWidth: 680 }}>
          Binding a class to a framework is what lets the product convert raw marks into MYP
          levels, DP grades, μόρια projections or predicted GCSEs. It is not a prerequisite for
          anything else: a class with no framework still records marks at question grain and
          still gets trajectory, topic and gap analytics. Leave it unset until the school
          actually wants the awarded grade.
        </p>
        {groups.length === 0 ? (
          <div className="empty">No classes in the current academic year.</div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Class</th><th>Subject</th><th>Year</th>
                  <th align="right">Students</th><th>Framework</th>
                </tr>
              </thead>
              <tbody>
                {groups.map((g) => (
                  <tr key={g.id}>
                    <td>{g.label}</td>
                    <td className="secondary">{g.subject_name}</td>
                    <td className="muted">{g.year_level ?? '—'}</td>
                    <td className="num">{g.n_students}</td>
                    <td>
                      <select value={g.framework_version_id ?? ''} disabled={busy}
                              aria-label={`Framework for ${g.subject_name} ${g.label}`}
                              onChange={(e) => void run(() =>
                                api.post(`/admin/groups/${g.id}/framework`, {
                                  framework_version_id: e.target.value || null,
                                }))}>
                        <option value="">none — marks still work</option>
                        {frameworks.map((f) => (
                          <option key={f.framework_version_id} value={f.framework_version_id}>
                            {f.name} · {f.version_label}
                          </option>
                        ))}
                      </select>
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
