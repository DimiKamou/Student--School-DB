import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, fmtDate } from '../lib/api'
import { Pill } from '../components/Pill'

/**
 * The alert inbox.
 *
 * Three things distinguish this screen from every "insights feed" in every
 * other school platform:
 *
 *  1. It is ADJUDICATED. Every alert can be marked useful, already known, not
 *     useful or plain wrong, and analytics.v_alert_precision turns that into a
 *     measured precision figure which this screen shows back — including when
 *     the figure is bad. An early-warning product that cannot state its own
 *     false-positive rate is a horoscope with a database behind it.
 *  2. It is FINITE. analytics.fire_alerts() raises under a weekly budget with a
 *     21-day refractory window, so the inbox can actually be emptied.
 *  3. It says WHO CAN SEE IT. A systemic flag about a class reaches its teacher
 *     first and leadership only after a delay, and the teacher is told so.
 *     That is the whole difference between a tool and surveillance.
 */

type AlertRow = {
  id: string
  kind: string
  headline: string
  rule_version: string
  student_id: string | null
  teaching_group_id: string | null
  tag_id: string | null
  effect_size: string | null
  p_value: string | null
  evidence_count: number | null
  raised_at: string
  evidence_as_of: string
  acknowledged_at: string | null
  feedback: string | null
  feedback_note: string | null
  suppressed_until: string | null
  visibility_scope: string
  visible_to_leadership_after: string | null
  is_mine: boolean | null
  student_name: string | null
  group_label: string | null
  subject_name: string | null
  tag_label: string | null
  term_label: string | null
  n_interventions: string
}

type PrecisionRow = {
  kind: string
  rule_version: string
  raised: string
  adjudicated: string
  useful: string
  precision: string | null
  mean_hours_to_ack: string | null
}

type PrecisionTotals = {
  raised: string
  acknowledged: string
  adjudicated: string
  useful: string
  already_knew: string
  not_useful: string
  wrong: string
  snoozed: string
}

const STATES = [
  { key: 'open', label: 'Open' },
  { key: 'snoozed', label: 'Snoozed' },
  { key: 'adjudicated', label: 'Judged' },
  { key: 'all', label: 'Everything' },
] as const
type StateKey = (typeof STATES)[number]['key']

const VERDICTS = [
  { key: 'useful', label: 'Useful', hint: 'Told me something I would have acted on.' },
  { key: 'already_knew', label: 'Already knew', hint: 'True, but not news. Counts against precision as this view defines it.' },
  { key: 'not_useful', label: 'Not useful', hint: 'Technically defensible, not worth the interruption.' },
  { key: 'wrong', label: 'Wrong', hint: 'The finding is not true of this student or class.' },
] as const

/**
 * Alert kind -> the shared pill vocabulary in Pill.tsx. Kinds with no agreed
 * word there are passed through unchanged, so the pill prints the rule's own
 * name rather than borrowing a verdict that does not apply to it.
 */
function pillFor(kind: string): string {
  switch (kind) {
    case 'systemic_topic_gap': return 'systemic'
    case 'individual_topic_gap': return 'individual'
    case 'trajectory_decline': return 'declining'
    case 'under_taught_topic': return 'under_taught'
    default: return kind
  }
}

/** The severity stripe: form, not colour, carrying the shape of the list. */
function stripeFor(kind: string): string {
  if (kind === 'systemic_topic_gap' || kind === 'under_taught_topic') return 'systemic'
  if (kind === 'trajectory_decline') return 'declining'
  return 'individual'
}

/**
 * Wilson 95% interval on a proportion.
 *
 * A bare "precision 1.00" over three judgements is the kind of number this
 * product exists not to print. The interval is what makes a small denominator
 * visibly small rather than quietly flattering.
 */
function wilson(k: number, n: number): { lo: number; hi: number } | null {
  if (!n) return null
  const z = 1.96
  const p = k / n
  const d = 1 + (z * z) / n
  const centre = p + (z * z) / (2 * n)
  const spread = z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))
  return { lo: Math.max(0, (centre - spread) / d), hi: Math.min(1, (centre + spread) / d) }
}

const pctOf = (x: number) => `${Math.round(x * 100)}%`
const num = (s: string | null | undefined) => (s == null ? 0 : Number(s))

