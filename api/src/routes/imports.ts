import type { FastifyInstance } from 'fastify'
import postgres from 'postgres'
import { z } from 'zod'
import { withTenant } from '../db.js'
import { HttpError, requireRole } from '../auth.js'

type Tx = postgres.TransactionSql

// ---------------------------------------------------------------------------
// Limits. A school that pastes its whole MIS export into a textarea should get
// a clear "too big, use the CLI" rather than a request that melts the server
// or a transaction that holds 40,000 row locks for two minutes.
//
// The CLI (tools/import_csv.py) exists for the whole-school case and is not
// bounded like this. The web importer is for a class, a year group, a fix-up.
// ---------------------------------------------------------------------------
const MAX_FILE_CHARS = 700_000
const MAX_TOTAL_CHARS = 1_400_000
const MAX_ROWS_PER_FILE = 5_000
const MAX_COLUMNS = 60
const SAMPLE_PROBLEMS = 8

const FILE_KINDS = ['students', 'staff', 'groups', 'enrolments', 'marks'] as const
type FileKind = (typeof FILE_KINDS)[number]

// ---------------------------------------------------------------------------
// Loose column matching, lifted from tools/import_csv.py so the web importer
// and the CLI accept exactly the same files. No two school systems export the
// same header twice; making a school rename its columns first is how an import
// gets abandoned half way.
// Order matters: the first alias present in the row wins.
// ---------------------------------------------------------------------------
const ALIASES: Record<string, string[]> = {
  student_ref: ['student_ref', 'student', 'student_id', 'external_ref', 'upn', 'candidate_number'],
  staff_ref: ['staff_ref', 'teacher_ref', 'staff', 'teacher', 'external_ref'],
  given_name: ['given_name', 'first_name', 'forename'],
  family_name: ['family_name', 'last_name', 'surname'],
  group_code: ['group_code', 'group', 'class', 'class_code', 'set', 'teaching_group'],
  subject_code: ['subject_code', 'subject'],
  subject_name: ['subject_name', 'subject_title', 'subject'],
  label: ['label', 'class_label', 'group_label', 'class', 'set'],
  year_level: ['year_level', 'year', 'yeargroup', 'year_group', 'form'],
  assessment_title: ['assessment_title', 'assessment', 'title', 'task', 'test'],
  date: ['date', 'occurred_on', 'sat_on', 'assessment_date', 'held_on'],
  item_label: ['item_label', 'item', 'question', 'q', 'criterion', 'component'],
  max_value: ['max_value', 'max', 'out_of', 'total_marks', 'maximum'],
  raw_value: ['raw_value', 'mark', 'score', 'result', 'value', 'raw'],
  topic: ['topic', 'unit', 'tag', 'strand', 'content'],
  kind: ['kind', 'type', 'assessment_type'],
}

/** The fields each file kind can use, in the order the preview lists them. */
const FIELDS: Record<FileKind, string[]> = {
  students: ['student_ref', 'given_name', 'family_name', 'year_level'],
  staff: ['staff_ref', 'given_name', 'family_name'],
  groups: ['group_code', 'subject_code', 'subject_name', 'label', 'year_level', 'staff_ref'],
  enrolments: ['student_ref', 'group_code'],
  marks: ['student_ref', 'group_code', 'assessment_title', 'date', 'item_label',
    'max_value', 'raw_value', 'topic', 'kind'],
}

/** Without these a file cannot be joined to anything and is refused outright. */
const REQUIRED: Record<FileKind, string[]> = {
  students: ['student_ref'],
  staff: ['staff_ref'],
  groups: ['group_code'],
  enrolments: ['student_ref', 'group_code'],
  marks: ['student_ref', 'group_code', 'date'],
}

const ASSESSMENT_KINDS = new Set([
  'formative', 'summative', 'mock', 'exam', 'homework', 'oral', 'practical', 'project', 'external',
])

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------
function norm(h: string): string {
  return (h ?? '').replace(/^\uFEFF/, '').trim().toLowerCase().replace(/[ -]/g, '_')
}

/**
 * Delimiter sniffing. A Greek or German Excel exports semicolons, and a school
 * that gets "1 column detected" back from a comma-only parser concludes the
 * product is broken rather than that its locale is.
 */
function detectDelimiter(firstLine: string): string {
  const candidates = [',', ';', '\t', '|']
  let best = ','
  let bestCount = 0
  for (const d of candidates) {
    let count = 0
    let inQuotes = false
    for (let i = 0; i < firstLine.length; i++) {
      const c = firstLine[i]
      if (c === '"') inQuotes = !inQuotes
      else if (c === d && !inQuotes) count++
    }
    if (count > bestCount) { best = d; bestCount = count }
  }
  return best
}

/** RFC4180-ish: quoted fields, doubled quotes, CRLF or LF, trailing newline. */
function splitCsv(text: string, delim: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let inQuotes = false
  let started = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++ } else inQuotes = false
      } else field += c
      continue
    }
    if (c === '"' && field === '') { inQuotes = true; started = true }
    else if (c === delim) { row.push(field); field = ''; started = true }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; started = false }
    else if (c === '\r') { /* handled by \n */ }
    else { field += c ?? ''; started = true }
  }
  if (started || field !== '' || row.length > 0) { row.push(field); rows.push(row) }
  // Blank lines carry no information and should not be reported as rows.
  return rows.filter((r) => r.some((v) => v.trim() !== ''))
}

