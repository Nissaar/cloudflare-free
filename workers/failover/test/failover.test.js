import { test } from "node:test";
import assert from "node:assert/strict";
import { handle, isRouteMissing, isStreaming, limitStream } from "../src/index.js";

const env = {
  STANDBY_HOSTS: JSON.stringify({ "ntfy.example.com": "ntfy-standby.example.com" }),
  PRIMARY_TIMEOUT_MS: "50",
};

// Fake fetch: `routes` maps hostname -> handler(url, init) returning a Response,
// throwing, or never settling. Records every call.
function fakeFetch(routes) {
  const calls = [];
  const fn = async (input, init = {}) => {
    const isRequest = input instanceof Request;
    const url = new URL(isRequest ? input.url : input);
    calls.push({ url, init, original: isRequest ? input : null });
    const route = routes[url.hostname];
    if (!route) throw new Error(`unexpected host ${url.hostname}`);
    return route(url, init);
  };
  fn.calls = calls;
  return fn;
}

const ok = (text = "ok") => () => new Response(text, { status: 200 });
const status = (code) => () => new Response(`err ${code}`, { status: code });
const networkError = () => () => {
  throw new TypeError("fetch failed");
};
// Settles only when aborted, like an origin that never answers.
const hang = () => (_url, init) =>
  new Promise((_resolve, reject) => {
    init.signal.addEventListener("abort", () => {
      const err = new Error("aborted");
      err.name = "AbortError";
      reject(err);
    });
  });

test("origin 200 is returned and the standby is never called", async () => {
  const f = fakeFetch({ "ntfy.example.com": ok("home") });
  const res = await handle(new Request("https://ntfy.example.com/v1/account"), env, f);
  assert.equal(res.status, 200);
  assert.equal(await res.text(), "home");
  assert.equal(f.calls.length, 1);
  assert.equal(res.headers.get("x-failover"), null);
});

test("origin 4xx is not a failure", async () => {
  const f = fakeFetch({ "ntfy.example.com": status(403) });
  const res = await handle(new Request("https://ntfy.example.com/topic/auth"), env, f);
  assert.equal(res.status, 403);
  assert.equal(f.calls.length, 1);
});

const traefik404 = () => () =>
  new Response("404 page not found\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });

test("Traefik's 'no route' 404 (container stopped) fails over", async () => {
  const f = fakeFetch({ "ntfy.example.com": traefik404(), "ntfy-standby.example.com": ok("cluster") });
  const res = await handle(new Request("https://ntfy.example.com/general/json?poll=1"), env, f);
  assert.equal(res.status, 200);
  assert.equal(await res.text(), "cluster");
  assert.equal(res.headers.get("x-failover"), "standby");
  assert.equal(res.headers.get("x-failover-reason"), "origin has no route");
});

test("the app's own JSON 404 is not a failure", async () => {
  const json404 = () => () =>
    new Response('{"code":40401,"http":404,"error":"not found"}', { status: 404, headers: { "content-type": "application/json" } });
  const f = fakeFetch({ "ntfy.example.com": json404(), "ntfy-standby.example.com": ok("cluster") });
  const res = await handle(new Request("https://ntfy.example.com/nope"), env, f);
  assert.equal(res.status, 404);
  assert.equal(f.calls.length, 1);
});

test("isRouteMissing only matches Traefik's exact text", async () => {
  assert.equal(await isRouteMissing(await traefik404()()), true);
  assert.equal(await isRouteMissing(new Response("404 page not found\n", { status: 200 })), false);
  assert.equal(await isRouteMissing(new Response("something else", { status: 404, headers: { "content-type": "text/plain" } })), false);
});

test("origin 5xx (Cloudflare 521) fails over, keeping path and query", async () => {
  const f = fakeFetch({ "ntfy.example.com": status(521), "ntfy-standby.example.com": ok("cluster") });
  const res = await handle(new Request("https://ntfy.example.com/alerts/json?poll=1&since=10m"), env, f);
  assert.equal(res.status, 200);
  assert.equal(await res.text(), "cluster");
  assert.equal(res.headers.get("x-failover"), "standby");
  assert.equal(res.headers.get("x-failover-reason"), "origin 521");
  assert.equal(f.calls[1].url.toString(), "https://ntfy-standby.example.com/alerts/json?poll=1&since=10m");
});

test("/v1/health never fails over: monitors must see Home's real state", async () => {
  const f = fakeFetch({ "ntfy.example.com": status(521), "ntfy-standby.example.com": ok("cluster") });
  const req = new Request("https://ntfy.example.com/v1/health");
  const res = await handle(req, env, f);
  assert.equal(res.status, 521);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].original, req);
});

