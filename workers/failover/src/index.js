// Failover Worker (module syntax, no dependencies, one file: OpenTofu uploads
// this file as-is with cloudflare_workers_script).
//
// Runs on routes like ntfy.example.com/*. For each request:
//   1. The request goes to the Home origin. fetch() to the Worker's own
//      hostname is sent to the zone's origin (it does not re-enter this
//      Worker) as long as the global_fetch_strictly_public compatibility flag
//      is NOT set.
//   2. If the origin answers 5xx (including Cloudflare's 52x), answers
//      Traefik's own "404 page not found" (the app container is stopped, so
//      Traefik has no route for the host; the app's own 404s are JSON and are
//      NOT treated as failures), does not send response headers within
//      PRIMARY_TIMEOUT_MS, or the fetch throws, the same request is sent to
//      the standby hostname (the cluster copy).
//   3. Subscriptions (ntfy JSON/SSE/raw streams, websockets) follow the same
//      rule, so the phone's one subscription to ntfy.example.com lands on the
//      standby while Home is down. Only the wait for response headers is
//      timed; a stream that is open is never cut on the origin side.
//      A stream (JSON/SSE/raw) served by the STANDBY is closed after
//      STANDBY_STREAM_MAX_MS: the app reconnects by itself, and the reconnect
//      tries Home first again. So once Home is back, subscribers return
//      within that time. (A websocket on the standby stays until the app
//      reconnects on its own; the ntfy app's default is the JSON stream.)
//   4. /v1/health never fails over: monitors (Uptime Kuma, ChatOps, Alloy)
//      must see Home's real state, not the standby's. The standby has its
//      own health URL (ntfy-standby.example.com/v1/health).
//
// Bindings (set by OpenTofu):
//   STANDBY_HOSTS          JSON object {"ntfy.example.com": "ntfy-standby.example.com"}
//   PRIMARY_TIMEOUT_MS     string, default 4000
//   STANDBY_STREAM_MAX_MS  string, default 300000 (5 minutes)

export const DEFAULT_TIMEOUT_MS = 4000;
export const STANDBY_TIMEOUT_MS = 15000;
export const DEFAULT_STANDBY_STREAM_MAX_MS = 5 * 60 * 1000;
// Bodies larger than this (or of unknown length) are not buffered, so such
// requests go to the origin once, without failover.
export const MAX_REPLAY_BODY = 16 * 1024 * 1024;

const STREAM_SUFFIX = /\/(json|sse|raw|ws)$/;
// Paths that always go to the origin only (see 4. above).
export const ORIGIN_ONLY_PATHS = new Set(["/v1/health"]);
const POLL_VALUES = new Set(["1", "true", "yes"]);

export function isStreaming(request) {
  const upgrade = (request.headers.get("upgrade") || "").toLowerCase();
  if (upgrade === "websocket") return true;
  const accept = (request.headers.get("accept") || "").toLowerCase();
  if (accept.includes("text/event-stream")) return true;
  if (request.method !== "GET") return false;
  const url = new URL(request.url);
  if (!STREAM_SUFFIX.test(url.pathname)) return false;
  // ?poll=1 returns cached messages and closes: a normal request.
  const poll = (url.searchParams.get("poll") || "").toLowerCase();
  return !POLL_VALUES.has(poll);
}

// Traefik answers a host it has no router for (container stopped) with this
// exact plain-text body. ntfy's own 404s are JSON, so they never match.
export async function isRouteMissing(response) {
  if (response.status !== 404) return false;
  const type = (response.headers.get("content-type") || "").toLowerCase();
  if (!type.startsWith("text/plain")) return false;
  const length = Number(response.headers.get("content-length"));
  if (Number.isFinite(length) && length > 64) return false;
  try {
    return (await response.clone().text()).trim() === "404 page not found";
  } catch {
    return false;
  }
}

function standbyHosts(env) {
  const raw = env && env.STANDBY_HOSTS;
  if (!raw) return {};
  if (typeof raw === "string") {
    try {
      return JSON.parse(raw);
    } catch {
      return {};
    }
  }
  return raw;
}