type Parsed = {
  kind: FileKind
  filename: string
  delimiter: string
  raw_headers: string[]
  headers: string[]
  rows: { line_no: number; values: Record<string, string> }[]
  truncated: boolean
}

function parseFile(kind: FileKind, filename: string, text: string): Parsed {
  const firstLine = text.slice(0, text.search(/\r?\n/) === -1 ? text.length : text.search(/\r?\n/))
  const delimiter = detectDelimiter(firstLine)
  const grid = splitCsv(text, delimiter)
  const headerRow = grid[0] ?? []
  if (headerRow.length > MAX_COLUMNS) {
    throw new HttpError(400, `${filename}: ${headerRow.length} columns. That is not a data export.`)
  }
  const raw_headers = headerRow.map((h) => h.trim())
  const headers = headerRow.map(norm)
  const body = grid.slice(1)
  const truncated = body.length > MAX_ROWS_PER_FILE
  const kept = truncated ? body.slice(0, MAX_ROWS_PER_FILE) : body

  const rows = kept.map((cells, i) => {
    const values: Record<string, string> = {}
    headers.forEach((h, c) => { if (h) values[h] = (cells[c] ?? '').trim() })
    return { line_no: i + 2, values } // +2: 1-based, and line 1 is the header
  })
  return { kind, filename, delimiter, raw_headers, headers, rows, truncated }
}

function pick(values: Record<string, string>, field: string): string {
  for (const alias of ALIASES[field] ?? [field]) {
    const v = values[alias]
    if (v !== undefined && v.trim() !== '') return v.trim()
  }
  return ''
}

/** Which header fed each field, for "detected columns" in the preview. */
function sourceHeader(headers: string[], field: string): string | null {
  for (const alias of ALIASES[field] ?? [field]) if (headers.includes(alias)) return alias
  return null
}

/** Accepts ISO, and the DD/MM/YYYY that every UK and Greek export produces. */
function normDate(v: string): string | null {
  const s = v.trim()
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return Number.isNaN(Date.parse(s)) ? null : s
  const m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/.exec(s)
  if (m) {
    const [, d, mo, y] = m
    const iso = `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`
    return Number.isNaN(Date.parse(iso)) ? null : iso
  }
  return null
}

/** '7,5' is seven and a half in half of Europe. */
function num(v: string): number | null {
  const s = v.trim().replace(',', '.')
  if (s === '') return null
  const n = Number(s)
  return Number.isFinite(n) ? n : null
}

const ABSENT = new Set(['a', 'abs', 'absent', 'x', '-', 'n/a', 'na'])

// ---------------------------------------------------------------------------
// Analysis. Preview and apply run THIS, not two similar things, so what the
// screen promised and what the database did cannot drift apart.
// ---------------------------------------------------------------------------
type FileReport = {
  kind: FileKind
  filename: string
  delimiter: string
  n_rows: number
  truncated: boolean
  columns: { field: string; header: string | null }[]
  ignored_headers: string[]
  missing_required: string[]
  n_problems: number
  problems: { line_no: number; message: string }[]
}

type Plan = {
  files: FileReport[]
  blocking: string[]
  notes: string[]
  distinct: {
    students: number; staff: number; subjects: number; groups: number
    enrolments: number; assessments: number; items: number; marks: number; topics: number
  }
  groups_inferred_from_marks: string[]
  marks_without_a_student: number
  marks_without_a_max: number
}

