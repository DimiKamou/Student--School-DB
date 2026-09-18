import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { api, fmtDate, type Group } from '../lib/api'
import { Pill } from '../components/Pill'
import {
  NEEDS_WORK, fullName, groupBy, pct, sortGaps,
  type GapRow, type GroupHead, type RosterStudent, type TrajectoryRow,
} from './Reports'
import './reports.css'

export type AttendanceRow = {
  student_id: string
  lessons_tracked: string
  lessons_missed: string
  lessons_late: string
}

export type PrepPack = {
  group: GroupHead
  students: RosterStudent[]
  gaps: GapRow[]
  trajectory: TrajectoryRow[]
  attendance: AttendanceRow[]
  lessons_held: number
  generated_on: string
}

const TRAJECTORY_SENTENCE: Record<string, string> = {
  improving: 'Recent work sits above their own earlier baseline.',
  declining: 'Recent work sits below their own earlier baseline. Worth asking what changed.',
  stable: 'Holding their position against the class’s own movement.',
  no_baseline: 'Not enough earlier work to compare against yet.',
  insufficient_recent_evidence: 'Nothing recent enough to judge a trend.',
}

/**
 * One printable page per student: what to say, what to ask, and room to write
 * down what the parent tells you.
 *
 * Everything on the sheet is something the marks support. Where they do not
 * support it — no register kept, no topic tagging, too few marks — the sheet
 * says that in words rather than leaving a blank that reads as a zero. A
 * parents' evening is exactly where an overclaimed number does the most damage,
 * because it gets repeated at home for a year.
 */
