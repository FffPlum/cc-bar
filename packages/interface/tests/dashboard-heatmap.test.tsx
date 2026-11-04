import { fireEvent, render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import type { DashboardHeatmap } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { HeatmapBlocks } from "@/features/stats/dashboard-heatmap";
import { TooltipProvider } from "@/components/ui/tooltip";
import { LanguageProvider } from "@/lib/i18n";
import type { TokenAxisMode } from "@/lib/token-axis-scale";

vi.mock("@/host/host-context", async () => {
  const fixtures = await import("./fixtures");
  return { useHost: () => ({ bootstrap: fixtures.bootstrap }) };
});
// Motion sequencing is covered separately; these tests verify the data views.
vi.mock("@/components/chart-view-transition", () => ({
  ChartViewTransition: ({
    view,
    children,
  }: {
    view: string;
    children: (view: string, interactive: boolean) => React.ReactNode;
  }) => children(view, true),
}));

const totals = usage["window.usage.overview"].totals;
const block = {
  fromDay: "2026-01-05",
  toDay: "2027-01-11",
  cumulativeFromDay: "2025-01-01",
  days: Array.from({ length: 371 }, (_, index) => {
    const date = new Date("2026-01-05T00:00:00Z");
    date.setUTCDate(date.getUTCDate() + index);
    return {
      day: date.toISOString().slice(0, 10),
      cumulativeTokens:
        1_000_000_000 + (((index + 1) * (index + 2)) / 2) * 1_000_000,
      totals: { ...totals, totalTokens: (index + 1) * 1_000_000 },
      value: 1,
      label: "$1",
      normalizedValue: 1,
    };
  }),
  nextBeforeDay: "2026-01-05",
} as DashboardHeatmap;

const chartElement = (input = block, weeklyScale?: TokenAxisMode) => (
  <LanguageProvider language="en">
    <TooltipProvider>
      <HeatmapBlocks
        blocks={[input]}
        today="2026-01-18"
        weeklyScale={weeklyScale}
      />
    </TooltipProvider>
  </LanguageProvider>
);
const setup = (input = block) => render(chartElement(input));

it("puts months below daily cells and removes weekdays and older pagination", () => {
  const { container } = setup();
  const chart = container.querySelector('[data-slot="daily-token-chart"]')!;
  expect(chart.lastElementChild?.getAttribute("data-slot")).toBe(
    "heatmap-month-labels",
  );
  expect(screen.queryByText("Mon")).toBeNull();
  expect(screen.queryByText("Sun")).toBeNull();
  expect(screen.queryByRole("button", { name: "Load older" })).toBeNull();
  expect(screen.getAllByRole("tab").map((tab) => tab.textContent)).toEqual([
    "Daily",
    "Weekly",
    "Cumulative",
  ]);
  expect(screen.queryByLabelText(/^2026-01-19:/)).toBeNull();
});

it("shows natural-week token sums as bars without counting future days", () => {
  const { container } = setup();
  fireEvent.click(screen.getByRole("tab", { name: "Weekly" }));
  expect(
    container.querySelectorAll('[data-slot="weekly-token-bar"]'),
  ).toHaveLength(2);
  expect(
    screen.getByRole("button", {
      name: "2026-01-05 – 2026-01-11: 28.00M Tokens",
    }),
  ).toBeTruthy();
  expect(
    screen.getByRole("button", {
      name: "2026-01-12 – 2026-01-18: 77.00M Tokens",
    }),
  ).toBeTruthy();
  expect(container.querySelector('[data-slot="daily-token-chart"]')).toBeNull();
});

it("shows full historical cumulative Tokens rather than a seven-day or display-window sum", () => {
  const { container } = setup();
  fireEvent.click(screen.getByRole("tab", { name: "Cumulative" }));
  expect(
    container.querySelector('[data-slot="cumulative-token-line"]'),
  ).toBeTruthy();
  expect(
    screen.getByRole("button", {
      name: "2025-01-01 – 2026-01-12: 1.04B Tokens",
    }),
  ).toBeTruthy();
  expect(
    screen.getByRole("button", {
      name: "2025-01-01 – 2026-01-05: 1.00B Tokens",
    }),
  ).toBeTruthy();
  expect(screen.getByText("Cumulative Token Usage")).toBeTruthy();
  expect(screen.queryByRole("button", { name: /\/7 days/ })).toBeNull();
  expect(
    container.querySelectorAll('[data-slot="weekly-token-bar"]'),
  ).toHaveLength(0);
  fireEvent.click(screen.getByRole("tab", { name: "Daily" }));
  expect(
    screen.getByRole("button", { name: "2026-01-05: 1,000,000 Tokens" }),
  ).toBeTruthy();
});

it("draws zero-usage days horizontally and rises when historical usage increases", () => {
  const { container } = setup({
    ...block,
    days: block.days.map((day, index) => ({
      ...day,
      cumulativeTokens: index < 2 ? 100 : 1_000,
      totals: {
        ...day.totals,
        totalTokens: index === 0 ? 10 : index === 2 ? 900 : 0,
      },
    })),
  });
  fireEvent.click(screen.getByRole("tab", { name: "Cumulative" }));
  const points = container
    .querySelector('[data-slot="cumulative-token-line"]')!
    .getAttribute("points")!
    .split(" ")
    .map((point) => Number(point.split(",")[1]));
  expect(points).toHaveLength(14);
  expect(points[1]).toBe(points[0]);
  expect(points[2]).toBeLessThan(points[1]!);
  expect(points.slice(2).every((y) => y === points[2])).toBe(true);
});

it.each([
  [0, ["0", "1", "2"]],
  [1, ["0", "1", "2"]],
  [3, ["0", "2", "4"]],
] as const)(
  "keeps weekly axis labels distinct for a %i-Token week",
  (tokens, labels) => {
    const { container } = setup({
      ...block,
      days: block.days.map((day, index) => ({
        ...day,
        totals: { ...day.totals, totalTokens: index === 0 ? tokens : 0 },
      })),
    });
    fireEvent.click(screen.getByRole("tab", { name: "Weekly" }));
    expect(
      Array.from(
        container.querySelectorAll('[data-slot="token-value-tick"]'),
        (tick) => tick.textContent,
      ),
    ).toEqual(labels);
  },
);

it("uses the weekly peak for both axis labels and linear bar heights", () => {
  const { container } = setup({
    ...block,
    days: block.days.map((day, index) => ({
      ...day,
      totals: {
        ...day.totals,
        totalTokens: index === 0 ? 837_200_000 : index === 7 ? 425_000_000 : 0,
      },
    })),
  });
  fireEvent.click(screen.getByRole("tab", { name: "Weekly" }));
  expect(
    container
      .querySelector('[data-slot="weekly-token-chart"]')
      ?.getAttribute("data-scale"),
  ).toBe("linear");
  const ticks = Array.from(
    container.querySelectorAll<HTMLElement>('[data-slot="token-value-tick"]'),
  );
  expect(ticks.map((tick) => tick.textContent)).toEqual(["0", "425M", "850M"]);
  expect(ticks.map((tick) => tick.style.top)).toEqual(["97.5%", "50%", "2.5%"]);
  const bars = Array.from(
    container.querySelectorAll<HTMLElement>('[data-slot="weekly-token-bar"]'),
  );
  expect(parseFloat(bars[0]!.style.height)).toBeCloseTo(93.57, 2);
  expect(parseFloat(bars[1]!.style.height)).toBe(47.5);
});

it("switches the weekly scale through props without adding controls or changing raw Tokens", () => {
  const input = {
    ...block,
    days: block.days.map((day, index) => ({
      ...day,
      totals: {
        ...day.totals,
        totalTokens: index === 0 ? 1_000_000 : index === 7 ? 100_000_000 : 0,
      },
    })),
  };
  const { container, rerender } = setup(input);
  fireEvent.click(screen.getByRole("tab", { name: "Weekly" }));
  const chart = container.querySelector('[data-slot="weekly-token-chart"]');
  const firstBar = container.querySelector<HTMLElement>(
    '[data-slot="weekly-token-bar"]',
  )!;
  expect(parseFloat(firstBar.style.height)).toBeCloseTo(0.95);

  rerender(chartElement(input, "log"));
  expect(container.querySelector('[data-slot="weekly-token-chart"]')).toBe(
    chart,
  );
  expect(chart?.getAttribute("data-scale")).toBe("log");
  expect(parseFloat(firstBar.style.height)).toBeCloseTo(71.25, 4);
  expect(
    screen.getByRole("button", {
      name: "2026-01-05 – 2026-01-11: 1.00M Tokens",
    }),
  ).toBeTruthy();
  const ticks = Array.from(
    container.querySelectorAll<HTMLElement>('[data-slot="token-value-tick"]'),
  );
  const gridlines = Array.from(
    container.querySelectorAll<HTMLElement>(
      '[data-slot="token-value-gridline"]',
    ),
  );
  expect(ticks.map((tick) => tick.textContent)).toEqual(["0", "10K", "100M"]);
  expect(ticks.map((tick) => tick.style.top)).toEqual(
    gridlines.map((line) => line.style.top),
  );
  expect(screen.queryByRole("button", { name: /log|linear/i })).toBeNull();

  fireEvent.click(screen.getByRole("tab", { name: "Cumulative" }));
  expect(
    container
      .querySelector('[data-slot="cumulative-token-chart"]')
      ?.getAttribute("data-scale"),
  ).toBe("linear");
  fireEvent.click(screen.getByRole("tab", { name: "Weekly" }));
  rerender(chartElement(input, "linear"));
  expect(
    parseFloat(
      container.querySelector<HTMLElement>('[data-slot="weekly-token-bar"]')!
        .style.height,
    ),
  ).toBeCloseTo(0.95);
});