function analyse(files: Parsed[]): Plan {
  const reports: FileReport[] = []
  const blocking: string[] = []
  const notes: string[] = []

  for (const f of files) {
    const columns = FIELDS[f.kind].map((field) => ({ field, header: sourceHeader(f.headers, field) }))
    const used = new Set(columns.map((c) => c.header).filter((h): h is string => h !== null))
    const missing_required = REQUIRED[f.kind].filter((r) => sourceHeader(f.headers, r) === null)
    const problems: { line_no: number; message: string }[] = []
    let n_problems = 0

    const note = (line_no: number, message: string) => {
      n_problems++
      if (problems.length < SAMPLE_PROBLEMS) problems.push({ line_no, message })
    }

    if (missing_required.length > 0) {
      blocking.push(
        `${f.filename}: no column matched ${missing_required.join(' or ')}. ` +
        `Headers found: ${f.raw_headers.join(', ') || '(none)'}.`,
      )
    } else {
      for (const r of f.rows) {
        for (const req of REQUIRED[f.kind]) {
          if (req === 'date') {
            const d = pick(r.values, 'date')
            if (!d) note(r.line_no, 'no date')
            else if (!normDate(d)) note(r.line_no, `date "${d}" is not a date this reads`)
          } else if (!pick(r.values, req)) {
            note(r.line_no, `${req.replace(/_/g, ' ')} is empty`)
          }
        }
        if (f.kind === 'marks') {
          const raw = pick(r.values, 'raw_value')
          if (raw && !ABSENT.has(raw.toLowerCase()) && num(raw) === null) {
            note(r.line_no, `mark "${raw}" is neither a number nor an absence`)
          }
        }
      }
    }

    reports.push({
      kind: f.kind,
      filename: f.filename,
      delimiter: f.delimiter === '\t' ? 'tab' : f.delimiter,
      n_rows: f.rows.length,
      truncated: f.truncated,
      columns,
      ignored_headers: f.raw_headers.filter((h) => !used.has(norm(h))),
      missing_required,
      n_problems,
      problems,
    })
    if (f.truncated) {
      blocking.push(
        `${f.filename}: more than ${MAX_ROWS_PER_FILE.toLocaleString()} rows. ` +
        `Split it, or use tools/import_csv.py, which is built for a whole school at once.`,
      )
    }
  }

  const byKind = new Map(files.map((f) => [f.kind, f]))
  const distinctSet = (kind: FileKind, fn: (v: Record<string, string>) => string | null) => {
    const f = byKind.get(kind)
    const out = new Set<string>()
    if (!f) return out
    for (const r of f.rows) { const k = fn(r.values); if (k) out.add(k) }
    return out
  }

  const studentRefs = distinctSet('students', (v) => pick(v, 'student_ref'))
  const staffRefs = distinctSet('staff', (v) => pick(v, 'staff_ref'))
  const groupCodes = distinctSet('groups', (v) => pick(v, 'group_code'))
  const subjectCodes = distinctSet('groups', (v) => pick(v, 'subject_code') || 'GEN')

  const enrolPairs = new Set<string>()
  for (const r of byKind.get('enrolments')?.rows ?? []) {
    const s = pick(r.values, 'student_ref'); const g = pick(r.values, 'group_code')
    if (s && g) enrolPairs.add(`${s}\u0000${g}`)
  }

  const assessments = new Set<string>()
  const items = new Set<string>()
  const topics = new Set<string>()
  const groupsFromMarks = new Set<string>()
  let marks = 0
  let marksWithoutStudent = 0
  let marksWithoutMax = 0
  for (const r of byKind.get('marks')?.rows ?? []) {
    const v = r.values
    const sref = pick(v, 'student_ref')
    const gcode = pick(v, 'group_code')
    const date = normDate(pick(v, 'date'))
    if (!sref || !gcode || !date) continue
    if (studentRefs.size > 0 && !studentRefs.has(sref)) marksWithoutStudent++
    if (!groupCodes.has(gcode)) groupsFromMarks.add(gcode)
    const title = pick(v, 'assessment_title') || 'Imported'
    const akey = `${gcode}\u0000${title}\u0000${date}`
    assessments.add(akey)
    items.add(`${akey}\u0000${pick(v, 'item_label') || 'Total'}`)
    const topic = pick(v, 'topic')
    if (topic) topics.add(`${gcode}\u0000${topic}`)
    if (!pick(v, 'max_value')) marksWithoutMax++
    marks++
  }

  // Honesty notes. Each one is a thing the importer will silently do, said out
  // loud before it does it.
  if (groupsFromMarks.size > 0) {
    notes.push(
      `${groupsFromMarks.size} class(es) appear in the marks but not in a class list, ` +
      `so they will be created from the marks: ${[...groupsFromMarks].slice(0, 8).join(', ')}` +
      `${groupsFromMarks.size > 8 ? ', …' : ''}. Dropping them instead would leave you with ` +
      `an import that reported success and a product with nothing in it.`,
    )
  }
  if (marksWithoutStudent > 0) {
    notes.push(
      `${marksWithoutStudent} mark(s) name a student ref that is not in the student list. ` +
      `Those rows will be skipped and recorded as errors — nothing is invented for them.`,
    )
  }
  if (marks > 0 && marksWithoutMax === marks) {
    notes.push(
      'No "out of" / max column was detected. The marks will be stored, but without a ' +
      'denominator they cannot be turned into a percentage, so topic and cohort analytics ' +
      'will stay empty. Add a max column if you want those.',
    )
  } else if (marksWithoutMax > 0) {
    notes.push(
      `${marksWithoutMax} mark(s) have no "out of" value. They are kept as raw marks but are ` +
      `left out of every percentage-based analytic, rather than being guessed at.`,
    )
  }
  if (marks > 0 && enrolPairs.size === 0) {
    notes.push(
      'No enrolment list was supplied. A student who has a mark in a class is taken to be in ' +
      'that class, so the register is built from the marks. Without it every "outstanding" ' +
      'count would be measured against zero students.',
    )
  }
  if (topics.size > 0) {
    notes.push(
      `${topics.size} topic(s) will be created as an imported taxonomy per subject. ` +
      `Topic tagging is what unlocks the topic-level analytics; untagged marks still give ` +
      `trajectory.`,
    )
  }

  return {
    files: reports,
    blocking,
    notes,
    distinct: {
      students: studentRefs.size,
      staff: staffRefs.size,
      subjects: subjectCodes.size,
      groups: groupCodes.size + groupsFromMarks.size,
      enrolments: enrolPairs.size,
      assessments: assessments.size,
      items: items.size,
      marks,
      topics: topics.size,
    },
    groups_inferred_from_marks: [...groupsFromMarks],
    marks_without_a_student: marksWithoutStudent,
    marks_without_a_max: marksWithoutMax,
  }
}

