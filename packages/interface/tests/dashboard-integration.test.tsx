import {
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { beforeEach, expect, it, vi } from "vitest";
import usage from "../../host-api/fixtures/window-usage.json";
import { DashboardQueryScope } from "@/features/stats/dashboard-query";
import { DashboardPage } from "@/features/stats/dashboard-page";
import { LanguageProvider } from "@/lib/i18n";
import { TooltipProvider } from "@/components/ui/tooltip";
const total = usage["window.usage.overview"].totals;
const status = usage["window.usage.overview"].status;
const coverage = {
  precision: "event",
  incomplete: false,
  unlocatedTotals: total,
  message: null,
};
const resolvedRange = {
  from: "2026-01-01T00:00:00Z",
  to: "2026-11-01T00:00:00Z",
  asOf: "2026-11-01T00:00:00Z",
  timeZone: "UTC",
  granularity: "day",
};
const data = {
  revision: "1",
  resolvedRange,
  coverage,
  totals: total,
  kpiDisplay: { cost: "$1", requests: "2", tokens: "3", cacheHitRate: "0%" },
  facets: { services: [], sources: [], models: [] },
  providerRows: [],
  modelRows: [],
  samples: [],
  axisTicks: [],
  status,
};
const listeners = new Set<(event: any) => void>();
const api = {
  subscribe: vi.fn((listener: (event: any) => void) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  }),
  usageDashboard: vi.fn(async () => data),
  usageRequests: vi.fn(async () => ({
    revision: "1",
    resolvedRange,
    totalCount: 0,
    rows: [],
    nextCursor: null,
    coverage,
    status,
  })),
  usageHeatmap: vi.fn(async () => ({
    fromDay: "2025-01-06",
    toDay: "2026-01-12",
    timeZone: "UTC",
    days: [],
    totals: total,
    nextBeforeDay: null,
    coverage,
    status,
  })),
};
let session = { ...api };
beforeEach(async () => {
  session = { ...api };
  const fixtures = await import("./fixtures");
  fixtures.bootstrap.visibleUsageServices = ["codex", "kimi"];
});
vi.mock("@/host/host-context", async () => {
  const f = await import("./fixtures");
  return {
    useHost: () => ({
      api: session,
      bootstrap: f.bootstrap,
      settings: f.settings,
    }),
    errorMessage: (error: unknown) => String(error),
  };
});
it("queries dashboard immediately and loads request and heatmap only when opened", async () => {
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  expect(api.usageDashboard).toHaveBeenCalled();
  expect(api.usageRequests).not.toHaveBeenCalled();
  expect(api.usageHeatmap).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("tab", { name: /Request logs/ }));
  await waitFor(() => expect(api.usageRequests).toHaveBeenCalled());
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "All",
      exact: true,
    }),
  );
  await waitFor(() => expect(api.usageHeatmap).toHaveBeenCalled());
  expect(api.usageDashboard.mock.lastCall?.[0]).toMatchObject({ range: "all" });
});
it("discards a deferred heatmap when the filter changes", async () => {
  let resolve!: (value: unknown) => void;
  api.usageHeatmap.mockImplementationOnce(
    () =>
      new Promise((r) => {
        resolve = r;
      }) as never,
  );
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "All",
      exact: true,
    }),
  );
  await waitFor(() => expect(api.usageHeatmap).toHaveBeenCalled());
  fireEvent.click(
    screen
      .getAllByRole("button", { name: "All" })
      .find((x) => x.hasAttribute("aria-haspopup"))!,
  );
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", { name: "Today" }),
  );
  resolve({
    fromDay: "1990-01-01",
    toDay: "1991-01-01",
    timeZone: "UTC",
    days: [],
    totals: total,
    nextBeforeDay: null,
    coverage,
    status,
  });
  await waitFor(() =>
    expect(api.usageDashboard.mock.lastCall?.[0]).toMatchObject({
      range: "today",
    }),
  );
  expect(screen.queryByText(/1990-01-01/)).toBeNull();
});
it("recovers the first page when a cursor expires", async () => {
  const { HostError } = await import("@ccbar/host-api");
  api.usageRequests.mockReset();
  api.usageRequests.mockImplementation(async (q: any) => {
    if (q.cursor) throw new HostError("invalid_cursor", "expired");
    return {
      revision: "1",
      resolvedRange,
      totalCount: 2,
      rows: [],
      nextCursor: "old",
      coverage,
      status,
    };
  });
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("tab", { name: /Request logs/ }));
  fireEvent.click(await screen.findByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Next" })).toBeTruthy(),
  );
  expect(
    api.usageRequests.mock.calls.some(
      (call: any[]) => call[0].cursor === "old",
    ),
  ).toBe(true);
});
it("appends older heatmap windows", async () => {
  api.usageHeatmap.mockReset();
  api.usageHeatmap.mockImplementation(async (q: any) => ({
    ...{ timeZone: "UTC", days: [], totals: total, coverage, status },
    ...(q.beforeDay
      ? { fromDay: "2024-01-01", toDay: "2025-01-06", nextBeforeDay: null }
      : {
          fromDay: "2025-01-06",
          toDay: "2026-01-12",
          nextBeforeDay: "2025-01-06",
        }),
  }));
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "All",
      exact: true,
    }),
  );
  fireEvent.click(await screen.findByRole("button", { name: "Load older" }));
  await screen.findByText(/2024-01-01/);
  expect(screen.getByText(/2025-01-06/)).toBeTruthy();
  expect(api.usageHeatmap.mock.lastCall?.[0]).toMatchObject({
    beforeDay: "2025-01-06",
  });
});
it("keeps older windows and reloads them when revision changes", async () => {
  const { HeatmapResource } = await import("@/features/stats/dashboard-page");
  api.usageHeatmap.mockReset();
  api.usageHeatmap.mockImplementation(async (q: any) => ({
    timeZone: "UTC",
    days: [],
    totals: total,
    coverage,
    status,
    ...(q.beforeDay
      ? { fromDay: "2024-01-01", toDay: "2025-01-06", nextBeforeDay: null }
      : {
          fromDay: "2025-01-06",
          toDay: "2026-01-12",
          nextBeforeDay: "2025-01-06",
        }),
  }));
  const query = { range: "all", metric: "tokens" } as const;
  const element = (revision: string) => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardQueryScope>
          <HeatmapResource
            query={query}
            revision={revision}
            today="2026-11-02"
          />
        </DashboardQueryScope>
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(element("1"));
  fireEvent.click(await screen.findByRole("button", { name: "Load older" }));
  await screen.findByText(/2024-01-01/);
  api.usageHeatmap.mockClear();
  view.rerender(element("2"));
  expect(screen.getByText(/2024-01-01/)).toBeTruthy();
  await waitFor(() => expect(api.usageHeatmap).toHaveBeenCalledTimes(2));
  expect(screen.getByText(/2024-01-01/)).toBeTruthy();
  expect(
    api.usageHeatmap.mock.calls.some(
      (args: any[]) => args[0].beforeDay === "2025-01-06",
    ),
  ).toBe(true);
});
it("refreshes moving presets on the visible minute timer", async () => {
  const { act } = await import("@testing-library/react");
  vi.useFakeTimers();
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
  await act(async () => {
    render(
      <LanguageProvider language="en">
        <TooltipProvider>
          <DashboardPage onService={() => {}} />
        </TooltipProvider>
      </LanguageProvider>,
    );
  });
  const count = api.usageDashboard.mock.calls.length;
  await act(async () => {
    await vi.advanceTimersByTimeAsync(60000);
  });
  expect(api.usageDashboard.mock.calls.length).toBeGreaterThan(count);
  vi.restoreAllMocks();
  vi.useRealTimers();
});
it("keeps existing heatmap blocks and retries a failed refresh", async () => {
  const { HeatmapResource } = await import("@/features/stats/dashboard-page");
  const query = { range: "all", metric: "tokens" } as const;
  const block = {
    fromDay: "2025-01-06",
    toDay: "2026-01-12",
    timeZone: "UTC",
    days: [],
    totals: total,
    nextBeforeDay: null,
    coverage,
    status,
  };
  api.usageHeatmap.mockReset();
  api.usageHeatmap
    .mockResolvedValueOnce(block)
    .mockRejectedValueOnce(new Error("offline"))
    .mockResolvedValueOnce(block);
  const viewFor = (revision: string) => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardQueryScope>
          <HeatmapResource
            query={query}
            revision={revision}
            today="2026-11-02"
          />
        </DashboardQueryScope>
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(viewFor("1"));
  await screen.findByText(/2025-01-06/);
  view.rerender(viewFor("2"));
  await screen.findByRole("alert");
  expect(screen.getByText(/2025-01-06/)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  expect(screen.getByText(/2025-01-06/)).toBeTruthy();
});
it("ignores an expired cursor from an earlier filter after another page is open", async () => {
  const { HostError } = await import("@ccbar/host-api");
  const { act } = await import("@testing-library/react");
  let rejectOld!: (error: unknown) => void;
  api.usageRequests.mockReset();
  api.usageRequests.mockImplementation(async (q: any) => {
    if (q.range === "last7" && q.cursor)
      return new Promise((_, reject) => {
        rejectOld = reject;
      });
    return {
      revision: "1",
      resolvedRange,
      totalCount: 2,
      rows: [],
      nextCursor: q.cursor ? null : q.range,
      coverage,
      status,
    };
  });
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("tab", { name: /Request logs/ }));
  fireEvent.click(await screen.findByRole("button", { name: "Next" }));
  await waitFor(() => expect(rejectOld).toBeTypeOf("function"));
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Last 30 days",
    }),
  );
  await waitFor(() =>
    expect(api.usageRequests.mock.lastCall?.[0]).toMatchObject({
      range: "last30",
    }),
  );
  fireEvent.click(await screen.findByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(api.usageRequests.mock.lastCall?.[0]).toMatchObject({
      range: "last30",
      cursor: "last30",
    }),
  );
  const count = api.usageRequests.mock.calls.length;
  await act(async () => {
    rejectOld(new HostError("invalid_cursor", "expired"));
    await Promise.resolve();
  });
  expect(api.usageRequests.mock.calls.length).toBe(count);
});
it("follows the shifted pagination chain across Monday without losing a week", async () => {
  const { HeatmapResource } = await import("@/features/stats/dashboard-page");
  const query = { range: "all", metric: "tokens" } as const;
  let monday = false;
  api.usageHeatmap.mockReset();
  api.usageHeatmap.mockImplementation(async (q: any) => ({
    timeZone: "UTC",
    days: [],
    totals: total,
    coverage,
    status,
    ...(!q.beforeDay
      ? monday
        ? {
            fromDay: "2025-01-13",
            toDay: "2026-01-19",
            nextBeforeDay: "2025-01-13",
          }
        : {
            fromDay: "2025-01-06",
            toDay: "2026-01-12",
            nextBeforeDay: "2025-01-06",
          }
      : {
          fromDay: q.beforeDay === "2025-01-13" ? "2024-01-08" : "2024-01-01",
          toDay: q.beforeDay,
          nextBeforeDay: null,
        }),
  }));
  const viewFor = (today: string) => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardQueryScope>
          <HeatmapResource query={query} revision="1" today={today} />
        </DashboardQueryScope>
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(viewFor("2026-01-11"));
  fireEvent.click(await screen.findByRole("button", { name: "Load older" }));
  await screen.findByText(/2024-01-01/);
  monday = true;
  api.usageHeatmap.mockClear();
  view.rerender(viewFor("2026-01-12"));
  expect(screen.getByText(/2024-01-01/)).toBeTruthy();
  await screen.findByText(/2024-01-08/);
  expect(api.usageHeatmap.mock.calls[1]?.[0]).toMatchObject({
    beforeDay: "2025-01-13",
  });
  expect(screen.queryByText(/2024-01-01/)).toBeNull();
});
it("keeps filters mounted while switching, then serves a revisited key from cache", async () => {
  let finish!: (v: any) => void;
  api.usageDashboard.mockReset();
  api.usageDashboard.mockImplementation((q: any) =>
    q.range === "last30"
      ? new Promise((resolve) => {
          finish = resolve;
        })
      : Promise.resolve(data),
  );
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Last 30 days",
    }),
  );
  expect(screen.getByRole("button", { name: /Last 30 days/ })).toBeTruthy();
  expect(screen.getByText(/Changing filters/)).toBeTruthy();
  finish({ ...data, kpiDisplay: { ...data.kpiDisplay, cost: "$30" } });
  await screen.findByText("$30");
  fireEvent.click(screen.getByRole("button", { name: /Last 30 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Last 7 days",
    }),
  );
  expect(screen.getByText("$1")).toBeTruthy();
  expect(
    api.usageDashboard.mock.calls.filter(
      (call: any[]) => call[0].range === "last7",
    ),
  ).toHaveLength(1);
});
it("does not show old cached results across a privacy context change", async () => {
  const fixtures = await import("./fixtures");
  let finish!: (v: any) => void;
  api.usageDashboard
    .mockReset()
    .mockResolvedValueOnce(data)
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
  const element = () => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(element());
  await screen.findByText("$1");
  fixtures.settings.appearance.privacyMode = true;
  view.rerender(element());
  expect(screen.queryByText("$1")).toBeNull();
  finish({ ...data, kpiDisplay: { ...data.kpiDisplay, cost: "hidden" } });
  await screen.findByText("hidden");
  fixtures.settings.appearance.privacyMode = false;
});
it("invalidates an in-flight query without accepting its older result as fresh", async () => {
  const { act } = await import("@testing-library/react");
  let old!: (v: any) => void;
  api.usageDashboard
    .mockReset()
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          old = resolve;
        }),
    )
    .mockResolvedValue({
      ...data,
      kpiDisplay: { ...data.kpiDisplay, cost: "fresh" },
    });
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await waitFor(() => expect(old).toBeTypeOf("function"));
  await act(async () => {
    for (const listener of listeners) listener({ domains: ["usage"] });
    await Promise.resolve();
  });
  await screen.findByText("fresh");
  await act(async () => {
    old({ ...data, kpiDisplay: { ...data.kpiDisplay, cost: "obsolete" } });
    await Promise.resolve();
  });
  expect(screen.queryByText("obsolete")).toBeNull();
  expect(api.usageDashboard.mock.calls.length).toBeGreaterThanOrEqual(2);
});
it("does not reset the selected filters on broad usage events with unchanged context", async () => {
  const { act } = await import("@testing-library/react");
  api.usageDashboard.mockReset().mockResolvedValue(data);
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Last 30 days",
    }),
  );
  await waitFor(() =>
    expect(api.usageDashboard.mock.lastCall?.[0]).toMatchObject({
      range: "last30",
    }),
  );
  await act(async () => {
    for (const listener of listeners)
      listener({ domains: ["usage", "settings", "applications"] });
    await new Promise((resolve) => setTimeout(resolve, 150));
  });
  expect(screen.getByRole("button", { name: /Last 30 days/ })).toBeTruthy();
});
it("isolates cached data when the visible usage services change", async () => {
  const fixtures = await import("./fixtures");
  let finish!: (v: any) => void;
  api.usageDashboard
    .mockReset()
    .mockResolvedValueOnce(data)
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
  const element = () => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(element());
  await screen.findByText("$1");
  fixtures.bootstrap.visibleUsageServices = ["codex"];
  view.rerender(element());
  expect(screen.queryByText("$1")).toBeNull();
  finish({ ...data, kpiDisplay: { ...data.kpiDisplay, cost: "new scope" } });
  await screen.findByText("new scope");
  fixtures.bootstrap.visibleUsageServices = [];
});
it("reuses the session cache across page remount and revalidates it", async () => {
  let resolve!: (value: any) => void;
  api.usageDashboard
    .mockReset()
    .mockResolvedValueOnce(data)
    .mockImplementationOnce(
      () =>
        new Promise((r) => {
          resolve = r;
        }),
    );
  const element = () => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>
  );
  const first = render(element());
  await screen.findByText("$1");
  first.unmount();
  render(element());
  expect(screen.getByText("$1")).toBeTruthy();
  await waitFor(() => expect(resolve).toBeTypeOf("function"));
  resolve({ ...data, kpiDisplay: { ...data.kpiDisplay, cost: "refreshed" } });
  await screen.findByText("refreshed");
});
it("updates application selection immediately while its result is pending", async () => {
  const React = await import("react");
  let finish!: (value: any) => void;
  const scoped = {
    ...data,
    facets: {
      ...data.facets,
      services: [
        { id: "codex", title: "Codex", requestCount: 1 },
        { id: "claude", title: "Claude", requestCount: 1 },
      ],
    },
  };
  api.usageDashboard.mockReset().mockImplementation((q: any) =>
    q.service === "codex"
      ? new Promise((r) => {
          finish = r;
        })
      : Promise.resolve(scoped),
  );
  function View() {
    const [service, setService] =
      React.useState<import("@ccbar/host-api/window").UsageService>();
    return <DashboardPage service={service} onService={setService} />;
  }
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <View />
      </TooltipProvider>
    </LanguageProvider>,
  );
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("button", { name: "Codex" }));
  expect(
    screen.getByRole("button", { name: "Codex" }).getAttribute("aria-pressed"),
  ).toBe("true");
  expect(screen.getByText(/Changing filters/)).toBeTruthy();
  finish(scoped);
});

