import { useCallback, useEffect, useState } from 'react'
import { Row, fmtTime, get, post, qs } from '../api'
import { Alert } from '../components/ui'

const TITLES: Record<string, [string, string]> = {
  config_payer_insurance_group: ['Payer Configurations', 'Universal'],
  config_service_line: ['Service Line', 'Universal'],
  config_federal_timeline: ['Federal Timeline (NSA date, claim selection window)', 'Universal'],
  config_federal_calendar: ['Federal Calendar', 'Universal'],
  config_rarc_code: ['RARC Codes', 'Universal'],
  config_bifurcated_state: ['Bifurcated State List', 'Universal'],
  config_medicare_fee_schedule: ['Medicare fee schedule', 'Universal'],
  config_idre_fee_schedule: ['IDRE fee schedule', 'Universal'],
  config_tax_id_entity_mapping: ['Tax-ID Entity Mappings', 'Client'],
  config_claim_selection_logic: ['Claim Selection Logic', 'Client'],
  config_allowed_amount_threshold: ['Allowed Amount Threshold', 'Client'],
  config_offer_amount: ['Offer Amounts (anesthesia per unit)', 'Client'],
  config_lp_offer_amount: ['LP Offer Amounts (percent of charge)', 'Client'],
  config_systemic_exclusion: ['Systemic Exclusion', 'Client'],
  config_batching_logic: ['Batching Logic', 'Client'],
  config_cool_off_logic: ['Cool-off Logic', 'Client'],
  config_downcoded_service_code: ['Downcoded Service Codes', 'Client'],
  config_criteria_version: ['Criteria versions', 'Client'],
  config_client: ['Clients', 'Setup'],
  config_tenant: ['Tenants', 'Setup'],
}
const title = (t: string) => TITLES[t]?.[0] ?? t.replace('config_', '').replace(/_/g, ' ')
const HELP: Record<string, string> = {
  config_allowed_amount_threshold: 'Lower / upper % of the Medicare reference (or of units x per-unit amount for anesthesia). No row for a payer x service line = case excluded (509).',
  config_batching_logic: 'Field names: dos_range_days, cs_internal_wait_day_count, payer_id, insurance_group, service_line, tax_id, service_code (True / False).',
  config_cool_off_logic: 'Field names: cool_off_period_batched (days), cool_off_period_single, and the key flags payer_id, insurance_group, service_line, tax_id, service_code. No rows = cool-off DATA_NOT_AVAILABLE.',
  config_claim_selection_logic: 'Which Tax IDs / facilities / physician NPIs / service codes qualify for a payer x service line. "All" = any. Lists use ; or ,',
  config_systemic_exclusion: 'A matching row moves a Selected case to Not pursued: systemic. "All" or empty = wildcard; the service code is a lower-upper range.',
  config_tax_id_entity_mapping: 'A Tax ID listed here is a client-approved TIN. Remove it to see rule TAX_ID fail (506).',
  config_payer_insurance_group: 'Payers and insurance groups. is_disabled = true excludes the payer (505). Historic settlement rate drives the state routing rule (rate > 95 = Federal).',
  config_rarc_code: 'federal_idr_process_eligible = false makes the RARC exclude the case (503).',
  config_downcoded_service_code: 'A paid 835 code inside [lower, upper] of the 837 code matches as an approved downcode.',
  config_federal_timeline: 'timer_name "Claim Selection Window" (business days) and "NSA Effective Date" are read by Exclusion Validation and Exception Status Monitoring.',
  config_offer_amount: 'Reference Rate = Per Unit rows give the anesthesia per-unit amount for the listed modifiers (on_offer).',
  config_medicare_fee_schedule: 'Reference amount per service code (optional state / modifier). Missing = exception (Exclusion Validation).',
}

const inputFor = (type: string) => (type === 'date' ? 'date' : ['int2', 'int4', 'int8', 'numeric', 'float8'].includes(type) ? 'number' : 'text')