export default function ParentsEvening() {
  const { groupId } = useParams()
  const nav = useNavigate()
  const [groups, setGroups] = useState<Group[]>([])
  const [pack, setPack] = useState<PrepPack | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => { api.get<Group[]>('/groups').then(setGroups).catch((e) => setErr(e.message)) }, [])

  useEffect(() => {
    if (!groupId) { setPack(null); return }
    setLoading(true)
    api.get<PrepPack>(`/parents-evening/groups/${groupId}`)
      .then((p) => { setPack(p); setErr(null) })
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [groupId])

  const gapsByStudent = useMemo(() => groupBy(pack?.gaps ?? [], (g) => g.student_id), [pack])
  const trajByStudent = useMemo(() => groupBy(pack?.trajectory ?? [], (t) => t.student_id), [pack])
  const attByStudent = useMemo(() => {
    const m = new Map<string, AttendanceRow>()
    for (const a of pack?.attendance ?? []) m.set(a.student_id, a)
    return m
  }, [pack])

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <div className="row no-print">
        <h1>{pack ? `Parents’ evening · ${pack.group.subject_name} ${pack.group.label}` : 'Parents’ evening'}</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <select value={groupId ?? ''}
                onChange={(e) => nav(e.target.value ? `/parents-evening/${e.target.value}` : '/parents-evening')}>
          <option value="">Choose a class…</option>
          {groups.map((g) => (
            <option key={g.id} value={g.id}>{g.subject_name} · {g.label} ({g.n_students})</option>
          ))}
        </select>
        {pack && <button className="primary" onClick={() => window.print()}>Print sheets</button>}
      </div>

      {!groupId && (
        <section className="card">
          <header>
            <h2>Pick a class</h2>
            <span className="sub">One page per student, ready to print and write on.</span>
          </header>
          {groups.length === 0 ? <div className="empty">No classes assigned to you.</div> : (
            <table>
              <thead><tr><th>Class</th><th>Subject</th><th align="right">Students</th><th /></tr></thead>
              <tbody>
                {groups.map((g) => (
                  <tr key={g.id}>
                    <td><Link to={`/parents-evening/${g.id}`}>{g.label}</Link></td>
                    <td className="secondary">{g.subject_name}</td>
                    <td className="num">{g.n_students}</td>
                    <td><Link to={`/reports/${g.id}`}>Write reports →</Link></td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      )}

      {loading && <div className="empty">Loading…</div>}

      {pack && (
        <>
          <div className="note no-print">
            One sheet per student, in register order. Printing gives one page each with the
            navigation and controls removed. Everything printed is drawn from recorded marks;
            where there is nothing to draw on, the sheet says so rather than leaving a gap that
            reads as a problem.
          </div>

          {pack.students.length === 0 && <div className="empty">Nobody is enrolled in this class.</div>}

          {pack.students.map((s) => {
            const gaps = sortGaps(gapsByStudent.get(s.id) ?? [])
            const traj = trajByStudent.get(s.id) ?? []
            const att = attByStudent.get(s.id)
            const strengths = gaps.filter((g) => g.verdict === 'ok')
              .sort((a, b) => Number(b.mean_pct ?? 0) - Number(a.mean_pct ?? 0)).slice(0, 3)
            const work = gaps.filter((g) => NEEDS_WORK.has(g.verdict)).slice(0, 2)
            const absence = gaps.filter((g) => g.verdict === 'explained_by_absence').slice(0, 2)
            const thin = gaps.filter((g) => g.verdict === 'insufficient_evidence').length

            const tracked = Number(att?.lessons_tracked ?? 0)
            const missed = Number(att?.lessons_missed ?? 0)
            const late = Number(att?.lessons_late ?? 0)

            return (
              <section className="card prep-sheet" key={s.id}>
                <div className="prep-head">
                  <h2>{fullName(s)}</h2>
                  <span className="secondary">
                    {pack.group.subject_name} · {pack.group.label}
                    {pack.group.year_level ? ` · ${pack.group.year_level}` : ''}
                  </span>
                  <span className="spacer" style={{ marginLeft: 'auto' }} />
                  <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
                    {s.external_ref ? `${s.external_ref} · ` : ''}prepared {fmtDate(pack.generated_on)}
                  </span>
                </div>

                <div className="prep-cols">
                  <div>
                    <h4>Strengths</h4>
                    {strengths.length === 0 ? (
                      <p className="muted" style={{ margin: 0, fontSize: 'var(--t-small)' }}>
                        No topic reads as a clear strength on the marks recorded so far.
                      </p>
                    ) : (
                      <ul className="prep-list">
                        {strengths.map((g) => (
                          <li key={g.tag_id}>
                            <strong>{g.tag_label}</strong>{' '}
                            <span className="num">{pct(g.mean_pct)}</span>{' '}
                            <span className="muted">
                              (class <span className="num">{pct(g.cohort_mean_pct)}</span>,{' '}
                              <span className="num">{g.n_responses}</span> marks)
                            </span>
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>

                  <div>
                    <h4>Worth working on</h4>
                    {work.length === 0 && absence.length === 0 ? (
                      <p className="muted" style={{ margin: 0, fontSize: 'var(--t-small)' }}>
                        Nothing is flagged. Either the work is holding up or there is not yet
                        enough of it to say otherwise.
                      </p>
                    ) : (
                      <ul className="prep-list">
                        {work.map((g) => (
                          <li key={g.tag_id}>
                            <strong>{g.tag_label}</strong> <Pill value={g.verdict} />
                            <div className="muted">
                              <span className="num">{pct(g.mean_pct)}</span> against a class{' '}
                              <span className="num">{pct(g.cohort_mean_pct)}</span>
                              {g.verdict === 'systemic' && ' — this one is the class’s, not theirs'}
                              {g.time_context === 'under_taught' && ' · under-taught this year'}
                            </div>
                          </li>
                        ))}
                        {absence.map((g) => (
                          <li key={g.tag_id}>
                            <strong>{g.tag_label}</strong> <Pill value="explained_by_absence" />
                            <div className="muted">
                              Lessons missed account for this. Not an ability question.
                            </div>
                          </li>
                        ))}
                      </ul>
                    )}
                    {thin > 0 && (
                      <p className="muted" style={{ marginTop: 6, fontSize: 'var(--t-micro)' }}>
                        <span className="num">{thin}</span>{' '}
                        {thin === 1 ? 'other topic has' : 'other topics have'} too few marks to judge.
                        No figure is shown for {thin === 1 ? 'it' : 'them'}.
                      </p>
                    )}
                  </div>

                  <div>
                    <h4>Direction of travel</h4>
                    {traj.length === 0 ? (
                      <p className="muted" style={{ margin: 0, fontSize: 'var(--t-small)' }}>
                        No trajectory yet — that needs marks from more than one point in the year.
                      </p>
                    ) : traj.map((t, i) => (
                      <p key={i} style={{ margin: '0 0 6px', fontSize: 'var(--t-small)' }}>
                        <Pill value={t.trajectory} />{' '}
                        <span className="secondary">
                          {TRAJECTORY_SENTENCE[t.trajectory] ?? ''}
                        </span>
                        <br />
                        <span className="muted" style={{ fontSize: 'var(--t-micro)' }}>
                          <span className="num">{t.n_recent}</span> recent marks vs{' '}
                          <span className="num">{t.n_prior}</span> earlier.
                        </span>
                      </p>
                    ))}

                    <h4 style={{ marginTop: 12 }}>Attendance</h4>
                    {/* A register that was never taken is not 100% attendance. */}
                    {tracked === 0 ? (
                      <p className="muted" style={{ margin: 0, fontSize: 'var(--t-small)' }}>
                        No register recorded for this class
                        {pack.lessons_held > 0
                          ? ` (${pack.lessons_held} lessons logged, none with attendance)`
                          : ''}
                        , so attendance cannot be offered as context either way.
                      </p>
                    ) : (
                      <p style={{ margin: 0, fontSize: 'var(--t-small)' }}>
                        Present for <span className="num">{tracked - missed}</span> of{' '}
                        <span className="num">{tracked}</span> recorded lessons
                        {late > 0 && <> · late <span className="num">{late}</span></>}.
                        {missed / tracked > 0.3 && (
                          <><br /><span className="secondary">
                            Over a third missed — worth raising before anything about the work.
                          </span></>
                        )}
                      </p>
                    )}
                  </div>
                </div>

                <div>
                  <h4 style={{
                    margin: '14px 0 0', fontSize: 'var(--t-micro)', fontWeight: 600,
                    letterSpacing: '0.085em', textTransform: 'uppercase', color: 'var(--text-muted)',
                  }}>
                    Notes from the conversation
                  </h4>
                  <div className="note-lines" />
                </div>
              </section>
            )
          })}
        </>
      )}
    </div>
  )
}
