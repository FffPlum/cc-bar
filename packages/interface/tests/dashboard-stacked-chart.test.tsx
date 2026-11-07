import { cloneElement, type ReactElement } from "react";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import type {
  DashboardHeatmap,
  DashboardMetric,
  DashboardSample,
  UsageDashboard,
  UsageService,
} from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import {
  DashboardChart,
  HeatmapBlocks,
} from "@/features/stats/dashboard-charts";
import { DashboardAreaChart } from "@/features/stats/dashboard-area-chart";
import { LanguageProvider } from "@/lib/i18n";
import { TooltipProvider } from "@/components/ui/tooltip";
import { bootstrap, settings } from "./fixtures";
vi.mock("@/host/host-context", async () => {
  const f = await import("./fixtures");
  return { useHost: () => ({ bootstrap: f.bootstrap, settings: f.settings }) };
});
vi.mock("recharts", async (importOriginal) => {
  const actual = await importOriginal<typeof import("recharts")>();
  return {
    ...actual,
    // jsdom does not lay out containers; keep the real chart and series renderers.
    ResponsiveContainer: ({
      children,
    }: {
      children: ReactElement<{ width?: number; height?: number }>;
    }) => cloneElement(children, { width: 600, height: 160 }),
  };
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
      service: "codex",
      totals: { ...totals, totalTokens: 75 },
      value: 75,
      label: "75",
      share: 0.75,
    },
    {
      service: "claude",
      totals: { ...totals, totalTokens: 25 },
      value: 25,
      label: "25",
      share: 0.25,
    },
    {
      service: "kimi",
      totals: { ...totals, totalTokens: 0 },
      value: 0,
      label: "0",
      share: 0,
    },
  ],
} as unknown as DashboardSample;
const make = (
  samples: DashboardSample[],
  axisTicks: UsageDashboard["axisTicks"] = [],
) =>
  ({
    samples,
    axisTicks,
    resolvedRange: { granularity: "day" },
    coverage: { precision: "event" },
  }) as unknown as UsageDashboard;
const renderChart = (
  samples: DashboardSample[],
  title = "Tokens",
  metric: DashboardMetric = "tokens",
  service?: UsageService,
) =>
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart
          data={make(samples)}
          title={title}
          metric={metric}
          service={service}
        />
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
  expect(card!.textContent).not.toMatch(/Requests:|Cost:/);
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
            {
              ...second,
              label: "250",
              totals: { ...totals, totalTokens: 250 },
            },
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
        <HeatmapBlocks blocks={[block]} />
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
  expect(card!.textContent).not.toMatch(/Requests:|Cost:/);
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

it("keeps the old and new chart mounted together during a view crossfade", async () => {
  const block = {
    fromDay: "2026-11-02",
    toDay: "2027-11-08",
    days: [
      {
        day: "2026-11-02",
        totals,
        value: 100,
        label: "100",
        normalizedValue: 1,
      },
    ],
    totals,
    nextBeforeDay: null,
  } as DashboardHeatmap;
  const result = render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <HeatmapBlocks blocks={[block]} today="2026-11-02" />
      </TooltipProvider>
    </LanguageProvider>,
  );
  const daily = result.container.querySelector(
    '[data-slot="daily-token-chart"]',
  );
  fireEvent.click(screen.getByRole("tab", { name: "Weekly" }));
  expect(
    result.container.querySelector('[data-slot="daily-token-chart"]'),
  ).toBe(daily);
  const weekly = result.container.querySelector(
    '[data-slot="weekly-token-chart"]',
  );
  expect(weekly).toBeTruthy();
  for (const chart of [daily, weekly]) {
    expect(
      chart
        ?.closest(".cc-chart-view-transition-content")
        ?.hasAttribute("inert"),
    ).toBe(true);
  }
  await waitFor(() => expect(daily?.isConnected).toBe(false));
  expect(
    result.container.querySelector('[data-slot="weekly-token-chart"]'),
  ).toBe(weekly);
  expect(
    weekly?.closest(".cc-chart-view-transition-content")?.hasAttribute("inert"),
  ).toBe(false);
});
afterEach(() => {
  bootstrap.appearance = "light";
  bootstrap.visibleUsageServices = [];
  settings.appearance.brandColors = [];
  settings.appearance.statsChartType = "bar";
});
it("combines application segments into one column using the configured service order", () => {
  bootstrap.visibleUsageServices = ["claude", "codex", "kimi"];
  const { container } = renderChart([sample]);
  const bars = container.querySelectorAll<HTMLElement>(
    '[data-slot="dashboard-bar"]',
  );
  expect(bars).toHaveLength(1);
  expect(bars[0]!.style.height).toBe("80%");
  const segments = Array.from(
    bars[0]!.querySelectorAll<HTMLElement>("[data-service]"),
  );
  expect(segments.map((segment) => segment.dataset.service)).toEqual([
    "claude",
    "codex",
  ]);
  expect(segments.map((segment) => parseFloat(segment.style.height))).toEqual([
    25, 75,
  ]);
  expect(
    container.querySelector('[data-slot="dashboard-bar-group"]'),
  ).toBeNull();
  expect(screen.getByLabelText("Applications").textContent).toBe(
    "Claude CodeCodexKimi Code",
  );
  expect(
    screen
      .getByRole("button", { name: /Codex: 75\.00, 75.0%/ })
      .getAttribute("aria-label"),
  ).toContain("Claude Code: 25.00, 25.0%");
});

