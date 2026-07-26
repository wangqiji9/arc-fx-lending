// ─────────────────────────────────────────────────────────────────────────────
// Global single-flight, rate-limited RPC queue for the Arc Testnet public RPC.
//
// Why this exists: the public endpoint (https://rpc.testnet.arc.network) enforces
// an aggressive rate limit. Empirically ~1 in 3 sequential requests and ~4 of 5
// concurrent requests are rejected with HTTP 429 / JSON-RPC error -32011
// ("request limit reached"). On page mount the app fires many reads at once, so
// most were being rejected and dependent UI values (TVL, balances, prices) fell
// back to 0.
//
// This module serializes ALL outbound JSON-RPC calls through one queue: at most
// one in-flight request, a minimum gap between requests, and backoff+retry when
// the node signals rate limiting. Combined with Multicall3 batching (see wagmi.ts)
// this keeps the request count low and every read eventually resolves.
// ─────────────────────────────────────────────────────────────────────────────

const RPC_URL = 'https://rpc.testnet.arc.network'

// Minimum spacing between successive requests (ms). Tuned against the observed
// limiter: smaller values start tripping 429s again.
const MIN_GAP_MS = 350
const MAX_RETRIES = 15
const BASE_BACKOFF_MS = 300
const MAX_BACKOFF_STEPS = 6

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

// Tail of the single-flight chain. Each request waits for the previous one to
// finish (plus MIN_GAP_MS) before it fires, regardless of success/failure.
let chain: Promise<unknown> = Promise.resolve()

function isRateLimited(status: number, json: unknown): boolean {
  if (status === 429) return true
  const arr = Array.isArray(json) ? json : [json]
  return arr.some(
    (x) => (x as { error?: { code?: number } })?.error?.code === -32011,
  )
}

export function queuedRpc(body: unknown): Promise<unknown> {
  const run = chain.then(async () => {
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const res = await fetch(RPC_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      const json = await res.json()
      if (!isRateLimited(res.status, json)) return json
      const step = Math.min(attempt + 1, MAX_BACKOFF_STEPS)
      await sleep(BASE_BACKOFF_MS * step)
    }
    throw new Error('Arc RPC: rate limit — exhausted retries')
  })

  // Advance the chain after this request settles, keeping a fixed gap. Swallow
  // errors here so one failure doesn't break the queue for later requests.
  chain = run.then(
    () => sleep(MIN_GAP_MS),
    () => sleep(MIN_GAP_MS),
  )
  return run
}
