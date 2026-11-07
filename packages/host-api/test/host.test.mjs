import { test } from "node:test";
import assert from "node:assert/strict";
import { HostAPI, HostError } from "../dist/index.js";
import { createMacOSTransport } from "../dist/macos.js";
function harness(send) {
  let listener;
  return {
    send,
    subscribe(fn) {
      listener = fn;
      return () => {
        listener = undefined;
      };
    },
    emit(x) {
      listener?.(x);
    },
    dispose() {},
  };
}
test("concurrent replies are isolated and envelopes validated", async () => {
  const calls = [];
  const t = harness(
    (r) => new Promise((resolve) => calls.push({ r, resolve })),
  );
  const api = new HostAPI(t);
  const a = api.request("a"),
    b = api.request("b");
  await new Promise((resolve) => setImmediate(resolve));
  calls[1].resolve({ version: 1, id: calls[1].r.id, result: 2 });
  calls[0].resolve({ version: 1, id: calls[0].r.id, result: 1 });
  assert.deepEqual(await Promise.all([a, b]), [1, 2]);
  const c = api.request("c");
  await new Promise((resolve) => setImmediate(resolve));
  calls[2].resolve({ version: 2, id: calls[2].r.id, result: null });
  await assert.rejects(c, { code: "invalid_response" });
  api.dispose();
});
test("error shape, timeout, and disposal reject", async () => {
  let t = harness(async (r) => ({
    version: 1,
    id: r.id,
    error: { code: 3, message: "bad" },
  }));
  let api = new HostAPI(t);
  await assert.rejects(api.request("x"), { code: "invalid_response" });
  api.dispose();
  t = harness(() => new Promise(() => {}));
  api = new HostAPI(t, 5);
  await assert.rejects(api.request("x"), { code: "timeout" });
  const pending = api.request("x");
  api.dispose();
  await assert.rejects(pending, { code: "disposed" });
  await assert.rejects(api.request("x"), { code: "disposed" });
});
test("events unsubscribe and dispose cleanly", () => {
  const t = harness(async () => null),
    api = new HostAPI(t);
  let count = 0;
  const off = api.subscribe(() => count++);
  t.emit({
    version: 1,
    event: "state.changed",
    revision: "1",
    domains: ["quota"],
  });
  t.emit({ version: 2, event: "state.changed", revision: "2", domains: [] });
  off();
  t.emit({ version: 1, event: "state.changed", revision: "3", domains: [] });
  assert.equal(count, 1);
  api.dispose();
});
test("macOS adapter removes its callback and detects unavailable host", async () => {
  globalThis.window = {};
  const t = createMacOSTransport();
  await assert.rejects(
    t.send({ version: 1, id: "a", method: "x", params: {} }),
    { code: "unavailable" },
  );
  assert.throws(() => createMacOSTransport(), HostError);
  t.dispose();
  assert.equal(window.__ccbarHostReceiveEvent, undefined);
  delete globalThis.window;
});

test("shared wire fixture is accepted", async () => {
  const { readFile } = await import("node:fs/promises");
  const fixture = JSON.parse(
    await readFile(new URL("../fixtures/wire.json", import.meta.url), "utf8"),
  );
  const { parseResponse, parseEvent } = await import("../dist/index.js");
  assert.deepEqual(
    parseResponse(fixture.success, fixture.request.id),
    fixture.success.result,
  );
  assert.throws(() => parseResponse(fixture.error, fixture.request.id), {
    code: "invalid_params",
  });
  assert.deepEqual(parseEvent(fixture.event), fixture.event);
});