it("keeps missing and zero segments out of combined columns while retaining empty date targets", () => {
  bootstrap.visibleUsageServices = ["claude", "codex", "kimi"];
  const second = {
    ...sample,
    key: "2",
    start: "2026-11-03T00:00:00Z",
    segments: [{ ...sample.segments[0]!, share: 1 }],
  };
  const empty = { ...sample, key: "3", normalizedValue: 0, segments: [] };
  const { container } = renderChart([sample, second, empty]);
  const bars = Array.from(
    container.querySelectorAll<HTMLElement>('[data-slot="dashboard-bar"]'),
  );
  expect(bars).toHaveLength(3);
  expect(
    bars.map((bar) =>
      Array.from(bar.querySelectorAll<HTMLElement>("[data-service]")).map(
        (segment) => segment.dataset.service,
      ),
    ),
  ).toEqual([["claude", "codex"], ["codex"], []]);
  expect(bars[2]!.style.height).toBe("0%");
  expect(screen.getAllByRole("button")).toHaveLength(3);
});

it("keeps a single application's full-height column within the existing width limit", () => {
  const one = { ...sample, segments: [{ ...sample.segments[0]!, share: 1 }] };
  const { container } = renderChart([one], "Tokens", "tokens", "codex");
  const bar = container.querySelector<HTMLElement>(
    '[data-slot="dashboard-bar"]',
  )!;
  expect(
    bar.querySelector<HTMLElement>('[data-service="codex"]')?.style.height,
  ).toBe("100%");
  expect(parseFloat(bar.style.height)).toBeCloseTo(80);
  expect(bar.style.width).toBe("28px");
  expect(bar.style.maxWidth).toBe("100%");
});

it("uses configured appearance colors and custom brand colors for combined column segments", () => {
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
  const bar = (service: UsageService) =>
    view.container.querySelector<HTMLElement>(
      `[data-slot="dashboard-bar"] [data-service="${service}"]`,
    )!;
  expect(bar("codex").style.backgroundColor).toBe("rgb(17, 17, 17)");
  expect(bar("claude").style.backgroundColor).toBe("rgb(18, 52, 86)");
  bootstrap.appearance = "dark";
  view.rerender(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart data={make([sample])} title="Tokens" metric="tokens" />
      </TooltipProvider>
    </LanguageProvider>,
  );
  expect(bar("codex").style.backgroundColor).toBe("rgb(221, 221, 221)");
});

function cacheSample(): DashboardSample {
  return {
    ...sample,
    label: "52.5%",
    normalizedValue: 0.8,
    totals: {
      ...totals,
      cacheReadTokens: 105,
      inputWithCacheTokens: 200,
      cacheHitRate: 0.525,
    },
    segments: [
      {
        ...sample.segments[0]!,
        label: "12.5 pp",
        share: 25 / 105,
        totals: {
          ...totals,
          cacheReadTokens: 25,
          inputWithCacheTokens: 100,
          cacheHitRate: 0.25,
        },
      },
      {
        ...sample.segments[1]!,
        label: "40.0 pp",
        share: 80 / 105,
        totals: {
          ...totals,
          cacheReadTokens: 80,
          inputWithCacheTokens: 100,
          cacheHitRate: 0.8,
        },
      },
      {
        ...sample.segments[2]!,
        label: "0.0 pp",
        share: 0,
        totals: {
          ...totals,
          cacheReadTokens: 0,
          inputWithCacheTokens: 0,
          cacheHitRate: 0,
        },
      },
    ],
  };
}

