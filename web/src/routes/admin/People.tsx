import { useCallback, useEffect, useState } from 'react'
import { NavLink } from 'react-router-dom'
import { api, fmtDate } from '../../lib/api'

/**
 * PEOPLE — staff, roles, and who is attached to which class and which tutee.
 *
 * Two things this screen refuses to do quietly.
 *
 * First, roles are a data-protection decision, not a preference. A school
 * admin ticking "tutor" is deciding which children's marks a member of staff
 * can read, and the consequence is enforced in the database by
 * app.can_see_student(). So the consequence is written out on the screen, in
 * words, next to the checkboxes — not hidden in a manual nobody opens.
 *
 * Second, it tells the truth about head_of_dept: the role is recorded, and the
 * database currently grants it nothing beyond teacher. Displaying it as if it
 * conferred departmental oversight would be the product lying about its own
 * access model.
 *
 * Every endpoint behind this screen enforces school_admin server-side. Hiding
 * this screen is not the control; requireRole is.
 */

// ---------------------------------------------------------------------------
// Types. Postgres counts arrive as strings (bigint), dates as ISO strings.
// ---------------------------------------------------------------------------
type UserRow = {
  id: string
  display_name: string
  email: string | null
  is_active: boolean
  last_seen_at: string | null
  roles: string[]
  n_classes: string
}
type StaffRow = {
  id: string
  given_name: string
  family_name: string
  preferred_name: string | null
  external_ref: string | null
  user_id: string | null
  left_on: string | null
  display_name: string | null
  email: string | null
  is_active: boolean | null
  roles: string[]
  n_classes: string
  n_tutees: string
}
type GroupRow = {
  id: string
  label: string
  subject_name: string
  year_level: string | null
  n_students: string
  teachers: string[]
}
type AssignmentRow = {
  id: string
  role: string
  from_date: string
  staff_id: string
  given_name: string
  family_name: string
  teaching_group_id: string
  group_label: string
  subject_name: string
}
type TutorRow = {
  id: string
  from_date: string
  staff_id: string
  staff_given: string
  staff_family: string
  student_id: string
  student_given: string
  student_family: string
  external_ref: string | null
}
type StudentRow = {
  id: string
  given_name: string
  family_name: string
  external_ref: string | null
  n_tutors: string
}
type InviteRow = {
  id: string
  email: string
  display_name: string | null
  roles: string[]
  created_at: string
  expires_at: string
  accepted_at: string | null
}

// ---------------------------------------------------------------------------
// What each role can actually see. Taken from 009_rls.sql, not from intent.
// ---------------------------------------------------------------------------
const ROLES: { code: string; name: string; sees: string; caution?: string }[] = [
  {
    code: 'school_admin',
    name: 'School admin',
    sees: 'Every student in the school, every mark, every class, and these settings. ' +
      'The widest access the product grants.',
    caution: 'Give it to as few people as the school can run on.',
  },
  {
    code: 'dpo',
    name: 'Data protection officer',
    sees: 'Every student in the school, the same as an admin, so that subject-access ' +
      'requests can be answered. Every read is written to the access log.',
  },
  {
    code: 'teacher',
    name: 'Teacher',
    sees: 'Only students currently enrolled in a class they are currently assigned to. ' +
      'End the assignment and the access ends with it.',
  },
  {
    code: 'tutor',
    name: 'Tutor / homeroom',
    sees: 'Their tutees, across every subject — including subjects they do not teach. ' +
      'This is the pastoral view and it is deliberately wider than a teacher’s.',
    caution: 'A subject teacher sees one subject. A tutor sees the whole child.',
  },
  {
    code: 'head_of_dept',
    name: 'Head of department',
    sees: 'Recorded on the account, but the database grants it no access beyond teacher. ' +
      'It does not open up a department’s students.',
    caution: 'Shown honestly rather than implied: ticking this does not widen anything yet.',
  },
]

/**
 * A status badge. Colour never carries the meaning on its own: every one of
 * these pairs the status colour with a glyph and a word, exactly as
 * components/Pill.tsx does for analytic verdicts.
 */
