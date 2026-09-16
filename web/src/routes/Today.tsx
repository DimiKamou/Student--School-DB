import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, fmtDate, type Attention, type Todo } from '../lib/api'
import { Pill } from '../components/Pill'

/**
 * The landing screen, and the one that decides whether this product reads as
 * help or as admin. Two lists only: what needs your judgement, and what you
 * still owe. Both are capped. A wall of every student who dipped once is how
 * teachers learn to ignore the whole thing.
 */
export default function Today() {
  const [attention, setAttention] = useState<Attention[]>([])
  const [todo, setTodo] = useState<Todo[]>([])
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    Promise.all([api.get<Attention[]>('/attention?limit=5'), api.get<Todo[]>('/todo')])
      .then(([a, t]) => { setAttention(a); setTodo(t) })
      .catch((e) => setErr(e.message))
  }, [])

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <section className="card">
        <header>
          <h1>Worth your attention</h1>
          <span className="sub">Whole-class findings first — one action there helps everyone.</span>
        </header>
        {attention.length === 0 ? (
          <div className="empty">Nothing flagged. Either everything is fine or there isn’t enough data yet.</div>
        ) : (
          <div className="stack" style={{ gap: 10 }}>
            {attention.map((a, i) => (
              <div key={i} className="row" style={{ alignItems: 'flex-start', gap: 10 }}>
                <Pill value={a.kind === 'systemic_topic_gap' ? 'systemic'
                  : a.kind === 'trajectory_decline' ? 'declining' : 'individual'} />
                <div style={{ flex: 1, minWidth: 220 }}>
                  <div>
                    {a.student_id
                      ? <Link to={`/students/${a.student_id}`}>{a.headline}</Link>
                      : a.headline}
                  </div>
                  <div className="muted" style={{ fontSize: 12 }}>
                    {a.group_label} · {a.evidence} marks
                    {a.time_context === 'under_taught' && ' · received well under its planned teaching time'}
                  </div>
                </div>
                {a.time_context === 'under_taught' && <Pill value="under_taught" />}
              </div>
            ))}
          </div>
        )}
      </section>

      <section className="card">
        <header>
          <h2>Still to mark</h2>
          <span className="sub">Counted against the register, so “no rows” never masquerades as “nothing to do”.</span>
        </header>
        {todo.length === 0 ? (
          <div className="empty">Nothing outstanding.</div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr><th>Assessment</th><th>Class</th><th>Outstanding</th><th>Set</th><th /></tr>
              </thead>
              <tbody>
                {todo.map((t) => (
                  <tr key={t.assessment_id}>
                    <td>{t.title}</td>
                    <td className="secondary">{t.group_label}</td>
                    <td className="tabular">
                      <strong>{t.students_outstanding}</strong>
                      <span className="muted"> of {t.students_expected}</span>
                    </td>
                    <td className="muted tabular" title={fmtDate(t.occurred_on)}>{t.days_since}d ago</td>
                    <td><Link to={`/assessments/${t.assessment_id}`}>Mark →</Link></td>
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
