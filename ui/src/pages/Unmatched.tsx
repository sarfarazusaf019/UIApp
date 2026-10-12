import { Fragment, useCallback, useEffect, useState } from 'react'
import { JOBS, Row, fmtDate, fmtTime, get, money, qs } from '../api'
import { Badge, RunJobs, Tile } from '../components/ui'

export default function Unmatched() {
  const [meta, setMeta] = useState<any>(null)
  const [client, setClient] = useState('')
  const [data, setData] = useState<{ lines: Row[]; summary: Row[] } | null>(null)
  const [open, setOpen] = useState<number | null>(null)
  const [history, setHistory] = useState<Row[]>([])

  useEffect(() => { get('/api/meta').then(setMeta) }, [])
  const load = useCallback(() => get(`/api/unmatched${qs({ client })}`).then(setData), [client])
  useEffect(() => { load() }, [load])

  const toggle = async (id: number) => {
    if (open === id) return setOpen(null)
    setOpen(id); setHistory(await get(`/api/remit-lines/${id}/history`))
  }
  const lines = data?.lines ?? []
  const sum = (f: (r: Row) => boolean) => lines.filter(f).length

  return (
    <div className="page">
      <h1>Unmatched remit lines</h1>
      <p className="sub">835 lines that have no matching 837 line. Each run of Claim-remit matching retries them while the exception is OPEN; Exception Status Monitoring tracks the 30-business-day window.</p>

      <div className="tiles">
        <Tile label="Unmatched remit lines" value={lines.length} />
        <Tile label="Still OPEN (retried each run)" value={sum(r => r.exception_status === 'OPEN')} tone="yellow" />
        <Tile label="Expired (window ended)" value={sum(r => r.exception_status === 'EXPIRED_EXCLUDED')} tone="red" />
        <Tile label="Not processed yet" value={sum(r => r.exception_status === 'NOT PROCESSED YET')} />
        <Tile label="Total matching attempts" value={lines.reduce((a, r) => a + Number(r.match_attempts), 0)} />
      </div>

      <div className="card">
        <div className="filters" style={{ marginBottom: 6 }}>
          <div><label>Client</label>
            <select value={client} onChange={e => setClient(e.target.value)}>
              <option value="">All clients</option>
              {meta?.clients.map((c: Row) => <option key={c.client_id} value={c.client_id}>{c.client_id}</option>)}
            </select></div>
          <div style={{ flex: 1 }}><RunJobs only={['CLAIM_REMIT_MATCHING', 'EXCEPTION_AGING']} onDone={load} /></div>
        </div>
      </div>

      <div className="card">
        <h2>Report: result by exception</h2>
        <table>
          <thead><tr><th>Reason code</th><th>Reason description</th><th>Status</th><th className="num">Remit lines</th><th className="num">Matching attempts</th><th className="num">Highest retry count</th></tr></thead>
          <tbody>
            {data?.summary.map((s, i) => (
              <tr key={i}><td><b>{s.exception_code}</b></td><td>{s.exception_label}</td><td><Badge value={s.exception_status} /></td>
                <td className="num">{s.lines}</td><td className="num">{s.match_attempts}</td><td className="num">{s.max_retry_count}</td></tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card scroll" style={{ padding: 0 }}>
        <table>
          <thead><tr><th>PCN</th><th>Client</th><th>Payer</th><th>Paid code</th><th>DOS</th><th>Remit date</th><th className="num">Allowed</th>
            <th>Reason code</th><th>Reason description</th><th>Status</th><th className="num">Matching runs</th><th>Last matching result</th><th className="num">Days From Remit Payment date</th><th className="num">Retry count</th><th className="num">Days left</th><th>Reason detail</th></tr></thead>
          <tbody>
            {lines.map(r => (
              <Fragment key={r.remit_line_id}>
                <tr className="click" onClick={() => toggle(r.remit_line_id)}>
                  <td><a>{r.patient_control_number}</a></td><td>{r.client_id}</td><td>{r.payer_business_id}</td><td>{r.paid_service_code}</td>
                  <td>{fmtDate(r.date_of_service)}</td><td>{fmtDate(r.remit_payment_date)}</td><td className="num">{money(r.allowed_amount)}</td>
                  <td><b>{r.exception_code}</b></td><td>{r.exception_label}</td><td><Badge value={r.exception_status} /></td>
                  <td className="num"><b>{r.match_attempts}</b></td><td><Badge value={r.last_match_result} /></td>
                  <td className="num">{r.days_from_remit_payment_date}</td><td className="num">{r.retry_count}</td><td className="num">{r.days_remaining_in_window}</td>
                  <td className="mono">{r.reason_text}{r.missing_fields && r.missing_fields !== '[]' ? ` ${r.missing_fields}` : ''}</td>
                </tr>
                {open === r.remit_line_id && (
                  <tr><td colSpan={16} style={{ background: '#f7fafd' }}>
                    <b>Job history for this remit line</b>
                    <div className="timeline" style={{ marginTop: 8 }}>
                      {history.length === 0 && <span className="muted">No job has processed this line yet.</span>}
                      {history.map((t, i) => <div className="tl-item" key={i}>
                        <b>{JOBS.find(j => j.code === t.job_code)?.name}</b> <span className="muted">- run #{t.run_no} - {fmtTime(t.logged_at_utc)}</span> <Badge value={t.result} /> <span className="mono">{t.detail}</span>
                      </div>)}
                    </div></td></tr>
                )}
              </Fragment>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
