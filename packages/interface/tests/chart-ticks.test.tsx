import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { expect, it } from "vitest";
import {
  chartTickIndices,
  chartBarWidth,
  StackedBarChart,
} from "@/components/stacked-bar-chart";
import { positiveShares } from "@/features/stats/overview-page";
import { TooltipProvider } from "@/components/ui/tooltip";

it("uses readable evenly spaced ticks and adapts their count to the container", () => {
  expect([...chartTickIndices(30, 480)]).toEqual([0, 6, 12, 17, 23, 29]);
  expect([...chartTickIndices(30, 240)]).toEqual([0, 15, 29]);
  expect(chartTickIndices(30, 2000).size).toBe(8);
  expect([...chartTickIndices(3, 480)]).toEqual([0, 1, 2]);
});

it("keeps every bar focusable and its tooltip available when its date tick is omitted", async () => {
  const columns = Array.from({ length: 30 }, (_, index) => ({
    key: String(index),
    label: `Oct ${index + 1}`,
    total: 10,
    totalLabel: "10 Tokens",
    segments: [{ seriesID: "codex", value: 10, label: "$0.10" }],
  }));
  const { container } = render(
    <TooltipProvider>
      <StackedBarChart
        columns={columns}
        series={[{ id: "codex", name: "Codex", color: "#666666" }]}
      />
    </TooltipProvider>,
  );
  expect(container.querySelectorAll('[data-slot="chart-tick"]')).toHaveLength(
    6,
  );
  expect(screen.getAllByRole("button")).toHaveLength(30);
  const bar = screen.getByRole("button", { name: "Oct 2: 10 Tokens" });
  expect(bar.getAttribute("tabindex")).not.toBe("-1");
  expect(bar.querySelector('[data-slot="chart-tick"]')).toBeNull();
  fireEvent.focus(bar);
  await waitFor(() =>
    expect(
      document.querySelector('[data-slot="tooltip-content"]')?.textContent,
    ).toContain("Oct 2"),
  );
});

it("uses the native bar width at each density boundary", () => {
  expect([3, 4, 14, 15, 45, 46].map(chartBarWidth)).toEqual([
    28, 18, 18, 10, 10, 5,
  ]);
});

it("applies bar width to the bar and separates tooltip title and total", async () => {
  const { container } = render(
    <TooltipProvider>
      <StackedBarChart
        columns={[
          {
            key: "a",
            label: "Nov 1",
            tooltipTitle: "November 1, 2026",
            total: 10,
            totalLabel: "10 Tokens · $1",
            tooltipTotal: "$1",
            segments: [
              { seriesID: "codex", value: 10, label: "$1" },
              { seriesID: "empty", value: 0, label: "$0" },
            ],
            tooltip: <span>Tokens 10</span>,
          },
        ]}
        series={[
          { id: "codex", name: "Codex", color: "#666" },
          { id: "empty", name: "Empty", color: "#aaa" },
        ]}
      />
    </TooltipProvider>,
  );
  const bar = screen.getByRole("button");
  expect(bar.querySelector('[style*="width: 28px"]')).not.toBeNull();
  fireEvent.focus(bar);
  await waitFor(() =>
    expect(
      document.querySelector('[data-slot="tooltip-content"]')?.textContent,
    ).toContain("November 1, 2026"),
  );
  const text =
    document.querySelector('[data-slot="tooltip-content"]')?.textContent ?? "";
  expect(text).toContain("Tokens 10");
  expect(text).toContain("Empty");
  expect(container.querySelectorAll('[data-slot="chart-tick"]')).toHaveLength(
    1,
  );
});

it("excludes zero and invalid shares so flex weights normalize over positive rows", () => {
  expect(
    positiveShares([
      { share: 0 },
      { share: 0.2 },
      { share: 0.3 },
      { share: NaN },
    ]),
  ).toEqual([{ share: 0.2 }, { share: 0.3 }]);
});
