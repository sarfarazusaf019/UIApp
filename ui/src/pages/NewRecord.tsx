import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { JOBS, Row, fmtTime, get, post, qs } from '../api'
import { Alert, Badge, RunJobs } from '../components/ui'

const day = (offset: number) => { const d = new Date(); d.setDate(d.getDate() + offset); return d.toISOString().slice(0, 10) }

const blankLine = () => ({
  service_line: 'EM', service_code: '99285', paid_service_code: '', date_of_service: day(-20), date_of_service835: '', revenue_code837: '', revenue_code835: '', units: 1,
  charge_amount: 500, paid_amount: 200, allowed_amount: 300, offer_amount: 250, modifiers837: '', modifiers835: '',
})

const initial = () => ({
  client_id: 'QA-COMPREHENSIVE', claim_type: 'P', patient_control_number: `DEMO-${Date.now().toString().slice(-6)}`,
  payer_id: 'QA-PAYER', remit_payer_id: '', insurance_group: 'QA-GROUP-FULL', include837: true, include835: true, register_tin: true, invoice_number: '',
  frequency_code: '1', is_void: false, tin: '50-7770001', billing_npi: '1000000001', rendering_npi: '2000000001',
  facility_npi: '3000000001', facility_name: 'QA Facility A', facility_state: 'TX', remit_payment_date: day(-5), rarc_codes: 'N877', drg837: '', drg835: '',
  lines: [blankLine()],
})

const PRESETS: { name: string; note: string; apply: (f: any) => any }[] = [
  { name: 'Happy path', note: 'Matches, passes every selection rule, is selected, cool-off cleared and batched.', apply: f => ({ ...f }) },
  { name: 'Corrected 837 only', note: 'Use the PCN of an existing claim: inserts only a newer 837 version (frequency 7). Run the jobs: the case is re-pointed and re-evaluated.', apply: f => ({ ...f, include835: false, frequency_code: '7' }) },
  { name: 'No 837 (unmatched)', note: 'Only a remit: matching raises exception 201 and retries on every run.', apply: f => ({ ...f, include837: false }) },
  { name: 'Approved downcode', note: '837 says 99285, payer paid 99284 (inside the configured downcode range).', apply: f => ({ ...f, lines: [{ ...f.lines[0], paid_service_code: '99284' }] }) },
  { name: 'Unapproved downcode', note: 'Paid 99291 is outside the range: no match, exception 201.', apply: f => ({ ...f, lines: [{ ...f.lines[0], paid_service_code: '99291' }] }) },
  { name: 'DOS before NSA', note: 'Matches, then Exclusion Validation excludes it (501).', apply: f => ({ ...f, lines: [{ ...f.lines[0], date_of_service: '2021-12-15' }] }) },
  { name: 'Unconfigured payer', note: 'Matches, then Exclusion Validation excludes it (505).', apply: f => ({ ...f, payer_id: 'QA-GOV', insurance_group: '' }) },
  { name: 'Invalid: missing service code', note: 'Blank 835 service code and remit date: matching raises exception 202 (mandatory field missing).', apply: f => ({ ...f, remit_payment_date: '', lines: [{ ...f.lines[0], service_code: '', paid_service_code: '' }] }) },
  { name: 'Institutional: DRG match', note: '837I with DRG 470 on both sides: passes the DRG check, then the service code comparison.', apply: f => ({ ...f, claim_type: 'I', drg837: '470', drg835: '470' }) },
  { name: 'Institutional: DRG mismatch', note: '837I DRG 470 vs 835 DRG 871: moved to the exception table (201).', apply: f => ({ ...f, claim_type: 'I', drg837: '470', drg835: '871' }) },
  { name: 'Institutional: revenue code', note: '837I without DRG, revenue code 0450 on both sides: matches.', apply: f => ({ ...f, claim_type: 'I', lines: [{ ...f.lines[0], revenue_code837: '0450', revenue_code835: '0450' }] }) },
  { name: 'Institutional: revenue mismatch', note: '837I without DRG, revenue 0450 vs 0360: exception (201).', apply: f => ({ ...f, claim_type: 'I', lines: [{ ...f.lines[0], revenue_code837: '0450', revenue_code835: '0360' }] }) },
  { name: 'Institutional: no DRG or revenue', note: '837I with neither a DRG nor a revenue code: exception (201).', apply: f => ({ ...f, claim_type: 'I' }) },
  { name: 'Anesthesia', note: '4 units with modifier AA on both sides; allowed 100 is inside the anesthesia range.', apply: f => ({ ...f, lines: [{ ...blankLine(), service_line: 'AN', service_code: '00100', units: 4, allowed_amount: 100, paid_amount: 100, offer_amount: 100, modifiers837: 'AA', modifiers835: 'AA' }] }) },
]

