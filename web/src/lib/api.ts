const BASE = '/api'

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(BASE + path, {
    credentials: 'include',
    headers: init?.body ? { 'content-type': 'application/json' } : undefined,
    ...init,
  })
  if (!res.ok) {
    const body = await res.json().catch(() => ({ error: res.statusText }))
    throw new Error(body.error ?? `HTTP ${res.status}`)
  }
  return res.json() as Promise<T>
}

export const api = {
  get: <T,>(p: string) => req<T>(p),
  post: <T,>(p: string, body?: unknown) =>
    req<T>(p, { method: 'POST', body: body === undefined ? undefined : JSON.stringify(body) }),
}

export type DevUser = {
  user_id: string; display_name: string; tenant_id: string; tenant_name: string; roles: string[]
}
export type Group = {
  id: string; label: string; year_level: string | null; subject_name: string
  subject_code: string; academic_year: string; n_students: string; framework: string | null
}
export type Student = {
  id: string; given_name: string; family_name: string
  preferred_name: string | null; external_ref: string | null; is_provisional?: boolean
}
export type Attention = {
  kind: string; student_id: string | null; student_name: string | null
  teaching_group_id: string; group_label: string
  tag_id: string | null; tag_label: string | null
  headline: string; effect: string; evidence: string; time_context: string | null
}
export type HeatCell = {
  tag_id: string; tag_code: string; tag_label: string
  n_responses: string; n_students: string
  cohort_mean_pct: string | null; cohort_verdict: string
  external_facility: string | null
  lessons_delivered: string | null; delivery_ratio: string | null
  n_students_below: string
}
export type Todo = {
  assessment_id: string; title: string; occurred_on: string; group_label: string
  subject_name: string; students_expected: string; students_marked: string
  students_outstanding: string; days_since: number
}
export type GridItem = {
  id: string; seq: number; label: string; max_value: string | null
  topic_label: string | null; measure_label: string | null
}
export type Grid = {
  assessment: {
    id: string; title: string; kind: string; occurred_on: string
    max_total: string | null; group_label: string; subject_name: string
    marking_closed_at: string | null; teaching_group_id: string
  }
  items: GridItem[]
  students: Student[]
  marks: { item_id: string; student_id: string; raw_value: string | null; status: string }[]
}
export type Gap = {
  teaching_group_id: string; group_label: string; subject_name: string
  tag_id: string; tag_label: string
  n_responses: string; n_assessments: string
  mean_pct: string | null; mean_pct_recent: string | null
  mean_residual: string | null; residual_ci_upper: string | null
  cohort_mean_pct: string | null; verdict: string; time_context: string | null
  missed_ratio: string | null
}
export type TimelinePoint = {
  observed_on: string; group_label: string; subject_name: string
  assessment_title: string; mean_pct: string; mean_adj: string; n_responses: string
}
export type StudentProfile = {
  student: Student
  gaps: Gap[]
  timeline: TimelinePoint[]
  trajectory: { group_label: string; subject_name: string; trajectory: string; shift: string | null }[]
  pooling: { pooling_verdict: string; n_frameworks: string } | null
}

/** Postgres dates arrive as ISO strings; never show a raw timestamp to a teacher. */
export function fmtDate(d: string | null | undefined): string {
  if (!d) return '—'
  const t = new Date(d)
  return Number.isNaN(t.getTime()) ? String(d)
    : t.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
}
