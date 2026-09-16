import { useEffect, useState } from 'react'
import { NavLink, Navigate, Route, Routes, useNavigate } from 'react-router-dom'
import { api } from './lib/api'
import Login from './routes/Login'
import Today from './routes/Today'
import ClassView from './routes/ClassView'
import Entry from './routes/Entry'
import StudentView from './routes/StudentView'

type Me = { userId: string; tenantId: string; roles: string[]; display_name: string; tenant_name: string }

export default function App() {
  const [me, setMe] = useState<Me | null | undefined>(undefined)
  const nav = useNavigate()

  useEffect(() => {
    api.get<Me>('/me').then(setMe).catch(() => setMe(null))
  }, [])

  if (me === undefined) return <div className="empty">Loading…</div>
  if (me === null) return <Login onSignedIn={(m) => { setMe(m); nav('/') }} />

  return (
    <div className="app">
      <header className="topbar">
        <span className="brand">Student–School DB</span>
        <nav>
          <NavLink to="/" end className={({ isActive }) => (isActive ? 'active' : '')}>Today</NavLink>
          <NavLink to="/classes" className={({ isActive }) => (isActive ? 'active' : '')}>Classes</NavLink>
        </nav>
        <span className="spacer" />
        <span className="muted">{me.display_name} · {me.tenant_name}</span>
        <button onClick={async () => { await api.post('/auth/logout'); setMe(null) }}>Sign out</button>
      </header>
      <main className="main">
        <Routes>
          <Route path="/" element={<Today />} />
          <Route path="/classes" element={<ClassView />} />
          <Route path="/classes/:groupId" element={<ClassView />} />
          <Route path="/assessments/:assessmentId" element={<Entry />} />
          <Route path="/students/:studentId" element={<StudentView />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  )
}