export default function NewRecord() {
  const [meta, setMeta] = useState<any>(null)
  const [f, setF] = useState<any>(initial())
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [trace, setTrace] = useState<Row[] | null>(null)
  const [inserted, setInserted] = useState<{ client: string; pcn: string } | null>(null)

  useEffect(() => { get('/api/meta').then(setMeta) }, [])
  const set = (k: string, v: any) => setF((p: any) => ({ ...p, [k]: v }))
  const setLine = (i: number, k: string, v: any) => setF((p: any) => ({ ...p, lines: p.lines.map((l: any, j: number) => (j === i ? { ...l, [k]: v } : l)) }))

  const refresh = async (client = inserted?.client, pcn = inserted?.pcn) => {
    if (client && pcn) setTrace((await get(`/api/records/trace${qs({ client, pcn })}`)).lines)
  }

  const submit = async () => {
    setBusy(true); setMsg(null); setTrace(null)
    try {
      const body = { ...f, lines: f.lines.map((l: any) => ({ ...l, units: Number(l.units), charge_amount: Number(l.charge_amount), paid_amount: Number(l.paid_amount), allowed_amount: l.allowed_amount === '' ? null : Number(l.allowed_amount), offer_amount: l.offer_amount === '' ? null : Number(l.offer_amount) })) }
      const r = await post('/api/records', body)
      setInserted({ client: r.client_id, pcn: r.pcn })
      setMsg({ kind: 'ok', text: `Inserted ${f.include837 ? `837 claim (version ${r.claim_version}) and ` : ''}835 remit for PCN ${r.pcn}. Now run the jobs and check the result below.` })
      await refresh(r.client_id, r.pcn)
    } catch (e: any) {
      setMsg({ kind: 'err', text: e.message })
    } finally { setBusy(false) }
  }

  const F = ({ label, k, req, help, type = 'text', list }: any) => (
    <div className="field"><label>{label}{req && <span className="req"> *</span>}</label>
      <input type={type} value={f[k] ?? ''} list={list} onChange={e => set(k, e.target.value)} />{help && <small>{help}</small>}</div>
  )
  const L = (i: number, k: string, type = 'text') => <input type={type} value={f.lines[i][k] ?? ''} onChange={e => setLine(i, k, e.target.value)} />

  return (
    <div className="page">
      <h1>New claim-remit record</h1>
      <p className="sub">Insert a claim (837) and its remittance (835), then run the jobs. Matching, Exclusion Validation and the rest process the new data like any other record.</p>

      <div className="card">
        <h3>Start from a scenario</h3>
        <div className="row">
          {PRESETS.map(p => <button key={p.name} className="secondary small" title={p.note} onClick={() => { setF(PRESETS.find(x => x.name === p.name)!.apply(initial())); setMsg({ kind: 'ok', text: `${p.name}: ${p.note}` }) }}>{p.name}</button>)}
        </div>
      </div>

      {msg && <Alert kind={msg.kind}>{msg.text}</Alert>}

      <div className="grid g2">
        <div className="card">
          <h2>Common (both files)</h2>
          <div className="grid g2">
            <div className="field"><label>Client <span className="req">*</span></label>
              <select value={f.client_id} onChange={e => set('client_id', e.target.value)}>{meta?.clients.map((c: Row) => <option key={c.client_id}>{c.client_id}</option>)}</select></div>
            <div className="field"><label>Claim type <span className="req">*</span></label>
              <select value={f.claim_type} onChange={e => set('claim_type', e.target.value)}><option value="P">Professional (837P)</option><option value="I">Institutional (837I)</option></select></div>
            {F({ label: 'Patient control number (PCN)', k: 'patient_control_number', req: true, help: 'Key used to match 835 to 837' })}
            {F({ label: 'Payer ID', k: 'payer_id', req: true, list: 'payers', help: 'Must be in Payer Configurations to be eligible' })}
            {F({ label: '835 payer ID (if different)', k: 'remit_payer_id', list: 'payers', help: 'Blank = same as the 837 payer. A different value tests a payer mismatch.' })}
            {F({ label: 'Insurance group number', k: 'insurance_group', help: 'Empty = defaults to Federal IDR' })}
            {F({ label: 'Remit payment date (835)', k: 'remit_payment_date', type: 'date', help: 'Inside the 30-business-day window. Blank = missing data (exception 202)' })}
            {f.claim_type === 'I' && F({ label: 'DRG (837)', k: 'drg837', help: 'Institutional only. If the 837 has a DRG it must equal the 835 DRG' })}
            {f.claim_type === 'I' && F({ label: 'DRG (835)', k: 'drg835', help: 'Institutional only (CLP11)' })}
            {F({ label: 'RARC codes (835)', k: 'rarc_codes', help: 'Comma separated, e.g. N877. N871 = state law applies' })}
          </div>
          <datalist id="payers">{meta?.payers.map((p: Row) => <option key={p.payer_edi_id} value={p.payer_edi_id}>{p.payer_name}</option>)}</datalist>
        </div>

        <div className="card">
          <div className="row" style={{ justifyContent: 'space-between' }}>
            <h2>837 claim</h2>
            <label style={{ margin: 0 }}><input style={{ width: 'auto' }} type="checkbox" checked={f.include837} onChange={e => set('include837', e.target.checked)} /> Insert the 837 claim</label>
          </div>
          <label style={{ margin: 0 }}><input style={{ width: 'auto' }} type="checkbox" checked={f.include835} onChange={e => set('include835', e.target.checked)} /> Insert the 835 remit (off = only a new 837 version)</label>
          {!f.include837 && <p className="muted">No 837 will be inserted, so the remit line stays unmatched (exception 201).</p>}
          {f.include837 && (
            <div className="grid g2">
              {F({ label: 'Billing provider TIN', k: 'tin', help: 'Must be mapped (Tax-ID Entity Mappings). Blank = missing Tax ID (exception)' })}
              {F({ label: 'Invoice number', k: 'invoice_number', help: 'Blank = generated' })}
              {F({ label: 'Billing NPI', k: 'billing_npi' })}
              {F({ label: 'Rendering (physician) NPI', k: 'rendering_npi', help: 'Used by Claim Selection Logic / Systemic rules' })}
              {F({ label: 'Facility name', k: 'facility_name', help: 'Used by Claim Selection Logic' })}
              {F({ label: 'Facility NPI', k: 'facility_npi' })}
              {F({ label: 'Facility state', k: 'facility_state', help: 'Bifurcated states may route to state IDR' })}
              <div className="field"><label>Frequency code</label>
                <select value={f.frequency_code} onChange={e => set('frequency_code', e.target.value)}><option value="1">1 - original</option><option value="7">7 - corrected (new version)</option><option value="8">8 - cancelled</option></select></div>
              <label><input style={{ width: 'auto' }} type="checkbox" checked={f.register_tin} onChange={e => set('register_tin', e.target.checked)} /> Also map this TIN in Tax-ID Entity Mappings</label>
              <label><input style={{ width: 'auto' }} type="checkbox" checked={f.is_void} onChange={e => set('is_void', e.target.checked)} /> Void claim</label>
            </div>
          )}
        </div>
      </div>

      <div className="card">
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <h2>Service lines (837 line and the matching 835 line)</h2>
          <button className="secondary small" onClick={() => set('lines', [...f.lines, { ...blankLine(), date_of_service: f.lines[0].date_of_service }])}>+ Add line</button>
        </div>
        <div className="scroll linestable">
          <table>
            <thead><tr><th>#</th><th>Service line</th><th>837 service code</th><th>835 paid code</th><th>DOS (837)</th><th>DOS (835, if different)</th><th>Units</th><th>Charge</th><th>Paid</th><th>Allowed</th><th>Offer</th>{f.claim_type === 'I' && <><th>Revenue code (837)</th><th>Revenue code (835)</th></>}<th>837 modifiers</th><th>835 modifiers</th><th /></tr></thead>
            <tbody>
              {f.lines.map((l: any, i: number) => (
                <tr key={i}><td>{i + 1}</td>
                  <td><select value={l.service_line} onChange={e => setLine(i, 'service_line', e.target.value)}>{meta?.service_lines.map((s: Row) => <option key={s.code} value={s.code}>{s.code} - {s.name}</option>)}</select></td>
                  <td>{L(i, 'service_code')}</td><td>{L(i, 'paid_service_code')}</td><td>{L(i, 'date_of_service', 'date')}</td><td>{L(i, 'date_of_service835', 'date')}</td><td>{L(i, 'units', 'number')}</td>
                  <td>{L(i, 'charge_amount', 'number')}</td><td>{L(i, 'paid_amount', 'number')}</td><td>{L(i, 'allowed_amount', 'number')}</td><td>{L(i, 'offer_amount', 'number')}</td>
                  {f.claim_type === 'I' && <><td>{L(i, 'revenue_code837')}</td><td>{L(i, 'revenue_code835')}</td></>}
                  <td>{L(i, 'modifiers837')}</td><td>{L(i, 'modifiers835')}</td>
                  <td>{f.lines.length > 1 && <button className="secondary small" onClick={() => set('lines', f.lines.filter((_: any, j: number) => j !== i))}>x</button>}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
        <small className="muted">835 paid code blank = same as the 837 code. Modifiers are comma separated (anesthesia needs one, for example AA). Units matter for anesthesia. Leave a field blank to test invalid data (blank paid code or DOS = exception 202).</small>
        <div className="row" style={{ marginTop: 14 }}>
          <button disabled={busy} onClick={submit}>{busy ? 'Inserting...' : 'Insert record'}</button>
          <button className="secondary" onClick={() => { setF(initial()); setMsg(null); setTrace(null); setInserted(null) }}>Reset form</button>
        </div>
      </div>

      {inserted && (
        <div className="card">
          <h2>Step 2 - run the jobs for {inserted.pcn}</h2>
          <RunJobs onDone={() => refresh()} />
          <h2 style={{ marginTop: 22 }}>Result for {inserted.pcn}</h2>
          {(!trace || trace.length === 0) && <span className="muted">Nothing yet.</span>}
          {trace?.map(t => {
            const history: Row[] = JSON.parse(t.history || '[]')
            return (
              <div key={t.remit_line_id} className="card" style={{ background: '#f7fafd' }}>
                <div className="row">
                  <b>Remit line {t.line_number} ({t.paid_service_code})</b>
                  {t.case_id ? <>Matched <Badge value="Matched" /> {t.match_type} - case <Link to={`/cases/${t.case_id}`}>#{t.case_id}</Link> <Badge value={t.outcome_code} /></> :
                    <><Badge value="Unmatched" /> {t.exception_code && <>exception <b>{t.exception_code}</b> <Badge value={t.exception_status} /> retry {t.retry_count} - {t.reason_text}</>}{!t.exception_code && <span className="muted">not processed yet - run Claim-remit matching</span>}</>}
                  {t.cool_off_status && <>Cool-off <Badge value={t.cool_off_status} /></>}{t.batch_reference && <>Batch <span className="mono">{t.batch_reference}</span></>}
                </div>
                <div className="timeline" style={{ marginTop: 10 }}>
                  {history.map((h, i) => <div className="tl-item" key={i}><b>{JOBS.find(j => j.code === h.job)?.name}</b> <span className="muted">{fmtTime(h.at)}</span> <Badge value={h.result} /> <span className="mono">{h.detail}</span></div>)}
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
