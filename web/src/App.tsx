import { useCallback, useEffect, useState } from 'react'
import { NavLink, Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { api } from './lib/api'

import Login from './routes/Login'
import Today from './routes/Today'
import ClassView from './routes/ClassView'
import Entry from './routes/Entry'
import StudentView from './routes/StudentView'
import Landing from './routes/public/Landing'
import Product from './routes/public/Product'
import Method from './routes/public/Method'

export type Me = {
  userId: string
  tenantId: string
  roles: string[]
  display_name: string
  tenant_name: string
  tenant_slug?: string
  person_id?: string | null
}

/** Routes anyone may see, signed in or not. */
const PUBLIC_PATHS = ['/', '/product', '/method', '/pricing', '/login', '/setup', '/accept']

type NavItem = { to: string; label: string; roles?: string[] }
const NAV: NavItem[] = [
  { to: '/app', label: 'Today' },
  { to: '/classes', label: 'Classes' },
  { to: '/admin/people', label: 'Admin', roles: ['school_admin'] },
]

function visible(items: NavItem[], roles: string[]) {
  return items.filter((i) => !i.roles || i.roles.some((r) => roles.includes(r)))
}

export default function App() {
  const [me, setMe] = useState<Me | null | undefined>(undefined)
  const nav = useNavigate()
  const loc = useLocation()

  useEffect(() => {
    api.get<Me>('/me').then(setMe).catch(() => setMe(null))
  }, [])

  const signedIn = useCallback((m: unknown) => setMe(m as Me), [])
  const isPublic = PUBLIC_PATHS.includes(loc.pathname)

  if (me === undefined) return <div className="empty">Loading…</div>

  // Signed out: the public site, plus the ways in.
  if (!me) {
    return (
      <Routes>
        <Route path="/" element={<Landing />} />
        <Route path="/product" element={<Product />} />
        <Route path="/method" element={<Method />} />
        <Route path="/login" element={<Login onSignedIn={signedIn} />} />
        <Route path="*" element={<Navigate to="/login" replace state={{ from: loc.pathname }} />} />
      </Routes>
    )
  }

  // Signed in, but looking at a marketing page: show it without the app chrome.
  if (isPublic && loc.pathname !== '/login') {
    return (
      <Routes>
        <Route path="/" element={<Navigate to="/app" replace />} />
        <Route path="/product" element={<Product />} />
        <Route path="/method" element={<Method />} />
        <Route path="*" element={<Navigate to="/app" replace />} />
      </Routes>
    )
  }

  const items = visible(NAV, me.roles)

  return (
    <div className="app">
      <header className="topbar">
        <span className="brand">Student–School DB</span>
        <nav>
          {items.map((i) => (
            <NavLink key={i.to} to={i.to}
                     className={({ isActive }) => (isActive ? 'active' : '')}>
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
          <Route path="/assessments/:assessmentId" element={<Entry />} />
          <Route path="/students/:studentId" element={<StudentView />} />
          <Route path="*" element={<Navigate to="/app" replace />} />
        </Routes>
      </main>
    </div>
  )
}