function Flag({ tone, glyph, label, title }:
  { tone: 'good' | 'warning' | 'serious' | 'critical' | 'neutral'
    glyph: string; label: string; title: string }) {
  return (
    <span className={`pill ${tone}`} title={title}>
      <span className="glyph" aria-hidden="true">{glyph}</span>{label}
    </span>
  )
}

/** Shared sub-navigation for the three administration screens. */
export function AdminTabs() {
  const tabs = [
    { to: '/admin/people', label: 'People' },
    { to: '/admin/school', label: 'School' },
    { to: '/admin/curriculum', label: 'Curriculum' },
  ]
  return (
    <div className="row" style={{ gap: 14 }}>
      {tabs.map((t) => (
        <NavLink key={t.to} to={t.to}
                 className={({ isActive }) => (isActive ? '' : 'muted')}
                 style={({ isActive }) => ({
                   fontWeight: isActive ? 600 : 500,
                   fontSize: 'var(--t-small)',
                   textDecoration: 'none',
                   borderBottom: isActive ? '2px solid var(--accent)' : '2px solid transparent',
                   paddingBottom: 3,
                 })}>
          {t.label}
        </NavLink>
      ))}
    </div>
  )
}

const INVITABLE = ['teacher', 'tutor', 'head_of_dept', 'school_admin', 'dpo'] as const