it("uses the lowest valid application rate across dates for the same bar and area scale", async () => {
  bootstrap.visibleUsageServices = ["kimi", "codex", "claude"];
  const base = cacheSample();
  const lowest = {
    ...base,
    label: "95.3%",
    totals: {
      ...base.totals,
      cacheReadTokens: 1048,
      inputWithCacheTokens: 1100,
      cacheHitRate: 1048 / 1100,
    },
    segments: [
      {
        ...base.segments[0]!,
        service: "codex" as const,
        totals: {
          ...base.totals,
          cacheReadTokens: 960,
          inputWithCacheTokens: 1000,
          cacheHitRate: 0.96,
        },
      },
      {
        ...base.segments[2]!,
        service: "kimi" as const,
        totals: {
          ...base.totals,
          cacheReadTokens: 88,
          inputWithCacheTokens: 100,
          cacheHitRate: 0.88,
        },
      },
      {
        ...base.segments[1]!,
        service: "claude" as const,
        totals: {
          ...base.totals,
          cacheReadTokens: 0,
          inputWithCacheTokens: 0,
          cacheHitRate: 0,
        },
      },
    ],
  };
  const earlier = {
    ...lowest,
    key: "earlier",
    start: "2026-11-01T00:00:00Z",
    label: "96%",
    totals: {
      ...lowest.totals,
      cacheReadTokens: 960,
      inputWithCacheTokens: 1000,
      cacheHitRate: 0.96,
    },
    segments: [lowest.segments[0]!, lowest.segments[2]!],
  };
  const chart = () => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart
          data={make(
            [earlier, lowest],
            [
              { position: 0, label: "90%" },
              { position: 0.5, label: "95%" },
              { position: 1, label: "100%" },
            ],
          )}
          title="Cache hit rate"
          metric="cacheHitRate"
        />
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(chart());
  const axisLabels = () =>
    Array.from(
      view.container.querySelectorAll('[data-slot="dashboard-axis-tick"]'),
    ).map((tick) => tick.textContent);
  expect(axisLabels()).toEqual(["80%", "90%", "100%"]);
  const groups = Array.from(
    view.container.querySelectorAll('[data-slot="dashboard-bar-group"]'),
  );
  expect(groups).toHaveLength(2);
  const slots = groups.map((group) =>
    Array.from(group.querySelectorAll('[data-slot="dashboard-bar-slot"]')),
  );
  expect(
    slots.map((items) =>
      items.map(
        (slot) =>
          slot.querySelector<HTMLElement>('[data-slot="dashboard-bar"]')
            ?.dataset.service,
      ),
    ),
  ).toEqual([
    [undefined, "codex", undefined],
    ["kimi", "codex", undefined],
  ]);
  const bars = Array.from(
    groups[1]!.querySelectorAll<HTMLElement>('[data-slot="dashboard-bar"]'),
  );
  expect(parseFloat(bars[0]!.style.height)).toBeCloseTo(40);
  expect(parseFloat(bars[1]!.style.height)).toBeCloseTo(80);
  expect(screen.getByLabelText("Applications").textContent).toBe(
    "Kimi CodeCodexClaude Code",
  );
  const labels = screen
    .getAllByRole("button")
    .map((button) => button.getAttribute("aria-label"));
  expect(labels[1]).toContain("Kimi Code: 88%");
  expect(labels[1]).toContain("Codex: 96%");
  expect(labels[1]).not.toMatch(/pp|Claude Code: 0/);

  settings.appearance.statsChartType = "area";
  view.rerender(chart());
  expect(axisLabels()).toEqual(["80%", "90%", "100%"]);
  expect(
    view.container.querySelector('[data-slot="dashboard-bar"]'),
  ).toBeNull();
  expect(
    screen
      .getAllByRole("button")
      .map((button) => button.getAttribute("aria-label")),
  ).toEqual(labels);
  act(() => screen.getAllByRole("button")[1]!.focus());
  const tooltip = (await screen.findByText("Cache hit rate: 95.3%")).closest(
    '[data-slot="chart-data-tooltip"]',
  )!;
  expect(tooltip.textContent).toMatch(/Kimi Code.*88%/);
  expect(tooltip.textContent).toMatch(/Codex.*96%/);
  const points = Array.from(
    view.container.querySelectorAll<HTMLElement>(
      '[data-slot="dashboard-area-point"]',
    ),
  );
  expect(points.map((point) => point.dataset.service)).toEqual([
    "kimi",
    "codex",
  ]);
  expect(parseFloat(points[0]!.style.bottom)).toBeCloseTo(40);
  expect(parseFloat(points[1]!.style.bottom)).toBeCloseTo(80);
  await waitFor(() =>
    expect(view.container.querySelectorAll(".recharts-area-dot")).toHaveLength(
      3,
    ),
  );
  const curveHeights = Array.from(
    view.container.querySelectorAll(".recharts-area-dot"),
  )
    .map((dot) => Number(dot.getAttribute("cy")))
    .sort((a, b) => a - b);
  expect(curveHeights[0]).toBeCloseTo(32);
  expect(curveHeights[1]).toBeCloseTo(32);
  expect(curveHeights[2]).toBeCloseTo(96);
});

