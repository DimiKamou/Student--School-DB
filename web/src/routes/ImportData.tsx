import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { api, fmtDate } from '../lib/api'

/**
 * Getting a school's data in.
 *
 * Two things this screen is built around:
 *
 *  1. The ORDER. Anonymise, then import. Pseudonymised data — where a mapping
 *     back to the real student still exists — is personal data in full GDPR
 *     scope. Anonymised data, where that mapping has been destroyed, is out of
 *     scope entirely. The wording here is lifted from SETUP.md deliberately:
 *     the tool, the docs and this screen should say the same thing.
 *
 *  2. PREVIEW BEFORE WRITE. Nothing is written until someone has seen row
 *     counts, the columns that were matched, and what the importer intends to
 *     infer. An import that silently invents twenty classes is worse than one
 *     that refuses.
 */

const KINDS = ['students', 'staff', 'groups', 'enrolments', 'marks'] as const
type FileKind = (typeof KINDS)[number]

const MAX_FILE_CHARS = 700_000

const SPEC: Record<FileKind, { title: string; need: string; also: string; why: string }> = {
  students: {
    title: 'Students',
    need: 'a student reference',
    also: 'given name, family name, year level',
    why: 'The reference is whatever your MIS calls a pupil — it only has to be consistent across your files.',
  },
  staff: {
    title: 'Staff',
    need: 'a staff reference',
    also: 'given name, family name',
    why: 'This creates staff records, not sign-in accounts. Accounts come from an invitation each person accepts themselves.',
  },
  groups: {
    title: 'Classes',
    need: 'a class code',
    also: 'subject code, subject name, class label, year level, teacher reference',
    why: 'Optional. If you skip it, classes are built from whatever the marks say.',
  },
  enrolments: {
    title: 'Enrolments',
    need: 'a student reference and a class code',
    also: '—',
    why: 'Optional. A student with a mark in a class is taken to be in that class, so the register can be built from the marks.',
  },
  marks: {
    title: 'Marks',
    need: 'a student reference, a class code and a date',
    also: 'assessment title, question or criterion label, out of, mark, topic, type',
    why: 'The only file that really matters. One row per scored slot — question or criterion grain is what makes the diagnosis possible.',
  },
}

type ColumnMap = { field: string; header: string | null }
type FileReport = {
  kind: FileKind
  filename: string
  delimiter: string
  n_rows: number
  truncated: boolean
  columns: ColumnMap[]
  ignored_headers: string[]
  missing_required: string[]
  n_problems: number
  problems: { line_no: number; message: string }[]
}
type Counts = {
  students: number; staff: number; subjects: number; groups: number
  enrolments: number; assessments: number; items: number; marks: number; topics: number
}
type Preview = {
  ok: boolean
  academic_year: string | null
  blocking: string[]
  notes: string[]
  files: FileReport[]
  will_create: Counts
  will_match: { students: number; groups: number }
  groups_inferred_from_marks: string[]
}
type Applied = {
  ok: true
  batches: { id: string; kind: FileKind; row_count: number; ok: number; errors: number }[]
  created: Counts
  groups_inferred_from_marks: string[]
  enrolments_inferred_from_marks: number
  notes: string[]
  next: string
}
type Batch = {
  id: string; kind: string; filename: string | null; uploaded_at: string
  row_count: number | null; ok_count: number | null; error_count: number | null
  status: string; uploaded_by: string | null
}

const COUNT_WORDS: [keyof Counts, string][] = [
  ['students', 'students'], ['staff', 'staff'], ['subjects', 'subjects'], ['groups', 'classes'],
  ['enrolments', 'enrolments'], ['assessments', 'assessments'], ['items', 'questions'],
  ['marks', 'marks'], ['topics', 'topics'],
]

function empty(): Record<FileKind, string> {
  return { students: '', staff: '', groups: '', enrolments: '', marks: '' }
}

