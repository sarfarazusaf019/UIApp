export type Row = Record<string, any>

async function call<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, { headers: { 'content-type': 'application/json' }, ...init })
  const text = await res.text()
  const body = text ? JSON.parse(text) : null
  if (!res.ok) throw new Error(body?.error ?? `${res.status} ${res.statusText}`)
  return body as T
}

export const get = <T = any>(url: string) => call<T>(url)
export const post = <T = any>(url: string, body: unknown) => call<T>(url, { method: 'POST', body: JSON.stringify(body) })

export const qs = (params: Record<string, string | undefined>) => {
  const p = new URLSearchParams()
  Object.entries(params).forEach(([k, v]) => v && p.set(k, v))
  const s = p.toString()
  return s ? `?${s}` : ''
}

export const JOBS = [
  { code: 'CLAIM_REMIT_MATCHING', name: 'Claim-remit matching', short: 'Matching' },
  { code: 'EXCEPTION_AGING', name: 'Exception Status Monitoring', short: 'Status Monitoring' },
  { code: 'EXCLUSION_VALIDATION', name: 'Exclusion Validation', short: 'Exclusion Validation' },
  { code: 'SYSTEMIC_NOT_PURSUED', name: 'Systemic not pursued', short: 'Systemic' },
  { code: 'COOL_OFF_STATUS', name: 'Cool-off status', short: 'Cool-off' },
  { code: 'PRELIMINARY_BATCHING', name: 'Preliminary batching', short: 'Batching' },
]

export const fmtDate = (v?: string | null) => (v ? String(v).slice(0, 10) : '')
export const fmtTime = (v?: string | null) => (v ? new Date(v).toLocaleString() : '')
export const money = (v: any) => (v === null || v === undefined ? '' : Number(v).toLocaleString(undefined, { style: 'currency', currency: 'USD' }))