it("compares low application cache rates in area mode on a 0–100% axis", async () => {
  bootstrap.visibleUsageServices = ["claude", "codex", "kimi"];
  settings.appearance.statsChartType = "area";
  const { container } = renderChart(
    [cacheSample()],
    "Cache hit rate",
    "cacheHitRate",
  );
  expect(container.querySelector('[data-slot="dashboard-bar"]')).toBeNull();
  const ticks = Array.from(
    container.querySelectorAll('[data-slot="dashboard-axis-tick"]'),
  );
  expect(ticks.map((tick) => tick.textContent).sort()).toEqual([
    "0%",
    "100%",
    "50%",
  ]);
  expect(screen.getByLabelText("Applications").textContent).toBe(
    "Claude CodeCodexKimi Code",
  );
  const trigger = screen.getByRole("button", { name: /Cache read tokens/ });
  expect(trigger.getAttribute("aria-label")).toContain("Codex: 25%");
  expect(trigger.getAttribute("aria-label")).toContain("Claude Code: 80%");
  expect(trigger.getAttribute("aria-label")).not.toMatch(
    /pp|23\.8%|76\.2%|Kimi Code: 0/,
  );
  expect(
    container.querySelectorAll('[data-slot="dashboard-area-point"]'),
  ).toHaveLength(0);
  fireEvent.focus(trigger);
  const detail = await screen.findByText("Cache read tokens: 105.00");
  const tooltip = detail.closest('[data-slot="chart-data-tooltip"]')!;
  expect(tooltip.textContent).toContain("Cache hit rate: 52.5%");
  expect(tooltip.textContent).toMatch(/Codex.*25%/);
  expect(tooltip.textContent).toMatch(/Claude Code.*80%/);
  expect(tooltip.textContent).not.toMatch(/pp|23\.8%|76\.2%|Requests:|Cost:/);
  const points = Array.from(
    container.querySelectorAll<HTMLElement>(
      '[data-slot="dashboard-area-point"]',
    ),
  );
  expect(points.map((point) => point.dataset.service)).toEqual([
    "claude",
    "codex",
  ]);
  expect(points.map((point) => parseFloat(point.style.bottom))).toEqual([
    80, 25,
  ]);
});

it("marks a true zero cache rate but does not mark a zero-input application", async () => {
  settings.appearance.statsChartType = "area";
  const cached = cacheSample();
  cached.segments[0]!.totals.cacheReadTokens = 0;
  cached.segments[0]!.totals.cacheHitRate = 0;
  const { container } = renderChart([cached], "Cache hit rate", "cacheHitRate");
  fireEvent.focus(screen.getByRole("button", { name: /Cache read tokens/ }));
  await screen.findByText("Cache read tokens: 105.00");
  const zero = container.querySelector<HTMLElement>(
    '[data-slot="dashboard-area-point"][data-service="codex"]',
  )!;
  expect(parseFloat(zero.style.bottom)).toBe(0);
  expect(
    container.querySelector(
      '[data-slot="dashboard-area-point"][data-service="kimi"]',
    ),
  ).toBeNull();
});