const renderDashboard = () =>
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardPage onService={() => {}} />
      </TooltipProvider>
    </LanguageProvider>,
  );
const requestPage = (modelID: string, nextCursor: string | null = null) => ({
  revision: "1",
  resolvedRange,
  totalCount: 2,
  rows: [
    {
      id: modelID,
      service: "codex",
      sourceID: "session:codex",
      modelID,
      timestamp: "2026-11-01T10:00:00Z",
      totals: total,
    },
  ],
  nextCursor,
  coverage,
  status,
});

it("keeps request rows while paging and immediately reuses a cached page", async () => {
  const { act } = await import("@testing-library/react");
  let finish!: (value: any) => void;
  api.usageDashboard.mockReset().mockResolvedValue(data);
  api.usageRequests.mockReset().mockImplementation((query: any) =>
    query.cursor
      ? new Promise((resolve) => {
          finish = resolve;
        })
      : (Promise.resolve(requestPage("first-page-model", "page-2")) as never),
  );
  renderDashboard();
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("tab", { name: /Request logs/ }));
  await screen.findByText("first-page-model");
  fireEvent.click(screen.getByRole("button", { name: "Next" }));
  expect(screen.getByText("first-page-model")).toBeTruthy();
  expect(screen.queryByText("Loading request records…")).toBeNull();
  expect(
    (screen.getByRole("button", { name: "Next" }) as HTMLButtonElement)
      .disabled,
  ).toBe(true);
  expect(
    (screen.getByRole("button", { name: "Previous" }) as HTMLButtonElement)
      .disabled,
  ).toBe(true);
  await act(async () => {
    finish(requestPage("second-page-model"));
  });
  await screen.findByText("second-page-model");
  fireEvent.click(screen.getByRole("button", { name: "Previous" }));
  expect(screen.getByText("first-page-model")).toBeTruthy();
  expect(api.usageRequests).toHaveBeenCalledTimes(2);
});