export default function Config() {
  const [tables, setTables] = useState<Row[]>([])
  const [meta, setMeta] = useState<any>(null)
  const [selected, setSelected] = useState('config_allowed_amount_threshold')
  const [client, setClient] = useState('QA-COMPREHENSIVE')
  const [clients, setClients] = useState<Row[]>([])
  const [search, setSearch] = useState('')
  const [data, setData] = useState<any>(null)
  const [form, setForm] = useState<{ mode: 'edit' | 'add'; values: Row; key: Row } | null>(null)
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [audit, setAudit] = useState<Row[] | null>(null)

  useEffect(() => { get('/api/config/tables').then(setTables); get('/api/meta').then(m => { setMeta(m); setClients(m.clients) }) }, [])
  const load = useCallback(() => {
    setForm(null)
    get(`/api/config/${selected}${qs({ client: client || undefined, search: search || undefined })}`).then(setData).catch(e => setMsg({ kind: 'err', text: e.message }))
  }, [selected, client, search])
  useEffect(() => { load() }, [selected, client])

  const send = async (fn: () => Promise<any>, ok: string) => {
    try { await fn(); setMsg({ kind: 'ok', text: ok }); load(); get('/api/config/tables').then(setTables) } catch (e: any) { setMsg({ kind: 'err', text: e.message }) }
  }
  const put = (url: string, body: unknown) => fetch(url, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then(async r => { if (!r.ok) throw new Error((await r.json()).error); })

  const cols: Row[] = data?.columns ?? []
  const key: string[] = data?.key ?? []
  const startEdit = (r: Row) => setForm({ mode: 'edit', values: { ...r }, key: Object.fromEntries(key.map(k => [k, r[k]])) })
  const startAdd = () => setForm({ mode: 'add', values: data?.has_client && client ? { client_id: client } : {}, key: {} })

  const grouped = ['Client', 'Universal', 'Setup'].map(g => [g, tables.filter(t => (TITLES[t.name]?.[1] ?? 'Setup') === g)] as const)

  return (
    <div className="page">
      <h1>Configuration</h1>
      <p className="sub">Edit the configuration tables the jobs read. Changes apply on the next job run and are recorded in the change history. Selected cases are not re-evaluated automatically: use "Send back for re-evaluation" on the case page.</p>
      {msg && <Alert kind={msg.kind}>{msg.text}</Alert>}
      <div style={{ display: 'grid', gridTemplateColumns: '290px 1fr', gap: 16 }}>
        <div className="card" style={{ padding: 10 }}>
          {grouped.map(([g, list]) => (
            <div key={g}><div className="muted" style={{ fontWeight: 700, margin: '8px 6px 2px' }}>{g === 'Client' ? 'Client specific' : g}</div>
              {list.map(t => (
                <div key={t.name} onClick={() => { setSelected(t.name); setAudit(null); setSearch(''); setMsg(null) }}
                  style={{ padding: '6px 8px', borderRadius: 6, cursor: 'pointer', background: selected === t.name ? '#dbe9fa' : 'transparent', display: 'flex', justifyContent: 'space-between', gap: 6 }}>
                  <span>{title(t.name)}</span><span className="muted">{t.rows}</span></div>))}</div>))}
          <div style={{ margin: '12px 6px 2px' }}><button className="secondary small" onClick={async () => setAudit(await get('/api/config/audit'))}>Change history</button></div>
        </div>

        <div>
          {audit ? (
            <div className="card"><h2>Change history (all configuration tables)</h2>
              <div className="scroll"><table><thead><tr><th>When</th><th>User</th><th>Table</th><th>Record</th><th>Field</th><th>From</th><th>To</th></tr></thead>
                <tbody>{audit.map((a, i) => <tr key={i}><td>{fmtTime(a.changed_at_utc)}</td><td>{a.user_id}</td><td>{a.category}</td><td>{a.record_key}</td><td>{a.field_name}</td><td className="mono">{a.prior_value}</td><td className="mono">{String(a.new_value ?? '').slice(0, 120)}</td></tr>)}</tbody></table></div></div>
          ) : (
            <div className="card">
              <h2>{title(selected)}</h2>
              {HELP[selected] && <div className="pill-help">{HELP[selected]}</div>}
              <div className="filters">
                {data?.has_client && <div><label>Client</label><select value={client} onChange={e => setClient(e.target.value)}>
                  <option value="">All clients</option>{clients.map(c => <option key={c.client_id}>{c.client_id}</option>)}</select></div>}
                <div><label>Search</label><input value={search} onChange={e => setSearch(e.target.value)} onKeyDown={e => e.key === 'Enter' && load()} placeholder="text in any column" /></div>
                <button onClick={load}>Search</button>
                <button className="secondary" onClick={startAdd}>+ Add row</button>
                <span className="muted">{data?.rows.length} row(s){data?.rows.length === 300 ? ' (first 300)' : ''}</span>
              </div>

              {form && (
                <div className="card" style={{ background: '#f7fafd' }}>
                  <h3>{form.mode === 'add' ? 'Add row' : 'Edit row'}</h3>
                  <div className="grid g3">
                    {cols.filter(c => form.mode === 'edit' || !c.generated).map(c => {
                      const isKey = form.mode === 'edit' && key.includes(c.name)
                      const v = form.values[c.name] ?? ''
                      const set = (x: any) => setForm({ ...form, values: { ...form.values, [c.name]: x } })
                      return (
                        <div className="field" key={c.name}>
                          <label>{c.name}{!c.nullable && !c.has_default && !c.generated && <span className="req"> *</span>}</label>
                          {c.type === 'bool' ? (
                            <select disabled={isKey} value={String(v)} onChange={e => set(e.target.value)}><option value="">(default)</option><option value="true">true</option><option value="false">false</option></select>
                          ) : (
                            <input disabled={isKey || (form.mode === 'edit' && c.generated)} type={inputFor(c.type)} step="any" value={c.type === 'date' ? String(v).slice(0, 10) : String(v)} onChange={e => set(e.target.value)} />
                          )}
                          <small>{c.type}{isKey ? ' - key' : ''}</small>
                        </div>
                      )
                    })}
                  </div>
                  <div className="row" style={{ marginTop: 10 }}>
                    <button onClick={() => send(() => form.mode === 'add'
                      ? post(`/api/config/${selected}`, { values: form.values })
                      : put(`/api/config/${selected}`, { key: form.key, values: form.values }), form.mode === 'add' ? 'Row added.' : 'Row saved.')}>Save</button>
                    {form.mode === 'edit' && <button className="secondary" onClick={() => confirm('Delete this row?') && send(() => post(`/api/config/${selected}/delete`, { key: form.key }), 'Row deleted.')}>Delete</button>}
                    <button className="secondary" onClick={() => setForm(null)}>Cancel</button>
                  </div>
                </div>
              )}

              <div className="scroll">
                <table>
                  <thead><tr><th />{cols.filter(c => !c.generated || key.includes(c.name)).map(c => <th key={c.name}>{c.name}</th>)}</tr></thead>
                  <tbody>
                    {data?.rows.map((r: Row, i: number) => (
                      <tr key={i} className="click" onClick={() => startEdit(r)}>
                        <td><a>edit</a></td>
                        {cols.filter(c => !c.generated || key.includes(c.name)).map(c => <td key={c.name} className={['numeric', 'int4', 'int8'].includes(c.type) ? 'num' : ''}>{r[c.name] === null ? <span className="muted">-</span> : String(r[c.name]).slice(0, c.type === 'date' ? 10 : 90)}</td>)}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
