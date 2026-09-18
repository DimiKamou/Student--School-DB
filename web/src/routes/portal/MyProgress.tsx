import { useEffect, useState } from 'react'
import { api, fmtDate } from '../../lib/api'
import { Sparkline, type Point } from '../../components/Sparkline'
import './portal.css'

/**
 * The portal: what a student, or their guardian, sees.
 *
 * This screen is read-only and deliberately narrower than the teacher's view of
 * the same child. The things it will not render are as considered as the things
 * it will:
 *
 *   - no alerts. 009_rls.sql blocks students and guardians from
 *     analytics.alert by policy, because an "at risk" label handed to a
 *     14-year-old is a self-fulfilling prophecy. The API never reads it.
 *   - no residuals, no confidence intervals, no z-scores, no rank, no class
 *     average, no classmates. A number whose meaning is "compared to the people
 *     sitting next to you" does not belong on a child's own page.
 *   - no verdict the schema marked insufficient_evidence or assessment_artefact.
 *     Those are the database saying it does not know; the screen says so too,
 *     by leaving the topic out rather than guessing at a sentence.
 *
 * Everything that IS shown is phrased as something to do, not something to be:
 * "spend some time on integration by parts", never "you are behind on
 * integration". And where the whole class is weak on a topic, it is the class
 * that is working on it -- a teaching or timetable problem is not a child's
 * fault, and telling them it is would be both wrong and harmful.
 */

type Child = {
  student_id: string
  display_name: string
  relation: string
  is_self: boolean
}

type Enrolment = {
  teaching_group_id: string
  group_label: string
  subject_name: string
  year_level: string | null
}

type TimelinePoint = {
  observed_on: string
  subject_name: string
  group_label: string
  assessment_title: string
  mean_pct: string
  n_responses: string
}

type Topic = {
  tag_id: string
  tag_label: string
  subject_name: string
  group_label: string
  focus: 'going_well' | 'work_on' | 'class_and_you' | 'class_working_on' | 'catch_up'
  own_mean_pct: string | null
  evidence: string
}

type Target = {
  id: string
  subject_name: string | null
  group_label: string | null
  measure_label: string | null
  term_label: string | null
  scale_name: string | null
  target_label: string | null
  target_pct: string | null
  current_label: string | null
  current_pct: string | null
  current_on: string | null
  current_status: 'recorded' | 'insufficient_evidence' | 'nothing_recorded'
}

type Progress = {
  subject: Child
  children: Child[]
  enrolments: Enrolment[]
  timeline: TimelinePoint[]
  topics: Topic[]
  targets: Target[]
  pooling: { pooling_verdict: string; n_frameworks: string } | null
}

const pct = (v: string | null) => (v == null ? '—' : `${Math.round(Number(v) * 100)}%`)

/** Second person for the student themselves, the child's name for a guardian. */
function sentence(t: Topic, self: boolean, name: string): string {
  switch (t.focus) {
    case 'work_on':
      return self
        ? `Spend some time on ${t.tag_label}.`
        : `Some practice time on ${t.tag_label} would help ${name} most.`
    case 'catch_up':
      return self
        ? `Catch up on the lessons you missed on ${t.tag_label} — ask for the notes.`
        : `${name} missed lessons on ${t.tag_label}. Catching those up comes before extra practice.`
    case 'class_and_you':
      return self
        ? `Your class is still working on ${t.tag_label} together, and some practice of your own there would help too.`
        : `${name}’s class is still working on ${t.tag_label} together, and some practice at home would help as well.`
    case 'class_working_on':
      return self
        ? `Your class is working on ${t.tag_label} together, so it is being picked up in lessons.`
        : `${name}’s class as a whole is still working on ${t.tag_label}.`
    case 'going_well':
      return self
        ? `Keep doing whatever you are doing on ${t.tag_label} — it is working.`
        : `${t.tag_label} is going well. Whatever ${name} is doing there, it is working.`
  }
}

