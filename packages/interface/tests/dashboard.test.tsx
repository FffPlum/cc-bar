import { fireEvent, render, screen, within } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import type { DashboardHeatmap, UsageDashboard } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import {
  civilInput,
  civilToISO,
  DashboardFilters,
} from "@/features/stats/dashboard-filters";
import {
  DashboardChart,
  HeatmapBlocks,
} from "@/features/stats/dashboard-charts";
import { DashboardTable } from "@/features/stats/dashboard-table";
import { TooltipProvider } from "@/components/ui/tooltip";
import { LanguageProvider } from "@/lib/i18n";
vi.mock("@/host/host-context", async () => {
  const f = await import("./fixtures");
  return { useHost: () => ({ bootstrap: f.bootstrap, settings: f.settings }) };
});
const total = usage["window.usage.overview"].totals;
const data = {
  revision: "1",
  resolvedRange: {
    from: "2026-10-01T00:00:00Z",
    to: "2026-11-01T00:00:00Z",
    asOf: "2026-11-01T00:00:00Z",
    timeZone: "Asia/Shanghai",
    granularity: "day",
  },
  coverage: {
    precision: "day",
    incomplete: true,
    unlocatedTotals: total,
    message: "Incomplete",
  },
  totals: total,
  facets: {
    services: [{ id: "codex", title: "Codex", requestCount: 2 }],
    sources: [
      {
        id: "source",
        title: "Source",
        service: "codex",
        requestCount: 2,
        models: [{ id: "model", title: "Model", requestCount: 2 }],
      },
    ],
    models: [{ id: "model", title: "Model", requestCount: 2 }],
  },
  providerRows: [
    {
      id: "a",
      title: "A",
      service: "codex",
      sourceID: "a",
      modelID: null,
      totals: { ...total, requestCount: 1 },
      successRate: null,
    },
    {
      id: "b",
      title: "B",
      service: "codex",
      sourceID: "b",
      modelID: null,
      totals: { ...total, requestCount: 4 },
      successRate: null,
    },
  ],
  modelRows: [],
  samples: [],
  axisTicks: [],
  status: usage["window.usage.overview"].status,
} as unknown as UsageDashboard;
const wrap = (child: React.ReactNode) =>
  render(
    <LanguageProvider language="en">
      <TooltipProvider>{child}</TooltipProvider>
    </LanguageProvider>,
  );
