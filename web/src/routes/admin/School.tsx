import { useCallback, useEffect, useState } from 'react'
import { api, fmtDate } from '../../lib/api'
import { AdminTabs } from './People'

/**
 * SCHOOL — the calendar every analytic is keyed by, the structure marks hang
 * off, and the two governance settings that decide whether staff keep using
 * this product at all.
 *
 * The calendar is not administrivia here. Terms are the reporting periods the
 * period-effect analysis groups on, by date: a year with no terms produces no
 * period analysis, and a gap between two terms silently drops every mark that
 * falls in it. So this screen checks the calendar for gaps and overlaps and
 * says what the consequence is, rather than presenting terms as a tidy list.
 */

type Tenant = {
  id: string
  name: string
  slug: string
  country_code: string
  timezone: string
  plan: string
  subscription_ends_on: string | null
  alert_budget_weekly: number
  leadership_delay_days: number
  data_retention_years: number
}
type Year = {
  id: string; label: string; starts_on: string; ends_on: string; is_current: boolean
  n_terms: string; n_groups: string
}
type Term = {
  id: string; academic_year_id: string; label: string; seq: number
  starts_on: string; ends_on: string; is_reporting: boolean
}
type Department = { id: string; name: string; n_subjects: string }
type Subject = {
  id: string; code: string; name: string
  department_id: string | null; department_name: string | null; n_groups: string
}
type SchoolPayload = {
  tenant: Tenant; years: Year[]; terms: Term[]
  departments: Department[]; subjects: Subject[]
}

function Flag({ tone, glyph, label, title }:
  { tone: 'good' | 'warning' | 'serious' | 'critical' | 'neutral'
    glyph: string; label: string; title: string }) {
  return (
    <span className={`pill ${tone}`} title={title}>
      <span className="glyph" aria-hidden="true">{glyph}</span>{label}
    </span>
  )
}

const DAY = 86_400_000
function days(a: string, b: string): number {
  return Math.round((new Date(b).getTime() - new Date(a).getTime()) / DAY)
}

/**
 * Problems in one year's term structure, in the words of what they cost.
 * Dates are compared as ISO strings ordered lexically, which is exact for
 * YYYY-MM-DD and avoids a timezone shifting a term boundary by a day.
 */
function calendarProblems(year: Year, terms: Term[]): string[] {
  const out: string[] = []
  const ts = [...terms].sort((a, b) => a.starts_on.localeCompare(b.starts_on))
  if (ts.length === 0) {
    out.push('No terms. Every period-level analytic is keyed by term, so this year ' +
      'produces none at all until terms exist.')
    return out
  }
  for (let i = 1; i < ts.length; i++) {
    const prev = ts[i - 1]!, cur = ts[i]!
    if (cur.starts_on <= prev.ends_on) {
      out.push(`${prev.label} and ${cur.label} overlap. A mark in the overlap is counted ` +
        'in whichever term the analysis reaches first.')
    } else if (days(prev.ends_on, cur.starts_on) > 21) {
      out.push(`A ${days(prev.ends_on, cur.starts_on)}-day gap between ${prev.label} and ` +
        `${cur.label}. Marks recorded in that gap belong to no term and drop out of the ` +
        'period analysis.')
    }
  }
  const first = ts[0]!, last = ts[ts.length - 1]!
  if (first.starts_on > year.starts_on) {
    out.push(`Term 1 starts ${days(year.starts_on, first.starts_on)} days after the year does.`)
  }
  if (last.ends_on < year.ends_on) {
    out.push(`The last term ends ${days(last.ends_on, year.ends_on)} days before the year does.`)
  }
  if (!ts.some((t) => t.is_reporting)) {
    out.push('No term is marked as a reporting period.')
  }
  return out
}