it("retains the last request page when the next page fails and supports retry", async () => {
  api.usageDashboard.mockReset().mockResolvedValue(data);
  api.usageRequests
    .mockReset()
    .mockResolvedValueOnce(requestPage("retained-model", "page-2") as never)
    .mockRejectedValueOnce(new Error("database temporarily busy"))
    .mockResolvedValueOnce(requestPage("retried-model") as never);
  renderDashboard();
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("tab", { name: /Request logs/ }));
  await screen.findByText("retained-model");
  fireEvent.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByRole("alert");
  expect(screen.getByText("retained-model")).toBeTruthy();
  expect(screen.getByText(/Request records could not be updated/)).toBeTruthy();
  expect(
    (screen.getByRole("button", { name: "Next" }) as HTMLButtonElement)
      .disabled,
  ).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await screen.findByText("retried-model");
  expect(screen.queryByText("retained-model")).toBeNull();
  expect(screen.queryByRole("alert")).toBeNull();
});

it("retains prior dashboard results after filter failure without caching them under the failed key", async () => {
  api.usageDashboard
    .mockReset()
    .mockResolvedValueOnce(data)
    .mockRejectedValueOnce(new Error("database temporarily busy"))
    .mockResolvedValueOnce({
      ...data,
      kpiDisplay: { ...data.kpiDisplay, cost: "$30" },
    });
  renderDashboard();
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Last 30 days",
    }),
  );
  await screen.findByText(/Filters could not be applied/);
  expect(screen.getByText("$1")).toBeTruthy();
  expect(
    screen.getByRole("table").querySelector("tbody[inert]"),
  ).not.toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await screen.findByText("$30");
  expect(screen.getByRole("table").querySelector("tbody[inert]")).toBeNull();
  expect(api.usageDashboard.mock.lastCall?.[0]).toMatchObject({
    range: "last30",
  });
});

