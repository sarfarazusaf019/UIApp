import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { JOBS, Row, fmtDate, fmtTime, get, money, post } from '../api'
import { Badge, Kv, RunJobs, YesNo } from '../components/ui'

const split = (v?: string | null) => (v ? String(v).split(',').map(x => x.trim()).filter(Boolean) : [])
const same = (a: any, b: any) => a !== null && a !== undefined && a !== '' && b !== null && b !== undefined && b !== '' && String(a).trim().toLowerCase() === String(b).trim().toLowerCase()
type Kind = 'ok' | 'warn' | 'bad' | 'info'
const TONES: Record<Kind, string> = { ok: 'green', warn: 'yellow', bad: 'red', info: 'grey' }
const Result = ({ kind, text }: { kind: Kind; text: string }) => <span className={`badge b-${TONES[kind]}`}>{text}</span>

/** Side by side 837 / 835: which fields the matching compared, the rule applied and whether the two agree. */
function MatchComparison({ h, c837, r835 }: { h: Row; c837?: Row; r835?: Row }) {
  if (!c837 || !r835) return <div className="card"><span className="muted">No matched 837 / 835 pair for this case.</span></div>
  const institutional = String(c837.claim_type ?? '').includes('I')
  const mods837 = split(c837.modifiers)
  const mods835 = split(r835.modifiers).map(m => m.toLowerCase())
  const modOk = mods837.length === 0 || mods837.some(m => mods835.includes(m.toLowerCase()))
  const exactCode = same(c837.service_code, r835.paid_service_code)
  const drgPresent = !!c837.drg_code
  const eq = (a: any, b: any): [Kind, string] => same(a, b) ? ['ok', 'Equal'] : ['bad', 'Different']

  const rows: [string, any, any, string, [Kind, string]][] = [
    ['Patient control number', c837.patient_account_number, r835.patient_control_number, 'Must be equal', eq(c837.patient_account_number, r835.patient_control_number)],
    ['Payer ID', c837.payer_business_id, r835.payer_business_id, 'Must be equal', eq(c837.payer_business_id, r835.payer_business_id)],
    ['Service line', c837.service_line_code, r835.service_line_code, 'Must be equal', eq(c837.service_line_code, r835.service_line_code)],
    ['Date of service', fmtDate(c837.date_of_service), fmtDate(r835.date_of_service), 'Must be equal', eq(fmtDate(c837.date_of_service), fmtDate(r835.date_of_service))],
    ['Modifier', c837.modifiers, r835.modifiers, 'No 837 modifier = no restriction; otherwise an 837 modifier must also be on the 835',
      mods837.length === 0 ? ['info', 'No 837 modifier: not restricted'] : modOk ? ['ok', 'Found on the 835'] : ['bad', 'Not on the 835']],
    ['Service code', c837.service_code, r835.paid_service_code, 'Equal, or the paid code is inside the approved downcode range of the 837 code (the 837 code stays the case code)',
      exactCode ? ['ok', 'Exact'] : ['warn', 'Approved downcode']],
  ]
  if (institutional) {
    rows.push(['DRG (837I)', c837.drg_code, r835.drg_code, 'If the 837 has a DRG it must equal the 835 DRG', drgPresent ? eq(c837.drg_code, r835.drg_code) : ['info', 'No 837 DRG: revenue code used']])
    rows.push(['Revenue code (837I)', c837.revenue_code, r835.revenue_code, 'Without a DRG the 837 revenue code must equal the 835 revenue code', drgPresent ? ['info', 'Not compared (DRG decides)'] : eq(c837.revenue_code, r835.revenue_code)])
  }
  const other: [string, any, any, string][] = [
    ['Insurance group', c837.insurance_group_number, r835.insurance_group_number, `Case uses: ${h.insurance_group_number ?? '-'} (835 first, then 837)`],
    ['Line charge', money(c837.line_charge_amount), money(r835.line_charge_amount), `Billed amount of the case: ${money(h.billed_amount) || '-'} (837 charge, else 835)`],
    ['Units', c837.units, r835.units, ''],
    ['Line number', c837.line_number, r835.line_number, 'Line numbers are never compared'],
    ['Allowed / paid / offer', '', `${money(r835.allowed_amount) || '-'} / ${money(r835.line_paid_amount) || '-'} / ${money(r835.provider_offer_amount) || '-'}`, 'Amounts exist on the 835 only'],
    ['Tax ID / facility / rendering NPI', `${c837.billing_provider_tin ?? '-'} / ${c837.facility_name ?? '-'} / ${c837.rendering_provider_npi ?? '-'}`, '', 'Used by the Selection Rules, not by matching'],
  ]
  const allOk = rows.every(r => r[4][0] !== 'bad')

  return (
    <div className="card">
      <h2>How the 837 and the 835 are related</h2>
      <p className="sub">
        Matched as <b>{h.match_type === 'APPROVED_DOWNCODE' ? 'approved downcode' : 'exact'}</b> to 837 claim {c837.edi_837_claim_id} <b>version {h.matched_version ?? c837.version_sequence}</b>
        {' '}(frequency {c837.frequency_code}{c837.is_void ? ', void' : ''}), invoice {c837.invoice_number ?? '-'}; case <span className="mono">{h.case_reference}</span>.
        {' '}The matching keeps only the latest version of each claim and ignores void / cancelled versions. {allOk ? '' : 'A field below differs: check the match.'}
      </p>
      <table>
        <thead><tr><th>Compared field</th><th>837 claim</th><th></th><th>835 remit line</th><th>Result</th><th>Rule</th></tr></thead>
        <tbody>
          {rows.map(([name, a, b, rule, res]) => (
            <tr key={name}><td><b>{name}</b></td><td>{a ?? <span className="muted">-</span>}</td><td className="muted" style={{ textAlign: 'center' }}>&harr;</td>
              <td>{b ?? <span className="muted">-</span>}</td><td><Result kind={res[0]} text={res[1]} /></td><td className="muted">{rule}</td></tr>
          ))}
        </tbody>
      </table>
      <h3 style={{ margin: '14px 0 6px' }}>Other fields side by side (not matching keys)</h3>
      <table>
        <thead><tr><th>Field</th><th>837 claim</th><th>835 remit line</th><th>Note</th></tr></thead>
        <tbody>
          {other.map(([name, a, b, note]) => <tr key={name}><td><b>{name}</b></td><td>{a || <span className="muted">-</span>}</td><td>{b || <span className="muted">-</span>}</td><td className="muted">{note}</td></tr>)}
        </tbody>
      </table>
    </div>
  )
}