it("shows an unavailable total cache rate when the sample has no input tokens", async () => {
  const cached = cacheSample();
  cached.label = "0%";
  cached.normalizedValue = 0;
  cached.totals = {
    ...cached.totals,
    cacheReadTokens: 0,
    inputWithCacheTokens: 0,
    cacheHitRate: 0,
  };
  cached.segments = [];
  const { container } = renderChart([cached], "Cache hit rate", "cacheHitRate");
  expect(
    Array.from(
      container.querySelectorAll('[data-slot="dashboard-axis-tick"]'),
    ).map((tick) => tick.textContent),
  ).toEqual(["0%", "50%", "100%"]);
  expect(container.querySelector('[data-slot="dashboard-bar"]')).toBeNull();
  const trigger = screen.getByRole("button", { name: /Cache read tokens/ });
  expect(trigger.getAttribute("aria-label")).toMatch(
    /: —; Cache read tokens: 0\.00/,
  );
  fireEvent.focus(trigger);
  const tooltip = (await screen.findByText("Cache hit rate: —")).closest(
    '[data-slot="chart-data-tooltip"]',
  )!;
  expect(tooltip.textContent).toContain("Cache read tokens: 0.00");
  expect(tooltip.textContent).not.toContain("Cache hit rate: 0%");
});

it("preserves the selected application's cache scale, brand color and aggregate-only detail", async () => {
  settings.appearance.brandColors = [
    {
      brand: "codex",
      mode: "brand",
      customHex: null,
      defaultLightHex: "#111111",
      defaultDarkHex: "#dddddd",
    },
  ];
  const cached = cacheSample();
  const axisTicks = [
    { position: 0, label: "40%" },
    { position: 0.5, label: "50%" },
    { position: 1, label: "60%" },
  ];
  const chart = () => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart
          data={make([cached], axisTicks)}
          title="Cache hit rate"
          metric="cacheHitRate"
          service="codex"
        />
      </TooltipProvider>
    </LanguageProvider>
  );
  const view = render(chart());
  const bar = () =>
    view.container.querySelector<HTMLElement>('[data-slot="dashboard-bar"]')!;
  expect(
    view.container.querySelectorAll('[data-slot="dashboard-bar"]'),
  ).toHaveLength(1);
  expect(bar().style.height).toBe("80%");
  expect(bar().style.backgroundColor).toBe("rgb(17, 17, 17)");
  expect(
    Array.from(
      view.container.querySelectorAll('[data-slot="dashboard-axis-tick"]'),
    ).map((tick) => tick.textContent),
  ).toEqual(["40%", "50%", "60%"]);
  bootstrap.appearance = "dark";
  view.rerender(chart());
  expect(bar().style.backgroundColor).toBe("rgb(221, 221, 221)");
  settings.appearance.brandColors[0]!.mode = "custom";
  settings.appearance.brandColors[0]!.customHex = "#123456";
  view.rerender(chart());
  expect(bar().style.backgroundColor).toBe("rgb(18, 52, 86)");
  const trigger = screen.getByRole("button", { name: /Cache read tokens/ });
  expect(trigger.getAttribute("aria-label")).not.toMatch(/Codex|Claude|pp/);
  fireEvent.focus(trigger);
  const tooltip = (
    await screen.findByText("Cache read tokens: 105.00")
  ).closest('[data-slot="chart-data-tooltip"]')!;
  expect(tooltip.textContent).toContain("Cache hit rate: 52.5%");
  expect(tooltip.textContent).not.toMatch(/Codex|Claude|Kimi|pp/);
});