it.each(["usage", "pricing"])(
  "keeps displayed results during %s background refresh and on failure",
  async (domain) => {
    const { act } = await import("@testing-library/react");
    let fail!: (reason: Error) => void;
    api.usageDashboard
      .mockReset()
      .mockResolvedValueOnce(data)
      .mockImplementationOnce(
        () =>
          new Promise((_, reject) => {
            fail = reject;
          }),
      );
    renderDashboard();
    await screen.findByText("$1");
    const table = screen.getByRole("table");
    await act(async () => {
      for (const listener of listeners) listener({ domains: [domain] });
    });
    await waitFor(() => expect(fail).toBeTypeOf("function"));
    expect(screen.getByText("$1")).toBeTruthy();
    expect(screen.getByRole("table")).toBe(table);
    expect(
      document.querySelector('[data-slot="chart-loading-overlay"]'),
    ).toBeNull();
    expect(document.querySelector('[data-slot="table-skeleton"]')).toBeNull();
    expect(screen.getByText("$1").className).not.toContain("invisible");
    await act(async () => {
      fail(new Error("temporarily unavailable"));
    });
    await screen.findByText(/Refresh failed/);
    expect(screen.getByText("$1")).toBeTruthy();
    expect(screen.getByRole("table")).toBe(table);
  },
);

