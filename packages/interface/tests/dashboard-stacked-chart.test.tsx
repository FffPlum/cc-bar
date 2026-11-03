import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import type {
  DashboardHeatmap,
  DashboardMetric,
  DashboardSample,
  UsageDashboard,
} from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import {
  DashboardChart,
  HeatmapBlocks,
} from "@/features/stats/dashboard-charts";
import { LanguageProvider } from "@/lib/i18n";
import { TooltipProvider } from "@/components/ui/tooltip";
import { bootstrap, settings } from "./fixtures";
vi.mock("@/host/host-context", async () => {
  const f = await import("./fixtures");
  return { useHost: () => ({ bootstrap: f.bootstrap, settings: f.settings }) };
});
const totals = usage["window.usage.overview"].totals;
const sample = {
  key: "1",
  start: "2026-11-02T00:00:00Z",
  totals: { ...totals, totalTokens: 100 },
  value: 100,
  label: "100",
  normalizedValue: 0.8,
  segments: [
    {
      service: "codex", totals: { ...totals, totalTokens: 75 },
      value: 75, label: "75", share: 0.75,
    },
    {
      service: "claude", totals: { ...totals, totalTokens: 25 },
      value: 25, label: "25", share: 0.25,
    },
    {
      service: "kimi", totals: { ...totals, totalTokens: 0 },
      value: 0, label: "0", share: 0,
    },
  ],
} as unknown as DashboardSample;
const make = (samples: DashboardSample[]) =>
  ({
    samples,
    axisTicks: [],
    resolvedRange: { granularity: "day" },
    coverage: { precision: "event" },
  }) as unknown as UsageDashboard;
const renderChart = (
  samples: DashboardSample[],
  title = "Tokens",
  metric: DashboardMetric = "tokens",
) =>
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart data={make(samples)} title={title} metric={metric} />
      </TooltipProvider>
    </LanguageProvider>,
  );

it("shares the trend card across columns and refreshes its content in place", async () => {
  const second = {
    ...sample,
    key: "2",
    start: "2026-11-03T00:00:00Z",
    label: "200",
    totals: { ...totals, totalTokens: 200 },
  };
  const view = renderChart([sample, second]);
  const [first, next] = screen.getAllByRole("button");
  fireEvent.mouseMove(first!, { clientX: 100, clientY: 100 });
  fireEvent.mouseEnter(first!);
  const card = (await screen.findByText("Tokens: 100.00")).closest(
    '[data-slot="chart-data-tooltip"]',
  );
  fireEvent.mouseLeave(first!, { relatedTarget: next });
  fireEvent.mouseEnter(next!, { relatedTarget: first });
  expect(
    (await screen.findByText("Tokens: 200.00")).closest(
      '[data-slot="chart-data-tooltip"]',
    ),
  ).toBe(card);
  view.rerender(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart
          data={make([
            sample,
            { ...second, label: "250", totals: { ...totals, totalTokens: 250 } },
          ])}
          title="Tokens"
          metric="tokens"
        />
      </TooltipProvider>
    </LanguageProvider>,
  );
  expect(
    (await screen.findByText("Tokens: 250.00")).closest(
      '[data-slot="chart-data-tooltip"]',
    ),
  ).toBe(card);
  fireEvent.mouseLeave(next!);
  await waitFor(() => expect(card!.isConnected).toBe(false));
});

