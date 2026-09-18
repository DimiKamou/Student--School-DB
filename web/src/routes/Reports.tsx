import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { api, fmtDate, type Group } from '../lib/api'
import { Pill } from '../components/Pill'
import { BandPill, type BankComment } from './CommentBank'
import './reports.css'

/* ---------------------------------------------------------------------------
 * Types for this slice. Numerics arrive from PostgreSQL as strings; they are
 * kept that way and converted at the point of display, so a rounding decision
 * is always visible in the component that makes it.
 * ------------------------------------------------------------------------- */
export type RosterStudent = {
  id: string
  given_name: string
  family_name: string
  preferred_name: string | null
  external_ref: string | null
  /** False means teach.merge_comment will use the they/them default. */
  pronoun_recorded: boolean
}

export type GapRow = {
  student_id: string
  tag_id: string
  tag_label: string
  verdict: string
  time_context: string | null
  n_responses: string
  n_assessments: string
  mean_pct: string | null
  mean_pct_recent: string | null
  mean_residual: string | null
  residual_ci_upper: string | null
  cohort_mean_pct: string | null
  missed_ratio: string | null
}

export type TrajectoryRow = {
  student_id: string
  trajectory: string
  shift: string | null
  n_recent: string
  n_prior: string
  model_kind: string | null
}

export type GroupHead = {
  id: string
  label: string
  year_level: string | null
  subject_id: string
  subject_name: string
  academic_year: string
}

export type Term = {
  id: string; label: string; seq: number
  starts_on: string; ends_on: string; is_reporting: boolean
}

export type ReportComment = {
  id: string
  student_id: string
  body: string
  is_final: boolean
  drafted_from: string | null
  updated_at: string
}

export type ReportPack = {
  group: GroupHead
  term: Term | null
  terms: Term[]
  students: RosterStudent[]
  gaps: GapRow[]
  trajectory: TrajectoryRow[]
  comments: ReportComment[]
}

type MergeResult = {
  merged: string
  pronoun_recorded: boolean
  pronoun_defaulted: boolean
  unfilled: string[]
}

/** Action order, straight from mv_gap_signal's own verdict ranking. */
const VERDICT_RANK: Record<string, number> = {
  systemic_and_individual: 1, individual: 2, systemic: 3,
  explained_by_absence: 4, assessment_artefact: 5, insufficient_evidence: 6, ok: 7,
}

export const NEEDS_WORK = new Set(['systemic_and_individual', 'individual', 'systemic'])

/** A verdict the schema marks as unsupported must never render as a figure. */
export const NO_NUMBER = new Set(['insufficient_evidence', 'assessment_artefact'])

export function pct(v: string | null): string {
  return v == null ? '—' : `${Math.round(Number(v) * 100)}%`
}

export function sortGaps(rows: GapRow[]): GapRow[] {
  return [...rows].sort((a, b) => {
    const r = (VERDICT_RANK[a.verdict] ?? 9) - (VERDICT_RANK[b.verdict] ?? 9)
    return r !== 0 ? r : Number(a.mean_residual ?? 0) - Number(b.mean_residual ?? 0)
  })
}

export function groupBy<T>(rows: T[], key: (r: T) => string): Map<string, T[]> {
  const m = new Map<string, T[]>()
  for (const r of rows) {
    const k = key(r)
    const list = m.get(k)
    if (list) list.push(r)
    else m.set(k, [r])
  }
  return m
}

export function fullName(s: RosterStudent): string {
  return `${s.preferred_name ?? s.given_name} ${s.family_name}`
}

type DraftState = {
  body: string
  is_final: boolean
  dirty: boolean
  saving: boolean
  saved: boolean
  note: string | null
  unfilled: string[]
}

const BLANK: DraftState = {
  body: '', is_final: false, dirty: false, saving: false, saved: false,
  note: null, unfilled: [],
}

/**
 * Write a whole class's report comments in one pass, with each student's actual
 * data beside the box.
 *
 * The evidence panel is not decoration. A comment written from memory in week
 * eleven is a comment about the loudest child in the room; a comment written
 * beside the topic verdicts is about the work. Where the schema says the
 * evidence is too thin, the panel says so instead of printing a number that
 * would then get quoted back at a parents' evening.
 */