export default function ImportData() {
  const [text, setText] = useState<Record<FileKind, string>>(empty)
  const [filename, setFilename] = useState<Record<FileKind, string>>(empty)
  const [active, setActive] = useState<FileKind>('students')

  const [preview, setPreview] = useState<Preview | null>(null)
  const [previewedPayload, setPreviewedPayload] = useState<string>('')
  const [applied, setApplied] = useState<Applied | null>(null)
  const [batches, setBatches] = useState<Batch[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState<'' | 'preview' | 'apply' | 'refresh'>('')
  const [refreshed, setRefreshed] = useState<string | null>(null)
  const fileInput = useRef<HTMLInputElement | null>(null)

  const payload = useMemo(() => JSON.stringify({
    files: KINDS.filter((k) => text[k].trim() !== '')
      .map((k) => ({ kind: k, filename: filename[k] || `${k}.csv`, text: text[k] })),
  }), [text, filename])

  const nFiles = KINDS.filter((k) => text[k].trim() !== '').length
  const stale = preview !== null && payload !== previewedPayload

  useEffect(() => { void loadBatches() }, [])

  async function loadBatches() {
    try { setBatches(await api.get<Batch[]>('/imports')) } catch { /* not an admin, or none yet */ }
  }

  async function onFile(kind: FileKind, file: File | undefined) {
    if (!file) return
    const content = await file.text()
    if (content.length > MAX_FILE_CHARS) {
      setErr(`${file.name} is ${(content.length / 1e6).toFixed(1)} MB. This screen takes files up to ` +
        `${(MAX_FILE_CHARS / 1e3).toFixed(0)} thousand characters; for a whole school at once use ` +
        `tools/import_csv.py, which has no such limit.`)
      return
    }
    setErr(null)
    setText((t) => ({ ...t, [kind]: content }))
    setFilename((f) => ({ ...f, [kind]: file.name }))
  }

  async function doPreview() {
    setBusy('preview'); setErr(null); setApplied(null)
    try {
      const p = await api.post<Preview>('/imports/preview', JSON.parse(payload))
      setPreview(p)
      setPreviewedPayload(payload)
    } catch (e) {
      setPreview(null)
      setErr((e as Error).message)
    } finally { setBusy('') }
  }

  async function doApply() {
    setBusy('apply'); setErr(null)
    try {
      setApplied(await api.post<Applied>('/imports/apply', JSON.parse(payload)))
      setPreview(null)
      await loadBatches()
    } catch (e) {
      setErr((e as Error).message)
    } finally { setBusy('') }
  }

  async function doRefresh() {
    setBusy('refresh'); setErr(null)
    try {
      const r = await api.post<{ ok: boolean; ms: number }>('/admin/refresh-analytics')
      setRefreshed(`Analytics rebuilt in ${(r.ms / 1000).toFixed(1)}s.`)
    } catch (e) {
      setErr((e as Error).message)
    } finally { setBusy('') }
  }

  return (
    <div className="stack">
      <h1>Import your school’s data</h1>

      {/* ---- The order, and why it is the order --------------------------- */}
      <section className="card">
        <header>
          <h2>Do these in this order</h2>
          <span className="sub">The order is the point.</span>
        </header>

        <ol className="stack" style={{ gap: 14, margin: 0, paddingLeft: 20 }}>
          <li>
            <strong>Export to CSV</strong> from whatever your school already uses. Column names
            are matched loosely, so <span className="kbd">Surname</span>,{' '}
            <span className="kbd">surname</span> and <span className="kbd">family_name</span> all
            work. You do not have to rename anything.
          </li>
          <li>
            <strong>Anonymise it — before it goes anywhere.</strong>
            <div className="kbd" style={{ display: 'inline-block', margin: '6px 0', padding: '4px 8px' }}>
              python3 tools/anonymise.py --in ./export --out ./anon
            </div>
            <div className="secondary">
              This strips names, emails, SEN flags and free-text comments, reduces dates of birth
              to the year, and replaces every id with a pseudonym that stays consistent across
              files so the data still joins. Then it <strong>destroys the mapping</strong>.
            </div>
          </li>
          <li>
            <strong>Import the anonymised files here.</strong> Preview first; nothing is written
            until you say so.
          </li>
        </ol>

        <div className="scroll-x" style={{ marginTop: 16 }}>
          <table>
            <thead>
              <tr><th>If you keep the mapping</th><th>If you destroy it</th></tr>
            </thead>
            <tbody>
              <tr>
                <td>
                  <span className="pill serious">
                    <span className="glyph" aria-hidden="true">◐</span>Pseudonymised
                  </span>
                  <div className="secondary" style={{ marginTop: 6 }}>
                    You can still get back to a real student. That is <strong>still personal
                    data</strong>, still fully in GDPR scope: lawful basis, DPA, retention rules,
                    the lot.
                  </div>
                </td>
                <td>
                  <span className="pill good">
                    <span className="glyph" aria-hidden="true">✓</span>Anonymised
                  </span>
                  <div className="secondary" style={{ marginTop: 6 }}>
                    The mapping cannot be reconstructed. <strong>Out of GDPR scope entirely.</strong>{' '}
                    This is what <span className="kbd">anonymise.py</span> does by default.
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p className="note" style={{ marginTop: 14 }}>
          You lose nothing analytically. Not one signal in this platform needs a real name.
        </p>
        <p className="note">
          <strong>Small classes re-identify themselves.</strong> Anonymising names does not make a
          class of six anonymous — “the only student taking Further Maths and Music” is
          identifiable to any colleague, whatever name is on the row. Treat small-group output as
          personal data regardless.
        </p>
      </section>

      {err && <p className="err" role="alert">{err}</p>}

      {/* ---- The files ---------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Your files</h2>
          <span className="sub">Paste the CSV, or choose a file. All of them are optional except marks.</span>
        </header>

        <div className="row" style={{ gap: 6, marginBottom: 14 }}>
          {KINDS.map((k) => {
            const loaded = text[k].trim() !== ''
            return (
              <button key={k} type="button" className={active === k ? 'primary' : ''}
                      onClick={() => setActive(k)}>
                {loaded && <span aria-hidden="true">✓ </span>}
                {SPEC[k].title}
                {loaded && <span className="unit"> · {countLines(text[k])}</span>}
              </button>
            )
          })}
        </div>

        <p className="secondary" style={{ marginTop: 0 }}>
          <strong>Needs {SPEC[active].need}.</strong>{' '}
          {SPEC[active].also !== '—' && <>Also reads: {SPEC[active].also}. </>}
          <span className="muted">{SPEC[active].why}</span>
        </p>

        <div className="row" style={{ marginBottom: 10 }}>
          <input ref={fileInput} type="file" accept=".csv,.txt,text/csv,text/plain"
                 style={{ display: 'none' }}
                 onChange={(e) => { void onFile(active, e.target.files?.[0]); e.target.value = '' }} />
          <button type="button" onClick={() => fileInput.current?.click()}>
            Choose {SPEC[active].title.toLowerCase()} file…
          </button>
          {filename[active] && <span className="muted">{filename[active]}</span>}
          <span className="spacer" style={{ marginLeft: 'auto' }} />
          {text[active] !== '' && (
            <button type="button" className="ghost"
                    onClick={() => {
                      setText((t) => ({ ...t, [active]: '' }))
                      setFilename((f) => ({ ...f, [active]: '' }))
                    }}>
              Clear
            </button>
          )}
        </div>

        <textarea
          value={text[active]}
          spellCheck={false}
          onChange={(e) => setText((t) => ({ ...t, [active]: e.target.value }))}
          placeholder={placeholderFor(active)}
          style={{ width: '100%', minHeight: 170, fontFamily: 'var(--font-figure)', fontSize: 12.5 }}
        />

        <div className="row" style={{ marginTop: 14 }}>
          <button type="button" className="primary" disabled={nFiles === 0 || busy !== ''}
                  onClick={() => void doPreview()}>
            {busy === 'preview' ? 'Reading…' : `Preview ${nFiles || ''} file${nFiles === 1 ? '' : 's'}`.trim()}
          </button>
          <button type="button" disabled={!preview?.ok || stale || busy !== ''}
                  onClick={() => void doApply()}>
            {busy === 'apply' ? 'Importing…' : 'Import for real'}
          </button>
          <span className="muted">
            {stale ? 'You changed the data since the preview — preview again before importing.'
              : preview?.ok ? 'Nothing has been written yet.'
              : 'Preview writes nothing at all — not even a record that you tried.'}
          </span>
        </div>
      </section>

      {/* ---- What will happen --------------------------------------------- */}
      {preview && (
        <section className="card">
          <header>
            <h2>What this will do</h2>
            <span className="sub">
              {preview.academic_year ? `Into academic year ${preview.academic_year}` : 'No academic year set'}
            </span>
          </header>

          {preview.blocking.length > 0 && (
            <div className="stack" style={{ gap: 8, marginBottom: 14 }}>
              {preview.blocking.map((b, i) => (
                <div key={i} className="row" style={{ alignItems: 'flex-start', gap: 8 }}>
                  <span className="pill critical">
                    <span className="glyph" aria-hidden="true">▲</span>Blocked
                  </span>
                  <span style={{ flex: 1, minWidth: 200 }}>{b}</span>
                </div>
              ))}
            </div>
          )}

          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>File</th><th align="right">Rows</th><th>Separator</th>
                  <th align="right">Problem rows</th>
                </tr>
              </thead>
              <tbody>
                {preview.files.map((f) => (
                  <tr key={f.kind}>
                    <td>{SPEC[f.kind].title} <span className="muted">{f.filename}</span></td>
                    <td className="num">{f.n_rows.toLocaleString()}</td>
                    <td className="muted">{f.delimiter === ',' ? 'comma' : f.delimiter}</td>
                    <td className="num">
                      {f.n_problems === 0
                        ? <span className="muted">none</span>
                        : <span className="pill warning">
                            <span className="glyph" aria-hidden="true">●</span>{f.n_problems}
                          </span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Columns: which of your headers fed which field. The single most
              common import failure is a column nobody noticed was ignored. */}
          {preview.files.map((f) => (
            <div key={f.kind} style={{ marginTop: 16 }}>
              <div className="eyebrow" style={{ marginBottom: 6 }}>
                {SPEC[f.kind].title} · columns matched
              </div>
              <div className="scroll-x">
                <table>
                  <thead><tr><th>Field</th><th>Your column</th></tr></thead>
                  <tbody>
                    {f.columns.map((c) => (
                      <tr key={c.field}>
                        <td>{c.field.replace(/_/g, ' ')}</td>
                        <td>
                          {c.header
                            ? <span className="kbd">{c.header}</span>
                            : <span className="muted">not found — left empty</span>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {f.ignored_headers.length > 0 && (
                <p className="note" style={{ marginTop: 8 }}>
                  Ignored, because nothing in this product uses them:{' '}
                  {f.ignored_headers.map((h) => <span key={h} className="kbd" style={{ marginRight: 4 }}>{h}</span>)}
                </p>
              )}
              {f.problems.length > 0 && (
                <div className="scroll-x" style={{ marginTop: 8 }}>
                  <table>
                    <thead><tr><th align="right">Line</th><th>Problem</th></tr></thead>
                    <tbody>
                      {f.problems.map((p, i) => (
                        <tr key={i}><td className="num">{p.line_no}</td><td className="secondary">{p.message}</td></tr>
                      ))}
                    </tbody>
                  </table>
                  {f.n_problems > f.problems.length && (
                    <p className="muted" style={{ fontSize: 'var(--t-small)' }}>
                      …and {f.n_problems - f.problems.length} more. Those rows are recorded as
                      errors and skipped; the rest still import.
                    </p>
                  )}
                </div>
              )}
            </div>
          ))}

          <div style={{ marginTop: 18 }}>
            <div className="eyebrow" style={{ marginBottom: 6 }}>What gets written</div>
            <div className="scroll-x">
              <table>
                <thead>
                  <tr><th>Thing</th><th align="right">New</th><th align="right">Already here</th></tr>
                </thead>
                <tbody>
                  {COUNT_WORDS.filter(([k]) => preview.will_create[k] > 0
                    || (k === 'students' && preview.will_match.students > 0)
                    || (k === 'groups' && preview.will_match.groups > 0)).map(([k, word]) => (
                    <tr key={k}>
                      <td>{word}</td>
                      <td className="num">{preview.will_create[k].toLocaleString()}</td>
                      <td className="num muted">
                        {k === 'students' ? preview.will_match.students.toLocaleString()
                          : k === 'groups' ? preview.will_match.groups.toLocaleString()
                          : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {preview.notes.length > 0 && (
            <div style={{ marginTop: 18 }}>
              <div className="eyebrow" style={{ marginBottom: 6 }}>What will be inferred</div>
              {preview.notes.map((n, i) => (
                <p key={i} className="note" style={{ marginTop: 8 }}>{n}</p>
              ))}
            </div>
          )}
        </section>
      )}

      {/* ---- Done --------------------------------------------------------- */}
      {applied && (
        <section className="card">
          <header>
            <h2>Imported</h2>
            <span className="sub">One transaction — all of it landed, or none of it would have.</span>
          </header>
          <div className="scroll-x">
            <table>
              <thead><tr><th>Thing</th><th align="right">Written</th></tr></thead>
              <tbody>
                {COUNT_WORDS.filter(([k]) => applied.created[k] > 0).map(([k, word]) => (
                  <tr key={k}>
                    <td>{word}</td>
                    <td className="num">{applied.created[k].toLocaleString()}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {applied.batches.some((b) => b.errors > 0) && (
            <p className="note" style={{ marginTop: 12 }}>
              {applied.batches.filter((b) => b.errors > 0)
                .map((b) => `${b.errors} ${b.kind} row(s)`).join(', ')} could not be used and were
              recorded as errors rather than guessed at. They are kept with the import batch.
            </p>
          )}
          {applied.enrolments_inferred_from_marks > 0 && (
            <p className="note" style={{ marginTop: 12 }}>
              {applied.enrolments_inferred_from_marks} enrolment(s) were inferred from the marks: a
              student with a mark in a class is on that class’s register.
            </p>
          )}

          <p className="note" style={{ marginTop: 12 }}>
            <strong>{applied.next}</strong> The analytics are materialised, so until they are
            rebuilt the dashboards will show you an empty product and look broken.
          </p>
          <div className="row" style={{ marginTop: 12 }}>
            <button className="primary" disabled={busy !== ''} onClick={() => void doRefresh()}>
              {busy === 'refresh' ? 'Rebuilding…' : 'Refresh analytics'}
            </button>
            <Link className="btn" to="/classes">Go to classes</Link>
            {refreshed && <span className="saved-flash">{refreshed}</span>}
          </div>
        </section>
      )}

      {/* ---- History ------------------------------------------------------ */}
      {batches.length > 0 && (
        <section className="card">
          <header>
            <h2>Earlier imports</h2>
            <span className="sub">Every row of every import is kept, so a bad one is one delete rather than an incident.</span>
          </header>
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>When</th><th>File</th><th>Kind</th>
                  <th align="right">Rows</th><th align="right">Errors</th><th>By</th>
                </tr>
              </thead>
              <tbody>
                {batches.map((b) => (
                  <tr key={b.id}>
                    <td className="muted">{fmtDate(b.uploaded_at)}</td>
                    <td>{b.filename ?? '—'}</td>
                    <td className="secondary">{b.kind}</td>
                    <td className="num">{b.row_count ?? 0}</td>
                    <td className="num">
                      {(b.error_count ?? 0) === 0
                        ? <span className="muted">0</span>
                        : <span className="pill warning">
                            <span className="glyph" aria-hidden="true">●</span>{b.error_count}
                          </span>}
                    </td>
                    <td className="muted">{b.uploaded_by ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  )
}

/** Rows, not lines: the header is not a row of data and counting it misleads. */
function countLines(text: string): string {
  const n = Math.max(0, text.trim().split(/\r?\n/).filter((l) => l.trim() !== '').length - 1)
  return `${n.toLocaleString()} row${n === 1 ? '' : 's'}`
}

function placeholderFor(kind: FileKind): string {
  switch (kind) {
    case 'students': return 'external_ref,given_name,family_name,year_level\nS001,Alpha,Ash,Y11'
    case 'staff': return 'external_ref,given_name,family_name\nT001,Bravo,Birch'
    case 'groups': return 'group_code,subject_code,subject_name,label,year_level,teacher_ref\n11H1,HIST,History,11H/1,Y11,T001'
    case 'enrolments': return 'student_ref,group_code\nS001,11H1'
    case 'marks': return 'student_ref,group_code,assessment_title,date,item_label,max_value,raw_value,topic,kind\n'
      + 'S001,11H1,Sources test,2026-01-15,Q1,10,7,Source evaluation,summative'
  }
}