it("converts host time and rejects invalid and nonexistent civil time", () => {
  expect(civilInput(new Date("2026-01-01T00:00:00Z"), "Asia/Shanghai")).toBe(
    "2026-01-01T08:00",
  );
  expect(civilToISO("2026-01-01T08:00", "Asia/Shanghai")).toBe(
    "2026-01-01T00:00:00.000Z",
  );
  expect(civilToISO("2026-03-08T02:30", "America/New_York")).toBeNull();
  expect(civilToISO("2026-02-30T12:00", "UTC")).toBeNull();
});
it("applies custom dates and offers presets", () => {
  const range = vi.fn();
  wrap(
    <DashboardFilters
      data={data}
      range="last7"
      onRange={range}
      onService={() => {}}
      onSource={() => {}}
      onModel={() => {}}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: /Last 7 days/ }));
  expect(screen.getByRole("button", { name: "Last 14 days" })).toBeTruthy();
  fireEvent.change(screen.getByLabelText("Start"), {
    target: { value: "2026-10-01T08:00" },
  });
  fireEvent.change(screen.getByLabelText("End"), {
    target: { value: "2026-10-02T08:00" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Apply" }));
  expect(range).toHaveBeenCalledWith("custom", {
    customFrom: "2026-10-01T00:00:00.000Z",
    customTo: "2026-10-02T00:00:00.000Z",
    followNow: false,
  });
});
it("selects provider and model", () => {
  const source = vi.fn(),
    model = vi.fn();
  wrap(
    <DashboardFilters
      data={data}
      range="last7"
      onRange={() => {}}
      onService={() => {}}
      onSource={source}
      onModel={model}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: /Provider \/ model/ }));
  fireEvent.click(screen.getByRole("button", { name: /Source/ }));
  fireEvent.click(screen.getByRole("button", { name: /Model2/ }));
  expect(source).toHaveBeenCalledWith("source");
  expect(model).toHaveBeenCalledWith("model");
});
it("does not show false hourly zero bars", () => {
  wrap(
    <DashboardChart
      data={{
        ...data,
        resolvedRange: { ...data.resolvedRange, granularity: "hour" },
      }}
      title="Tokens"
    />,
  );
  expect(screen.getByText(/Hourly data is unavailable/)).toBeTruthy();
});
it("sorts aggregate rows and displays unknown values", () => {
  wrap(
    <DashboardTable
      data={data}
      tab="providers"
      onTabChange={() => {}}
      requests={null}
      error={null}
      loading={false}
      requestSort={{ sort: "time", direction: "desc" }}
      onRequestSort={() => {}}
      next={() => {}}
      previous={() => {}}
      reset={() => {}}
    />,
  );
  const table = screen.getByRole("table");
  expect(within(table).getAllByRole("row")[1]?.textContent).toContain("B");
  fireEvent.click(screen.getByRole("button", { name: /Requests/ }));
  expect(within(table).getAllByRole("row")[1]?.textContent).toContain("A");
  expect(within(table).getAllByRole("row")[1]?.textContent).toContain("—");
});
it("loads an older heatmap window", () => {
  const older = vi.fn();
  const block = {
    fromDay: "2025-01-06",
    toDay: "2026-01-12",
    timeZone: "UTC",
    days: [
      {
        day: "2025-01-06",
        totals: total,
        value: 1,
        label: "1",
        normalizedValue: 1,
      },
    ],
    totals: total,
    nextBeforeDay: "2025-01-06",
    coverage: data.coverage,
    status: data.status,
  } as DashboardHeatmap;
  wrap(<HeatmapBlocks blocks={[block]} onOlder={older} loading={false} />);
  fireEvent.click(screen.getByRole("button", { name: "Load older" }));
  expect(older).toHaveBeenCalledWith("2025-01-06");
  expect(screen.getByLabelText("2025-01-06: 1")).toBeTruthy();
});
it("requests global sorting from the host and uses host axis labels", () => {
  const sort = vi.fn();
  const requestData = {
    revision: "1",
    resolvedRange: data.resolvedRange,
    totalCount: 0,
    rows: [],
    nextCursor: null,
    coverage: data.coverage,
    status: data.status,
  };
  const result = wrap(
    <DashboardTable
      data={data}
      tab="providers"
      onTabChange={() => {}}
      requests={requestData}
      error={null}
      loading={false}
      requestSort={{ sort: "time", direction: "desc" }}
      onRequestSort={sort}
      next={() => {}}
      previous={() => {}}
      reset={() => {}}
    />,
  );
  result.rerender(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardTable
          data={data}
          tab="requests"
          onTabChange={() => {}}
          requests={requestData}
          loading={false}
          error={null}
          requestSort={{ sort: "time", direction: "desc" }}
          onRequestSort={sort}
          next={() => {}}
          previous={() => {}}
          reset={() => {}}
        />
      </TooltipProvider>
    </LanguageProvider>,
  );
  fireEvent.click(screen.getByRole("button", { name: /Cost/ }));
  expect(sort).toHaveBeenCalledWith({ sort: "cost", direction: "desc" });
  result.unmount();
  wrap(
    <DashboardChart
      data={{
        ...data,
        axisTicks: [
          { position: 0, label: "$0.00" },
          { position: 1, label: "$12.34" },
        ],
      }}
      title="Cost"
    />,
  );
  expect(screen.getByText("$12.34")).toBeTruthy();
});
it("leaves future heatmap dates blank and stops the current block at today", () => {
  const block = {
    fromDay: "2026-10-26",
    toDay: "2026-11-09",
    timeZone: "UTC",
    days: [
      {
        day: "2026-11-02",
        totals: total,
        value: 1,
        label: "1",
        normalizedValue: 1,
      },
      {
        day: "2026-11-03",
        totals: total,
        value: 0,
        label: "0",
        normalizedValue: 0,
      },
    ],
    totals: total,
    nextBeforeDay: null,
    coverage: data.coverage,
    status: data.status,
  } as DashboardHeatmap;
  wrap(
    <HeatmapBlocks
      blocks={[block]}
      today="2026-11-02"
      onOlder={() => {}}
      loading={false}
    />,
  );
  expect(screen.getByText(/2026-10-26 – 2026-11-02/)).toBeTruthy();
  expect(screen.queryByLabelText("2026-11-03: 0")).toBeNull();
});