it("switches to real gradient areas without changing category targets, values or axes", async () => {
  bootstrap.visibleUsageServices = ["claude", "codex", "kimi"];
  const second = { ...sample, key: "2", start: "2026-11-09T00:00:00Z" };
  const view = renderChart([sample, second]);
  const labels = screen
    .getAllByRole("button")
    .map((node) => node.getAttribute("aria-label"));
  const axis = view.container.querySelector(
    '[data-slot="dashboard-y-axis"]',
  )?.textContent;
  settings.appearance.statsChartType = "area";
  view.rerender(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart
          data={make([sample, second])}
          title="Tokens"
          metric="tokens"
        />
      </TooltipProvider>
    </LanguageProvider>,
  );
  expect(
    view.container.querySelector('[data-slot="dashboard-bar"]'),
  ).toBeNull();
  const area = view.container.querySelector<HTMLElement>(
    '[data-slot="dashboard-area"]',
  )!;
  await waitFor(() =>
    expect(area.querySelectorAll(".recharts-area-area")).toHaveLength(2),
  );
  const gradients = Array.from(area.querySelectorAll("linearGradient"));
  expect(gradients.map((gradient) => gradient.id.split("-").at(-1))).toEqual([
    "claude",
    "codex",
  ]);
  gradients.forEach((gradient) => {
    const stops = Array.from(gradient.querySelectorAll("stop"));
    expect(stops).toHaveLength(2);
    expect(Number(stops[0]!.getAttribute("stop-opacity"))).toBeGreaterThan(
      Number(stops[1]!.getAttribute("stop-opacity")),
    );
    expect(
      area.querySelector(`.recharts-area-area[fill="url(#${gradient.id})"]`),
    ).toBeTruthy();
  });
  expect(
    screen
      .getAllByRole("button")
      .map((node) => node.getAttribute("aria-label")),
  ).toEqual(labels);
  expect(
    view.container.querySelector('[data-slot="dashboard-y-axis"]')?.textContent,
  ).toBe(axis);
  fireEvent.focus(screen.getAllByRole("button")[0]!);
  expect(await screen.findByText("Tokens: 100.00")).toBeTruthy();
  expect(await screen.findByText("75.00 · 75.0%")).toBeTruthy();
});

it("marks each application's actual curve value only for the date whose tooltip is open", async () => {
  settings.appearance.statsChartType = "area";
  const firstSample = { ...sample, segments: sample.segments.slice(0, 2) };
  const secondSample = {
    ...firstSample,
    key: "2",
    start: "2026-11-03T00:00:00Z",
    normalizedValue: 0.5,
    totals: { ...totals, totalTokens: 200 },
    segments: [
      {
        ...firstSample.segments[0]!,
        share: 0.4,
        totals: { ...totals, totalTokens: 80 },
      },
      {
        ...firstSample.segments[1]!,
        share: 0.6,
        totals: { ...totals, totalTokens: 120 },
      },
    ],
  };
  const { container } = renderChart([firstSample, secondSample]);
  const [first, next] = screen.getAllByRole("button");
  const points = () =>
    Array.from(
      container.querySelectorAll<HTMLElement>(
        '[data-slot="dashboard-area-point"]',
      ),
    );
  const pointFor = (service: UsageService) =>
    points().find((point) => point.dataset.service === service)!;
  expect(points()).toHaveLength(0);
  fireEvent.mouseEnter(first!);
  const card = (await screen.findByText("Tokens: 100.00")).closest(
    '[data-slot="chart-data-tooltip"]',
  )!;
  expect(points()).toHaveLength(2);
  expect(
    first!.querySelectorAll('[data-slot="dashboard-area-point"]'),
  ).toHaveLength(2);
  expect(parseFloat(pointFor("codex").style.bottom)).toBeCloseTo(60);
  expect(parseFloat(pointFor("claude").style.bottom)).toBeCloseTo(20);

  fireEvent.mouseLeave(first!, { relatedTarget: next });
  fireEvent.mouseEnter(next!, { relatedTarget: first });
  expect(
    (await screen.findByText("Tokens: 200.00")).closest(
      '[data-slot="chart-data-tooltip"]',
    ),
  ).toBe(card);
  expect(points()).toHaveLength(2);
  expect(
    first!.querySelectorAll('[data-slot="dashboard-area-point"]'),
  ).toHaveLength(0);
  expect(
    next!.querySelectorAll('[data-slot="dashboard-area-point"]'),
  ).toHaveLength(2);
  expect(parseFloat(pointFor("codex").style.bottom)).toBeCloseTo(20);
  expect(parseFloat(pointFor("claude").style.bottom)).toBeCloseTo(30);
  fireEvent.mouseLeave(next!);
  await waitFor(() => expect(points()).toHaveLength(0));
});