it("revalidates the cached first page when a database change expires its pagination cursor", async () => {
  const { HostError } = await import("@ccbar/host-api");
  api.usageDashboard.mockReset().mockResolvedValue(data);
  api.usageRequests
    .mockReset()
    .mockResolvedValueOnce(
      requestPage("outdated-page", "expired-cursor") as never,
    )
    .mockRejectedValueOnce(new HostError("invalid_cursor", "expired"))
    .mockResolvedValueOnce(requestPage("current-page", "fresh-cursor") as never)
    .mockResolvedValueOnce(requestPage("current-next-page") as never);
  renderDashboard();
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("tab", { name: /Request logs/ }));
  await screen.findByText("outdated-page");
  fireEvent.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("current-page");
  expect(api.usageRequests).toHaveBeenCalledTimes(3);
  expect(api.usageRequests.mock.lastCall?.[0].cursor).toBeUndefined();
  fireEvent.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("current-next-page");
  expect(api.usageRequests.mock.lastCall?.[0]).toMatchObject({
    cursor: "fresh-cursor",
  });
});

const emptyTotal = {
  ...total,
  inputTokens: 0,
  outputTokens: 0,
  inputWithCacheTokens: 0,
  totalTokens: 0,
  costUSD: "0",
  costDisplay: "$0",
  requestCount: 0,
};
const emptyDashboard = {
  ...data,
  totals: emptyTotal,
  coverage: { ...coverage, refreshing: false, unlocatedTotals: emptyTotal },
  kpiDisplay: { cost: "—", requests: "—", tokens: "—", cacheHitRate: "—" },
  axisTicks: [
    { position: 0, label: "0" },
    { position: 0.5, label: "1" },
    { position: 1, label: "2" },
  ],
  samples: ["2026-11-01", "2026-11-02", "2026-11-03"].map((day) => ({
    key: day,
    start: `${day}T00:00:00Z`,
    totals: emptyTotal,
    value: 0,
    label: "0",
    normalizedValue: 0,
    segments: [],
  })),
};