function forwardHeaders(request) {
  const headers = new Headers(request.headers);
  // fetch() derives Host from the URL; a stale Host would be wrong for the standby.
  headers.delete("host");
  return headers;
}

async function fetchWithTimeout(fetchFn, url, init, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    // The timer only covers the wait for response headers: once they arrive
    // it is cleared, so a slow body is never cut off.
    return await fetchFn(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function markStandby(response, reason) {
  // A websocket upgrade (101) must be returned as it is.
  if (response.status === 101 || response.webSocket) return response;
  const out = new Response(response.body, response);
  out.headers.set("x-failover", "standby");
  out.headers.set("x-failover-reason", reason);
  return out;
}

// Pass a streaming body through, but end it after maxMs. The app sees a
// normal end of stream and reconnects (to Home first).
export function limitStream(response, maxMs, waitUntil) {
  if (!response.body || !(maxMs > 0)) return response;
  const { readable, writable } = new TransformStream();
  const reader = response.body.getReader();
  const writer = writable.getWriter();
  const timer = setTimeout(() => {
    reader.cancel("standby stream time limit").catch(() => {});
  }, maxMs);
  const pump = (async () => {
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        await writer.write(value);
      }
      await writer.close();
    } catch {
      // client went away or the standby broke the stream
      await reader.cancel().catch(() => {});
      await writer.abort().catch(() => {});
    } finally {
      clearTimeout(timer);
    }
  })();
  if (waitUntil) waitUntil(pump);
  return new Response(readable, response);
}

export async function handle(request, env, fetchFn = fetch, ctx) {
  const url = new URL(request.url);
  const standbyHost = standbyHosts(env)[url.hostname];
  if (!standbyHost || ORIGIN_ONLY_PATHS.has(url.pathname)) {
    return fetchFn(request);
  }
  const streaming = isStreaming(request);

  let body = null;
  if (request.method !== "GET" && request.method !== "HEAD" && request.body !== null) {
    const length = Number(request.headers.get("content-length"));
    if (!request.headers.has("content-length") || !Number.isFinite(length) || length > MAX_REPLAY_BODY) {
      return fetchFn(request);
    }
    body = await request.arrayBuffer();
  }

  const init = () => ({
    method: request.method,
    headers: forwardHeaders(request),
    body,
    redirect: "manual",
  });

  const timeoutMs = Number(env && env.PRIMARY_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS;
  let primary = null;
  let reason;
  try {
    primary = await fetchWithTimeout(fetchFn, url.toString(), init(), timeoutMs);
    if (primary.status < 500 && !(await isRouteMissing(primary))) return primary;
    reason = primary.status === 404 ? "origin has no route" : `origin ${primary.status}`;
  } catch (err) {
    reason = err && err.name === "AbortError" ? "origin timeout" : "origin network error";
  }

  const standbyUrl = new URL(url);
  standbyUrl.hostname = standbyHost;
  try {
    const standby = await fetchWithTimeout(fetchFn, standbyUrl.toString(), init(), STANDBY_TIMEOUT_MS);
    if (standby.status >= 500 && primary) {
      // Both failed: show the origin's own error, not the standby's.
      await cancelBody(standby);
      return primary;
    }
    if (primary) await cancelBody(primary);
    const maxMs = Number(env && env.STANDBY_STREAM_MAX_MS) || DEFAULT_STANDBY_STREAM_MAX_MS;
    const out = markStandby(standby, reason);
    if (streaming && out.status === 200) {
      return limitStream(out, maxMs, ctx && ctx.waitUntil ? (p) => ctx.waitUntil(p) : undefined);
    }
    return out;
  } catch {
    if (primary) return primary;
    return new Response(`Origin and standby both unavailable (${reason})\n`, {
      status: 502,
      headers: { "content-type": "text/plain; charset=utf-8", "x-failover": "failed" },
    });
  }
}

async function cancelBody(response) {
  try {
    if (response.body) await response.body.cancel();
  } catch {
    // already consumed or closed
  }
}

export default {
  async fetch(request, env, ctx) {
    return handle(request, env, fetch, ctx);
  },
};