export default function CaseDetail() {
  const { id } = useParams()
  const [d, setD] = useState<any>(null)
  const [tab, setTab] = useState<'jobs' | 'rules' | 'source' | 'workflow'>('jobs')
  const [evalId, setEvalId] = useState<number | null>(null)
  const [error, setError] = useState('')

  const load = useCallback(() => get(`/api/cases/${id}`).then(x => { setD(x); setEvalId(x.evaluations[0]?.idr_claim_selection_evaluation_id ?? null) }).catch(e => setError(e.message)), [id])
  useEffect(() => { load() }, [load])

  if (error) return <div className="page"><div className="alert err">{error}</div></div>
  if (!d) return <div className="page">Loading...</div>
  const h = d.header
  const timeline: Row[] = d.timeline

  return (
    <div className="page">
      <p><Link to="/cases">&larr; All IDR cases</Link></p>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <div>
          <h1>{h.patient_control_number} <Badge value={h.outcome_code} /></h1>
          <p className="sub mono">{h.case_reference}</p>
        </div>
        <div>
          <RunJobs onDone={load} />
          {['CS-SUCCESS-SELECTED', 'CS-SUCCESS-EXCLUDED', 'CS-SUCCESS-EXCEPTION'].includes(h.outcome_code) && (
            <button className="secondary small" style={{ marginTop: 8 }} title="Sets the case back to pending so the next Exclusion Validation run re-checks it against the current configuration"
              onClick={async () => { try { await post(`/api/cases/${id}/reevaluate`, {}); setError(''); load() } catch (e: any) { setError(e.message) } }}>
              Send back for re-evaluation (after a config change)</button>)}
        </div>
      </div>

      <div className="grid g3">
        <div className="card"><h3>Case</h3>
          <Kv items={[['Client', h.client_id], ['Payer', h.payer_business_id], ['Tax ID', h.tax_id], ['Entity', h.entity_name],
            ['Service line', h.service_line_code], ['Service code (837)', h.service_code], ['Modifier', h.qualifying_modifier],
            ['Date of service', fmtDate(h.date_of_service)], ['Remit payment date', fmtDate(h.remit_payment_date)],
            ['Insurance group', h.insurance_group_number], ['Funding type', h.funding_type], ['Facility state', h.facility_state_code]]} /></div>
        <div className="card"><h3>Money</h3>
          <Kv items={[['Billed (837)', money(h.billed_amount)], ['Allowed (835)', money(h.allowed_amount)], ['Paid', money(h.paid_amount)],
            ['Medicare reference', money(h.medicare_reference_amount)], ['Provider offer', money(h.provider_offer_amount)]]} />
          <h3 style={{ marginTop: 16 }}>Flags</h3>
          <Kv items={[['Selected for Federal IDR', <YesNo v={h.selected_for_federal_idr} />], ['Stage', h.current_stage]]} /></div>
        <div className="card"><h3>Job runs on this case</h3>
          <table>
            <thead><tr><th>Job</th><th className="num">Runs</th><th>Last result</th></tr></thead>
            <tbody>
              {JOBS.map(j => {
                const rows = timeline.filter(t => t.job_code === j.code)
                const last = rows[rows.length - 1]
                return <tr key={j.code}><td>{j.short}</td><td className="num"><b>{rows.length}</b></td><td>{last ? <Badge value={last.result} /> : <span className="muted">not run for this case</span>}</td></tr>
              })}
            </tbody>
          </table></div>
      </div>

      <div className="tabs">
        {([['jobs', 'Job history'], ['rules', 'Selection Rules'], ['source', '837 / 835 source'], ['workflow', 'Cool-off, batch, exceptions']] as const).map(([k, l]) =>
          <button key={k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>{l}</button>)}
      </div>

      {tab === 'jobs' && (
        <div className="card">
          <h2>Every job run that touched this case, in order</h2>
          <p className="sub">Run # counts how many times that job has looked at this case. Exclusion Validation is stored again only when its result changes, so "unchanged" runs are shown here from the job log.</p>
          <div className="timeline">
            {timeline.length === 0 && <span className="muted">No job history yet. Run the jobs.</span>}
            {timeline.map((t, i) => (
              <div className="tl-item" key={i}>
                <b>{JOBS.find(j => j.code === t.job_code)?.name ?? t.job_code}</b> <span className="muted">- run #{t.run_no} - {fmtTime(t.logged_at_utc)}</span><br />
                <Badge value={t.result} /> <span className="mono">{t.detail}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {tab === 'rules' && (
        <div className="card">
          <h2>Selection Rules</h2>
          {d.evaluations.length === 0 ? <p className="muted">This case has not been evaluated yet (or was created as a seeded control).</p> : (
            <>
              <div className="row" style={{ marginBottom: 10 }}>
                <label style={{ margin: 0 }}>Evaluation</label>
                <select style={{ width: 380 }} value={evalId ?? ''} onChange={e => setEvalId(Number(e.target.value))}>
                  {d.evaluations.map((e: Row) => <option key={e.idr_claim_selection_evaluation_id} value={e.idr_claim_selection_evaluation_id}>
                    #{e.evaluation_no} {e.evaluation_type} - {e.final_outcome_code} - {fmtTime(e.completed_at_utc)}</option>)}
                </select>
              </div>
              <table>
                <thead><tr><th>Rule</th><th>Result</th><th>Exclusion</th><th>Reason code</th><th>Case value</th><th>Configured / expected</th></tr></thead>
                <tbody>
                  {d.rules.filter((r: Row) => r.idr_claim_selection_evaluation_id === evalId).map((r: Row, i: number) => (
                    <tr key={i}><td><b>{r.rule_code}</b></td><td><Badge value={r.rule_outcome} /></td>
                      <td>{r.exclusion_code && <span title={r.exclusion_label}>{r.exclusion_code} <span className="muted">{r.exclusion_label}</span></span>}</td>
                      <td className="mono">{r.reason_code}</td><td className="mono">{r.source_value}</td><td className="mono">{r.configuration_value}</td></tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </div>
      )}

      {tab === 'source' && (
        <>
          <MatchComparison h={h} c837={d.source_837[0]} r835={d.source_835[0]} />
          <h2 style={{ margin: '18px 0 8px' }}>Full 837 and 835 details</h2>
          <div className="grid g2">
            <div className="card"><h2>837 claim (matched version)</h2>
              {d.source_837.map((s: Row, i: number) => <Kv key={i} items={[['Claim type', `${s.claim_type} (${s.transaction_type})`], ['Invoice', s.invoice_number], ['Payer', s.payer_business_id],
                ['Frequency / version', `${s.frequency_code} / v${s.version_sequence}${s.is_void ? ' (void)' : ''}`], ['Billing TIN', s.billing_provider_tin], ['Billing NPI', s.billing_provider_npi],
                ['Rendering NPI', s.rendering_provider_npi], ['Facility', s.facility_name], ['Facility NPI', s.facility_npi], ['Facility state', s.facility_state_code],
                ['Insurance group', s.insurance_group_number], ['Line', s.line_number], ['Service code', s.service_code], ['Service line', s.service_line_code],
                ['Modifiers', s.modifiers], ['DRG', s.drg_code], ['Revenue code', s.revenue_code], ['Units', s.units], ['Line charge', money(s.line_charge_amount)], ['DOS', fmtDate(s.date_of_service)]]} />)}</div>
            <div className="card"><h2>835 remit line</h2>
              {d.source_835.map((s: Row, i: number) => <Kv key={i} items={[['Transaction', s.transaction_control_number], ['Payment date', fmtDate(s.payment_effective_date)], ['Payer', s.payer_business_id],
                ['PCN', s.patient_control_number], ['Insurance group', s.insurance_group_number], ['Line', s.line_number], ['Paid service code', s.paid_service_code],
                ['Service line', s.service_line_code], ['Modifiers', s.modifiers], ['DRG', s.drg_code], ['Revenue code', s.revenue_code], ['RARC codes', s.rarc_codes], ['Units', s.units], ['Charge', money(s.line_charge_amount)],
                ['Paid', money(s.line_paid_amount)], ['Allowed', money(s.allowed_amount)], ['Offer', money(s.provider_offer_amount)], ['DOS', fmtDate(s.date_of_service)]]} />)}</div>
          </div>
        </>
      )}

      {tab === 'workflow' && (
        <div className="grid g2">
          <div className="card"><h2>Cool-off</h2>
            {d.cool_off.length === 0 ? <span className="muted">No cool-off evaluation yet (only active cases are evaluated).</span> :
              d.cool_off.map((c: Row, i: number) => <Kv key={i} items={[['Status', <Badge value={c.check_status} />], ['Start', fmtDate(c.cool_off_start_date)], ['End', fmtDate(c.cool_off_end_date)], ['Prior determination', c.determination_reference]]} />)}
            <h2 style={{ marginTop: 18 }}>Preliminary batch</h2>
            {d.batch.length === 0 ? <span className="muted">Not batched.</span> :
              d.batch.map((b: Row, i: number) => <Kv key={i} items={[['Reference', b.batch_reference], ['Status', <Badge value={b.batch_status} />], ['Grouping', b.grouping_mode], ['Tax ID', b.tax_id], ['Payer', b.payer_business_id],
                ['Group', b.insurance_group_number], ['Service code', b.service_code], ['DOS range', `${fmtDate(b.earliest_dos)} to ${fmtDate(b.latest_dos)}`], ['First remit', fmtDate(b.first_remit_payment_date)],
                ['Open until', fmtDate(b.batch_open_end_date)], ['Cases in batch', b.cases_in_batch]]} />)}</div>
          <div className="card"><h2>Matching exceptions for this remit line</h2>
            {d.exceptions.length === 0 ? <span className="muted">None.</span> : d.exceptions.map((e: Row, i: number) =>
              <Kv key={i} items={[['Reason code', e.exception_code], ['Reason description', e.exception_label], ['Status', <Badge value={e.status} />], ['Retry count', e.retry_count], ['Days remaining', e.days_remaining_in_window],
                ['Opened', fmtTime(e.opened_at_utc)], ['Resolved', fmtTime(e.resolved_at_utc)], ['Reason detail', e.reason_text]]} />)}
            <h2 style={{ marginTop: 18 }}>837 claim versions used by this case</h2>
            {d.claim_versions.length === 0 ? <span className="muted">No version recorded.</span> :
              <table><thead><tr><th>Captured</th><th>Version</th><th>Claim</th><th>Frequency</th><th>Service code</th><th>Charge</th><th>Change</th><th>Current</th><th>Note</th></tr></thead>
                <tbody>{d.claim_versions.map((v: Row, i: number) => <tr key={i}><td>{fmtTime(v.captured_at_utc)}</td><td>{v.version_sequence}</td><td>{v.edi_837_claim_id}</td><td>{v.frequency_code}{v.is_void ? ' (void)' : ''}</td><td>{v.service_code}</td><td>{v.line_charge_amount}</td><td>{v.change_type}</td><td>{v.is_current ? 'yes' : ''}</td><td>{v.note}</td></tr>)}</tbody></table>}
            <h2 style={{ marginTop: 18 }}>Outcome history</h2>
            <table><thead><tr><th>When</th><th>Source</th><th>From</th><th>To</th><th>Note</th></tr></thead>
              <tbody>{d.status_history.map((s: Row, i: number) => <tr key={i}><td>{fmtTime(s.changed_at_utc)}</td><td>{s.event_source}</td><td><Badge value={s.prior_outcome} /></td><td><Badge value={s.new_outcome} /></td><td>{s.notes}</td></tr>)}</tbody></table></div>
        </div>
      )}
    </div>
  )
}