it("keeps every enabled application in configured order during loading and when query facets change", async () => {
  const { act } = await import("@testing-library/react");
  const fixtures = await import("./fixtures");
  fixtures.bootstrap.visibleUsageServices = ["kimi", "codex"];
  // Neither app is in the sidebar; usage enablement is independent of sidebar membership.
  expect(fixtures.bootstrap.sidebarApplications).toHaveLength(0);
  let finish!: (value: any) => void;
  api.usageDashboard
    .mockReset()
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    )
    .mockResolvedValue({
      ...data,
      facets: { services: [], sources: [], models: [] },
    });
  renderDashboard();
  const names = () =>
    within(screen.getByRole("group", { name: "Application filter" }))
      .getAllByRole("button")
      .map((button) => button.getAttribute("aria-label") ?? button.textContent);
  expect(names()).toEqual(["All", "Kimi Code", "Codex"]);
  expect(screen.queryByText("No data")).toBeNull();
  await act(async () => {
    finish({
      ...data,
      facets: {
        ...data.facets,
        services: [{ id: "codex", title: "Codex", requestCount: 2 }],
      },
    });
  });
  await screen.findByText("$1");
  expect(names()).toEqual(["All", "Kimi Code", "Codex"]);
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", { name: "Today" }),
  );
  await waitFor(() =>
    expect(api.usageDashboard.mock.lastCall?.[0]).toMatchObject({
      range: "today",
    }),
  );
  expect(names()).toEqual(["All", "Kimi Code", "Codex"]);
});

it("returns selection to all when the selected application is disabled", async () => {
  const React = await import("react");
  const fixtures = await import("./fixtures");
  api.usageDashboard.mockReset().mockResolvedValue(data);
  function View() {
    const [service, setService] = React.useState<
      import("@ccbar/host-api/window").UsageService | undefined
    >("codex");
    return (
      <LanguageProvider language="en">
        <TooltipProvider>
          <DashboardPage service={service} onService={setService} />
        </TooltipProvider>
      </LanguageProvider>
    );
  }
  const view = render(<View />);
  await screen.findByText("$1");
  expect(
    screen.getByRole("button", { name: "Codex" }).getAttribute("aria-pressed"),
  ).toBe("true");
  fixtures.bootstrap.visibleUsageServices = ["kimi"];
  view.rerender(<View />);
  const selector = screen.getByRole("group", { name: "Application filter" });
  expect(within(selector).queryByRole("button", { name: "Codex" })).toBeNull();
  expect(
    within(selector)
      .getByRole("button", { name: "All" })
      .getAttribute("aria-pressed"),
  ).toBe("true");
  await waitFor(() =>
    expect(api.usageDashboard.mock.lastCall?.[0].service).toBeUndefined(),
  );
});

it("keeps KPI, chart axes and all table columns when a successful query is empty", async () => {
  api.usageDashboard.mockReset().mockResolvedValue(emptyDashboard as never);
  api.usageRequests.mockReset().mockResolvedValue({
    revision: "1",
    resolvedRange,
    totalCount: 0,
    rows: [],
    nextCursor: null,
    coverage: emptyDashboard.coverage,
    status,
  });
  const view = renderDashboard();
  await screen.findByText("No data");
  for (const name of ["Cost", "Requests", "Tokens", "Cache hit rate"])
    expect(screen.getByRole("button", { name: `${name} —` })).toBeTruthy();
  expect(screen.getByRole("tab", { name: "Request logs 0" })).toBeTruthy();
  expect(screen.getByRole("tab", { name: "Providers 0" })).toBeTruthy();
  expect(screen.getByRole("tab", { name: "Models 0" })).toBeTruthy();
  expect(
    view.container.querySelector('[data-slot="dashboard-bar"]'),
  ).toBeNull();
  expect(screen.getByText("11/01")).toBeTruthy();
  expect(screen.getByText("11/03")).toBeTruthy();
  expect(screen.getByText("1")).toBeTruthy();
  expect(screen.getByText("2")).toBeTruthy();
  expect(screen.getAllByRole("columnheader")).toHaveLength(7);
  expect(screen.getByText("No data").getAttribute("colspan")).toBe("7");
  fireEvent.click(screen.getByRole("tab", { name: "Models 0" }));
  expect(screen.getAllByRole("columnheader")).toHaveLength(7);
  expect(screen.getByText("No data")).toBeTruthy();
  fireEvent.click(screen.getByRole("tab", { name: "Request logs 0" }));
  expect(screen.getAllByRole("columnheader")).toHaveLength(6);
  expect(screen.getByText("No data").getAttribute("colspan")).toBe("6");
  await waitFor(() => expect(api.usageRequests).toHaveBeenCalled());
});

