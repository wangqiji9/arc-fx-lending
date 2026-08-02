// ─────────────────────────────────────────────────────────────────────────────
// Concurrency-limited, de-duplicating, multi-endpoint JSON-RPC dispatcher.
//
// What the Arc limiter actually does (measured 2026-08-02, plain curl):
//   • 40 back-to-back sequential requests → 40x HTTP 200. There is NO
//     requests-per-second limit worth working around.
//   • It caps CONCURRENCY instead. On rpc.testnet.arc.network, 5 parallel
//     requests all succeed; at 6 the extras come back HTTP 429 / JSON-RPC
//     -32011 ("request limit reached").
//   • The two alternate endpoints published by Arc absorb 24 parallel requests
//     with zero rejections and are no slower (drpc measured fastest).
//
// The previous implementation serialized every call through a single chain with
// a fixed 350ms gap, on the theory that the limiter was rate-based. That cost
// ~680ms of wall clock per request (latency + gap) and, because retries also
// queued behind that chain, one 429 pushed everything after it back. Measured
// homepage effect: 13 HTTP requests for 2 distinct payloads, 8.85s before the
// TVL figure appeared.
//
// So instead: allow real parallelism up to a per-endpoint budget, collapse
// identical in-flight reads into one request, and treat a 429 as a signal to
// briefly cool that endpoint down and retry elsewhere — never as a reason to
// slow down every other call.
// ─────────────────────────────────────────────────────────────────────────────

interface Endpoint {
  url: string
  /** Parallel requests allowed. Measured ceilings, minus a safety margin. */
  maxConcurrent: number
  inFlight: number
  /** Timestamp (ms) until which this endpoint is skipped after a rate-limit. */
  cooldownUntil: number
}

// Order = preference. Ties in load are broken by this order, so the first
// healthy entry absorbs normal traffic and the rest are failover capacity.
const ENDPOINTS: Endpoint[] = [
  { url: 'https://rpc.drpc.testnet.arc.network', maxConcurrent: 8, inFlight: 0, cooldownUntil: 0 },
  { url: 'https://rpc.blockdaemon.testnet.arc.network', maxConcurrent: 8, inFlight: 0, cooldownUntil: 0 },
  // Official endpoint last: it is the one with the tight concurrency cap.
  { url: 'https://rpc.testnet.arc.network', maxConcurrent: 3, inFlight: 0, cooldownUntil: 0 },
]

const MAX_ATTEMPTS = 6
const COOLDOWN_MS = 1_500
const SLOT_WAIT_MS = 100

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

/** Backoff applies to the one failed call only, never to the shared queue. */
const backoffMs = (attempt: number) =>
  Math.min(150 * 2 ** attempt, 1_200) + Math.floor(Math.random() * 100)

// ── endpoint slot management ─────────────────────────────────────────────────

const waiters: Array<() => void> = []

function pickEndpoint(skip: Set<string>): Endpoint | null {
  const now = Date.now()
  let best: Endpoint | null = null
  for (const e of ENDPOINTS) {
    if (skip.has(e.url) || e.cooldownUntil > now || e.inFlight >= e.maxConcurrent) continue
    if (!best || e.inFlight < best.inFlight) best = e
  }
  return best
}

/** Claims a slot on the best available endpoint, waiting if all are saturated. */
async function acquire(skip: Set<string>): Promise<Endpoint> {
  for (;;) {
    const e = pickEndpoint(skip)
    if (e) {
      e.inFlight++
      return e
    }
    // Every endpoint is busy or cooling down. Wake on the next release, or poll
    // shortly so an expiring cooldown is also noticed.
    await new Promise<void>((resolve) => {
      const wake = () => {
        clearTimeout(timer)
        resolve()
      }
      const timer = setTimeout(() => {
        const i = waiters.indexOf(wake)
        if (i >= 0) waiters.splice(i, 1)
        resolve()
      }, SLOT_WAIT_MS)
      waiters.push(wake)
    })
  }
}

function release(e: Endpoint): void {
  e.inFlight--
  waiters.shift()?.()
}

// ── rate-limit detection ────────────────────────────────────────────────────

function isRateLimited(status: number, json: unknown): boolean {
  if (status === 429) return true
  const arr = Array.isArray(json) ? json : [json]
  return arr.some((x) => (x as { error?: { code?: number } })?.error?.code === -32011)
}

// ── in-flight de-duplication ────────────────────────────────────────────────

// Read-only methods are safe to collapse: two callers asking the same question
// at the same moment can share one answer. Anything that could mutate state or
// depend on call ordering (nonces, sends) is deliberately excluded.
const DEDUPABLE = new Set([
  'eth_call',
  'eth_chainId',
  'eth_blockNumber',
  'eth_getBalance',
  'eth_getCode',
  'eth_getBlockByNumber',
  'eth_gasPrice',
  'eth_feeHistory',
  'eth_maxPriorityFeePerGas',
])

const inFlight = new Map<string, Promise<unknown>>()

function dedupKey(body: unknown): string | null {
  const items = Array.isArray(body) ? body : [body]
  const parts: string[] = []
  for (const it of items) {
    const { method, params } = (it ?? {}) as { method?: string; params?: unknown }
    if (!method || !DEDUPABLE.has(method)) return null
    parts.push(`${method}:${JSON.stringify(params ?? [])}`)
  }
  return parts.join('|')
}

// ── dispatch ────────────────────────────────────────────────────────────────

type Attempt = { ok: true; json: unknown } | { ok: false }

async function attemptOnce(body: unknown, skip: Set<string>): Promise<Attempt> {
  const ep = await acquire(skip)
  try {
    const res = await fetch(ep.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const json = await res.json()
    if (isRateLimited(res.status, json)) {
      ep.cooldownUntil = Date.now() + COOLDOWN_MS
      skip.add(ep.url)
      return { ok: false }
    }
    return { ok: true, json }
  } catch {
    // Network/DNS/5xx-shaped failure: avoid this endpoint for the retry.
    skip.add(ep.url)
    return { ok: false }
  } finally {
    release(ep) // released before any backoff sleep, so a slot is never idled
  }
}

async function dispatch(body: unknown): Promise<unknown> {
  const skip = new Set<string>()
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    // Once every endpoint has rejected us, start over rather than give up.
    if (skip.size >= ENDPOINTS.length) skip.clear()
    const r = await attemptOnce(body, skip)
    if (r.ok) return r.json
    await sleep(backoffMs(attempt))
  }
  throw new Error('Arc RPC: all endpoints rate-limited or unreachable')
}

export function queuedRpc(body: unknown): Promise<unknown> {
  const key = dedupKey(body)
  if (key === null) return dispatch(body)

  const existing = inFlight.get(key)
  if (existing) return existing

  const p = dispatch(body)
  inFlight.set(key, p)
  // Clear once settled so the next render cycle issues a fresh read.
  void p.then(
    () => inFlight.delete(key),
    () => inFlight.delete(key),
  )
  return p
}
