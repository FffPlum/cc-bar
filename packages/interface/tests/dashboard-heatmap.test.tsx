import { fireEvent, render, screen } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import type { DashboardHeatmap } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { HeatmapBlocks } from "@/features/stats/dashboard-heatmap";
import { TooltipProvider } from "@/components/ui/tooltip";
import { LanguageProvider } from "@/lib/i18n";

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
  days: Array.from({ length: 371 }, (_, index) => {
    const date = new Date("2026-01-05T00:00:00Z");
    date.setUTCDate(date.getUTCDate() + index);
    return {
      day: date.toISOString().slice(0, 10),
      totals: { ...totals, totalTokens: (index + 1) * 1_000_000 },
      value: 1,
      label: "$1",
      normalizedValue: 1,
    };
  }),
  nextBeforeDay: "2026-01-05",
} as DashboardHeatmap;

const setup = (input = block) =>
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <HeatmapBlocks blocks={[input]} today="2026-01-18" />
      </TooltipProvider>
    </LanguageProvider>,
  );

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
    "Cumulative total",
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

it("shows rolling seven-day sums as a line and discloses partial windows", () => {
  const { container } = setup();
  fireEvent.click(screen.getByRole("tab", { name: "Cumulative total" }));
  expect(
    container.querySelector('[data-slot="rolling-token-line"]'),
  ).toBeTruthy();
  expect(
    screen.getByRole("button", {
      name: "2026-01-06 – 2026-01-12: 35.00M Tokens",
    }),
  ).toBeTruthy();
  expect(
    screen.getByRole("button", {
      name: "2025-12-30 – 2026-01-05: 1.00M Tokens · 1/7 days",
    }),
  ).toBeTruthy();
  expect(
    container.querySelectorAll('[data-slot="weekly-token-bar"]'),
  ).toHaveLength(0);
  fireEvent.click(screen.getByRole("tab", { name: "Daily" }));
  expect(
    screen.getByRole("button", { name: "2026-01-05: 1,000,000 Tokens" }),
  ).toBeTruthy();
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