it("does not treat actual zero-cost usage as an empty query", async () => {
  api.usageDashboard.mockReset().mockResolvedValue({
    ...data,
    totals: { ...total, costUSD: "0", costDisplay: "$0" },
    kpiDisplay: { ...data.kpiDisplay, cost: "$0" },
  });
  renderDashboard();
  await screen.findByText("$0");
  expect(screen.queryByText("No data")).toBeNull();
  expect(screen.getByRole("button", { name: "Requests 2" })).toBeTruthy();
});

it("keeps application filters but does not display empty success on initial query failure", async () => {
  api.usageDashboard
    .mockReset()
    .mockRejectedValue(new Error("database unavailable"));
  renderDashboard();
  await screen.findByText("Couldn’t load this page");
  expect(screen.getByRole("button", { name: "Codex" })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Kimi Code" })).toBeTruthy();
  expect(screen.queryByText("No data")).toBeNull();
});

it("does not claim empty data while request details are still being prepared", async () => {
  api.usageDashboard.mockReset().mockResolvedValue({
    ...emptyDashboard,
    coverage: { ...emptyDashboard.coverage, refreshing: true },
    kpiDisplay: { cost: "$0", requests: "0", tokens: "0", cacheHitRate: "0%" },
  } as never);
  renderDashboard();
  await screen.findByText("Updating request details…");
  expect(screen.queryByText("No data")).toBeNull();
  expect(screen.getByRole("tab", { name: "Request logs —" })).toBeTruthy();
});

it("uses the dashboard shell for first-load skeletons while controls remain usable", async () => {
  const { act } = await import("@testing-library/react");
  let finish!: (value: any) => void;
  api.usageDashboard.mockReset().mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const view = renderDashboard();
  const summary = view.container.querySelector(
    '[data-slot="dashboard-summary"]',
  );
  const table = screen.getByRole("table");
  expect(summary).not.toBeNull();
  expect(
    view.container.querySelector('[data-slot="chart-skeleton"]'),
  ).not.toBeNull();
  expect(
    view.container.querySelector('[data-slot="table-skeleton"]'),
  ).not.toBeNull();
  expect(screen.getAllByRole("status")).toHaveLength(1);
  expect(screen.getByRole("status").className).toContain("sr-only");
  expect(screen.getByRole("status").closest('[aria-busy="true"]')).toBeNull();
  expect(screen.queryByText("No data")).toBeNull();
  for (const skeleton of view.container.querySelectorAll(
    '[data-slot="skeleton"]',
  )) {
    expect(skeleton.className).toContain("motion-reduce:animate-none");
    expect(skeleton.getAttribute("aria-hidden")).toBe("true");
  }
  expect(
    (
      within(summary as HTMLElement).getByRole("button", {
        name: "Cost",
      }) as HTMLButtonElement
    ).disabled,
  ).toBe(false);
  fireEvent.click(screen.getByRole("tab", { name: "Models" }));
  fireEvent.click(screen.getByRole("button", { name: "Hide chart" }));
  expect(
    view.container.querySelector('[data-slot="dashboard-chart-region"]'),
  ).toBeNull();
  await act(async () => {
    finish(data);
  });
  await screen.findByText("$1");
  expect(view.container.querySelector('[data-slot="dashboard-summary"]')).toBe(
    summary,
  );
  expect(screen.getByRole("table")).toBe(table);
  expect(
    screen.getByRole("tab", { name: "Models 0" }).getAttribute("aria-selected"),
  ).toBe("true");
  expect(screen.getByRole("button", { name: "Show chart" })).toBeTruthy();
  expect(
    view.container.querySelector('[data-slot="table-skeleton"]'),
  ).toBeNull();
});

it("overlays fresh-filter skeletons without unmounting panels and skips them for a cached filter", async () => {
  const { act } = await import("@testing-library/react");
  let finish!: (value: any) => void;
  api.usageDashboard.mockReset().mockImplementation((query: any) =>
    query.range === "last30"
      ? new Promise((resolve) => {
          finish = resolve;
        })
      : Promise.resolve(data),
  );
  const view = renderDashboard();
  await screen.findByText("$1");
  const summary = view.container.querySelector(
    '[data-slot="dashboard-summary"]',
  );
  const table = screen.getByRole("table");
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Last 30 days",
    }),
  );
  expect(
    view.container.querySelector('[data-slot="chart-loading-overlay"]'),
  ).not.toBeNull();
  expect(
    view.container.querySelector('[data-slot="table-skeleton"]'),
  ).not.toBeNull();
  expect(view.container.querySelector('[data-slot="dashboard-summary"]')).toBe(
    summary,
  );
  expect(screen.getByRole("table")).toBe(table);
  expect(screen.getByText("$1").className).toContain("invisible");
  expect(
    screen.getByRole("tab", { name: "Models 0" }).closest("[inert]"),
  ).toBeNull();
  fireEvent.click(screen.getByRole("tab", { name: "Models 0" }));
  await act(async () => {
    finish({ ...data, kpiDisplay: { ...data.kpiDisplay, cost: "$30" } });
  });
  await screen.findByText("$30");
  expect(
    view.container.querySelector('[data-slot="table-skeleton"]'),
  ).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: /Last 30 days/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Last 7 days",
    }),
  );
  expect(screen.getByText("$1").className).not.toContain("invisible");
  expect(view.container.querySelector('[data-slot="skeleton"]')).toBeNull();
  expect(
    screen.getByRole("tab", { name: "Models 0" }).getAttribute("aria-selected"),
  ).toBe("true");
});