export default function Alerts() {
  const [rows, setRows] = useState<AlertRow[]>([])
  const [byKind, setByKind] = useState<PrecisionRow[]>([])
  const [totals, setTotals] = useState<PrecisionTotals | null>(null)
  const [state, setState] = useState<StateKey>('open')
  const [onlyMine, setOnlyMine] = useState(true)
  const [busy, setBusy] = useState<string | null>(null)
  const [noteFor, setNoteFor] = useState<string | null>(null)
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const [list, prec] = await Promise.all([
        api.get<AlertRow[]>(`/alerts?state=${state}&mine=${onlyMine}&limit=100`),
        api.get<{ by_kind: PrecisionRow[]; totals: PrecisionTotals | null }>('/alerts/precision'),
      ])
      setRows(list)
      setByKind(prec.by_kind)
      setTotals(prec.totals)
      setErr(null)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [state, onlyMine])

  useEffect(() => { void load() }, [load])

  const act = useCallback(async (id: string, path: string, body?: unknown) => {
    setBusy(id)
    try {
      await api.post(`/alerts/${id}${path}`, body)
      await load()
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(null)
    }
  }, [load])

  const adjudicated = num(totals?.adjudicated)
  const useful = num(totals?.useful)
  const raised = num(totals?.raised)
  const ci = wilson(useful, adjudicated)

  return (
    <div className="stack">
      {err && <p className="err">{err}</p>}

      <div className="row">
        <h1>Alerts</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <Link className="btn" to="/interventions">Interventions →</Link>
      </div>

      {/* ------------------------------------------------------------------
          The honesty panel. It goes ABOVE the alerts, not in a settings page:
          the reliability of the instrument is part of reading its output.
         ------------------------------------------------------------------ */}
      <section className="card">
        <header>
          <h2>Are these alerts any good?</h2>
          <span className="sub">
            Measured from teacher verdicts on the alerts you can see. Claimed by nobody.
          </span>
        </header>

        {adjudicated === 0 ? (
          <div className="note">
            <strong>Not measurable yet.</strong> {raised === 0
              ? 'No alerts have been raised, so there is nothing to score.'
              : `${raised} alert${raised === 1 ? ' has' : 's have'} been raised and none judged yet.`}{' '}
            Until alerts are marked useful or not, this product cannot state its own
            false-positive rate — and no figure is shown here in place of one.
          </div>
        ) : (
          <>
            <div className="row" style={{ alignItems: 'flex-end', gap: 26 }}>
              <div>
                <div className="eyebrow">Judged useful</div>
                <div className="tabular" style={{ fontSize: 'var(--t-display)', lineHeight: 1.05 }}>
                  {pctOf(useful / adjudicated)}
                </div>
                <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
                  <span className="num">{useful}</span> of <span className="num">{adjudicated}</span> judged
                  {ci && <> · 95% CI {pctOf(ci.lo)}–{pctOf(ci.hi)}</>}
                </div>
              </div>
              <div>
                <div className="eyebrow">Still unjudged</div>
                <div className="tabular" style={{ fontSize: 'var(--t-h1)', lineHeight: 1.1 }}>
                  {raised - adjudicated}
                </div>
                <div className="muted" style={{ fontSize: 'var(--t-small)' }}>of {raised} raised</div>
              </div>
            </div>

            {adjudicated < 10 && (
              <p className="note" style={{ marginTop: 14 }}>
                <strong>Provisional.</strong> {adjudicated} judgement{adjudicated === 1 ? '' : 's'} is
                too few for a stable figure. The interval above is wide on purpose; treat the headline
                percentage as a placeholder until several dozen alerts have been judged.
              </p>
            )}

            <p className="note" style={{ marginTop: 12 }}>
              <strong>What this percentage counts.</strong> Only “useful” lands in the numerator.
              An alert you marked <em>already knew</em> may well have been true, and it still counts
              against the figure — deliberately, because an alert that tells you what you already
              knew has not earned the interruption. The unjudged alerts are excluded entirely, so a
              low judging rate can flatter this number in either direction.
            </p>
          </>
        )}

        {totals && (
          <div className="scroll-x" style={{ marginTop: 14 }}>
            <table>
              <thead>
                <tr>
                  <th>Verdict</th>
                  <th align="right">Alerts</th>
                </tr>
              </thead>
              <tbody>
                <tr><td>Useful</td><td className="num">{totals.useful}</td></tr>
                <tr><td>Already knew</td><td className="num">{totals.already_knew}</td></tr>
                <tr><td>Not useful</td><td className="num">{totals.not_useful}</td></tr>
                <tr><td>Wrong</td><td className="num">{totals.wrong}</td></tr>
                <tr><td className="muted">Not judged</td><td className="num muted">{raised - adjudicated}</td></tr>
                <tr><td className="muted">Snoozed right now</td><td className="num muted">{totals.snoozed}</td></tr>
              </tbody>
            </table>
          </div>
        )}

        {byKind.length > 0 && (
          <div className="scroll-x" style={{ marginTop: 14 }}>
            <table>
              <thead>
                <tr>
                  <th>By rule</th>
                  <th align="right">Raised</th>
                  <th align="right">Judged</th>
                  <th align="right">Useful</th>
                  <th align="right">Precision</th>
                  <th align="right">Time to read</th>
                </tr>
              </thead>
              <tbody>
                {byKind.map((k) => {
                  const n = num(k.adjudicated)
                  return (
                    <tr key={`${k.kind}-${k.rule_version}`}>
                      <td>
                        {k.kind.replace(/_/g, ' ')}
                        <div className="muted" style={{ fontSize: 'var(--t-micro)' }}>rule {k.rule_version}</div>
                      </td>
                      <td className="num">{k.raised}</td>
                      <td className="num">{k.adjudicated}</td>
                      <td className="num">{k.useful}</td>
                      <td className="num">
                        {/* No denominator, no number. */}
                        {n === 0 ? <span className="muted">not judged</span>
                          : n < 5 ? <span className="muted" title="Too few judgements to quote a rate.">
                              {k.useful}/{k.adjudicated}
                            </span>
                          : k.precision == null ? <span className="muted">—</span>
                          : pctOf(Number(k.precision))}
                      </td>
                      <td className="num muted">
                        {k.mean_hours_to_ack == null ? '—' : `${Math.round(Number(k.mean_hours_to_ack))}h`}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* ------------------------------------------------------------------
          Who sees what. Stated plainly, once, at the top of the inbox.
         ------------------------------------------------------------------ */}
      <section className="card">
        <header>
          <h2>Who else sees these</h2>
          <span className="sub">Right of first sight, in plain words.</span>
        </header>
        <ul className="muted" style={{ margin: 0, paddingLeft: 18, fontSize: 'var(--t-small)' }}>
          <li style={{ marginBottom: 6 }}>
            A finding about your class is raised <strong>to you first</strong>. Leadership sees it only
            after the delay your school has set, and every alert below prints its own date.
          </li>
          <li style={{ marginBottom: 6 }}>
            Students and guardians never see raw alerts at all. That is enforced in the database,
            not by this screen.
          </li>
          <li>
            There are no teacher league tables in this product, and no view that groups outcomes by
            teacher. A whole-class finding is a finding about teaching time, curriculum or a topic —
            not a score for the person in the room.
          </li>
        </ul>
      </section>

      {/* ------------------------------------------------------------------
          The inbox itself.
         ------------------------------------------------------------------ */}
      <section className="card">
        <header>
          <h2>Inbox</h2>
          <span className="sub">
            Raised under a weekly budget, with a 21-day quiet period per finding, so this list can
            actually be emptied.
          </span>
        </header>

        <div className="row" style={{ marginBottom: 12 }}>
          {STATES.map((s) => (
            <button
              key={s.key}
              className={state === s.key ? 'primary' : 'ghost'}
              onClick={() => setState(s.key)}
            >
              {s.label}
            </button>
          ))}
          <span className="spacer" style={{ marginLeft: 'auto' }} />
          <label className="row" style={{ gap: 6 }}>
            <input
              type="checkbox"
              checked={onlyMine}
              onChange={(e) => setOnlyMine(e.target.checked)}
              style={{ width: 'auto' }}
            />
            Only alerts addressed to me
          </label>
        </div>

        {loading ? (
          <div className="empty">Loading…</div>
        ) : rows.length === 0 ? (
          <div className="empty">
            {state === 'open'
              ? 'Nothing open. Either nothing crossed the effect gate, or there isn’t enough evidence yet — no alert is raised on fewer than five marks.'
              : 'Nothing here.'}
          </div>
        ) : (
          <div>
            {rows.map((a) => {
              const leadershipAt = a.visible_to_leadership_after
                ? new Date(a.visible_to_leadership_after)
                : null
              const leadershipPending = leadershipAt ? leadershipAt.getTime() > Date.now() : false
              const snoozed = a.suppressed_until
                ? new Date(a.suppressed_until).getTime() > Date.now()
                : false
              const evidence = a.evidence_count ?? 0
              return (
                <div key={a.id} className={`finding ${stripeFor(a.kind)}`}>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0, flex: 1 }}>
                    <div className="row" style={{ gap: 8 }}>
                      <Pill value={pillFor(a.kind)} />
                      {a.feedback && <Pill value={a.feedback} />}
                      {snoozed && <Pill value="snoozed" />}
                      {!a.acknowledged_at && <span className="kbd">unread</span>}
                    </div>

                    <div style={{ lineHeight: 1.35 }}>
                      {a.student_id
                        ? <Link to={`/students/${a.student_id}`}>{a.headline}</Link>
                        : a.headline}
                    </div>

                    <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
                      {[a.subject_name, a.group_label, a.tag_label, a.term_label]
                        .filter(Boolean).join(' · ') || 'no class recorded'}
                    </div>

                    <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
                      Raised {fmtDate(a.raised_at)} on{' '}
                      <span className="num">{evidence}</span> mark{evidence === 1 ? '' : 's'}
                      {/* effect_size is a residual in normalised score units. It is
                          NOT a percentage and is never printed as one, and its
                          meaning differs per rule, so it is labelled generically. */}
                      {a.effect_size != null && evidence >= 5 && (
                        <> · effect{' '}
                          <span className="num"
                                title="Size of the gap in normalised score units, on the rule that raised this. Not a percentage.">
                            {Number(a.effect_size).toFixed(2)}
                          </span>
                          <span className="unit"> normalised score units</span></>
                      )}
                      {a.effect_size != null && evidence < 5 && (
                        <> · <span title="Too few marks behind this to quote a size.">size withheld — thin evidence</span></>
                      )}
                    </div>

                    {/* The visibility contract, per alert, in a date the teacher can act on. */}
                    <div className="muted" style={{ fontSize: 'var(--t-small)' }}>
                      {a.visibility_scope === 'teacher' && leadershipPending && (
                        <>Yours alone until <strong>{fmtDate(a.visible_to_leadership_after)}</strong>,
                          when leadership can see it too.</>
                      )}
                      {a.visibility_scope === 'teacher' && !leadershipPending && leadershipAt && (
                        <>Visible to leadership since {fmtDate(a.visible_to_leadership_after)}.</>
                      )}
                      {a.visibility_scope === 'teacher' && !leadershipAt && (
                        <>Addressed to the class teacher. No leadership release date recorded.</>
                      )}
                      {a.visibility_scope === 'department' && <>Visible to the department.</>}
                      {a.visibility_scope === 'leadership' && <>A leadership-scope alert.</>}
                      {a.is_mine === false && <> · Not addressed to you.</>}
                    </div>

                    {a.feedback_note && (
                      <div className="note" style={{ fontSize: 'var(--t-small)' }}>{a.feedback_note}</div>
                    )}

                    {Number(a.n_interventions) > 0 && (
                      <div style={{ fontSize: 'var(--t-small)' }}>
                        <Link to={`/interventions?alert=${a.id}`}>
                          {a.n_interventions} intervention{Number(a.n_interventions) === 1 ? '' : 's'} recorded →
                        </Link>
                      </div>
                    )}

                    {/* --- actions ------------------------------------------------ */}
                    <div className="row" style={{ gap: 6, marginTop: 4 }}>
                      {!a.acknowledged_at && (
                        <button
                          disabled={busy === a.id}
                          onClick={() => void act(a.id, '/acknowledge')}
                        >
                          Acknowledge
                        </button>
                      )}
                      <Link className="btn" to={`/interventions?from_alert=${a.id}`}>
                        Record what you did
                      </Link>
                      {snoozed ? (
                        <button disabled={busy === a.id} onClick={() => void act(a.id, '/snooze', { days: null })}>
                          Un-snooze (hidden until {fmtDate(a.suppressed_until)})
                        </button>
                      ) : (
                        <>
                          <button disabled={busy === a.id} onClick={() => void act(a.id, '/snooze', { days: 7 })}>
                            Snooze 7d
                          </button>
                          <button disabled={busy === a.id} onClick={() => void act(a.id, '/snooze', { days: 21 })}>
                            Snooze 21d
                          </button>
                        </>
                      )}
                    </div>

                    <div style={{ marginTop: 6 }}>
                      <div className="eyebrow" style={{ marginBottom: 4 }}>
                        Was this worth raising?
                      </div>
                      <div className="row" style={{ gap: 6 }}>
                        {VERDICTS.map((v) => (
                          <button
                            key={v.key}
                            title={v.hint}
                            className={a.feedback === v.key ? 'primary' : undefined}
                            disabled={busy === a.id}
                            onClick={() => void act(a.id, '/feedback', {
                              feedback: v.key,
                              feedback_note: a.feedback_note ?? null,
                            })}
                          >
                            {v.label}
                          </button>
                        ))}
                        {a.feedback && (
                          <button
                            className="ghost"
                            onClick={() => { setNoteFor(noteFor === a.id ? null : a.id); setNote(a.feedback_note ?? '') }}
                          >
                            {a.feedback_note ? 'Edit note' : 'Add a note'}
                          </button>
                        )}
                      </div>
                      {noteFor === a.id && (
                        <div className="row" style={{ gap: 6, marginTop: 6 }}>
                          <textarea
                            rows={2}
                            value={note}
                            placeholder="Why was it useful, or where did it go wrong? This is what improves the rule."
                            onChange={(e) => setNote(e.target.value)}
                            style={{ flex: 1, minWidth: 200 }}
                          />
                          <button
                            className="primary"
                            disabled={busy === a.id || !a.feedback}
                            onClick={async () => {
                              await act(a.id, '/feedback', {
                                feedback: a.feedback,
                                feedback_note: note.trim() || null,
                              })
                              setNoteFor(null)
                            }}
                          >
                            Save note
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </section>
    </div>
  )
}