test("macOS handler forwards requests, errors, and event subscriptions", async () => {
  let captured;
  globalThis.window = {
    webkit: {
      messageHandlers: {
        ccbarHost: {
          postMessage(request) {
            captured = request;
            return Promise.resolve({
              version: 1,
              id: request.id,
              result: null,
            });
          },
        },
      },
    },
  };
  const t = createMacOSTransport(),
    api = new HostAPI(t);
  assert.equal(await api.request("platform.test", { a: 1 }), null);
  assert.deepEqual(captured.params, { a: 1 });
  let seen = 0;
  let off = api.subscribe(() => seen++);
  const receive = window.__ccbarHostReceiveEvent;
  receive({
    version: 1,
    event: "state.changed",
    revision: "1",
    domains: ["quota"],
  });
  off();
  off = api.subscribe(() => seen++);
  receive({
    version: 1,
    event: "state.changed",
    revision: "2",
    domains: ["quota"],
  });
  off();
  assert.equal(seen, 2);
  window.webkit.messageHandlers.ccbarHost.postMessage = () => {
    throw new Error("bridge failed");
  };
  await assert.rejects(api.request("x"), /bridge failed/);
  api.dispose();
  receive({ version: 1, event: "state.changed", revision: "3", domains: [] });
  assert.equal(seen, 2);
  delete globalThis.window;
});
test("typed methods reject malformed payloads and malformed envelopes", async () => {
  const t = harness(async (r) => ({
    version: 1,
    id: r.id,
    result: { privacyMode: false },
  }));
  const api = new HostAPI(t);
  await assert.rejects(api.settingsGet(), { code: "invalid_response" });
  await assert.rejects(api.usageOverview({ from: "a", to: "b" }), {
    code: "invalid_response",
  });
  api.dispose();
  const { parseResponse } = await import("../dist/index.js");
  for (const v of [
    { version: 1, id: "wrong", result: null },
    { version: 1, id: "x", result: null, error: { code: "x", message: "x" } },
    { version: 1, id: "x", error: { code: "x" } },
  ])
    assert.throws(() => parseResponse(v, "x"), { code: "invalid_response" });
});

test("dispose before dispatch prevents side effects", async () => {
  let sends = 0;
  const api = new HostAPI(
    harness(async () => {
      sends++;
      return null;
    }),
  );
  const pending = api.settingsUpdate({ privacyMode: true });
  api.dispose();
  await assert.rejects(pending, { code: "disposed" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(sends, 0);
});

test("typed RPC methods accept host DTOs and reject invalid shapes", async () => {
  const totals = {
    inputTokens: 1,
    outputTokens: 2,
    cacheReadTokens: 0,
    cacheCreationTokens: 0,
    totalTokens: 3,
    costUSD: "0.01",
    requestCount: 1,
    hasUnpricedUsage: false,
    costIncomplete: false,
  };
  const responses = {
    "host.describe": {
      platform: "macos",
      timeZone: "Asia/Shanghai",
      capabilities: ["quota.snapshot"],
    },
    "usage.overview": { totals, samples: [{ date: "2026-01-01", totals }] },
    "quota.snapshot": {
      services: [
        {
          service: "codex",
          refresh: {
            inFlight: false,
            backoffUntil: null,
            lastSuccessAt: null,
            lastAttemptAt: null,
            failed: false,
            source: null,
          },
          snapshot: {
            fetchedAt: "2026-01-01T00:00:00Z",
            planType: null,
            isUnlimited: null,
            limits: [
              {
                id: "x",
                kind: "primary",
                displayName: null,
                usedPercent: 50,
                resetsAt: null,
                windowSeconds: null,
                isActive: null,
              },
            ],
          },
        },
      ],
    },
    "quota.refresh": { services: [] },
    "settings.get": { privacyMode: false, useInstalledAppIcons: true },
    "settings.update": { privacyMode: true, useInstalledAppIcons: true },
    "platform.pickDirectory": { path: null },
    "platform.revealPath": {},
    "platform.setLaunchAtLogin": { enabled: true, requiresApproval: false },
  };
  const calls = [];
  const api = new HostAPI(
    harness(async (r) => {
      calls.push(r);
      return { version: 1, id: r.id, result: responses[r.method] };
    }),
  );
  await api.describe();
  await api.usageOverview({ from: "a", to: "b" });
  await api.quotaSnapshot();
  await api.quotaRefresh();
  await api.settingsGet();
  await api.settingsUpdate({ privacyMode: true });
  await api.pickDirectory();
  await api.revealPath("/tmp");
  await api.setLaunchAtLogin(true);
  assert.deepEqual(
    calls.map((x) => x.method),
    Object.keys(responses),
  );
  assert.deepEqual(calls[7].params, { path: "/tmp" });
  responses["quota.snapshot"] = { services: [{ service: "x", snapshot: {} }] };
  await assert.rejects(api.quotaSnapshot(), { code: "invalid_response" });
  responses["host.describe"] = { platform: "macos", capabilities: [1] };
  await assert.rejects(api.describe(), { code: "invalid_response" });
  responses["platform.pickDirectory"] = {};
  await assert.rejects(api.pickDirectory(), { code: "invalid_response" });
  responses["platform.revealPath"] = null;
  await assert.rejects(api.revealPath("/tmp"), { code: "invalid_response" });
  responses["platform.setLaunchAtLogin"] = { enabled: true };
  await assert.rejects(api.setLaunchAtLogin(true), {
    code: "invalid_response",
  });
  api.dispose();
});