it("shares the heatmap card across date cells", async () => {
  const days = ["2026-11-01", "2026-11-02"].map((day) => ({
    day,
    totals,
    value: 100,
    label: "100",
    normalizedValue: 1,
  }));
  const block = {
    fromDay: "2026-11-01",
    toDay: "2026-11-03",
    days,
    totals,
    nextBeforeDay: null,
  } as DashboardHeatmap;
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <HeatmapBlocks blocks={[block]} onOlder={() => {}} loading={false} />
      </TooltipProvider>
    </LanguageProvider>,
  );
  const first = screen.getByRole("button", {
    name: `2026-11-01: ${totals.totalTokens.toLocaleString("en")} Tokens`,
  });
  const next = screen.getByRole("button", {
    name: `2026-11-02: ${totals.totalTokens.toLocaleString("en")} Tokens`,
  });
  fireEvent.mouseEnter(first);
  const card = (
    await screen.findByText("2026-11-01", { selector: "strong" })
  ).closest('[data-slot="chart-data-tooltip"]');
  fireEvent.mouseLeave(first, { relatedTarget: next });
  fireEvent.mouseEnter(next, { relatedTarget: first });
  expect(
    (await screen.findByText("2026-11-02", { selector: "strong" })).closest(
      '[data-slot="chart-data-tooltip"]',
    ),
  ).toBe(card);
  expect(
    document.querySelectorAll('[data-slot="chart-data-tooltip"]'),
  ).toHaveLength(1);
});
afterEach(() => {
  bootstrap.appearance = "light";
  bootstrap.visibleUsageServices = [];
  settings.appearance.brandColors = [];
});
it("renders proportional segments, excludes zeros, and orders the legend by configured services", () => {
  bootstrap.visibleUsageServices = ["claude", "codex", "kimi"];
  const { container } = renderChart([sample]);
  const bar = container.querySelector(
    '[data-slot="dashboard-bar"]',
  ) as HTMLElement;
  expect(bar.style.width).toBe("28px");
  expect(bar.style.height).toBe("80%");
  expect(bar.style.maxWidth).toBe("100%");
  expect(bar.querySelectorAll("[data-service]")).toHaveLength(2);
  expect(
    (bar.querySelector('[data-service="codex"]') as HTMLElement).style.height,
  ).toBe("75%");
  expect(
    (bar.querySelector('[data-service="claude"]') as HTMLElement).style.height,
  ).toBe("25%");
  expect(screen.getByLabelText("Applications").textContent).toBe(
    "Claude CodeCodexKimi Code",
  );
  expect(
    screen
      .getByRole("button", { name: /Codex: 75\.00, 75.0%/ })
      .getAttribute("aria-label"),
  ).toContain("Claude Code: 25.00, 25.0%");
});
it("uses one service for a single source and keeps an empty column focusable", () => {
  const one = { ...sample, segments: [{ ...sample.segments[0]!, share: 1 }] };
  const zero = { ...sample, key: "2", normalizedValue: 0, segments: [] };
  const { container } = renderChart([one, zero]);
  const bars = container.querySelectorAll('[data-slot="dashboard-bar"]');
  expect(bars[0]!.querySelectorAll("[data-service]")).toHaveLength(1);
  expect(bars[1]!.querySelectorAll("[data-service]")).toHaveLength(0);
  expect(screen.getAllByRole("button")).toHaveLength(2);
});
it("uses configured appearance colors and custom brand colors", () => {
  settings.appearance.brandColors = [
    {
      brand: "codex",
      mode: "brand",
      customHex: null,
      defaultLightHex: "#111111",
      defaultDarkHex: "#dddddd",
    },
    {
      brand: "claude",
      mode: "custom",
      customHex: "#123456",
      defaultLightHex: "#abcdef",
      defaultDarkHex: "#fedcba",
    },
  ];
  const view = renderChart([sample]);
  expect(
    (view.container.querySelector('[data-service="codex"]') as HTMLElement)
      .style.backgroundColor,
  ).toBe("rgb(17, 17, 17)");
  expect(
    (view.container.querySelector('[data-service="claude"]') as HTMLElement)
      .style.backgroundColor,
  ).toBe("rgb(18, 52, 86)");
  bootstrap.appearance = "dark";
  view.rerender(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart data={make([sample])} title="Tokens" metric="tokens" />
      </TooltipProvider>
    </LanguageProvider>,
  );
  expect(
    (view.container.querySelector('[data-service="codex"]') as HTMLElement)
      .style.backgroundColor,
  ).toBe("rgb(221, 221, 221)");
});
it("shows weighted cache-rate contribution labels and shares in the tooltip", async () => {
  const cached = {
    ...sample,
    label: "50%",
    segments: [
      { ...sample.segments[0]!, label: "30.0 pp", share: 0.6 },
      { ...sample.segments[1]!, label: "20.0 pp", share: 0.4 },
    ],
  };
  renderChart([cached], "Cache hit rate", "cacheHitRate");
  fireEvent.focus(screen.getByRole("button", { name: /Codex: 30.0 pp/ }));
  const detail = await screen.findByText("30.0 pp · 60.0%");
  const tooltip = detail.closest('[data-slot="chart-data-tooltip"]')!;
  expect(screen.getByText("20.0 pp · 40.0%")).toBeTruthy();
  expect(tooltip.textContent).toContain("Cache hit rate: 50%");
  expect(tooltip.textContent).not.toContain("Tokens:");
  expect(tooltip.textContent).toContain(
    `Requests: ${totals.requestCount.toLocaleString()}`,
  );
  expect(tooltip.textContent).toContain(`Cost: ${totals.costDisplay}`);
});
