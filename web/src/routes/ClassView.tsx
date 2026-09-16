import { useEffect, useState } from 'react'
import { Link, useParams, useNavigate } from 'react-router-dom'
import { api, type Group, type HeatCell, type Student } from '../lib/api'
import { Pill } from '../components/Pill'

/** Sequential blue ramp: one hue, light -> dark, magnitude only. Never a rainbow. */
const RAMP = ['--seq-100','--seq-200','--seq-300','--seq-400','--seq-500','--seq-600','--seq-700']
function rampFor(pct: number | null) {
  if (pct == null) return { background: 'transparent', color: 'var(--text-muted)' }
  const i = Math.min(RAMP.length - 1, Math.max(0, Math.round(pct * (RAMP.length - 1))))
  return {
    background: `var(${RAMP[i]})`,
    // Keep text legible as the fill darkens; ink never wears the series colour.
    color: i >= 4 ? '#fff' : 'var(--text-primary)',
  }
}

export default function ClassView() {
  const { groupId } = useParams()
  const nav = useNavigate()
  const [groups, setGroups] = useState<Group[]>([])
  const [heat, setHeat] = useState<HeatCell[]>([])
  const [roster, setRoster] = useState<Student[]>([])
  const [coverage, setCoverage] = useState<{ term_label: string; identifiability: string; caveat: string | null }[]>([])
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => { api.get<Group[]>('/groups').then(setGroups).catch((e) => setErr(e.message)) }, [])
  useEffect(() => {
    if (!groupId) { setHeat([]); setRoster([]); return }
    Promise.all([
      api.get<HeatCell[]>(`/groups/${groupId}/heatmap`),
      api.get<Student[]>(`/groups/${groupId}/roster`),
      api.get<any[]>(`/groups/${groupId}/coverage`),
    ]).then(([h, r, c]) => { setHeat(h); setRoster(r); setCoverage(c) })
      .catch((e) => setErr(e.message))
  }, [groupId])

  const group = groups.find((g) => g.id === groupId)

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}
      <div className="row">
        <h1>{group ? `${group.subject_name} · ${group.label}` : 'Classes'}</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <select value={groupId ?? ''} onChange={(e) => nav(e.target.value ? `/classes/${e.target.value}` : '/classes')}>
          <option value="">Choose a class…</option>
          {groups.map((g) => (
            <option key={g.id} value={g.id}>{g.subject_name} · {g.label} ({g.n_students})</option>
          ))}
        </select>
      </div>

      {!groupId && (
        <div className="card">
          <header><h2>Your classes</h2></header>
          {groups.length === 0 ? <div className="empty">No classes assigned to you.</div> : (
            <table>
              <thead><tr><th>Class</th><th>Subject</th><th>Year</th><th>Students</th><th>Framework</th></tr></thead>
              <tbody>
                {groups.map((g) => (
                  <tr key={g.id}>
                    <td><Link to={`/classes/${g.id}`}>{g.label}</Link></td>
                    <td>{g.subject_name}</td>
                    <td className="secondary">{g.year_level ?? '—'}</td>
                    <td className="tabular">{g.n_students}</td>
                    <td className="muted">{g.framework ?? 'none — marks still work'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}

      {groupId && (
        <>
          <section className="card">
            <header>
              <h2>Topics</h2>
              <span className="sub">
                Shading is the class average. The verdict is what to do about it.
              </span>
            </header>
            {heat.length === 0 ? (
              <div className="empty">
                No tagged marks yet. Tag an assessment to one topic and this fills in.
              </div>
            ) : (
              <div className="scroll-x">
                <table>
                  <thead>
                    <tr>
                      <th>Topic</th><th style={{ textAlign: 'right' }}>Class avg</th>
                      <th>Verdict</th><th>Teaching time</th>
                      <th style={{ textAlign: 'right' }}>Students behind</th>
                      <th style={{ textAlign: 'right' }}>Marks</th>
                    </tr>
                  </thead>
                  <tbody>
                    {heat.map((h) => {
                      const pct = h.cohort_mean_pct == null ? null : Number(h.cohort_mean_pct)
                      return (
                        <tr key={h.tag_id}>
                          <td>{h.tag_label}</td>
                          <td style={{ textAlign: 'right' }}>
                            {/* Direct label on every cell: the fill is never the only channel. */}
                            <span className="heat-cell" style={rampFor(pct)}>
                              {pct == null ? '—' : `${Math.round(pct * 100)}%`}
                            </span>
                          </td>
                          <td><Pill value={h.cohort_verdict} /></td>
                          <td>
                            {h.delivery_ratio == null ? <Pill value="time_not_recorded" />
                              : Number(h.delivery_ratio) < 0.6 ? <Pill value="under_taught" />
                              : <span className="muted tabular">{h.lessons_delivered} lessons</span>}
                          </td>
                          <td className="tabular" style={{ textAlign: 'right' }}>{h.n_students_below}</td>
                          <td className="tabular muted" style={{ textAlign: 'right' }}>{h.n_responses}</td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {coverage.some((c) => c.caveat) && (
            <section className="card">
              <header><h2>What this data can and cannot tell you</h2></header>
              {/* One caveat per distinct reason, listing the terms it applies to.
                  Repeating identical prose per term trains people to skip it. */}
              <ul className="muted" style={{ margin: 0, paddingLeft: 18 }}>
                {[...new Map(coverage.filter((c) => c.caveat)
                  .map((c) => [c.caveat!, coverage.filter((x) => x.caveat === c.caveat)
                    .map((x) => x.term_label)])).entries()].map(([caveat, terms], i) => (
                  <li key={i} style={{ marginBottom: 6 }}>
                    <strong>{terms.join(', ')}:</strong> {caveat}
                  </li>
                ))}
              </ul>
            </section>
          )}

          <section className="card">
            <header><h2>Students</h2><span className="sub">{roster.length} on roll</span></header>
            <div className="scroll-x">
              <table>
                <thead><tr><th>Name</th><th>Ref</th></tr></thead>
                <tbody>
                  {roster.map((s) => (
                    <tr key={s.id}>
                      <td><Link to={`/students/${s.id}`}>{s.family_name}, {s.preferred_name ?? s.given_name}</Link></td>
                      <td className="muted">{s.external_ref ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}
    </div>
  )
}