test("network error fails over", async () => {
  const f = fakeFetch({ "ntfy.example.com": networkError(), "ntfy-standby.example.com": ok("cluster") });
  const res = await handle(new Request("https://ntfy.example.com/v1/account"), env, f);
  assert.equal(await res.text(), "cluster");
  assert.equal(res.headers.get("x-failover-reason"), "origin network error");
});

test("timeout fails over", async () => {
  const f = fakeFetch({ "ntfy.example.com": hang(), "ntfy-standby.example.com": ok("cluster") });
  const started = Date.now();
  const res = await handle(new Request("https://ntfy.example.com/"), env, f);
  assert.equal(await res.text(), "cluster");
  assert.equal(res.headers.get("x-failover-reason"), "origin timeout");
  assert.ok(Date.now() - started < 2000);
});

test("publish body is replayed byte for byte to the standby", async () => {
  const seen = [];
  const f = fakeFetch({
    "ntfy.example.com": status(502),
    "ntfy-standby.example.com": (_url, init) => {
      seen.push(init);
      return new Response("{}", { status: 200 });
    },
  });
  const req = new Request("https://ntfy.example.com/alerts", {
    method: "POST",
    body: "disk full",
    headers: { "content-length": "9", title: "home", host: "ntfy.example.com" },
  });
  const res = await handle(req, env, f);
  assert.equal(res.status, 200);
  assert.equal(seen[0].method, "POST");
  assert.equal(new TextDecoder().decode(seen[0].body), "disk full");
  assert.equal(seen[0].headers.get("title"), "home");
  assert.equal(seen[0].headers.get("host"), null);
  assert.equal(seen[0].redirect, "manual");
});

test("both down: origin's own 5xx is returned", async () => {
  const f = fakeFetch({ "ntfy.example.com": status(522), "ntfy-standby.example.com": status(530) });
  const res = await handle(new Request("https://ntfy.example.com/"), env, f);
  assert.equal(res.status, 522);
});

test("both unreachable: 502 from the Worker", async () => {
  const f = fakeFetch({ "ntfy.example.com": networkError(), "ntfy-standby.example.com": networkError() });
  const res = await handle(new Request("https://ntfy.example.com/"), env, f);
  assert.equal(res.status, 502);
  assert.equal(res.headers.get("x-failover"), "failed");
});

const streams = () => [
  ["JSON stream", new Request("https://ntfy.example.com/alerts/json")],
  ["SSE stream", new Request("https://ntfy.example.com/alerts,infra/sse")],
  ["raw stream", new Request("https://ntfy.example.com/alerts/raw")],
  ["Accept: text/event-stream", new Request("https://ntfy.example.com/x", { headers: { accept: "text/event-stream" } })],
];

for (const [name, req] of streams()) {
  test(`${name}: origin up -> the origin's stream is returned as it is`, async () => {
    const f = fakeFetch({ "ntfy.example.com": ok("home-stream") });
    const res = await handle(req, env, f);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "home-stream");
    assert.equal(f.calls.length, 1);
    assert.equal(res.headers.get("x-failover"), null);
  });
}

for (const [name, req] of streams()) {
  test(`${name}: origin down -> the subscription goes to the standby`, async () => {
    const f = fakeFetch({ "ntfy.example.com": status(502), "ntfy-standby.example.com": ok("cluster-stream") });
    const res = await handle(req, env, f);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "cluster-stream");
    assert.equal(res.headers.get("x-failover"), "standby");
    assert.equal(f.calls[1].url.hostname, "ntfy-standby.example.com");
    assert.equal(f.calls[1].url.pathname, new URL(req.url).pathname);
  });
}

test("subscription timeout on the origin also fails over (headers only are timed)", async () => {
  const f = fakeFetch({ "ntfy.example.com": hang(), "ntfy-standby.example.com": ok("cluster") });
  const res = await handle(new Request("https://ntfy.example.com/alerts/json"), env, f);
  assert.equal(await res.text(), "cluster");
  assert.equal(res.headers.get("x-failover-reason"), "origin timeout");
});