it("supports keyboard markers and Escape while preserving a real zero and omitting a missing application", async () => {
  settings.appearance.statsChartType = "area";
  const firstSample = { ...sample, segments: sample.segments.slice(0, 2) };
  const zeroSample = {
    ...firstSample,
    key: "2",
    start: "2026-11-03T00:00:00Z",
    normalizedValue: 0,
    totals: { ...totals, totalTokens: 0 },
    segments: [
      {
        ...firstSample.segments[0]!,
        share: 0,
        totals: { ...totals, totalTokens: 0 },
      },
    ],
  };
  const { container } = renderChart([firstSample, zeroSample]);
  const [first, next] = screen.getAllByRole("button");
  const points = () =>
    Array.from(
      container.querySelectorAll<HTMLElement>(
        '[data-slot="dashboard-area-point"]',
      ),
    );
  act(() => first!.focus());
  expect(document.activeElement).toBe(first);
  await screen.findByText("Tokens: 100.00");
  expect(first!.hasAttribute("data-popup-open")).toBe(true);
  expect(points()).toHaveLength(2);
  fireEvent.keyDown(document, { key: "Escape" });
  await waitFor(() => expect(points()).toHaveLength(0));
  expect(first!.hasAttribute("data-popup-open")).toBe(false);
  act(() => next!.focus());
  expect(document.activeElement).toBe(next);
  const details = await screen.findByText("Tokens: 0.00");
  expect(next!.hasAttribute("data-popup-open")).toBe(true);
  expect(
    details.closest<HTMLElement>('[data-slot="chart-data-tooltip-positioner"]')!
      .style.visibility,
  ).toBe("visible");
  expect(points()).toHaveLength(1);
  expect(points()[0]!.dataset.service).toBe("codex");
  expect(points()[0]!.style.bottom).toBe("0%");
  fireEvent.keyDown(document, { key: "Escape" });
  await waitFor(() => expect(points()).toHaveLength(0));
  expect(next!.hasAttribute("data-popup-open")).toBe(false);
});

it("renders equal cache rates at the same height instead of stacking them", async () => {
  const cached = cacheSample();
  cached.segments = cached.segments.slice(0, 2).map((segment) => ({
    ...segment,
    totals: { ...segment.totals, cacheHitRate: 0.7 },
  }));
  const view = render(
    <DashboardAreaChart
      samples={[cached]}
      services={["codex", "claude"]}
      metric="cacheHitRate"
      independentRates
      colorFor={() => "#123456"}
      aggregateColor="#000000"
    />,
  );
  await waitFor(() =>
    expect(
      view.container.querySelectorAll(".recharts-area-curve"),
    ).toHaveLength(2),
  );
  const curves = Array.from(
    view.container.querySelectorAll(".recharts-area-curve"),
  );
  expect(curves[0]!.getAttribute("d")).toBeTruthy();
  expect(curves[0]!.getAttribute("d")).toBe(curves[1]!.getAttribute("d"));
});

it("renders equal token contributions as independent curves at the same height", async () => {
  const equal = {
    ...sample,
    segments: sample.segments
      .slice(0, 2)
      .map((segment) => ({ ...segment, share: 0.5 })),
  };
  const view = render(
    <DashboardAreaChart
      samples={[equal]}
      services={["codex", "claude"]}
      metric="tokens"
      independentRates={false}
      colorFor={() => "#123456"}
      aggregateColor="#000000"
    />,
  );
  await waitFor(() =>
    expect(
      view.container.querySelectorAll(".recharts-area-curve"),
    ).toHaveLength(2),
  );
  const curves = Array.from(
    view.container.querySelectorAll(".recharts-area-curve"),
  );
  expect(curves[0]!.getAttribute("d")).toBeTruthy();
  expect(curves[1]!.getAttribute("d")).toBeTruthy();
  expect(curves[0]!.getAttribute("d")).toBe(curves[1]!.getAttribute("d"));
});