export default function MyProgress() {
  const [data, setData] = useState<Progress | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [chosen, setChosen] = useState<string>('')

  useEffect(() => {
    setErr(null)
    api.get<Progress>(`/portal/progress${chosen ? `?student_id=${chosen}` : ''}`)
      .then(setData)
      .catch((e) => setErr(e.message))
  }, [chosen])

  if (err) return <p className="err">{err}</p>
  if (!data) return <div className="empty">Loading…</div>

  const self = data.subject.is_self
  const first = data.subject.display_name.split(' ')[0] ?? data.subject.display_name

  // Missed lessons come before extra practice: there is no point drilling a
  // topic somebody was never taught. A class-wide topic that also needs their
  // own practice belongs in this list, phrased so the class part stays the
  // class's — not in the class-only list, which would imply nothing to do.
  const ORDER: Record<Topic['focus'], number> = {
    catch_up: 0, work_on: 1, class_and_you: 2, class_working_on: 3, going_well: 4,
  }
  const work = data.topics
    .filter((t) => t.focus === 'catch_up' || t.focus === 'work_on' || t.focus === 'class_and_you')
    .sort((a, b) => ORDER[a.focus] - ORDER[b.focus])
  const classwork = data.topics.filter((t) => t.focus === 'class_working_on')
  const strengths = data.topics.filter((t) => t.focus === 'going_well')

  // One chart per subject. Two subjects on one pair of axes would be comparing
  // standards that are not the same standard.
  const bySubject = new Map<string, { subject_name: string; group_label: string; points: Point[] }>()
  for (const e of data.enrolments) {
    bySubject.set(`${e.subject_name}|${e.group_label}`,
      { subject_name: e.subject_name, group_label: e.group_label, points: [] })
  }
  for (const t of data.timeline) {
    const key = `${t.subject_name}|${t.group_label}`
    let entry = bySubject.get(key)
    if (!entry) {
      entry = { subject_name: t.subject_name, group_label: t.group_label, points: [] }
      bySubject.set(key, entry)
    }
    entry.points.push({
      x: new Date(t.observed_on).getTime(),
      label: new Date(t.observed_on).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }),
      y: Number(t.mean_pct),
      sub: t.assessment_title,
    })
  }
  const subjects = [...bySubject.values()].sort((a, b) => a.subject_name.localeCompare(b.subject_name))

  return (
    <div className="stack">
      <div className="row">
        <h1>{self ? 'Your progress' : `${first}’s progress`}</h1>
        {data.children.length > 1 && (
          <span className="portal-switcher" style={{ marginLeft: 'auto' }}>
            <label htmlFor="portal-child">Showing</label>
            <select id="portal-child" value={chosen || data.subject.student_id}
                    onChange={(e) => setChosen(e.target.value)}>
              {data.children.map((c) => (
                <option key={c.student_id} value={c.student_id}>
                  {c.display_name}{c.is_self ? '' : ` · ${c.relation}`}
                </option>
              ))}
            </select>
          </span>
        )}
      </div>

      <p className="portal-lede">
        {self
          ? 'Your own marked work, and a few things worth putting time into. This page never ranks you against anyone else in your class.'
          : `${first}’s own marked work, and where time would be best spent. This page never ranks ${first} against other children in the class.`}
      </p>

      {data.pooling?.pooling_verdict === 'unsafe_display_separately' && (
        <div className="card">
          <header><h2>Shown one subject at a time</h2></header>
          <p className="secondary" style={{ marginTop: 0 }}>
            {self ? 'Your work' : `${first}’s work`} sits under{' '}
            <span className="num">{data.pooling.n_frameworks}</span> different grading systems.
            A 6 in one is not the same standard as a 6 in another, so nothing here is averaged
            across them.
          </p>
        </div>
      )}

      {data.targets.length > 0 && (
        <section className="card">
          <header>
            <h2>{self ? 'Your target' : 'Target'}</h2>
            <span className="sub">What was set, and where things stand against it.</span>
          </header>
          {data.targets.map((t) => {
            const tp = t.target_pct == null ? null : Number(t.target_pct)
            const cp = t.current_pct == null ? null : Number(t.current_pct)
            return (
              <div className="portal-target" key={t.id}>
                <div className="portal-target-row">
                  <div>
                    <div className="eyebrow">{t.subject_name ?? t.measure_label ?? 'Target'}</div>
                    <div className="portal-figure">
                      {t.current_label ?? '—'}
                      <span className="unit" style={{ fontSize: 'var(--t-body)' }}>
                        {' '}now · target {t.target_label ?? '—'}
                      </span>
                    </div>
                  </div>
                  {t.current_status === 'recorded' && tp != null && cp != null && cp >= tp && (
                    <span className="pill good">
                      <span className="glyph" aria-hidden="true">✓</span>Target met
                    </span>
                  )}
                </div>

                {/* The bar is drawn only when both ends are real numbers on the
                    same scale. Otherwise the words stand on their own. */}
                {t.current_status === 'recorded' && tp != null && cp != null && (
                  <>
                    <div className="portal-track">
                      <div className="portal-track-fill"
                           style={{ width: `${Math.max(0, Math.min(1, cp)) * 100}%` }} />
                      <div className="portal-track-target"
                           style={{ left: `${Math.max(0, Math.min(1, tp)) * 100}%` }}
                           title={`Target: ${t.target_label ?? ''}`} />
                    </div>
                    <div className="portal-track-legend">
                      <span>Where things are now</span>
                      <span>| marks the target</span>
                    </div>
                  </>
                )}

                <div className="portal-action-meta">
                  {t.current_status === 'nothing_recorded' && (
                    <>No graded result has been recorded against this target yet, so there is
                    nothing honest to measure it with.</>
                  )}
                  {t.current_status === 'insufficient_evidence' && (
                    <>There is not enough marked work yet to say where{' '}
                    {self ? 'you are' : `${first} is`} against this target. A number here would
                    be a guess.</>
                  )}
                  {t.current_status === 'recorded' && (
                    <>{t.measure_label ?? t.scale_name ?? 'Grade'}
                      {t.term_label ? ` · ${t.term_label}` : ''}
                      {t.current_on ? ` · recorded ${fmtDate(t.current_on)}` : ''}</>
                  )}
                </div>
              </div>
            )
          })}
        </section>
      )}

      <section className="card">
        <header>
          <h2>{self ? 'Your marks over time' : 'Marks over time'}</h2>
          <span className="sub">One chart per subject. Each point is one marked piece of work.</span>
        </header>
        {subjects.length === 0 ? (
          <div className="empty">No classes on the register yet.</div>
        ) : (
          subjects.map((s) => (
            <div className="portal-subject" key={`${s.subject_name}|${s.group_label}`}>
              <div className="portal-subject-head">
                <h3>{s.subject_name}</h3>
                <span className="muted" style={{ fontSize: 'var(--t-small)' }}>{s.group_label}</span>
              </div>
              {s.points.length === 0
                ? <div className="empty">Nothing marked in this subject yet.</div>
                : <Sparkline points={s.points} yLabel="Score" />}
            </div>
          ))
        )}
      </section>

      <section className="card">
        <header>
          <h2>Worth some time</h2>
          <span className="sub">Things to do, in the order they would help most.</span>
        </header>
        {work.length === 0 ? (
          <div className="empty">
            Nothing stands out right now. That can also mean there isn’t enough marked work
            tagged to topics yet — it is not a verdict either way.
          </div>
        ) : (
          <ul className="portal-actions">
            {work.map((t) => (
              <li key={`${t.tag_id}|${t.group_label}`}>
                <div className="portal-action-text">{sentence(t, self, first)}</div>
                <div className="portal-action-meta">
                  {t.subject_name}
                  {t.own_mean_pct != null && <> · {pct(t.own_mean_pct)} of the marks so far</>}
                  {' · based on '}<span className="num">{t.evidence}</span>{' marked questions'}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      {classwork.length > 0 && (
        <section className="card">
          <header>
            <h2>What the class is working on</h2>
            <span className="sub">
              These are topics the whole class is still on. Not {self ? 'your' : 'a'} personal gap.
            </span>
          </header>
          <ul className="portal-actions">
            {classwork.map((t) => (
              <li key={`${t.tag_id}|${t.group_label}`}>
                <div className="portal-action-text">{sentence(t, self, first)}</div>
                <div className="portal-action-meta">{t.subject_name} · {t.group_label}</div>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="card">
        <header>
          <h2>Going well</h2>
          <span className="sub">Worth saying out loud, and worth keeping up.</span>
        </header>
        {strengths.length === 0 ? (
          <div className="empty">
            Not enough marked work tagged to topics yet to point at a strength.
          </div>
        ) : (
          <ul className="portal-actions">
            {strengths.map((t) => (
              <li key={`${t.tag_id}|${t.group_label}`}>
                <div className="portal-action-text">{sentence(t, self, first)}</div>
                <div className="portal-action-meta">
                  {t.subject_name}
                  {t.own_mean_pct != null && <> · {pct(t.own_mean_pct)} of the marks so far</>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* Saying what is deliberately absent is part of the product, not a
          disclaimer. A page that quietly omits things teaches people to assume
          the worst about what it is hiding. */}
      <section className="card">
        <header><h2>What this page does not show</h2></header>
        <ul className="muted" style={{ margin: 0, paddingLeft: 18, lineHeight: 1.6 }}>
          <li>No class ranking, and no comparison with any other student by name or position.</li>
          <li>
            No topic where there isn’t enough marked work to say something honest. Those are left
            out rather than filled in with a guess.
          </li>
          <li>
            No prediction of a final grade. {self ? 'Your' : 'A'} target, where one has been set,
            is shown as it was set — it is not re-forecast here.
          </li>
          <li>
            Absence is never counted as a zero anywhere in{' '}
            {self ? 'your' : `${first}’s`} figures.
          </li>
        </ul>
      </section>
    </div>
  )
}