export default function Reports() {
  const { groupId } = useParams()
  const nav = useNavigate()
  const [groups, setGroups] = useState<Group[]>([])
  const [pack, setPack] = useState<ReportPack | null>(null)
  const [termId, setTermId] = useState<string>('')
  const [bank, setBank] = useState<BankComment[]>([])
  const [drafts, setDrafts] = useState<Record<string, DraftState>>({})
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => { api.get<Group[]>('/groups').then(setGroups).catch((e) => setErr(e.message)) }, [])
  useEffect(() => { api.get<BankComment[]>('/comment-bank').then(setBank).catch(() => setBank([])) }, [])

  useEffect(() => {
    if (!groupId) { setPack(null); setDrafts({}); return }
    setLoading(true)
    api.get<ReportPack>(`/reports/groups/${groupId}${termId ? `?term_id=${termId}` : ''}`)
      .then((p) => {
        setPack(p)
        if (!termId && p.term) setTermId(p.term.id)
        const next: Record<string, DraftState> = {}
        for (const s of p.students) {
          const c = p.comments.find((x) => x.student_id === s.id)
          next[s.id] = { ...BLANK, body: c?.body ?? '', is_final: c?.is_final ?? false }
        }
        setDrafts(next)
        setErr(null)
      })
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [groupId, termId])

  const gapsByStudent = useMemo(
    () => groupBy(pack?.gaps ?? [], (g) => g.student_id), [pack])
  const trajByStudent = useMemo(
    () => groupBy(pack?.trajectory ?? [], (t) => t.student_id), [pack])

  const update = useCallback((id: string, patch: Partial<DraftState>) => {
    setDrafts((d) => ({ ...d, [id]: { ...(d[id] ?? BLANK), ...patch } }))
  }, [])

  const save = useCallback(async (studentId: string, override?: Partial<DraftState>) => {
    const cur = { ...(drafts[studentId] ?? BLANK), ...override }
    // An empty body is saved deliberately: clearing a comment has to persist,
    // or a teacher who deletes a sentence gets it back on reload.
    if (!pack || !pack.term) return
    update(studentId, { saving: true })
    try {
      await api.post('/reports/comments', {
        student_id: studentId,
        teaching_group_id: pack.group.id,
        term_id: pack.term.id,
        body: cur.body,
        is_final: cur.is_final,
      })
      update(studentId, { saving: false, dirty: false, saved: true })
      setTimeout(() => update(studentId, { saved: false }), 2000)
    } catch (e) {
      update(studentId, { saving: false })
      setErr((e as Error).message)
    }
  }, [drafts, pack, update])

  /**
   * Insert from the bank, merged for this student. One click, and the merge
   * happens on the server so the placeholder rules live in exactly one place —
   * teach.merge_comment() — rather than being re-implemented in the browser.
   */
  async function insert(student: RosterStudent, commentId: string) {
    if (!commentId) return
    const gaps = sortGaps(gapsByStudent.get(student.id) ?? [])
    const topic = gaps.find((g) => NEEDS_WORK.has(g.verdict))?.tag_label
      ?? gaps.find((g) => g.verdict === 'ok')?.tag_label
    try {
      const r = await api.post<MergeResult>(`/comment-bank/${commentId}/use`, {
        student_id: student.id,
        vars: topic ? { topic } : {},
      })
      const cur = drafts[student.id] ?? BLANK
      const body = cur.body.trim() ? `${cur.body.trim()} ${r.merged}` : r.merged
      update(student.id, {
        body, dirty: true, unfilled: r.unfilled,
        note: r.pronoun_defaulted
          ? 'Pronouns are not recorded for this student, so they/them was used.'
          : null,
      })
    } catch (e) { setErr((e as Error).message) }
  }

  const written = pack ? pack.students.filter((s) => (drafts[s.id]?.body ?? '').trim()).length : 0
  const finalised = pack ? pack.students.filter((s) => drafts[s.id]?.is_final).length : 0
  const total = pack?.students.length ?? 0

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <div className="row no-print">
        <h1>{pack ? `Reports · ${pack.group.subject_name} ${pack.group.label}` : 'Reports'}</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <select value={groupId ?? ''}
                onChange={(e) => { setTermId(''); nav(e.target.value ? `/reports/${e.target.value}` : '/reports') }}>
          <option value="">Choose a class…</option>
          {groups.map((g) => (
            <option key={g.id} value={g.id}>{g.subject_name} · {g.label} ({g.n_students})</option>
          ))}
        </select>
        {pack && pack.terms.length > 0 && (
          <select value={termId} onChange={(e) => setTermId(e.target.value)}>
            {pack.terms.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
          </select>
        )}
      </div>

      {!groupId && (
        <section className="card">
          <header>
            <h2>Pick a class to write for</h2>
            <span className="sub">One pass, every student, the data beside the box.</span>
          </header>
          {groups.length === 0 ? <div className="empty">No classes assigned to you.</div> : (
            <table>
              <thead><tr><th>Class</th><th>Subject</th><th align="right">Students</th><th /></tr></thead>
              <tbody>
                {groups.map((g) => (
                  <tr key={g.id}>
                    <td><Link to={`/reports/${g.id}`}>{g.label}</Link></td>
                    <td className="secondary">{g.subject_name}</td>
                    <td className="num">{g.n_students}</td>
                    <td><Link to={`/parents-evening/${g.id}`}>Parents’ evening sheets →</Link></td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      )}

      {loading && <div className="empty">Loading…</div>}

      {pack && !pack.term && (
        <div className="card">
          <strong>No reporting term is set up for this year.</strong>{' '}
          <span className="secondary">
            A report comment is stored against a term, so there is nowhere to save one yet.
            An administrator can add terms under the school setup.
          </span>
        </div>
      )}

      {pack && pack.term && (
        <>
          <section className="card no-print">
            <header>
              <h2>Progress</h2>
              <span className="sub">{pack.term.label} · {fmtDate(pack.term.starts_on)} – {fmtDate(pack.term.ends_on)}</span>
            </header>
            <div className="row">
              <strong className="num" style={{ fontSize: 'var(--t-h2)' }}>{written}</strong>
              <span className="muted">of <span className="num">{total}</span> written</span>
              <div className="rep-meter" aria-hidden="true">
                <span style={{ width: total ? `${(written / total) * 100}%` : '0%' }} />
              </div>
              <span className="muted"><span className="num">{finalised}</span> marked final</span>
              <span className="spacer" style={{ marginLeft: 'auto' }} />
              <Link className="btn" to={`/parents-evening/${pack.group.id}`}>Parents’ evening sheets</Link>
            </div>
          </section>

          <section className="card">
            <header>
              <h2>{pack.group.subject_name} · {pack.group.label}</h2>
              <span className="sub">
                Evidence on the left is what this student’s marks support — nothing more.
              </span>
            </header>

            {pack.students.length === 0 ? (
              <div className="empty">Nobody is enrolled in this class.</div>
            ) : pack.students.map((s) => {
              const d = drafts[s.id] ?? BLANK
              const gaps = sortGaps(gapsByStudent.get(s.id) ?? [])
              const traj = trajByStudent.get(s.id) ?? []
              return (
                <div className="rep-student" key={s.id}>
                  <div className="rep-name">
                    <h3><Link to={`/students/${s.id}`}>{fullName(s)}</Link></h3>
                    {traj.map((t, i) => <Pill key={i} value={t.trajectory} />)}
                    {d.is_final && <span className="pill good"><span className="glyph" aria-hidden="true">✓</span>Final</span>}
                    <span className="spacer" style={{ marginLeft: 'auto' }} />
                    {d.saving && <span className="muted" style={{ fontSize: 'var(--t-small)' }}>Saving…</span>}
                    {d.saved && <span className="saved-flash">Saved</span>}
                  </div>

                  <div className="rep-split" style={{ marginTop: 10 }}>
                    <div>
                      {gaps.length === 0 ? (
                        <div className="note">
                          No topic-level verdicts for {s.preferred_name ?? s.given_name} yet.
                          That means the marks are not tagged to topics, or there are too few
                          of them — not that there is nothing to say.
                        </div>
                      ) : (
                        <div className="scroll-x">
                          <table>
                            <thead>
                              <tr>
                                <th>Topic</th><th>Verdict</th>
                                <th align="right">Theirs</th><th align="right">Class</th>
                                <th align="right">Marks</th>
                              </tr>
                            </thead>
                            <tbody>
                              {gaps.slice(0, 6).map((g) => {
                                const thin = NO_NUMBER.has(g.verdict)
                                return (
                                  <tr key={g.tag_id}>
                                    <td>{g.tag_label}</td>
                                    <td>
                                      <Pill value={g.verdict} />
                                      {g.verdict === 'systemic' && g.time_context === 'under_taught'
                                        && <div style={{ marginTop: 3 }}><Pill value="under_taught" /></div>}
                                    </td>
                                    {/* A verdict the schema calls unsupported gets no figure:
                                        a number here would be quoted back at a parent. */}
                                    <td className="num" title={thin ? 'Too few marks to report a figure' : undefined}>
                                      {thin ? '—' : pct(g.mean_pct)}
                                    </td>
                                    <td className="num muted">{thin ? '—' : pct(g.cohort_mean_pct)}</td>
                                    <td className="num muted">{g.n_responses}</td>
                                  </tr>
                                )
                              })}
                            </tbody>
                          </table>
                        </div>
                      )}
                      {traj.length > 0 && traj.map((t, i) => (
                        <div className="muted" key={i} style={{ fontSize: 'var(--t-small)', marginTop: 8 }}>
                          Trajectory measured against their own baseline:{' '}
                          <span className="num">{t.n_recent}</span> recent marks vs{' '}
                          <span className="num">{t.n_prior}</span> earlier.
                        </div>
                      ))}
                    </div>

                    <div className="rep-box">
                      <textarea
                        value={d.body}
                        placeholder={`Report comment for ${s.preferred_name ?? s.given_name}…`}
                        onChange={(e) => update(s.id, { body: e.target.value, dirty: true })}
                        onBlur={() => { if (d.dirty) void save(s.id) }}
                      />

                      {d.unfilled.length > 0 && (
                        <div className="err">
                          Still contains {d.unfilled.map((u) => `{${u}}`).join(', ')} — fill{' '}
                          {d.unfilled.length > 1 ? 'these' : 'this'} in before marking final.
                        </div>
                      )}
                      {d.note && <div className="note">{d.note}</div>}
                      {!s.pronoun_recorded && !d.note && (
                        <div className="muted" style={{ fontSize: 'var(--t-micro)' }}>
                          No pronouns recorded — inserted comments will use they/them.
                        </div>
                      )}

                      <div className="rep-toolbar no-print">
                        <select defaultValue="" onChange={(e) => { void insert(s, e.target.value); e.target.value = '' }}>
                          <option value="">Insert from bank…</option>
                          {bank
                            .filter((c) => !c.subject_id || c.subject_id === pack.group.subject_id)
                            .map((c) => (
                              <option key={c.id} value={c.id}>
                                {c.band ? `[${c.band}] ` : ''}{c.body.slice(0, 60)}
                                {c.body.length > 60 ? '…' : ''}
                              </option>
                            ))}
                        </select>
                        <label style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}
                               title={d.body.trim() ? 'Mark this comment finished'
                                 : 'Write something before marking it final'}>
                          <input type="checkbox" checked={d.is_final}
                                 disabled={!d.body.trim()}
                                 onChange={(e) => {
                                   update(s.id, { is_final: e.target.checked, dirty: true })
                                   void save(s.id, { is_final: e.target.checked })
                                 }} />
                          Final
                        </label>
                        <span style={{ marginLeft: 'auto' }} />
                        <button className="primary" disabled={d.saving || !d.dirty}
                                onClick={() => void save(s.id)}>Save</button>
                      </div>
                    </div>
                  </div>
                </div>
              )
            })}
          </section>

          <section className="card no-print">
            <header><h2>Bands in your bank</h2>
              <span className="sub">Filter and edit these on the comment bank screen.</span></header>
            <div className="row">
              {(['excellent', 'secure', 'developing', 'concern'] as const).map((b) => (
                <span key={b} className="row" style={{ gap: 6 }}>
                  <BandPill band={b} />
                  <span className="num muted">{bank.filter((c) => c.band === b).length}</span>
                </span>
              ))}
              <span className="spacer" style={{ marginLeft: 'auto' }} />
              <Link to="/comment-bank">Manage comment bank →</Link>
            </div>
          </section>
        </>
      )}
    </div>
  )
}
