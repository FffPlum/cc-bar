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
beforeEach(() => {
  session = { ...api };
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