// ---------------------------------------------------------------------------
// Request shape
// ---------------------------------------------------------------------------
const fileSchema = z.object({
  kind: z.enum(FILE_KINDS),
  filename: z.string().max(200).optional(),
  text: z.string().max(MAX_FILE_CHARS,
    `A single file may not exceed ${MAX_FILE_CHARS.toLocaleString()} characters.`),
})
const bodySchema = z.object({ files: z.array(fileSchema).min(1).max(FILE_KINDS.length) })

function parseAll(body: unknown): Parsed[] {
  const parsed = bodySchema.safeParse(body)
  if (!parsed.success) {
    // A 500 with a Zod dump is not an error message a school administrator can
    // act on. Say the size limit, since that is what they actually hit.
    throw new HttpError(400,
      `That request could not be read. Each file must be plain CSV text of at most ` +
      `${MAX_FILE_CHARS.toLocaleString()} characters.`)
  }
  const { files } = parsed.data
  const total = files.reduce((n, f) => n + f.text.length, 0)
  if (total > MAX_TOTAL_CHARS) {
    throw new HttpError(413,
      `That is ${(total / 1e6).toFixed(1)} MB of CSV in one request. Import one file at a time, ` +
      `or use tools/import_csv.py for the whole school.`)
  }
  const seen = new Set<string>()
  return files.map((f) => {
    if (seen.has(f.kind)) throw new HttpError(400, `Two ${f.kind} files in one import.`)
    seen.add(f.kind)
    if (f.text.trim() === '') throw new HttpError(400, `The ${f.kind} file is empty.`)
    return parseFile(f.kind, f.filename ?? `${f.kind}.csv`, f.text)
  })
}

// ---------------------------------------------------------------------------
// Staging. Every source row is written to org.import_row before anything is
// derived from it, so a bad import is one DELETE rather than an incident.
// ---------------------------------------------------------------------------
type StageRow = { line_no: number; payload: Record<string, string>; status: string; message: string | null }

async function stage(tx: Tx, tenantId: string, batchId: string, rows: StageRow[]) {
  for (let i = 0; i < rows.length; i += 500) {
    const chunk = rows.slice(i, i + 500)
    await tx`
      INSERT INTO org.import_row (tenant_id, batch_id, line_no, payload, status, message)
      SELECT ${tenantId}::uuid, ${batchId}::uuid, (r->>'line_no')::int, r->'payload',
             r->>'status', r->>'message'
      FROM jsonb_array_elements(${tx.json(chunk)}::jsonb) AS r`
  }
}

async function openBatch(
  tx: Tx, tenantId: string, userId: string, kind: FileKind, filename: string, rowCount: number,
): Promise<string> {
  const [row] = await tx<{ id: string }[]>`
    INSERT INTO org.import_batch (tenant_id, kind, source, filename, uploaded_by, row_count, status)
    VALUES (${tenantId}, ${kind}, 'csv', ${filename}, ${userId}, ${rowCount}, 'validating')
    RETURNING id`
  return row!.id
}

async function closeBatch(tx: Tx, batchId: string, ok: number, errors: number) {
  await tx`UPDATE org.import_batch
           SET ok_count = ${ok}, error_count = ${errors}, status = 'applied'
           WHERE id = ${batchId}`
}