export default function School() {
  const [data, setData] = useState<SchoolPayload | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState<string | null>(null)

  const [budget, setBudget] = useState(5)
  const [delay, setDelay] = useState(7)

  const [yLabel, setYLabel] = useState('')
  const [yStart, setYStart] = useState('')
  const [yEnd, setYEnd] = useState('')

  const [tYear, setTYear] = useState('')
  const [tLabel, setTLabel] = useState('')
  const [tSeq, setTSeq] = useState('1')
  const [tStart, setTStart] = useState('')
  const [tEnd, setTEnd] = useState('')

  const [deptName, setDeptName] = useState('')
  const [subCode, setSubCode] = useState('')
  const [subName, setSubName] = useState('')
  const [subDept, setSubDept] = useState('')

  const [refresh, setRefresh] = useState<{ ms: number; at: string } | null>(null)
  const [refreshing, setRefreshing] = useState(false)

  const load = useCallback(async () => {
    try {
      const d = await api.get<SchoolPayload>('/admin/school')
      setData(d)
      setBudget(d.tenant.alert_budget_weekly)
      setDelay(d.tenant.leadership_delay_days)
      if (!tYear) setTYear(d.years.find((y) => y.is_current)?.id ?? d.years[0]?.id ?? '')
      setErr(null)
    } catch (e) { setErr((e as Error).message) }
    // tYear is read only to seed the form once; re-running on every keystroke
    // would fight the user for control of the select.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => { void load() }, [load])

  async function run(fn: () => Promise<unknown>, note?: string) {
    setBusy(true); setErr(null); setSaved(null)
    try { await fn(); await load(); if (note) setSaved(note) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  if (!data) {
    return (
      <div className="stack">
        <div className="row"><h1>School</h1></div>
        {err ? <p className="err">{err}</p> : <div className="empty">Loading…</div>}
      </div>
    )
  }

  const { tenant, years, terms, departments, subjects } = data
  const dirty = budget !== tenant.alert_budget_weekly || delay !== tenant.leadership_delay_days

  return (
    <div className="stack">
      <div className="row">
        <h1>{tenant.name}</h1>
        <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
          {tenant.slug} · {tenant.country_code} · {tenant.timezone}
        </span>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <AdminTabs />
      </div>
      {err && <p className="err">{err}</p>}
      {saved && <p className="saved-flash">{saved}</p>}

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Governance</h2>
          <span className="sub">Two settings that decide whether staff trust this product.</span>
        </header>

        <div style={{ display: 'grid', gap: 22 }}>
          <div>
            <label style={{ display: 'grid', gap: 4, maxWidth: 220 }}>
              <strong style={{ fontSize: 'var(--t-body)' }}>Alert budget</strong>
              <div className="row" style={{ gap: 8 }}>
                <input type="number" min={0} max={50} value={budget} style={{ width: 90 }}
                       onChange={(e) => setBudget(Number(e.target.value))} />
                <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
                  findings per teacher, per run
                </span>
              </div>
            </label>
            <p className="muted" style={{ fontSize: 'var(--t-small)', maxWidth: 640 }}>
              A teacher is sent at most this many findings, and they are the largest ones —
              ranked by effect size, not by whatever sorted first. This is the setting that
              stops the product training people to ignore it. Raise it and every extra finding
              is a smaller one; a teacher who dismisses ten notices a week stops reading the
              first.
            </p>
            {budget === 0 && (
              <p className="note">
                <Flag tone="warning" glyph="●" label="Alerts off"
                      title="No alerts will be raised for anyone." />{' '}
                Nothing will be raised at all. The dashboards still work; nobody is told anything.
              </p>
            )}
            {budget > 10 && (
              <p className="note">
                <Flag tone="warning" glyph="●" label="Above the useful range"
                      title="More than about ten findings a week is the volume at which teachers stop reading them." />{' '}
                More than about ten a week is where staff learn to dismiss the list unread.
              </p>
            )}
          </div>

          <div>
            <label style={{ display: 'grid', gap: 4, maxWidth: 220 }}>
              <strong style={{ fontSize: 'var(--t-body)' }}>Teacher right of first sight</strong>
              <div className="row" style={{ gap: 8 }}>
                <input type="number" min={0} max={90} value={delay} style={{ width: 90 }}
                       onChange={(e) => setDelay(Number(e.target.value))} />
                <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
                  days before leadership sees it
                </span>
              </div>
            </label>
            <p className="muted" style={{ fontSize: 'var(--t-small)', maxWidth: 640 }}>
              When the system flags something systemic about a class — the cohort is weak on a
              topic — the teacher of that class sees it this many days before anyone in
              leadership can. It exists so the first person to hear that a class is struggling
              is the person who can do something about it on Monday, not their line manager.
              Without it the product reads as surveillance and teachers stop entering honest
              formative marks, which is the only input it has.
            </p>
            {delay === 0 && (
              <p className="note">
                <Flag tone="critical" glyph="▲" label="No delay"
                      title="Leadership sees every systemic flag at the same moment as the teacher." />{' '}
                Leadership sees each flag the moment it is raised. This is the configuration
                that turns a diagnostic instrument into a monitoring one; expect the quality of
                formative marking to fall.
              </p>
            )}
          </div>

          <div className="row">
            <button className="primary" disabled={busy || !dirty}
                    onClick={() => void run(() => api.post('/admin/school/settings', {
                      alert_budget_weekly: budget, leadership_delay_days: delay,
                    }), 'Governance settings saved.')}>
              Save
            </button>
            {dirty && (
              <button className="ghost" disabled={busy} onClick={() => {
                setBudget(tenant.alert_budget_weekly); setDelay(tenant.leadership_delay_days)
              }}>Discard</button>
            )}
            <span className="spacer" style={{ marginLeft: 'auto' }} />
            <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
              Plan: {tenant.plan}
              {tenant.subscription_ends_on && ` · until ${fmtDate(tenant.subscription_ends_on)}`}
              {' · retention '}<span className="num">{tenant.data_retention_years}</span> years
            </span>
          </div>
        </div>
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Academic years</h2>
          <span className="sub">One year is current; that is the one the app screens read.</span>
        </header>
        <div className="scroll-x">
          <table>
            <thead>
              <tr>
                <th>Year</th><th>Runs</th><th align="right">Terms</th>
                <th align="right">Classes</th><th>Status</th><th />
              </tr>
            </thead>
            <tbody>
              {years.map((y) => (
                <tr key={y.id}>
                  <td><strong>{y.label}</strong></td>
                  <td className="muted">{fmtDate(y.starts_on)} – {fmtDate(y.ends_on)}</td>
                  <td className="num">{y.n_terms}</td>
                  <td className="num">{y.n_groups}</td>
                  <td>
                    {y.is_current
                      ? <Flag tone="good" glyph="✓" label="Current"
                              title="The year every screen defaults to." />
                      : <Flag tone="neutral" glyph="·" label="Archived"
                              title="Kept for multi-year trends; not shown on teaching screens." />}
                  </td>
                  <td>
                    {!y.is_current && (
                      <button className="ghost" disabled={busy}
                              onClick={() => void run(() =>
                                api.post(`/admin/academic-years/${y.id}/current`),
                              `${y.label} is now the current year.`)}>
                        Make current
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {years.length === 0 && (
                <tr><td colSpan={6}><div className="empty">No academic years yet.</div></td></tr>
              )}
            </tbody>
          </table>
        </div>

        <form className="row" style={{ alignItems: 'flex-end', gap: 10, marginTop: 14 }}
              onSubmit={(e) => {
                e.preventDefault()
                void run(async () => {
                  await api.post('/admin/academic-years', {
                    label: yLabel, starts_on: yStart, ends_on: yEnd,
                    is_current: years.length === 0,
                  })
                  setYLabel(''); setYStart(''); setYEnd('')
                }, 'Academic year added.')
              }}>
          <label style={{ display: 'grid', gap: 4 }}>
            Label
            <input required value={yLabel} placeholder="2026-2027" style={{ width: 130 }}
                   onChange={(e) => setYLabel(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Starts
            <input required type="date" value={yStart}
                   onChange={(e) => setYStart(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Ends
            <input required type="date" value={yEnd}
                   onChange={(e) => setYEnd(e.target.value)} />
          </label>
          <button className="primary" type="submit" disabled={busy}>Add year</button>
        </form>
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Terms</h2>
          <span className="sub">
            The reporting periods every period-level analytic is keyed by — MYP term,
            DP semester, τετράμηνο, half-term.
          </span>
        </header>

        {years.map((y) => {
          const mine = terms.filter((t) => t.academic_year_id === y.id)
            .sort((a, b) => a.seq - b.seq)
          const problems = calendarProblems(y, mine)
          return (
            <div key={y.id} style={{ marginBottom: 18 }}>
              <div className="row" style={{ gap: 8 }}>
                <h3>{y.label}</h3>
                {y.is_current && <Flag tone="good" glyph="✓" label="Current"
                                       title="The year every screen defaults to." />}
              </div>
              {mine.length === 0 ? (
                <div className="empty">No terms in this year.</div>
              ) : (
                <div className="scroll-x">
                  <table>
                    <thead>
                      <tr>
                        <th align="right">#</th><th>Term</th><th>Runs</th>
                        <th align="right">Days</th><th>Reporting</th><th />
                      </tr>
                    </thead>
                    <tbody>
                      {mine.map((t) => (
                        <tr key={t.id}>
                          <td className="num">{t.seq}</td>
                          <td>{t.label}</td>
                          <td className="muted">{fmtDate(t.starts_on)} – {fmtDate(t.ends_on)}</td>
                          <td className="num">{days(t.starts_on, t.ends_on)}</td>
                          <td>
                            {t.is_reporting
                              ? <Flag tone="good" glyph="✓" label="Reporting"
                                      title="Marks in this window are grouped into a reporting period." />
                              : <Flag tone="neutral" glyph="·" label="Not reporting"
                                      title="Kept in the calendar but not treated as a reporting period." />}
                          </td>
                          <td>
                            <button className="ghost" disabled={busy}
                                    onClick={() => {
                                      if (!confirm(`Delete ${t.label}? Marks in that window ` +
                                        'stop being attributed to any reporting period.')) return
                                      void run(() => api.post(`/admin/terms/${t.id}/delete`),
                                        'Term deleted.')
                                    }}>Delete</button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {problems.length > 0 && (
                <ul className="muted" style={{ margin: '10px 0 0', paddingLeft: 18,
                                               fontSize: 'var(--t-small)' }}>
                  {problems.map((p, i) => <li key={i} style={{ marginBottom: 4 }}>{p}</li>)}
                </ul>
              )}
            </div>
          )
        })}

        <form className="row" style={{ alignItems: 'flex-end', gap: 10 }}
              onSubmit={(e) => {
                e.preventDefault()
                void run(async () => {
                  await api.post('/admin/terms', {
                    academic_year_id: tYear, label: tLabel, seq: Number(tSeq),
                    starts_on: tStart, ends_on: tEnd, is_reporting: true,
                  })
                  setTLabel(''); setTStart(''); setTEnd('')
                  setTSeq(String(Number(tSeq) + 1))
                }, 'Term added.')
              }}>
          <label style={{ display: 'grid', gap: 4 }}>
            Year
            <select required value={tYear} onChange={(e) => setTYear(e.target.value)}>
              <option value="">Choose…</option>
              {years.map((y) => <option key={y.id} value={y.id}>{y.label}</option>)}
            </select>
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Label
            <input required value={tLabel} placeholder="Term 1" style={{ width: 130 }}
                   onChange={(e) => setTLabel(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Order
            <input required type="number" min={1} max={12} value={tSeq} style={{ width: 70 }}
                   onChange={(e) => setTSeq(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Starts
            <input required type="date" value={tStart}
                   onChange={(e) => setTStart(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Ends
            <input required type="date" value={tEnd}
                   onChange={(e) => setTEnd(e.target.value)} />
          </label>
          <button className="primary" type="submit" disabled={busy || !tYear}>Add term</button>
        </form>
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Departments and subjects</h2>
          <span className="sub">Subjects are what classes and taxonomies hang off.</span>
        </header>

        <div className="scroll-x">
          <table>
            <thead>
              <tr><th>Subject</th><th>Code</th><th>Department</th><th align="right">Classes</th></tr>
            </thead>
            <tbody>
              {subjects.map((s) => (
                <tr key={s.id}>
                  <td>{s.name}</td>
                  <td className="num muted">{s.code}</td>
                  <td>
                    <select value={s.department_id ?? ''} disabled={busy}
                            aria-label={`Department for ${s.name}`}
                            onChange={(e) => void run(() =>
                              api.post(`/admin/subjects/${s.id}/update`, {
                                name: s.name,
                                department_id: e.target.value || null,
                              }), 'Subject updated.')}>
                      <option value="">— none —</option>
                      {departments.map((d) => (
                        <option key={d.id} value={d.id}>{d.name}</option>
                      ))}
                    </select>
                  </td>
                  <td className="num">{s.n_groups}</td>
                </tr>
              ))}
              {subjects.length === 0 && (
                <tr><td colSpan={4}><div className="empty">No subjects yet.</div></td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="row" style={{ gap: 24, marginTop: 14, alignItems: 'flex-start' }}>
          <form className="row" style={{ alignItems: 'flex-end', gap: 10 }}
                onSubmit={(e) => {
                  e.preventDefault()
                  void run(async () => {
                    await api.post('/admin/subjects', {
                      code: subCode, name: subName, department_id: subDept || null,
                    })
                    setSubCode(''); setSubName('')
                  }, 'Subject added.')
                }}>
            <label style={{ display: 'grid', gap: 4 }}>
              Subject
              <input required value={subName} placeholder="Mathematics" style={{ width: 160 }}
                     onChange={(e) => setSubName(e.target.value)} />
            </label>
            <label style={{ display: 'grid', gap: 4 }}>
              Code
              <input required value={subCode} placeholder="MATH" style={{ width: 90 }}
                     onChange={(e) => setSubCode(e.target.value)} />
            </label>
            <label style={{ display: 'grid', gap: 4 }}>
              Department
              <select value={subDept} onChange={(e) => setSubDept(e.target.value)}>
                <option value="">— none —</option>
                {departments.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>
            </label>
            <button className="primary" type="submit" disabled={busy}>Add subject</button>
          </form>

          <form className="row" style={{ alignItems: 'flex-end', gap: 10 }}
                onSubmit={(e) => {
                  e.preventDefault()
                  void run(async () => {
                    await api.post('/admin/departments', { name: deptName })
                    setDeptName('')
                  }, 'Department added.')
                }}>
            <label style={{ display: 'grid', gap: 4 }}>
              Department
              <input required value={deptName} placeholder="Sciences" style={{ width: 150 }}
                     onChange={(e) => setDeptName(e.target.value)} />
            </label>
            <button type="submit" disabled={busy}>Add department</button>
          </form>
        </div>
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Recompute analytics</h2>
          <span className="sub">
            Normally a scheduled job. Run it here after a large import or a change to the calendar.
          </span>
        </header>
        <div className="row">
          <button className="primary" disabled={refreshing}
                  onClick={async () => {
                    setRefreshing(true); setErr(null)
                    try {
                      const r = await api.post<{ ok: boolean; ms: number }>(
                        '/admin/refresh-analytics')
                      setRefresh({ ms: r.ms, at: new Date().toISOString() })
                    } catch (e) { setErr((e as Error).message) }
                    finally { setRefreshing(false) }
                  }}>
            {refreshing ? 'Recomputing…' : 'Recompute now'}
          </button>
          {refresh && (
            <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
              Finished in <span className="num">{(refresh.ms / 1000).toFixed(1)}</span>
              <span className="unit"> s</span> · {new Date(refresh.at).toLocaleTimeString()}
            </span>
          )}
        </div>
        <p className="muted" style={{ fontSize: 'var(--t-small)', maxWidth: 640,
                                      marginBottom: 0 }}>
          This rebuilds the derived views the dashboards read. It does not change a single mark,
          and it does not raise alerts. On a school-sized dataset it takes seconds; on a very
          large one, minutes — the figure above is what it actually took here, not an estimate.
        </p>
      </section>
    </div>
  )
}