it.each(["missing", "zero input"] as const)(
  "keeps a gap for %s cache rates instead of drawing an invented zero",
  async (availability) => {
    const first = cacheSample();
    first.segments = first.segments.slice(0, 1);
    const missing = {
      ...first,
      key: "2",
      segments:
        availability === "missing"
          ? []
          : [
              {
                ...first.segments[0]!,
                totals: {
                  ...first.segments[0]!.totals,
                  inputWithCacheTokens: 0,
                },
              },
            ],
    };
    const last = { ...first, key: "3", start: "2026-11-04T00:00:00Z" };
    const view = render(
      <DashboardAreaChart
        samples={[first, missing, last]}
        services={["codex"]}
        metric="cacheHitRate"
        independentRates
        colorFor={() => "#123456"}
        aggregateColor="#000000"
      />,
    );
    await waitFor(() =>
      expect(
        view.container.querySelector(".recharts-area-curve")?.getAttribute("d"),
      ).toBeTruthy(),
    );
    const curve = view.container
      .querySelector(".recharts-area-curve")!
      .getAttribute("d")!;
    expect(curve.match(/M/g)).toHaveLength(2);
  },
);

it("marks only real cache-rate observations, without dots at extended edges or missing buckets", async () => {
  const first = cacheSample();
  first.segments = first.segments.slice(0, 1);
  const missing = { ...first, key: "2", segments: [] };
  const last = { ...first, key: "3", start: "2026-11-04T00:00:00Z" };
  const view = render(
    <DashboardAreaChart
      samples={[first, missing, last]}
      services={["codex"]}
      metric="cacheHitRate"
      independentRates
      colorFor={() => "#123456"}
      aggregateColor="#000000"
    />,
  );
  await waitFor(() =>
    expect(view.container.querySelectorAll(".recharts-area-dot")).toHaveLength(
      2,
    ),
  );
  const points = Array.from(
    view.container.querySelectorAll(".recharts-area-dot"),
  );
  expect(points.map((point) => Number(point.getAttribute("cx")))).toEqual([
    100, 500,
  ]);
});

it("leaves selected-application cache data without a denominator as a gap and without an active marker", async () => {
  settings.appearance.statsChartType = "area";
  const first = cacheSample();
  const missing = {
    ...first,
    key: "2",
    start: "2026-11-03T00:00:00Z",
    normalizedValue: 0,
    totals: {
      ...first.totals,
      cacheReadTokens: 0,
      inputWithCacheTokens: 0,
      cacheHitRate: 0,
    },
  };
  const last = { ...first, key: "3", start: "2026-11-04T00:00:00Z" };
  const { container } = renderChart(
    [first, missing, last],
    "Cache hit rate",
    "cacheHitRate",
    "codex",
  );
  await waitFor(() =>
    expect(
      container.querySelector(".recharts-area-curve")?.getAttribute("d"),
    ).toBeTruthy(),
  );
  expect(
    container
      .querySelector(".recharts-area-curve")!
      .getAttribute("d")!
      .match(/M/g),
  ).toHaveLength(2);
  fireEvent.focus(screen.getAllByRole("button")[1]!);
  await screen.findByText("Cache hit rate: —");
  expect(
    container.querySelectorAll('[data-slot="dashboard-area-point"]'),
  ).toHaveLength(0);
});

it("retains one aggregate area and aggregate-only tooltip for a selected application's cache rate", async () => {
  settings.appearance.statsChartType = "area";
  const view = renderChart(
    [cacheSample()],
    "Cache hit rate",
    "cacheHitRate",
    "codex",
  );
  const area = view.container.querySelector('[data-slot="dashboard-area"]')!;
  await waitFor(() =>
    expect(area.querySelectorAll(".recharts-area-area")).toHaveLength(1),
  );
  expect(area.querySelector("linearGradient")?.id).toMatch(/-total$/);
  fireEvent.focus(screen.getByRole("button", { name: /Cache read tokens/ }));
  const tooltip = (
    await screen.findByText("Cache read tokens: 105.00")
  ).closest('[data-slot="chart-data-tooltip"]')!;
  expect(tooltip.textContent).toContain("Cache hit rate: 52.5%");
  expect(tooltip.textContent).not.toMatch(/Codex|Claude|Kimi|pp/);
  const points = view.container.querySelectorAll<HTMLElement>(
    '[data-slot="dashboard-area-point"]',
  );
  expect(points).toHaveLength(1);
  expect(points[0]!.dataset.service).toBe("codex");
  expect(points[0]!.style.bottom).toBe("80%");
});
