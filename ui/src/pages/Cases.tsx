import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Row, fmtDate, get, money, qs } from '../api'
import { Badge, YesNo } from '../components/ui'

const OUTCOMES = ['CS-SUCCESS-SELECTED', 'CS-SUCCESS-EXCLUDED', 'CS-SUCCESS-EXCEPTION', 'CS-NOTPURSUED-SYSTEMIC', 'CS-NOTPURSUED-COOL-OFF', 'CS-PENDING-EVALUATION']

export default function Cases() {
  const nav = useNavigate()
  const [meta, setMeta] = useState<any>(null)
  const [client, setClient] = useState('')
  const [outcome, setOutcome] = useState('')
  const [search, setSearch] = useState('')
  const [rows, setRows] = useState<Row[]>([])
  const [error, setError] = useState('')

  useEffect(() => { get('/api/meta').then(setMeta).catch(e => setError(e.message)) }, [])
  const load = () => get(`/api/cases${qs({ client, outcome, search })}`).then(setRows).catch(e => setError(e.message))
  useEffect(() => { load() }, [client, outcome])

  return (
    <div className="page">
      <h1>IDR cases</h1>
      <p className="sub">One row per case created by claim-remit matching. Click a case to see every job that ran on it and the result.</p>
      {error && <div className="alert err">{error}</div>}
      <div className="filters">
        <div><label>Client</label>
          <select value={client} onChange={e => setClient(e.target.value)}>
            <option value="">All clients</option>
            {meta?.clients.map((c: Row) => <option key={c.client_id} value={c.client_id}>{c.client_id}</option>)}
          </select></div>
        <div><label>Outcome</label>
          <select value={outcome} onChange={e => setOutcome(e.target.value)}>
            <option value="">All outcomes</option>
            {OUTCOMES.map(o => <option key={o} value={o}>{o}</option>)}
          </select></div>
        <div><label>Search PCN / case / Tax ID</label>
          <input value={search} onChange={e => setSearch(e.target.value)} onKeyDown={e => e.key === 'Enter' && load()} placeholder="e.g. E03 or DEMO-001" /></div>
        <button onClick={load}>Search</button>
        <span className="muted">{rows.length} case(s)</span>
      </div>
      <div className="card scroll" style={{ padding: 0 }}>
        <table>
          <thead><tr>
            <th>PCN</th><th>Client</th><th>Payer</th><th>Line</th><th>Code</th><th>DOS</th><th>Remit date</th><th>Outcome</th>
            <th>Reason code and description</th><th>Selected</th><th>Cool-off</th><th>Batch</th><th className="num">Allowed</th><th className="num">Job events</th>
          </tr></thead>
          <tbody>
            {rows.map(r => (
              <tr key={r.idr_case_unit_id} className="click" onClick={() => nav(`/cases/${r.idr_case_unit_id}`)}>
                <td><a>{r.patient_control_number}</a></td><td>{r.client_id}</td><td>{r.payer_business_id}</td>
                <td>{r.service_line_code}</td><td>{r.service_code}</td><td>{fmtDate(r.date_of_service)}</td><td>{fmtDate(r.remit_payment_date)}</td>
                <td><Badge value={r.outcome_code} /></td><td className="mono">{r.failed_rules}</td>
                <td><YesNo v={r.selected_for_federal_idr} /></td>
                <td><Badge value={r.cool_off_status} /></td>
                <td>{r.batch_reference ? <span title={r.batch_reference}><Badge value={r.batch_status} label={`${r.batch_status}`} /></span> : <span className="muted">-</span>}</td>
                <td className="num">{money(r.allowed_amount)}</td><td className="num">{r.job_events}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