it("keeps the request table and paging area while first-page and next-page queries are pending", async () => {
  const { act } = await import("@testing-library/react");
  let finish!: (value: any) => void;
  api.usageDashboard.mockReset().mockResolvedValue(data);
  api.usageRequests.mockReset().mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const view = renderDashboard();
  await screen.findByText("$1");
  fireEvent.click(screen.getByRole("tab", { name: /Request logs/ }));
  const table = screen.getByRole("table");
  const body = table.parentElement!;
  expect(body.className).toContain("min-h-[196px]");
  expect(body.querySelector('[data-slot="table-skeleton"]')).not.toBeNull();
  expect(screen.getAllByRole("columnheader")).toHaveLength(6);
  expect(screen.getByRole("status").className).toContain("sr-only");
  expect(screen.getByRole("status").closest('[aria-busy="true"]')).toBeNull();
  const pager = view.container.querySelector(
    '[data-slot="dashboard-table"] .min-h-14',
  );
  expect(pager?.className).toContain("invisible");
  await act(async () => {
    finish(requestPage("loaded-row", "next"));
  });
  await screen.findByText("loaded-row");
  expect(screen.getByRole("table")).toBe(table);
  expect(pager?.className).not.toContain("invisible");
  fireEvent.click(screen.getByRole("button", { name: "Next" }));
  expect(screen.getByText("loaded-row")).toBeTruthy();
  expect(body.querySelector('[data-slot="table-skeleton"]')).not.toBeNull();
  expect(
    (screen.getByRole("button", { name: "Next" }) as HTMLButtonElement)
      .disabled,
  ).toBe(true);
  await act(async () => {
    finish(requestPage("next-row"));
  });
  await screen.findByText("next-row");
  expect(screen.getByRole("table")).toBe(table);
  expect(body.querySelector('[data-slot="table-skeleton"]')).toBeNull();
});

it("uses a full heatmap skeleton on first load and retains expanded blocks for a background reload", async () => {
  const { act } = await import("@testing-library/react");
  const { HeatmapResource } = await import("@/features/stats/dashboard-page");
  let finish!: (value: any) => void;
  const block = {
    fromDay: "2025-01-06",
    toDay: "2026-01-12",
    timeZone: "UTC",
    days: [],
    totals: total,
    nextBeforeDay: null,
    coverage,
    status,
  };
  api.usageHeatmap.mockReset().mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const element = (revision: string) => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardQueryScope>
          <HeatmapResource
            query={{ range: "all", metric: "tokens" }}
            today="2026-11-02"
            revision={revision}
          />
        </DashboardQueryScope>
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(element("1"));
  expect(
    view.container.querySelector('[data-slot="heatmap-skeleton"]'),
  ).not.toBeNull();
  expect(screen.getByRole("status").className).toContain("sr-only");
  expect(screen.getByRole("status").closest('[aria-busy="true"]')).toBeNull();
  await act(async () => {
    finish(block);
  });
  await screen.findByText(/2025-01-06/);
  const title = screen.getByText(/2025-01-06/);
  expect(
    view.container.querySelector('[data-slot="heatmap-skeleton"]'),
  ).toBeNull();
  view.rerender(element("2"));
  expect(screen.getByText(/2025-01-06/)).toBe(title);
  expect(
    view.container.querySelector('[data-slot="heatmap-skeleton"]'),
  ).toBeNull();
  expect(
    view.container.querySelectorAll('[data-slot="skeleton"]'),
  ).toHaveLength(1);
  await act(async () => {
    finish(block);
  });
  expect(screen.getByText(/2025-01-06/)).toBe(title);
});
