import { useEffect, useState } from 'react'
import { Row, get } from '../api'

// Source: SRS_01_ClaimSelection.docx (CS.01 - CS.08) and the configuration UI design. Verify against the official SRS.
const MATCH_FIELDS: [string, string, string][] = [
  ['Patient control number (PCN)', '835 + 837', 'Must be equal. A corrected claim with a new PCN is found through its lineage (root/original claim).'],
  ['Payer ID', '835 + 837', 'Must be equal'],
  ['Date of service', '835 line + 837 line', 'Must be equal'],
  ['Service code', '835 paid code + 837 code', 'Equal, or the paid code is inside the client Downcoded Service Codes range for the 837 code'],
  ['Service line', '835 line + 837 line', 'Must be equal (EM, HM, AN ...)'],
  ['Modifier', '835 + 837', 'No modifier on the 837 = no restriction. Otherwise it must also appear on the 835.'],
  ['Institutional only: DRG / revenue code', '837I + 835', 'Before the service code: if the 837 has a DRG it must equal the 835 DRG; else if it has a revenue code it must equal the 835 revenue code; neither = exception table. Line numbers are not compared.'],
  ['837 version', '837', 'Only the latest version of the claim lineage is used. A void or frequency 8 latest version means no match (no fallback).'],
]
const MANDATORY_835 = ['PCN', 'Payer ID', 'Paid service code', 'Service line', 'Date of service', 'Remit payment date']
const EXCEPTIONS: [string, string, string][] = [
  ['201', 'No eligible 837 found', 'Retried on every Matching run while OPEN; Exception Status Monitoring expires it after the 30-business-day window'],
  ['202', 'Mandatory 835 field missing', 'Same retry / expiry rules'],
  ['203', 'Zero or missing charge amount', 'Reserved: not raised by the current jobs'],
  ['204', 'Extenuating circumstance', 'Parked: not retried and not aged'],
  ['MATCH_AMBIGUOUS', 'More than one equally good 837', 'Never picked arbitrarily; retried'],
]
const RULES: [string, string, string, string, string][] = [
  ['NSA_DOS', '501', 'Date of service', 'Federal Timeline: NSA Effective Date', 'DOS on or after 2022-01-01'],
  ['REMIT_WINDOW', '502', 'Remit payment date', 'Federal Timeline: Claim Selection Window + Federal Calendar', 'Within 30 business days of today'],
  ['TAX_ID', '506', '837 billing TIN', 'Tax-ID Entity Mappings', 'TIN present and mapped for the client (missing = exception)'],
  ['PAYER', '505', 'Payer ID', 'Payer Configurations', 'Payer configured and not disabled. Government plans are simply not configured.'],
  ['SERVICE_LINE', '505', 'Service line', 'Service Line', 'Service line configured'],
  ['CLAIM_SELECTION_LOGIC', '505-508', 'TIN, facility name, physician NPI, service code', 'Claim Selection Logic', 'Payer x service line row lists the TIN, facility, NPI and code (All = any)'],
  ['INSURANCE_GROUP', '-', 'Insurance group (835 first, then 837)', 'Payer Configurations', 'Missing / unknown group defaults to Federal IDR and is flagged; never excludes'],
  ['FUNDING_TYPE', '-', 'From the payer group', 'Payer Configurations', 'Informational (used by batching and cool-off)'],
  ['STATE_ROUTING', '504', 'Facility state, group settlement rate', 'Bifurcated State List + historic settlement rate', 'No rate = Federal. Rate > 95% = Federal. A bifurcated state with a rate below 5% goes to state IDR (504). 5% to 95% = Federal.'],
  ['RARC', '503', '835 RARC codes', 'RARC Codes', 'Federal IDR eligible = Yes; N871 (state law) excludes; both together default to Federal'],
  ['REFERENCE_AMOUNT', '-', 'Service code, state, modifier', 'Medicare fee schedule', 'Reference rate must exist (missing = exception). Not used for anesthesia.'],
  ['ALLOWED_AMOUNT', '509', '835 allowed amount, 837 charge', 'Allowed Amount Threshold / LP Offer Amount', 'Allowed within [lower%, upper%] of the reference; no threshold row = excluded. LP facility: allowed/charge below the threshold %.'],
  ['ANESTHESIA_RATE', '509', 'Units, allowed amount', 'Offer Amounts (Per Unit) + Allowed Amount Threshold', 'Allowed within [lower%, upper%] of units x per-unit amount'],
  ['MODIFIER', '510', 'Qualifying modifier (anesthesia only)', 'Offer Amounts (modifier list)', 'Modifier present and configured'],
]
const JOB_TABLE: [string, string, string, string][] = [
  ['1 Claim-remit matching (disabled here: external matching service)', 'New 835 lines + OPEN retryable exceptions', 'Match, IDR case (CS-PENDING-EVALUATION) and financial summary; or one OPEN exception', 'Downcoded Service Codes'],
  ['2 Exception Status Monitoring', 'OPEN retryable exceptions', 'Retry count (once per business day), days remaining, EXPIRED_EXCLUDED', 'Federal Timeline window, Federal Calendar'],
  ['3 Exclusion Validation', 'Pending, exception and (for 45 days) excluded cases', 'Evaluation + 14 rule rows (Selection Rules); outcome Selected / Excluded / Exception', 'see rules below'],
  ['4 Systemic not pursued', 'Selected cases', 'Outcome Not pursued: systemic when a Systemic Exclusion row matches', 'Systemic Exclusion'],
  ['5 Cool-off status', 'Selected cases', 'ACTIVE / CLEARED / DATA_NOT_AVAILABLE with dates and prior determination', 'Cool-off Logic'],
  ['6 Preliminary batching', 'Selected cases with a cool-off status (cool-off is shown, never blocks)', 'Batch per composite key, DOS range and open window', 'Batching Logic'],
]
const OUTCOMES: [string, string][] = [
  ['CS-PENDING-EVALUATION', 'Case created by matching, waiting for Exclusion Validation'],
  ['CS-SUCCESS-SELECTED', 'All rules passed: selected for Federal IDR'],
  ['CS-SUCCESS-EXCLUDED', 'At least one rule failed (exclusion code shown)'],
  ['CS-SUCCESS-EXCEPTION', 'No failure, but required data is missing'],
  ['CS-NOTPURSUED-SYSTEMIC', 'A Systemic Exclusion row matched a selected case'],
  ['CS-NOTPURSUED-COOL-OFF', 'Not pursued because of a cool-off'],
  ['CS-NOTPURSUED-CLAIM-VOIDED', 'The 837 claim was voided after the case was created'],
]

