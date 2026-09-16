import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { api, fmtDate, type Grid } from '../lib/api'

type Cell = { item_id: string; student_id: string; raw_value: number | null; status: string }
const key = (s: string, i: string) => `${s}|${i}`

/**
 * THE ENTRY GRID.
 *
 * Entry cost is the binding constraint on this entire product: if a teacher
 * cannot finish a class in about two minutes, no data accumulates and every
 * analytic downstream is decoration on an empty table. So:
 *   - keyboard-first: Enter/arrows move down the column (how you read a pile
 *     of scripts), Tab moves across
 *   - paste a block straight out of Excel
 *   - autosave on a debounce; no Save button to forget
 *   - over-max values flagged immediately, not rejected on submit
 */
export default function Entry() {
  const { assessmentId } = useParams()
  const [grid, setGrid] = useState<Grid | null>(null)
  const [cells, setCells] = useState<Map<string, Cell>>(new Map())
  const [dirty, setDirty] = useState<Set<string>>(new Set())
  const [saving, setSaving] = useState(false)
  const [savedAt, setSavedAt] = useState<Date | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const started = useRef(new Date())
  const firstValue = useRef<Date | null>(null)
  const inputs = useRef<Map<string, HTMLInputElement>>(new Map())

  useEffect(() => {
    api.get<Grid>(`/assessments/${assessmentId}/grid`).then((g) => {
      setGrid(g)
      const m = new Map<string, Cell>()
      for (const mk of g.marks) {
        m.set(key(mk.student_id, mk.item_id), {
          item_id: mk.item_id, student_id: mk.student_id,
          raw_value: mk.raw_value === null ? null : Number(mk.raw_value), status: mk.status,
        })
      }
      setCells(m)
    }).catch((e) => setErr(e.message))
  }, [assessmentId])

  const save = useCallback(async () => {
    if (dirty.size === 0 || !grid) return
    const batch = [...dirty].map((k) => cells.get(k)).filter(Boolean) as Cell[]
    if (batch.length === 0) return
    setSaving(true)
    try {
      await api.post('/marks', {
        client_mutation_id: `${grid.assessment.id}-${Date.now()}`,
        marks: batch.map((c) => ({
          item_id: c.item_id, student_id: c.student_id,
          raw_value: c.raw_value, status: c.status,
        })),
      })
      setDirty(new Set())
      setSavedAt(new Date())
      setErr(null)
    } catch (e) { setErr((e as Error).message) } finally { setSaving(false) }
  }, [dirty, cells, grid])

  // Debounced autosave. Teachers do not press Save; they close the laptop.
  useEffect(() => {
    if (dirty.size === 0) return
    const t = setTimeout(save, 900)
    return () => clearTimeout(t)
  }, [dirty, save])

  // Report how long entry actually took, so the two-minute claim is measurable
  // rather than asserted.
  useEffect(() => {
    const report = (abandoned: boolean) => {
      if (!grid) return
      const payload = {
        assessment_id: grid.assessment.id, screen: 'entry_grid',
        started_at: started.current.toISOString(),
        first_value_at: firstValue.current?.toISOString() ?? null,
        ended_at: new Date().toISOString(),
        cells_expected: grid.students.length * grid.items.length,
        cells_entered: [...cells.values()].filter((c) => c.raw_value !== null).length,
        was_abandoned: abandoned, device: window.innerWidth < 820 ? 'tablet' : 'desktop',
      }
      navigator.sendBeacon?.('/api/entry-sessions',
        new Blob([JSON.stringify(payload)], { type: 'application/json' }))
    }
    const onHide = () => report(true)
    window.addEventListener('pagehide', onHide)
    return () => { window.removeEventListener('pagehide', onHide); report(false) }
  }, [grid, cells])

  const setCell = useCallback((student_id: string, item_id: string, raw: string) => {
    if (!firstValue.current) firstValue.current = new Date()
    const k = key(student_id, item_id)
    const trimmed = raw.trim()
    const upper = trimmed.toLowerCase()
    // Single-letter shortcuts, because typing "absent" 24 times is not a product.
    const status = upper === 'a' ? 'absent' : upper === 'x' ? 'not_submitted'
      : upper === 'e' ? 'exempt' : 'scored'
    const value = status !== 'scored' || trimmed === '' ? null : Number(trimmed)
    if (status === 'scored' && trimmed !== '' && Number.isNaN(value)) return
    setCells((prev) => {
      const next = new Map(prev)
      next.set(k, { item_id, student_id, raw_value: value, status })
      return next
    })
    setDirty((prev) => new Set(prev).add(k))
  }, [])

  const focusCell = (si: number, ii: number) => {
    if (!grid) return
    const s = grid.students[si], it = grid.items[ii]
    if (!s || !it) return
    inputs.current.get(key(s.id, it.id))?.focus()
  }

  /** Paste a rectangular block straight out of Excel, anchored at the focused cell. */
  const onPaste = (e: React.ClipboardEvent, si: number, ii: number) => {
    const text = e.clipboardData.getData('text/plain')
    if (!text.includes('\t') && !text.includes('\n')) return
    e.preventDefault()
    if (!grid) return
    const rows = text.replace(/\r/g, '').split('\n').filter((r) => r !== '')
    rows.forEach((row, dr) => {
      row.split('\t').forEach((v, dc) => {
        const s = grid.students[si + dr], it = grid.items[ii + dc]
        if (s && it && v.trim() !== '') setCell(s.id, it.id, v)
      })
    })
  }

  const total = useMemo(() => {
    if (!grid) return 0
    return grid.students.length * grid.items.length
  }, [grid])
  const entered = [...cells.values()].filter((c) => c.raw_value !== null || c.status !== 'scored').length

  if (err && !grid) return <p className="err">{err}</p>
  if (!grid) return <div className="empty">Loading…</div>

  return (
    <div className="stack">
      <div className="row">
        <div style={{ flex: 1, minWidth: 240 }}>
          <h1>{grid.assessment.title}</h1>
          <div className="muted">
            {grid.assessment.group_label} · {grid.assessment.subject_name} · {fmtDate(grid.assessment.occurred_on)}
          </div>
        </div>
        <div className="row" style={{ gap: 10 }}>
          <span className="tabular muted">{entered} / {total} cells</span>
          {saving ? <span className="muted">Saving…</span>
            : savedAt ? <span className="saved-flash">✓ Saved</span> : null}
          <button className="primary" onClick={save} disabled={dirty.size === 0}>
            Save now
          </button>
        </div>
      </div>

      {err && <p className="err">{err}</p>}

      <p className="muted" style={{ margin: 0, fontSize: 12 }}>
        <span className="kbd">Enter</span> next student ·
        <span className="kbd">Tab</span> next question ·
        <span className="kbd">A</span> absent ·
        <span className="kbd">X</span> not submitted ·
        <span className="kbd">E</span> exempt · paste a block from Excel anywhere.
        Absences are never counted as zero.
      </p>

      <div className="grid-wrap">
        <table className="entry">
          <thead>
            <tr>
              <th className="namecol">Student</th>
              {grid.items.map((it) => (
                <th key={it.id} style={{ textAlign: 'right' }}>
                  {it.label}
                  <div className="muted" style={{ fontWeight: 400 }}>
                    {it.max_value ? `/ ${Number(it.max_value)}` : it.measure_label ?? ''}
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {grid.students.map((s, si) => {
              const rowAbsent = grid.items.every(
                (it) => cells.get(key(s.id, it.id))?.status === 'absent')
              return (
                <tr key={s.id} className={rowAbsent ? 'absent' : ''}>
                  <td className="namecol">
                    <Link to={`/students/${s.id}`}>{s.family_name}, {s.preferred_name ?? s.given_name}</Link>
                  </td>
                  {grid.items.map((it, ii) => {
                    const c = cells.get(key(s.id, it.id))
                    const max = it.max_value ? Number(it.max_value) : null
                    const over = c?.raw_value != null && max != null && c.raw_value > max
                    const shown = c == null ? ''
                      : c.status === 'absent' ? 'A'
                      : c.status === 'not_submitted' ? 'X'
                      : c.status === 'exempt' ? 'E'
                      : c.raw_value ?? ''
                    return (
                      <td key={it.id} className="cell">
                        <input
                          className={`mark${over ? ' over' : ''}`}
                          value={shown}
                          title={over ? `Above the maximum of ${max}` : undefined}
                          ref={(el) => { if (el) inputs.current.set(key(s.id, it.id), el) }}
                          onChange={(e) => setCell(s.id, it.id, e.target.value)}
                          onPaste={(e) => onPaste(e, si, ii)}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter' || e.key === 'ArrowDown') {
                              e.preventDefault(); focusCell(si + 1, ii)
                            } else if (e.key === 'ArrowUp') {
                              e.preventDefault(); focusCell(si - 1, ii)
                            }
                          }}
                        />
                      </td>
                    )
                  })}
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}
