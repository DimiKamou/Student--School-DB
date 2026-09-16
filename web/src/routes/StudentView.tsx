import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { api, type StudentProfile } from '../lib/api'
import { Pill } from '../components/Pill'
import { Sparkline, type Point } from '../components/Sparkline'

export default function StudentView() {
  const { studentId } = useParams()
  const [p, setP] = useState<StudentProfile | null>(null)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    api.get<StudentProfile>(`/students/${studentId}`).then(setP).catch((e) => setErr(e.message))
  }, [studentId])

  if (err) return <p className="err">{err}</p>
  if (!p) return <div className="empty">Loading…</div>

  const points: Point[] = p.timeline.map((t) => ({
    x: new Date(t.observed_on).getTime(),
    label: new Date(t.observed_on).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }),
    y: Number(t.mean_pct),
    sub: `${t.assessment_title} · ${t.subject_name}`,
  }))
  const name = `${p.student.preferred_name ?? p.student.given_name} ${p.student.family_name}`

  return (
    <div className="stack">
      <div className="row">
        <h1>{name}</h1>
        {p.trajectory.map((t, i) => <Pill key={i} value={t.trajectory} />)}
      </div>

      {p.pooling?.pooling_verdict === 'unsafe_display_separately' && (
        <div className="card" style={{ borderColor: 'var(--serious)' }}>
          <strong>Shown separately by framework.</strong>{' '}
          <span className="secondary">
            This student has work under {p.pooling.n_frameworks} different grading systems whose
            scales have not been equated. Averaging across them would be arithmetic on a false
            premise, so it isn’t done here.
          </span>
        </div>
      )}

      <section className="card">
        <header>
          <h2>Score over time</h2>
          <span className="sub">Raw score per assessment. The adjusted figures are in the table below.</span>
        </header>
        <Sparkline points={points} yLabel="Score" />
      </section>

      <section className="card">
        <header>
          <h2>Where they stand, by topic</h2>
          <span className="sub">Ranked by what needs action first.</span>
        </header>
        {p.gaps.length === 0 ? <div className="empty">Not enough tagged marks yet.</div> : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Topic</th><th>Verdict</th>
                  <th style={{ textAlign: 'right' }}>Their avg</th>
                  <th style={{ textAlign: 'right' }}>Class avg</th>
                  <th style={{ textAlign: 'right' }}>vs own baseline</th>
                  <th style={{ textAlign: 'right' }}>Evidence</th>
                  <th>Context</th>
                </tr>
              </thead>
              <tbody>
                {p.gaps.map((g) => (
                  <tr key={g.tag_id + g.teaching_group_id}>
                    <td>{g.tag_label}<div className="muted" style={{ fontSize: 12 }}>{g.group_label}</div></td>
                    <td><Pill value={g.verdict} /></td>
                    <td className="tabular" style={{ textAlign: 'right' }}>
                      {g.mean_pct == null ? '—' : `${Math.round(Number(g.mean_pct) * 100)}%`}
                    </td>
                    <td className="tabular muted" style={{ textAlign: 'right' }}>
                      {g.cohort_mean_pct == null ? '—' : `${Math.round(Number(g.cohort_mean_pct) * 100)}%`}
                    </td>
                    <td className="tabular" style={{ textAlign: 'right' }}>
                      {g.mean_residual == null ? '—'
                        : `${Number(g.mean_residual) > 0 ? '+' : ''}${(Number(g.mean_residual) * 100).toFixed(1)}pp`}
                    </td>
                    <td className="tabular muted" style={{ textAlign: 'right' }}>
                      {g.n_responses} marks<br />
                      <span style={{ fontSize: 11 }}>{g.n_assessments} tasks</span>
                    </td>
                    <td>
                      {g.time_context === 'under_taught' && <Pill value="under_taught" />}
                      {g.missed_ratio != null && Number(g.missed_ratio) > 0.3 && (
                        <span className="muted" style={{ fontSize: 12 }}>
                          {' '}missed {Math.round(Number(g.missed_ratio) * 100)}% of lessons
                        </span>
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
