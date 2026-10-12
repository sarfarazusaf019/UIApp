import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter, NavLink, Navigate, Route, Routes } from 'react-router-dom'
import './styles.css'
import Jobs from './pages/Jobs'
import Cases from './pages/Cases'
import CaseDetail from './pages/CaseDetail'
import Unmatched from './pages/Unmatched'
import NewRecord from './pages/NewRecord'
import Reference from './pages/Reference'
import Config from './pages/Config'

function App() {
  return (
    <BrowserRouter>
      <header className="topbar">
        <div className="brand">TeamHealth<sup>®</sup><small>Claim Selection - job outcomes</small></div>
        <nav>
          <NavLink to="/jobs">Jobs</NavLink>
          <NavLink to="/cases">IDR cases</NavLink>
          <NavLink to="/unmatched">Unmatched remits</NavLink>
          <NavLink to="/new">New claim-remit record</NavLink>
          <NavLink to="/config">Configuration</NavLink>
          <NavLink to="/reference">IDR process reference</NavLink>
        </nav>
      </header>
      <Routes>
        <Route path="/" element={<Navigate to="/jobs" replace />} />
        <Route path="/jobs" element={<Jobs />} />
        <Route path="/cases" element={<Cases />} />
        <Route path="/cases/:id" element={<CaseDetail />} />
        <Route path="/unmatched" element={<Unmatched />} />
        <Route path="/new" element={<NewRecord />} />
        <Route path="/config" element={<Config />} />
        <Route path="/reference" element={<Reference />} />
      </Routes>
    </BrowserRouter>
  )
}

ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><App /></React.StrictMode>)
