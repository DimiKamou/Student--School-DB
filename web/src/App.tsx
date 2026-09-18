import { useCallback, useEffect, useState } from 'react'
import { NavLink, Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { api } from './lib/api'

import Login from './routes/Login'
import Setup from './routes/Setup'
import AcceptInvite from './routes/AcceptInvite'

import Today from './routes/Today'
import ClassView from './routes/ClassView'
import Entry from './routes/Entry'
import StudentView from './routes/StudentView'
import Assessments from './routes/Assessments'
import NewAssessment from './routes/NewAssessment'
import Blueprints from './routes/Blueprints'
import Alerts from './routes/Alerts'
import Interventions from './routes/Interventions'
import Reports from './routes/Reports'
import CommentBank from './routes/CommentBank'
import ParentsEvening from './routes/ParentsEvening'
import ImportData from './routes/ImportData'
import People from './routes/admin/People'
import School from './routes/admin/School'
import Curriculum from './routes/admin/Curriculum'
import MyProgress from './routes/portal/MyProgress'

import Landing from './routes/public/Landing'
import Product from './routes/public/Product'
import Method from './routes/public/Method'
import Pricing from './routes/public/Pricing'

export type Me = {
  userId: string
  tenantId: string
  roles: string[]
  display_name: string
  tenant_name: string
  tenant_slug?: string
  person_id?: string | null
}

const MARKETING = ['/', '/product', '/method', '/pricing']
const ENTRY_POINTS = ['/login', '/setup', '/accept']

/** Staff roles. A student or guardian is not staff and sees none of the app. */
const STAFF = ['school_admin', 'head_of_dept', 'teacher', 'tutor', 'dpo']
const isStaff = (roles: string[]) => roles.some((r) => STAFF.includes(r))

type NavItem = { to: string; label: string; show: (roles: string[]) => boolean }
const NAV: NavItem[] = [
  { to: '/app',         label: 'Today',       show: isStaff },
  { to: '/classes',     label: 'Classes',     show: isStaff },
  { to: '/assessments', label: 'Assessments', show: isStaff },
  { to: '/alerts',      label: 'Alerts',      show: isStaff },
  { to: '/reports',     label: 'Reports',     show: isStaff },
  { to: '/admin/people',label: 'Admin',       show: (r) => r.includes('school_admin') },
  { to: '/portal',      label: 'My progress',
    show: (r) => !isStaff(r) && (r.includes('student') || r.includes('guardian')) },
]

/** The marketing pages render their own header and footer; no app chrome. */
function PublicRoutes() {
  return (
    <>
      <Route path="/" element={<Landing />} />
      <Route path="/product" element={<Product />} />
      <Route path="/method" element={<Method />} />
      <Route path="/pricing" element={<Pricing />} />
    </>
  )
}

export default function App() {
  const [me, setMe] = useState<Me | null | undefined>(undefined)
  const nav = useNavigate()
  const loc = useLocation()
  const signedIn = useCallback((m: unknown) => setMe(m as Me), [])
  const refresh = useCallback(() => {
    api.get<Me>('/me').then(setMe).catch(() => setMe(null))
  }, [])

  useEffect(() => {
    api.get<Me>('/me').then(setMe).catch(() => setMe(null))
  }, [])

  if (me === undefined) return <div className="empty">Loading…</div>

  // --- Signed out: the public site, plus the three ways in. ----------------
  if (!me) {
    return (
      <Routes>
        {PublicRoutes().props.children}
        <Route path="/login" element={<Login onSignedIn={signedIn} />} />
        {/* Both flows sign the person in server-side and then call back; we
            re-read /me so the app picks up the new session and its roles. */}
        <Route path="/setup" element={<Setup onDone={refresh} />} />
        <Route path="/accept" element={<AcceptInvite onAccepted={refresh} />} />
        <Route path="*" element={<Navigate to="/login" replace />} />
      </Routes>
    )
  }

  // --- Signed in, reading a marketing page: still no app chrome. -----------
  if (MARKETING.includes(loc.pathname) && loc.pathname !== '/') {
    return <Routes>{PublicRoutes().props.children}</Routes>
  }
  if (ENTRY_POINTS.includes(loc.pathname) || loc.pathname === '/') {
    return <Navigate to={isStaff(me.roles) ? '/app' : '/portal'} replace />
  }

  const items = NAV.filter((i) => i.show(me.roles))
  const home = isStaff(me.roles) ? '/app' : '/portal'

  return (
    <div className="app">
      <header className="topbar">
        <span className="brand">Student–School DB</span>
        <nav>
          {items.map((i) => (
            <NavLink key={i.to} to={i.to} className={({ isActive }) => (isActive ? 'active' : '')}>
              {i.label}
            </NavLink>
          ))}
        </nav>
        <span className="spacer" />
        <span className="muted" style={{ fontSize: 'var(--t-small)' }}>
          {me.display_name} · {me.tenant_name}
        </span>
        <button className="ghost" onClick={async () => {
          await api.post('/auth/logout'); setMe(null); nav('/')
        }}>Sign out</button>
      </header>

      <main className="main">
        <Routes>
          <Route path="/app" element={<Today />} />
          <Route path="/classes" element={<ClassView />} />
          <Route path="/classes/:groupId" element={<ClassView />} />
          <Route path="/assessments" element={<Assessments />} />
          <Route path="/assessments/new" element={<NewAssessment />} />
          <Route path="/assessments/:assessmentId" element={<Entry />} />
          <Route path="/blueprints" element={<Blueprints />} />
          <Route path="/students/:studentId" element={<StudentView />} />
          <Route path="/alerts" element={<Alerts />} />
          <Route path="/interventions" element={<Interventions />} />
          <Route path="/reports" element={<Reports />} />
          <Route path="/reports/:groupId" element={<Reports />} />
          <Route path="/comment-bank" element={<CommentBank />} />
          <Route path="/parents-evening" element={<ParentsEvening />} />
          <Route path="/parents-evening/:groupId" element={<ParentsEvening />} />
          <Route path="/import" element={<ImportData />} />
          <Route path="/admin/people" element={<People />} />
          <Route path="/admin/school" element={<School />} />
          <Route path="/admin/curriculum" element={<Curriculum />} />
          <Route path="/portal" element={<MyProgress />} />
          <Route path="*" element={<Navigate to={home} replace />} />
        </Routes>
      </main>
    </div>
  )
}
