import { useCallback, useEffect, useState } from 'react'
import { JOBS, Row, fmtTime, get, post } from '../api'
import { Badge, RunJobs, Tile } from '../components/ui'

export default function Jobs() {
  const [data, setData] = useState<{ summary: Row[]; runs: Row[] } | null>(null)
  const [cases, setCases] = useState<Row[]>([])

  const load = useCallback(async () => {
    setData(await get('/api/job-runs'))
    setCases(await get('/api/cases'))
  }, [])
  useEffect(() => { load() }, [load])

  const by = (code: string) => data?.summary.find(s => s.job_code === code)
  const count = (o: string) => cases.filter(c => c.outcome_code === o).length

  return (
    <div className="page">
      <h1>Jobs</h1>
      <p className="sub">The Claim Selection jobs run in this order. The Worker service runs them; this page shows what each one did (the Run buttons are disabled here).</p>

      <div className="tiles">
        <Tile label="IDR cases" value={cases.length} />
        <Tile label="Excluded" value={count('CS-SUCCESS-EXCLUDED')} tone="red" />
        <Tile label="Exception" value={count('CS-SUCCESS-EXCEPTION')} tone="yellow" />
        <Tile label="Not pursued" value={cases.filter(c => c.outcome_code.startsWith('CS-NOTPURSUED')).length} />
        <Tile label="Selected" value={count('CS-SUCCESS-SELECTED')} tone="green" />
      </div>

      <div className="card">
        <h2>Run jobs</h2>
        <RunJobs onDone={load} />
        <div style={{ marginTop: 14 }}>
          <button className="secondary small" title="Empties claims, remits, cases and job history. Configuration is kept."
            onClick={async () => { if (confirm('Delete ALL claims, remits, cases and job history? Configuration is kept.')) { await post('/api/admin/clear-data', { confirm: 'CLEAR' }); load() } }}>
            Clear all claim / remit / case data (keep configuration)</button>
        </div>
      </div>

      <div className="card">
        <h2>How many times each job ran</h2>
        <table>
          <thead><tr><th>#</th><th>Job</th><th className="num">Runs</th><th className="num">Succeeded</th><th className="num">Failed</th><th className="num">Items in last run</th><th className="num">Items in all runs</th><th>Last run</th></tr></thead>
          <tbody>
            {JOBS.map((j, i) => {
              const s = by(j.code)
              return (
                <tr key={j.code}>
                  <td><span className="step">{i + 1}</span></td>
                  <td><b>{j.name}</b><div className="muted mono">{j.code}</div></td>
                  <td className="num">{s?.runs ?? 0}</td><td className="num">{s?.succeeded ?? 0}</td><td className="num">{s?.failed ?? 0}</td>
                  <td className="num">{s?.last_processed ?? '-'}</td><td className="num">{s?.total_processed ?? 0}</td>
                  <td>{fmtTime(s?.last_run_utc)}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h2>Run history</h2>
        <div className="scroll" style={{ maxHeight: 340 }}>
          <table>
            <thead><tr><th>Run</th><th>Job</th><th>Status</th><th className="num">Items</th><th>Started</th><th>Finished</th><th>Error</th></tr></thead>
            <tbody>
              {data?.runs.map(r => (
                <tr key={r.job_run_log_id}>
                  <td>{r.job_run_log_id}</td><td>{r.job_code}</td><td><Badge value={r.status} /></td>
                  <td className="num">{r.processed_count}</td><td>{fmtTime(r.started_at_utc)}</td><td>{fmtTime(r.finished_at_utc)}</td>
                  <td>{r.error_message}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