export default function People() {
  const [users, setUsers] = useState<UserRow[]>([])
  const [staff, setStaff] = useState<StaffRow[]>([])
  const [groups, setGroups] = useState<GroupRow[]>([])
  const [assignments, setAssignments] = useState<AssignmentRow[]>([])
  const [tutors, setTutors] = useState<TutorRow[]>([])
  const [invites, setInvites] = useState<InviteRow[]>([])
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // Invite form
  const [invEmail, setInvEmail] = useState('')
  const [invName, setInvName] = useState('')
  const [invRoles, setInvRoles] = useState<string[]>(['teacher'])
  const [inviteLink, setInviteLink] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  // Assignment forms
  const [aStaff, setAStaff] = useState('')
  const [aGroup, setAGroup] = useState('')
  const [aRole, setARole] = useState('primary')
  const [tStaff, setTStaff] = useState('')
  const [tStudent, setTStudent] = useState('')
  const [studentQ, setStudentQ] = useState('')
  const [students, setStudents] = useState<StudentRow[]>([])

  const load = useCallback(async () => {
    try {
      const [u, st, g, ta, tu, inv] = await Promise.all([
        api.get<UserRow[]>('/users'),
        api.get<StaffRow[]>('/admin/staff'),
        api.get<GroupRow[]>('/admin/groups'),
        api.get<AssignmentRow[]>('/admin/teaching-assignments'),
        api.get<TutorRow[]>('/admin/tutor-assignments'),
        api.get<InviteRow[]>('/invites'),
      ])
      setUsers(u); setStaff(st); setGroups(g)
      setAssignments(ta); setTutors(tu); setInvites(inv)
      setErr(null)
    } catch (e) { setErr((e as Error).message) }
  }, [])

  useEffect(() => { void load() }, [load])

  useEffect(() => {
    const t = setTimeout(() => {
      api.get<StudentRow[]>(`/admin/students?q=${encodeURIComponent(studentQ)}`)
        .then(setStudents).catch((e) => setErr((e as Error).message))
    }, 200)
    return () => clearTimeout(t)
  }, [studentQ])

  async function run(fn: () => Promise<unknown>) {
    setBusy(true); setErr(null)
    try { await fn(); await load() } catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  function toggleRole(u: UserRow, role: string) {
    const next = u.roles.includes(role)
      ? u.roles.filter((r) => r !== role)
      : [...u.roles, role]
    void run(() => api.post(`/users/${u.id}/roles`, { roles: next }))
  }

  const openInvites = invites.filter((i) => !i.accepted_at)
  const unstaffed = groups.filter((g) => g.teachers.length === 0)
  const staffWithoutAccount = staff.filter((s) => !s.user_id && !s.left_on)

  return (
    <div className="stack">
      <div className="row">
        <h1>People</h1>
        <span className="spacer" style={{ marginLeft: 'auto' }} />
        <AdminTabs />
      </div>
      {err && <p className="err">{err}</p>}

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>What each role can see</h2>
          <span className="sub">
            Read this before changing anyone’s roles. Access is enforced in the database,
            so these are the real limits, not a description of intent.
          </span>
        </header>
        <div className="scroll-x">
          <table>
            <thead><tr><th>Role</th><th>Whose data it opens</th></tr></thead>
            <tbody>
              {ROLES.map((r) => (
                <tr key={r.code}>
                  <td style={{ whiteSpace: 'nowrap' }}>
                    <strong>{r.name}</strong>
                    <div className="muted" style={{ fontSize: 'var(--t-micro)' }}>{r.code}</div>
                  </td>
                  <td style={{ maxWidth: 560 }}>
                    {r.sees}
                    {r.caution && (
                      <div className="note" style={{ marginTop: 6 }}>{r.caution}</div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="muted" style={{ fontSize: 'var(--t-small)', marginBottom: 0 }}>
          Students and guardians are never given staff roles here. They never see alerts at all —
          an “at risk” label reflected back at a 14-year-old is a self-fulfilling prophecy the
          product does not manufacture.
        </p>
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Staff accounts</h2>
          <span className="sub">{users.length} accounts · roles take effect immediately and sign that person out</span>
        </header>
        {users.length === 0 ? (
          <div className="empty">No accounts yet. Invite someone below.</div>
        ) : (
          <div className="scroll-x">
            <table>
              <thead>
                <tr>
                  <th>Name</th><th>Email</th>
                  {ROLES.map((r) => <th key={r.code} align="right">{r.name}</th>)}
                  <th align="right">Classes</th><th>Status</th><th />
                </tr>
              </thead>
              <tbody>
                {users.map((u) => (
                  <tr key={u.id}>
                    <td>{u.display_name}</td>
                    <td className="muted">{u.email ?? '—'}</td>
                    {ROLES.map((r) => (
                      <td key={r.code} align="right">
                        <input type="checkbox" checked={u.roles.includes(r.code)}
                               disabled={busy || !u.is_active}
                               aria-label={`${r.name} for ${u.display_name}`}
                               title={r.sees}
                               onChange={() => toggleRole(u, r.code)} />
                      </td>
                    ))}
                    <td className="num">{u.n_classes}</td>
                    <td>
                      {u.is_active
                        ? <Flag tone="good" glyph="✓" label="Active"
                                title={`Last seen ${fmtDate(u.last_seen_at)}`} />
                        : <Flag tone="neutral" glyph="·" label="Deactivated"
                                title="Cannot sign in. Their marks and history are untouched." />}
                    </td>
                    <td>
                      {u.is_active && (
                        <button className="ghost" disabled={busy}
                                onClick={() => {
                                  if (!confirm(`Deactivate ${u.display_name}? They are signed out ` +
                                    'everywhere immediately. Nothing they entered is deleted.')) return
                                  void run(() => api.post(`/users/${u.id}/deactivate`))
                                }}>Deactivate</button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {staffWithoutAccount.length > 0 && (
          <p className="note" style={{ marginBottom: 0 }}>
            <span className="num">{staffWithoutAccount.length}</span>{' '}
            staff {staffWithoutAccount.length === 1 ? 'member exists' : 'members exist'} as
            a person record with no sign-in: {staffWithoutAccount.slice(0, 5)
              .map((s) => `${s.given_name} ${s.family_name}`).join(', ')}
            {staffWithoutAccount.length > 5 ? '…' : ''}. They can be assigned to classes below;
            invite them when they need to enter marks themselves.
          </p>
        )}
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Invite staff</h2>
          <span className="sub">Nobody self-registers into a database of children.</span>
        </header>
        <form className="row" style={{ alignItems: 'flex-end', gap: 12 }}
              onSubmit={(e) => {
                e.preventDefault()
                void run(async () => {
                  const r = await api.post<{ accept_url: string }>('/invites', {
                    email: invEmail,
                    display_name: invName || undefined,
                    roles: invRoles.length ? invRoles : ['teacher'],
                  })
                  setInviteLink(r.accept_url); setCopied(false)
                  setInvEmail(''); setInvName('')
                })
              }}>
          <label style={{ display: 'grid', gap: 4 }}>
            Email
            <input type="email" required value={invEmail} style={{ width: 240 }}
                   onChange={(e) => setInvEmail(e.target.value)} placeholder="name@school.org" />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Name (optional)
            <input value={invName} style={{ width: 190 }}
                   onChange={(e) => setInvName(e.target.value)} />
          </label>
          <div style={{ display: 'grid', gap: 4 }}>
            <span style={{ fontSize: 'var(--t-small)' }}>Roles</span>
            <div className="row" style={{ gap: 10 }}>
              {INVITABLE.map((r) => {
                const info = ROLES.find((x) => x.code === r)
                return (
                  <label key={r} className="muted" title={info?.sees}
                         style={{ display: 'inline-flex', gap: 5, alignItems: 'center' }}>
                    <input type="checkbox" checked={invRoles.includes(r)}
                           onChange={() => setInvRoles((prev) => prev.includes(r)
                             ? prev.filter((x) => x !== r) : [...prev, r])} />
                    {info?.name ?? r}
                  </label>
                )
              })}
            </div>
          </div>
          <button className="primary" type="submit" disabled={busy || !invEmail}>
            Create invitation
          </button>
        </form>

        {inviteLink && (
          <div style={{ marginTop: 14 }}>
            <p className="note" style={{ marginTop: 0 }}>
              Copy this link and send it yourself. Email may not be configured on this
              installation, and the link is shown once — it is stored only as a hash, so
              nobody, including this screen, can retrieve it again.
            </p>
            <div className="row" style={{ gap: 8 }}>
              <input readOnly value={inviteLink} style={{ flex: 1, minWidth: 220 }}
                     onFocus={(e) => e.currentTarget.select()} />
              <button onClick={() => {
                void navigator.clipboard?.writeText(inviteLink)
                setCopied(true)
              }}>{copied ? 'Copied' : 'Copy'}</button>
              <button className="ghost" onClick={() => setInviteLink(null)}>Dismiss</button>
            </div>
          </div>
        )}

        {openInvites.length > 0 && (
          <div className="scroll-x" style={{ marginTop: 16 }}>
            <table>
              <thead><tr><th>Outstanding invitation</th><th>Roles</th><th>Expires</th></tr></thead>
              <tbody>
                {openInvites.map((i) => (
                  <tr key={i.id}>
                    <td>{i.email}{i.display_name ? ` · ${i.display_name}` : ''}</td>
                    <td className="secondary">{i.roles.join(', ')}</td>
                    <td className="muted">{fmtDate(i.expires_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Teachers and classes</h2>
          <span className="sub">
            Assignment is what gives a teacher access to those students — and what decides
            who receives a finding about the class.
          </span>
        </header>

        {unstaffed.length > 0 && (
          <p className="note">
            <span className="num">{unstaffed.length}</span> {unstaffed.length === 1
              ? 'class has' : 'classes have'} nobody assigned
            ({unstaffed.slice(0, 4).map((g) => `${g.subject_name} ${g.label}`).join(', ')}
            {unstaffed.length > 4 ? '…' : ''}).
            Findings about those classes have no owner, so no one is told.
          </p>
        )}

        <form className="row" style={{ alignItems: 'flex-end', gap: 10 }}
              onSubmit={(e) => {
                e.preventDefault()
                void run(() => api.post('/admin/teaching-assignments', {
                  staff_id: aStaff, teaching_group_id: aGroup, role: aRole,
                }))
              }}>
          <label style={{ display: 'grid', gap: 4 }}>
            Staff
            <select required value={aStaff} onChange={(e) => setAStaff(e.target.value)}>
              <option value="">Choose…</option>
              {staff.filter((s) => !s.left_on).map((s) => (
                <option key={s.id} value={s.id}>{s.family_name}, {s.given_name}</option>
              ))}
            </select>
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Class
            <select required value={aGroup} onChange={(e) => setAGroup(e.target.value)}>
              <option value="">Choose…</option>
              {groups.map((g) => (
                <option key={g.id} value={g.id}>
                  {g.subject_name} · {g.label} ({g.n_students})
                </option>
              ))}
            </select>
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Role
            <select value={aRole} onChange={(e) => setARole(e.target.value)}>
              <option value="primary">Primary</option>
              <option value="co_teacher">Co-teacher</option>
              <option value="support">Support</option>
              <option value="cover">Cover</option>
              <option value="moderator">Moderator</option>
            </select>
          </label>
          <button className="primary" type="submit" disabled={busy || !aStaff || !aGroup}>
            Assign
          </button>
        </form>

        <div className="scroll-x" style={{ marginTop: 14 }}>
          {assignments.length === 0 ? (
            <div className="empty">No current assignments.</div>
          ) : (
            <table>
              <thead>
                <tr><th>Teacher</th><th>Class</th><th>Role</th><th>Since</th><th /></tr>
              </thead>
              <tbody>
                {assignments.map((a) => (
                  <tr key={a.id}>
                    <td>{a.family_name}, {a.given_name}</td>
                    <td className="secondary">{a.subject_name} · {a.group_label}</td>
                    <td className="muted">{a.role.replace(/_/g, ' ')}</td>
                    <td className="muted">{fmtDate(a.from_date)}</td>
                    <td>
                      <button className="ghost" disabled={busy}
                              title="Ends the assignment today and keeps the history, so a mid-year teacher change stays visible to the analysis."
                              onClick={() => void run(() =>
                                api.post(`/admin/teaching-assignments/${a.id}/end`))}>
                        End
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </section>

      {/* ---------------------------------------------------------------- */}
      <section className="card">
        <header>
          <h2>Tutors and students</h2>
          <span className="sub">
            A tutor sees their tutees across every subject. Wider than a teacher, on purpose.
          </span>
        </header>

        <form className="row" style={{ alignItems: 'flex-end', gap: 10 }}
              onSubmit={(e) => {
                e.preventDefault()
                void run(() => api.post('/admin/tutor-assignments', {
                  staff_id: tStaff, student_id: tStudent,
                }))
              }}>
          <label style={{ display: 'grid', gap: 4 }}>
            Tutor
            <select required value={tStaff} onChange={(e) => setTStaff(e.target.value)}>
              <option value="">Choose…</option>
              {staff.filter((s) => !s.left_on).map((s) => (
                <option key={s.id} value={s.id}>{s.family_name}, {s.given_name}</option>
              ))}
            </select>
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Find a student
            <input value={studentQ} placeholder="name or MIS ref" style={{ width: 170 }}
                   onChange={(e) => setStudentQ(e.target.value)} />
          </label>
          <label style={{ display: 'grid', gap: 4 }}>
            Student
            <select required value={tStudent} onChange={(e) => setTStudent(e.target.value)}>
              <option value="">Choose…</option>
              {students.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.family_name}, {s.given_name}{s.external_ref ? ` · ${s.external_ref}` : ''}
                </option>
              ))}
            </select>
          </label>
          <button className="primary" type="submit" disabled={busy || !tStaff || !tStudent}>
            Assign tutor
          </button>
        </form>

        <div className="scroll-x" style={{ marginTop: 14 }}>
          {tutors.length === 0 ? (
            <div className="empty">
              No tutor assignments. Marks and analytics work without them; what is missing
              is the across-subject pastoral view.
            </div>
          ) : (
            <table>
              <thead><tr><th>Tutor</th><th>Student</th><th>Since</th><th /></tr></thead>
              <tbody>
                {tutors.map((t) => (
                  <tr key={t.id}>
                    <td>{t.staff_family}, {t.staff_given}</td>
                    <td className="secondary">
                      {t.student_family}, {t.student_given}
                      {t.external_ref && <span className="muted"> · {t.external_ref}</span>}
                    </td>
                    <td className="muted">{fmtDate(t.from_date)}</td>
                    <td>
                      <button className="ghost" disabled={busy}
                              onClick={() => void run(() =>
                                api.post(`/admin/tutor-assignments/${t.id}/end`))}>
                        End
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </section>
    </div>
  )
}