export async function registerImportRoutes(app: FastifyInstance) {
  // -------------------------------------------------------------------------
  // PREVIEW. Parses, reports, and writes nothing at all — not a staging row,
  // not a batch record. An admin has to be able to point this at a file they
  // are unsure about without consequences, or they will never try it.
  // -------------------------------------------------------------------------
  app.post('/imports/preview', async (req) => {
    const s = requireRole(req, 'school_admin')
    const files = parseAll(req.body)
    const plan = analyse(files)

    return withTenant(s, async (tx) => {
      const [year] = await tx<{ id: string; label: string; starts_on: string }[]>`
        SELECT id, label, starts_on::text FROM org.academic_year
        WHERE is_current ORDER BY starts_on DESC LIMIT 1`

      // What already exists, so the screen can say "matched" rather than
      // implying a fresh 900 students are about to appear.
      const studentRefs = [...new Set((files.find((f) => f.kind === 'students')?.rows ?? [])
        .map((r) => pick(r.values, 'student_ref')).filter(Boolean))]
      const groupLabels = [...new Set((files.find((f) => f.kind === 'groups')?.rows ?? [])
        .map((r) => pick(r.values, 'label') || pick(r.values, 'group_code')).filter(Boolean))]

      const existingStudents = studentRefs.length === 0 ? 0 : Number(
        (await tx<{ n: string }[]>`
          SELECT count(*)::text AS n FROM org.person
          WHERE external_ref = ANY(${studentRefs}::text[]) AND deleted_at IS NULL`)[0]?.n ?? 0)
      const existingGroups = groupLabels.length === 0 ? 0 : Number(
        (await tx<{ n: string }[]>`
          SELECT count(*)::text AS n FROM org.teaching_group
          WHERE label = ANY(${groupLabels}::text[])`)[0]?.n ?? 0)

      const blocking = [...plan.blocking]
      if (!year) {
        blocking.push(
          'This school has no current academic year, so there is nothing to attach classes to. ' +
          'Finish setting the school up first.')
      }

      return {
        ok: blocking.length === 0,
        academic_year: year?.label ?? null,
        blocking,
        notes: plan.notes,
        files: plan.files,
        will_create: {
          ...plan.distinct,
          students: Math.max(0, plan.distinct.students - existingStudents),
          groups: Math.max(0, plan.distinct.groups - existingGroups),
        },
        will_match: { students: existingStudents, groups: existingGroups },
        groups_inferred_from_marks: plan.groups_inferred_from_marks,
        limits: { max_rows_per_file: MAX_ROWS_PER_FILE, max_file_chars: MAX_FILE_CHARS },
      }
    })
  })

  // -------------------------------------------------------------------------
  // APPLY. One transaction: either the whole import lands or none of it does.
  // Everything runs inside withTenant, so RLS is between this code and any
  // other school's rows even if this file is wrong.
  // -------------------------------------------------------------------------
  app.post('/imports/apply', async (req) => {
    const s = requireRole(req, 'school_admin')
    const files = parseAll(req.body)
    const plan = analyse(files)
    if (plan.blocking.length > 0) throw new HttpError(400, plan.blocking.join(' '))

    const byKind = new Map(files.map((f) => [f.kind, f]))

    return withTenant(s, async (tx) => {
      const [year] = await tx<{ id: string; starts_on: string }[]>`
        SELECT id, starts_on::text FROM org.academic_year
        WHERE is_current ORDER BY starts_on DESC LIMIT 1`
      if (!year) {
        throw new HttpError(409,
          'This school has no current academic year. Finish setting the school up first.')
      }
      const yearId = year.id
      const fromDate = year.starts_on

      const created = {
        students: 0, staff: 0, subjects: 0, groups: 0, enrolments: 0,
        assessments: 0, items: 0, marks: 0, topics: 0,
      }
      const batches: { id: string; kind: FileKind; row_count: number; ok: number; errors: number }[] = []
      const people = new Map<string, string>()   // student external_ref -> person id
      const staff = new Map<string, string>()    // staff  external_ref -> person id
      const subjects = new Map<string, string>() // subject code        -> subject id
      const groups = new Map<string, string>()   // group code          -> teaching_group id
      const groupSubject = new Map<string, string>()

      // ---- students ------------------------------------------------------
      const studentsFile = byKind.get('students')
      if (studentsFile) {
        const batchId = await openBatch(tx, s.tenantId, s.userId, 'students',
          studentsFile.filename, studentsFile.rows.length)
        const staged: StageRow[] = []
        let ok = 0, errors = 0
        for (const r of studentsFile.rows) {
          const ref = pick(r.values, 'student_ref')
          if (!ref) {
            staged.push({ line_no: r.line_no, payload: r.values, status: 'error', message: 'no student ref' })
            errors++; continue
          }
          let id = await studentFor(ref)
          if (!id) {
            const [ins] = await tx<{ id: string }[]>`
              INSERT INTO org.person (tenant_id, external_ref, given_name, family_name, is_student)
              VALUES (${s.tenantId}, ${ref}, ${pick(r.values, 'given_name') || 'Student'},
                      ${pick(r.values, 'family_name') || ref}, true)
              RETURNING id`
            id = ins!.id
            created.students++
          }
          people.set(ref, id)
          staged.push({ line_no: r.line_no, payload: r.values, status: 'ok', message: null })
          ok++
        }
        await stage(tx, s.tenantId, batchId, staged)
        await closeBatch(tx, batchId, ok, errors)
        batches.push({ id: batchId, kind: 'students', row_count: studentsFile.rows.length, ok, errors })
      }

      // ---- staff ---------------------------------------------------------
      // People records only. No sign-in account is created here: accounts come
      // from an invitation the person accepts themselves, so nobody ends up
      // with a credential they never set.
      const staffFile = byKind.get('staff')
      if (staffFile) {
        const batchId = await openBatch(tx, s.tenantId, s.userId, 'staff',
          staffFile.filename, staffFile.rows.length)
        const staged: StageRow[] = []
        let ok = 0, errors = 0
        for (const r of staffFile.rows) {
          const ref = pick(r.values, 'staff_ref')
          if (!ref) {
            staged.push({ line_no: r.line_no, payload: r.values, status: 'error', message: 'no staff ref' })
            errors++; continue
          }
          const [found] = await tx<{ id: string }[]>`
            SELECT id FROM org.person
            WHERE external_ref = ${ref} AND deleted_at IS NULL LIMIT 1`
          let id = found?.id
          if (!id) {
            const [ins] = await tx<{ id: string }[]>`
              INSERT INTO org.person (tenant_id, external_ref, given_name, family_name, is_staff)
              VALUES (${s.tenantId}, ${ref}, ${pick(r.values, 'given_name') || 'Staff'},
                      ${pick(r.values, 'family_name') || ref}, true)
              RETURNING id`
            id = ins!.id
            created.staff++
          }
          staff.set(ref, id)
          staged.push({ line_no: r.line_no, payload: r.values, status: 'ok', message: null })
          ok++
        }
        await stage(tx, s.tenantId, batchId, staged)
        await closeBatch(tx, batchId, ok, errors)
        batches.push({ id: batchId, kind: 'staff', row_count: staffFile.rows.length, ok, errors })
      }

      // ---- helpers used by groups, enrolments and marks -------------------
      /**
       * A student already on roll is matched, never duplicated. A second import
       * that re-states last term's roster must not double the school.
       */
      async function studentFor(ref: string): Promise<string | undefined> {
        if (!ref) return undefined
        const cached = people.get(ref)
        if (cached) return cached
        const [found] = await tx<{ id: string }[]>`
          SELECT id FROM org.person
          WHERE external_ref = ${ref} AND deleted_at IS NULL LIMIT 1`
        if (found) people.set(ref, found.id)
        return found?.id
      }

      /** Lookup only. An enrolment must never bring a class into existence. */
      async function findGroup(code: string): Promise<string | undefined> {
        if (!code) return undefined
        const cached = groups.get(code)
        if (cached) return cached
        const [found] = await tx<{ id: string; subject_id: string }[]>`
          SELECT id, subject_id FROM org.teaching_group
          WHERE academic_year_id = ${yearId} AND label = ${code} LIMIT 1`
        if (found) { groups.set(code, found.id); groupSubject.set(code, found.subject_id) }
        return found?.id
      }

      async function subjectFor(code: string, name: string): Promise<string> {
        const existing = subjects.get(code)
        if (existing) return existing
        const [row] = await tx<{ id: string; inserted: boolean }[]>`
          INSERT INTO org.subject (tenant_id, code, name)
          VALUES (${s.tenantId}, ${code}, ${name || code})
          ON CONFLICT (tenant_id, code) DO UPDATE SET name = EXCLUDED.name
          RETURNING id, (xmax = 0) AS inserted`
        if (row!.inserted) created.subjects++
        subjects.set(code, row!.id)
        return row!.id
      }

      async function groupFor(code: string, subjectId: string, label: string, yearLevel: string | null) {
        const existing = groups.get(code)
        if (existing) return existing
        // Match an existing class by the label first. Resolving only by the
        // conflict target would create a second "11H/1" under a different
        // subject the moment a marks-only import guessed at the subject.
        const [found] = await tx<{ id: string; subject_id: string }[]>`
          SELECT id, subject_id FROM org.teaching_group
          WHERE academic_year_id = ${yearId} AND label = ${label || code} LIMIT 1`
        if (found) {
          groups.set(code, found.id)
          groupSubject.set(code, found.subject_id)
          return found.id
        }
        const [row] = await tx<{ id: string }[]>`
          INSERT INTO org.teaching_group (tenant_id, academic_year_id, subject_id, label, year_level)
          VALUES (${s.tenantId}, ${yearId}, ${subjectId}, ${label || code}, ${yearLevel})
          RETURNING id`
        created.groups++
        groups.set(code, row!.id)
        groupSubject.set(code, subjectId)
        return row!.id
      }

      const taxonomies = new Map<string, string>() // subject id -> taxonomy id
      const tags = new Map<string, string>()       // taxonomy id + label -> tag id
      async function tagFor(gcode: string, topic: string): Promise<string | null> {
        if (!topic) return null
        const subjectId = groupSubject.get(gcode)
        if (!subjectId) return null
        let taxId = taxonomies.get(subjectId)
        if (!taxId) {
          const [t] = await tx<{ id: string }[]>`
            INSERT INTO curric.taxonomy (owner_tenant_id, code, name, axis, subject_id)
            VALUES (${s.tenantId}, ${`IMPORTED-${subjectId}`}, 'Imported topics', 'topic', ${subjectId})
            ON CONFLICT (owner_tenant_id, code) DO UPDATE SET name = EXCLUDED.name
            RETURNING id`
          taxId = t!.id
          taxonomies.set(subjectId, taxId)
        }
        const key = `${taxId}\u0000${topic}`
        const cached = tags.get(key)
        if (cached) return cached
        const [tag] = await tx<{ id: string; inserted: boolean }[]>`
          INSERT INTO curric.tag (taxonomy_id, code, label)
          VALUES (${taxId}, ${topic.slice(0, 60)}, ${topic})
          ON CONFLICT (taxonomy_id, code) DO UPDATE SET label = EXCLUDED.label
          RETURNING id, (xmax = 0) AS inserted`
        if (tag!.inserted) created.topics++
        tags.set(key, tag!.id)
        return tag!.id
      }

      // ---- groups ---------------------------------------------------------
      const groupsFile = byKind.get('groups')
      if (groupsFile) {
        const batchId = await openBatch(tx, s.tenantId, s.userId, 'groups',
          groupsFile.filename, groupsFile.rows.length)
        const staged: StageRow[] = []
        let ok = 0, errors = 0
        for (const r of groupsFile.rows) {
          const gcode = pick(r.values, 'group_code')
          if (!gcode) {
            staged.push({ line_no: r.line_no, payload: r.values, status: 'error', message: 'no class code' })
            errors++; continue
          }
          const scode = pick(r.values, 'subject_code') || 'GEN'
          const subjectId = await subjectFor(scode, pick(r.values, 'subject_name'))
          await groupFor(gcode, subjectId, pick(r.values, 'label') || gcode,
            pick(r.values, 'year_level') || null)
          const tref = pick(r.values, 'staff_ref')
          const staffId = tref ? staff.get(tref) : undefined
          if (staffId) {
            await tx`
              INSERT INTO org.teaching_assignment
                (tenant_id, staff_id, teaching_group_id, role, from_date)
              SELECT ${s.tenantId}, ${staffId}, ${groups.get(gcode)!}, 'primary', ${fromDate}::date
              WHERE NOT EXISTS (
                SELECT 1 FROM org.teaching_assignment ta
                WHERE ta.staff_id = ${staffId} AND ta.teaching_group_id = ${groups.get(gcode)!}
                  AND ta.to_date IS NULL)`
          }
          staged.push({
            line_no: r.line_no, payload: r.values, status: tref && !staffId ? 'warning' : 'ok',
            message: tref && !staffId ? `teacher ref "${tref}" is not in the staff list` : null,
          })
          ok++
        }
        await stage(tx, s.tenantId, batchId, staged)
        await closeBatch(tx, batchId, ok, errors)
        batches.push({ id: batchId, kind: 'groups', row_count: groupsFile.rows.length, ok, errors })
      }

      // ---- enrolments -----------------------------------------------------
      const enrolFile = byKind.get('enrolments')
      if (enrolFile) {
        const batchId = await openBatch(tx, s.tenantId, s.userId, 'enrolments',
          enrolFile.filename, enrolFile.rows.length)
        const staged: StageRow[] = []
        let ok = 0, errors = 0
        for (const r of enrolFile.rows) {
          const sref = pick(r.values, 'student_ref')
          const gcode = pick(r.values, 'group_code')
          const studentId = await studentFor(sref)
          const groupId = await findGroup(gcode)
          // An enrolment never invents a class or a student: a typo here would
          // silently create a duplicate roster that nobody ever reconciles.
          if (!studentId || !groupId) {
            staged.push({
              line_no: r.line_no, payload: r.values, status: 'error',
              message: !studentId
                ? `no student matches "${sref}" — import the student list first`
                : `no class matches "${gcode}" — import the class list first`,
            })
            errors++; continue
          }
          const res = await tx`
            INSERT INTO org.enrolment (tenant_id, student_id, teaching_group_id, from_date)
            VALUES (${s.tenantId}, ${studentId}, ${groupId}, ${fromDate}::date)
            ON CONFLICT DO NOTHING`
          if (res.count > 0) created.enrolments++
          staged.push({ line_no: r.line_no, payload: r.values, status: 'ok', message: null })
          ok++
        }
        await stage(tx, s.tenantId, batchId, staged)
        await closeBatch(tx, batchId, ok, errors)
        batches.push({ id: batchId, kind: 'enrolments', row_count: enrolFile.rows.length, ok, errors })
      }

      // ---- marks ----------------------------------------------------------
      const inferredGroups: string[] = []
      let inferredEnrolments = 0
      const marksFile = byKind.get('marks')
      if (marksFile) {
        const batchId = await openBatch(tx, s.tenantId, s.userId, 'marks',
          marksFile.filename, marksFile.rows.length)
        const staged: StageRow[] = []
        let ok = 0, errors = 0
        const assessments = new Map<string, string>()
        const items = new Map<string, string>()
        // Keyed, not a list: a school export routinely repeats a cell, and
        // ON CONFLICT DO UPDATE cannot touch the same row twice in one
        // statement. Last value for a cell wins, exactly as re-marking does.
        const results = new Map<string, {
          item_id: string; student_id: string; raw_value: number | null
          max_value: number | null; status: string; observed_on: string
        }>()

        for (const r of marksFile.rows) {
          const v = r.values
          const sref = pick(v, 'student_ref')
          const gcode = pick(v, 'group_code')
          const date = normDate(pick(v, 'date'))
          if (!sref || !gcode || !date) {
            staged.push({
              line_no: r.line_no, payload: v, status: 'error',
              message: !date ? 'no usable date' : 'no student ref or class code',
            })
            errors++; continue
          }

          // A class present in the marks but absent from groups.csv is created
          // rather than dropped. Schools very often export marks with no
          // separate class list; skipping those rows means the admin imports a
          // file, sees no error, and gets an empty product.
          let groupId = await findGroup(gcode)
          if (!groupId) {
            const subjectId = await subjectFor('GEN', 'Imported')
            groupId = await groupFor(gcode, subjectId, gcode, null)
            inferredGroups.push(gcode)
          }

          const studentId = await studentFor(sref)
          if (!studentId) {
            staged.push({
              line_no: r.line_no, payload: v, status: 'error',
              message: `student "${sref}" is not in the student list and was not already on roll`,
            })
            errors++; continue
          }

          const title = pick(v, 'assessment_title') || 'Imported'
          const rawKind = pick(v, 'kind').toLowerCase()
          const akey = `${gcode}\u0000${title}\u0000${date}`
          let assessmentId = assessments.get(akey)
          if (!assessmentId) {
            const [a] = await tx<{ id: string }[]>`
              INSERT INTO gradebook.assessment
                (tenant_id, teaching_group_id, title, kind, occurred_on, topic_tag_id, created_by)
              VALUES (${s.tenantId}, ${groupId}, ${title},
                      ${ASSESSMENT_KINDS.has(rawKind) ? rawKind : 'summative'}, ${date}::date,
                      ${await tagFor(gcode, pick(v, 'topic'))}, ${s.userId})
              RETURNING id`
            assessmentId = a!.id
            assessments.set(akey, assessmentId)
            created.assessments++
          }

          const ilabel = pick(v, 'item_label') || 'Total'
          const ikey = `${akey}\u0000${ilabel}`
          const maxValue = num(pick(v, 'max_value'))
          let itemId = items.get(ikey)
          if (!itemId) {
            const seq = [...items.keys()].filter((k) => k.startsWith(`${akey}\u0000`)).length
            const [it] = await tx<{ id: string }[]>`
              INSERT INTO gradebook.item
                (tenant_id, assessment_id, seq, label, max_value, topic_tag_id)
              VALUES (${s.tenantId}, ${assessmentId}, ${seq}, ${ilabel.slice(0, 80)},
                      ${maxValue}, ${await tagFor(gcode, pick(v, 'topic'))})
              RETURNING id`
            itemId = it!.id
            items.set(ikey, itemId)
            created.items++
          }

          const raw = pick(v, 'raw_value')
          const absent = raw === '' || ABSENT.has(raw.toLowerCase())
          const value = absent ? null : num(raw)
          if (!absent && value === null) {
            staged.push({
              line_no: r.line_no, payload: v, status: 'error',
              message: `mark "${raw}" is neither a number nor an absence`,
            })
            errors++; continue
          }
          results.set(`${itemId}\u0000${studentId}`, {
            item_id: itemId, student_id: studentId, raw_value: value, max_value: maxValue,
            // Absence is never a zero. It is recorded as an absence and left
            // out of every mean.
            status: absent ? 'absent' : 'scored',
            observed_on: date,
          })
          staged.push({ line_no: r.line_no, payload: v, status: 'ok', message: null })
          ok++
        }

        const resultRows = [...results.values()]
        for (let i = 0; i < resultRows.length; i += 500) {
          const chunk = resultRows.slice(i, i + 500)
          const res = await tx`
            INSERT INTO gradebook.result
              (tenant_id, item_id, student_id, raw_value, max_value, status, observed_on, source)
            SELECT ${s.tenantId}::uuid, (r->>'item_id')::uuid, (r->>'student_id')::uuid,
                   (r->>'raw_value')::numeric, (r->>'max_value')::numeric,
                   r->>'status', (r->>'observed_on')::date, 'import'
            FROM jsonb_array_elements(${tx.json(chunk)}::jsonb) AS r
            ON CONFLICT (item_id, student_id, marker_role) DO UPDATE
              SET raw_value = EXCLUDED.raw_value, max_value = EXCLUDED.max_value,
                  status = EXCLUDED.status`
          created.marks += res.count
        }

        // A student with a mark in a class is in that class. Without this a
        // marks-only import produces classes with no register, and every
        // "outstanding" count and cohort statistic is computed against zero.
        const touched = [...new Set(groups.values())]
        if (touched.length > 0) {
          const inf = await tx`
            INSERT INTO org.enrolment (tenant_id, student_id, teaching_group_id, from_date)
            SELECT DISTINCT r.tenant_id, r.student_id, a.teaching_group_id, ${fromDate}::date
            FROM gradebook.result r
            JOIN gradebook.item i ON i.id = r.item_id
            JOIN gradebook.assessment a ON a.id = i.assessment_id
            WHERE a.teaching_group_id = ANY(${touched}::uuid[])
              AND NOT EXISTS (
                SELECT 1 FROM org.enrolment e
                WHERE e.student_id = r.student_id AND e.teaching_group_id = a.teaching_group_id
                  AND e.to_date IS NULL)
            ON CONFLICT DO NOTHING`
          inferredEnrolments = inf.count
          created.enrolments += inf.count
        }

        await stage(tx, s.tenantId, batchId, staged)
        await closeBatch(tx, batchId, ok, errors)
        batches.push({ id: batchId, kind: 'marks', row_count: marksFile.rows.length, ok, errors })
      }

      return {
        ok: true,
        batches,
        created,
        groups_inferred_from_marks: [...new Set(inferredGroups)],
        enrolments_inferred_from_marks: inferredEnrolments,
        notes: plan.notes,
        // Analytics are materialized. Until they are refreshed the dashboards
        // will show the school an empty product and it will look broken.
        next: 'Refresh analytics to see this data in the dashboards.',
      }
    })
  })

  // -------------------------------------------------------------------------
  // What has been imported before. Cheap, and it is the first thing an admin
  // asks when a number looks wrong.
  // -------------------------------------------------------------------------
  app.get('/imports', async (req) => {
    const s = requireRole(req, 'school_admin')
    return withTenant(s, async (tx) => tx`
      SELECT b.id, b.kind, b.filename, b.uploaded_at, b.row_count, b.ok_count, b.error_count,
             b.status, u.display_name AS uploaded_by
      FROM org.import_batch b
      LEFT JOIN platform.app_user u ON u.id = b.uploaded_by
      ORDER BY b.uploaded_at DESC LIMIT 50`)
  })

  /** The rows that did not land, for one batch. The only useful error report. */
  app.get('/imports/:id/problems', async (req) => {
    const s = requireRole(req, 'school_admin')
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params)
    return withTenant(s, async (tx) => tx`
      SELECT line_no, status, message, payload
      FROM org.import_row
      WHERE batch_id = ${id} AND status IN ('error', 'warning')
      ORDER BY line_no LIMIT 200`)
  })
}