export default function Reference() {
  const [meta, setMeta] = useState<any>(null)
  const [client, setClient] = useState('QA-COMPREHENSIVE')
  const [cfg, setCfg] = useState<any>(null)

  useEffect(() => { get('/api/meta').then(setMeta) }, [])
  useEffect(() => { get(`/api/reference/config?client=${encodeURIComponent(client)}`).then(setCfg) }, [client])

  const T = ({ head, rows }: { head: string[]; rows: (string | number | null)[][] }) => (
    <table><thead><tr>{head.map(h => <th key={h}>{h}</th>)}</tr></thead>
      <tbody>{rows.map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j} className={j === 0 ? 'mono' : ''}>{c}</td>)}</tr>)}</tbody></table>
  )

  return (
    <div className="page">
      <h1>IDR process reference</h1>
      <p className="sub">Fields and rules behind each job, for cross-checking results in the demo. Verify against the official SRS and configuration owners.</p>

      <div className="card"><h2>The eight jobs</h2><T head={['Job', 'Picks up', 'Produces', 'Configuration used']} rows={JOB_TABLE} /></div>

      <div className="grid g2">
        <div className="card"><h2>Claim-remit matching: fields compared</h2><T head={['Field', 'Source', 'Rule']} rows={MATCH_FIELDS} />
          <h3 style={{ marginTop: 14 }}>Mandatory 835 fields (else exception 202)</h3>
          <div>{MANDATORY_835.map(f => <span key={f} className="badge b-blue" style={{ margin: 2 }}>{f}</span>)}</div></div>
        <div className="card"><h2>Matching exceptions</h2><T head={['Code', 'Meaning', 'Handling']} rows={EXCEPTIONS} />
          <h3 style={{ marginTop: 14 }}>Case outcomes</h3><T head={['Outcome', 'Meaning']} rows={OUTCOMES} /></div>
      </div>

      <div className="card"><h2>Selection Rules: the 14 rules (every rule runs for every case)</h2>
        <T head={['Rule', 'Exclusion', 'Case fields used', 'Configuration table', 'Passes when']} rows={RULES} />
        <p className="muted">Any FAIL gives Excluded. Otherwise any missing data gives Exception. Otherwise Selected.</p></div>

      <div className="card">
        <div className="row" style={{ justifyContent: 'space-between' }}><h2>Live configuration in the database</h2>
          <select style={{ width: 240 }} value={client} onChange={e => setClient(e.target.value)}>{meta?.clients.map((c: Row) => <option key={c.client_id}>{c.client_id}</option>)}</select></div>
        {cfg && (
          <div className="grid g3">
            <div><h3>Batching Logic</h3><T head={['Field', 'Value']} rows={cfg.batching_logic.map((r: Row) => [r.field_name, r.current_value])} />
              <h3 style={{ marginTop: 12 }}>Cool-off Logic</h3><T head={['Field', 'Value']} rows={cfg.cool_off_logic.map((r: Row) => [r.field_name, r.current_value])} /></div>
            <div><h3>Federal Timeline</h3><T head={['Timer', 'Value', 'Units']} rows={cfg.timeline.map((r: Row) => [r.timer_name, r.value, r.units])} />
              <h3 style={{ marginTop: 12 }}>Downcoded Service Codes</h3><T head={['837 code', 'Lower', 'Upper']} rows={cfg.downcodes.map((r: Row) => [r.service_code_from_837, r.allowed_downcode_lower_range, r.allowed_downcode_upper_range])} />
              <h3 style={{ marginTop: 12 }}>Counts</h3><T head={['Item', 'Rows']} rows={[['Tax-ID mappings', cfg.counts.tax_id_mappings], ['Systemic rules (enabled)', cfg.counts.systemic_rules], ['Payer x group rows', cfg.counts.payer_groups]]} /></div>
            <div><h3>RARC Codes</h3><T head={['RARC', 'Federal IDR eligible']} rows={cfg.rarc.map((r: Row) => [r.rarc_code, r.federal_idr_process_eligible ? 'Yes' : 'No'])} /></div>
            <div style={{ gridColumn: '1 / -1' }}><h3>Allowed Amount Thresholds (first 60)</h3><T head={['Payer', 'Service line', 'Lower %', 'Upper %']} rows={cfg.thresholds.map((r: Row) => [r.payer_id, r.service_line, r.lower_threshold, r.upper_threshold])} />
              <h3 style={{ marginTop: 12 }}>Claim Selection Logic (first 60)</h3><T head={['Payer', 'Service line', 'Tax ID', 'Facility', 'Physician NPI', 'Service code']} rows={cfg.claim_selection_logic.map((r: Row) => [r.payer_id, r.service_line, r.tax_id, r.facility_name, r.physician_npi, r.service_code])} /></div>
          </div>
        )}
      </div>
    </div>
  )
}
