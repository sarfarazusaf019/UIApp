import { useEffect, useState } from 'react'
import { JOBS, get, post } from '../api'

const COLORS: Record<string, string> = {
  'CS-SUCCESS-SELECTED': 'green', 'CS-SUCCESS-EXCLUDED': 'red', 'CS-SUCCESS-EXCEPTION': 'yellow',
  'CS-NOTPURSUED-SYSTEMIC': 'purple', 'CS-NOTPURSUED-COOL-OFF': 'purple', 'CS-PENDING-EVALUATION': 'grey',
  Matched: 'green', Unmatched: 'red', Ambiguous: 'yellow', InvalidData: 'yellow',
  PASS: 'green', FAIL: 'red', MISSING_DATA: 'yellow', NOT_APPLICABLE: 'grey',
  OPEN: 'yellow', RESOLVED: 'green', EXPIRED_EXCLUDED: 'red', 'NOT PROCESSED YET': 'grey',
  ACTIVE: 'red', CLEARED: 'green', DATA_NOT_AVAILABLE: 'grey',
  ACTIVATED: 'green', REJECTED: 'red', NOT_PURSUED: 'purple', NO_MATCH: 'grey',
  NEW_BATCH: 'blue', JOINED_BATCH: 'blue', SUCCEEDED: 'green', FAILED: 'red', RUNNING: 'yellow',
  REPORT_STORED: 'blue', REPORT_UNCHANGED: 'grey', CLOSED: 'grey',
}

export function Badge({ value, label }: { value?: string | null; label?: string }) {
  if (!value) return null
  const short = label ?? value.replace('CS-SUCCESS-', '').replace('CS-NOTPURSUED-', 'NOT PURSUED: ').replace('CS-PENDING-EVALUATION', 'PENDING')
  return <span className={`badge b-${COLORS[value] ?? 'blue'}`}>{short}</span>
}

export const YesNo = ({ v }: { v?: boolean | null }) =>
  v === null || v === undefined ? null : <span className={`badge b-${v ? 'green' : 'grey'}`}>{v ? 'Yes' : 'No'}</span>

export function Tile({ label, value, tone = '' }: { label: string; value: any; tone?: string }) {
  return (
    <div className={`tile ${tone}`}>
      <div className="v">{value}</div>
      <div className="l">{label}</div>
    </div>
  )
}

export function Alert({ kind, children }: { kind: 'ok' | 'err' | 'info'; children: any }) {
  return <div className={`alert ${kind}`}>{children}</div>
}

export function Kv({ items }: { items: [string, any][] }) {
  return (
    <dl className="kv">
      {items.map(([k, v]) => (
        <div key={k} style={{ display: 'contents' }}>
          <dt>{k}</dt>
          <dd>{v === null || v === undefined || v === '' ? <span className="muted">-</span> : v}</dd>
        </div>
      ))}
    </dl>
  )
}

/** Runs one job (or all enabled jobs) through the API and reports what each job did. */
export function RunJobs({ onDone, only }: { onDone?: () => void; only?: string[] }) {
  const [busy, setBusy] = useState<string | null>(null)
  const [result, setResult] = useState<any>(null)
  const [error, setError] = useState<string | null>(null)
  const [disabled, setDisabled] = useState<string[]>([])
  // Jobs switched off in the API configuration (Jobs:Enabled) keep their button but can not be started.
  useEffect(() => { get('/api/meta').then(m => setDisabled((m.jobs ?? []).filter((j: any) => !j.enabled).map((j: any) => j.code))).catch(() => {}) }, [])

  const run = async (job: string) => {
    setBusy(job); setError(null); setResult(null)
    try {
      setResult(await post('/api/jobs/run', { job }))
      onDone?.()
    } catch (e: any) {
      setError(e.message)
    } finally {
      setBusy(null)
    }
  }
  const list = only ? JOBS.filter(j => only.includes(j.code)) : JOBS

  return (
    <div>
      <div className="row">
        <button disabled={!!busy || list.every(j => disabled.includes(j.code))} title={list.every(j => disabled.includes(j.code)) ? 'Disabled: jobs are run by the Worker service, this screen only shows the results' : undefined} onClick={() => run('RUN_ALL')}>{busy === 'RUN_ALL' ? 'Running all jobs...' : 'Run all jobs (in order)'}</button>
        {list.map(j => (
          <button key={j.code} className="secondary small" disabled={!!busy || disabled.includes(j.code)}
            title={disabled.includes(j.code) ? (j.code === 'CLAIM_REMIT_MATCHING' ? 'Disabled: claim-remit matching will be started through the Python matching service' : 'Disabled: jobs are run by the Worker service, this screen only shows the results') : undefined}
            onClick={() => run(j.code)}>
            {busy === j.code ? 'Running...' : j.short}
          </button>
        ))}
      </div>
      {error && <Alert kind="err">{error}</Alert>}
      {result && (
        <Alert kind="ok">
          <b>{result.job}</b> finished in {result.duration_ms} ms; {result.processed} item(s) processed.
          <table style={{ marginTop: 8, background: '#fff' }}>
            <thead><tr><th>Job</th><th>Status</th><th className="num">Items processed</th></tr></thead>
            <tbody>
              {result.steps.map((s: any, i: number) => (
                <tr key={i}><td>{s.job_code}</td><td><Badge value={s.status} /></td><td className="num">{s.processed_count}</td></tr>
              ))}
            </tbody>
          </table>
        </Alert>
      )}
    </div>
  )
}