test("a standby stream is closed after STANDBY_STREAM_MAX_MS so the app reconnects to Home", async () => {
  let controller;
  const endless = new ReadableStream({
    start(c) {
      controller = c;
      c.enqueue(new TextEncoder().encode('{"event":"open"}\n'));
    },
  });
  const f = fakeFetch({
    "ntfy.example.com": networkError(),
    "ntfy-standby.example.com": () => new Response(endless, { status: 200 }),
  });
  const started = Date.now();
  const res = await handle(new Request("https://ntfy.example.com/alerts/json"), { ...env, STANDBY_STREAM_MAX_MS: "80" }, f);
  assert.equal(res.headers.get("x-failover"), "standby");
  const text = await res.text(); // resolves only because the Worker ends the stream
  assert.equal(text, '{"event":"open"}\n');
  assert.ok(Date.now() - started < 2000);
  assert.ok(controller);
});

test("a stream from the origin is never cut", async () => {
  let cancelled = false;
  const body = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode("x"));
    },
    cancel() {
      cancelled = true;
    },
  });
  const f = fakeFetch({ "ntfy.example.com": () => new Response(body, { status: 200 }) });
  const res = await handle(new Request("https://ntfy.example.com/alerts/json"), { ...env, STANDBY_STREAM_MAX_MS: "20" }, f);
  const reader = res.body.getReader();
  assert.equal(new TextDecoder().decode((await reader.read()).value), "x");
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(cancelled, false);
  await reader.cancel();
});

test("limitStream passes the body through and ends it on time", async () => {
  const body = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode("a"));
    },
  });
  const waited = [];
  const res = limitStream(new Response(body, { status: 200, headers: { "x-a": "1" } }), 30, (p) => waited.push(p));
  assert.equal(res.headers.get("x-a"), "1");
  assert.equal(await res.text(), "a");
  assert.equal(waited.length, 1);
});

test("websocket: origin down -> upgrade sent to the standby, Upgrade header kept", async () => {
  const seen = [];
  const f = fakeFetch({
    "ntfy.example.com": status(521),
    "ntfy-standby.example.com": (_url, init) => {
      seen.push(init);
      // Node cannot build a real 101; the Worker must pass the standby's
      // response through without re-wrapping it when it is an upgrade.
      const res = new Response(null, { status: 200 });
      Object.defineProperty(res, "status", { value: 101 });
      return res;
    },
  });
  const req = new Request("https://ntfy.example.com/alerts/ws", { headers: { upgrade: "websocket" } });
  const res = await handle(req, env, f);
  assert.equal(res.status, 101);
  assert.equal(res.headers.get("x-failover"), null);
  assert.equal(seen[0].headers.get("upgrade"), "websocket");
  assert.equal(f.calls[1].url.toString(), "https://ntfy-standby.example.com/alerts/ws");
});

test("websocket: origin up -> origin's answer returned", async () => {
  const f = fakeFetch({ "ntfy.example.com": status(426) });
  const req = new Request("https://ntfy.example.com/alerts/ws", { headers: { upgrade: "websocket" } });
  const res = await handle(req, env, f);
  assert.equal(res.status, 426);
  assert.equal(f.calls.length, 1);
});

test("isStreaming: poll=1 and publishing are not streams", () => {
  assert.equal(isStreaming(new Request("https://ntfy.example.com/a/json?poll=1")), false);
  assert.equal(isStreaming(new Request("https://ntfy.example.com/a/json?poll=yes")), false);
  assert.equal(isStreaming(new Request("https://ntfy.example.com/a", { method: "POST", body: "x" })), false);
  assert.equal(isStreaming(new Request("https://ntfy.example.com/a/json?since=all")), true);
});

test("hostname without a standby passes through", async () => {
  const f = fakeFetch({ "other.example.com": status(500) });
  const req = new Request("https://other.example.com/");
  const res = await handle(req, env, f);
  assert.equal(res.status, 500);
  assert.equal(f.calls[0].original, req);
});

test("body of unknown length is sent once, without failover", async () => {
  const f = fakeFetch({ "ntfy.example.com": status(502), "ntfy-standby.example.com": ok() });
  const stream = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode("chunk"));
      c.close();
    },
  });
  const req = new Request("https://ntfy.example.com/a", { method: "PUT", body: stream, duplex: "half" });
  const res = await handle(req, env, f);
  assert.equal(res.status, 502);
  assert.equal(f.calls.length, 1);
});
