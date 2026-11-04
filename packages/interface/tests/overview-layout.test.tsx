import {
  fireEvent,
  render,
  screen,
  within,
  waitFor,
} from "@testing-library/react";
import { expect, it, vi } from "vitest";
import type { UsageOverview } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { OverviewPage, periodTitle } from "@/features/stats/overview-page";
import { LanguageProvider } from "@/lib/i18n";
import { formatTokens } from "@/lib/display";
import { TooltipProvider } from "@/components/ui/tooltip";

vi.mock("@/host/host-context", async () => {
  const fixtures = await import("./fixtures");
  return {
    useHost: () => ({
      settings: fixtures.settings,
      bootstrap: fixtures.bootstrap,
    }),
  };
});

it("keeps each composition dimension aligned, normalizes shares and expands rows", () => {
  const data = structuredClone(
    usage["window.usage.overview"],
  ) as unknown as UsageOverview;
  data.composition.project[0].title =
    "A very long project name that should be truncated in the name column";
  data.composition.project[0].subtitle =
    "/a/very/long/project/path/with/many/components";
  for (const dimension of ["provider", "model"] as const) {
    const child = [
      ...data.composition[dimension][0].models,
      ...data.composition[dimension][0].sources,
    ][0];
    child.model = `unique-${dimension}-child`;
    child.totals.outputTokensPerSecond = 123;
  }
  data.composition.service[0].share = 0.2;
  data.composition.service[1].share = 0.3;
  data.composition.service.push({
    ...data.composition.service[1],
    id: "zero",
    share: 0,
  });
  const { container } = render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <OverviewPage
          data={data}
          query={{ range: "today", granularity: "day" }}
          onService={() => {}}
          navigate={() => {}}
        />
      </TooltipProvider>
    </LanguageProvider>,
  );
  const segments = container.querySelector(
    '[data-slot="composition-share"]',
  )!.children;
  expect(segments).toHaveLength(2);
  expect(
    Array.from(segments).map((node) =>
      Number((node as HTMLElement).style.flexGrow),
    ),
  ).toEqual([0.4, 0.6]);
  for (const name of ["Application", "Provider", "Model", "Project"]) {
    fireEvent.click(screen.getByRole("button", { name, exact: true }));
    const table = screen.getByRole("table");
    expect(
      within(table)
        .getAllByRole("columnheader")
        .map((header) => header.textContent),
    ).toEqual([
      name,
      "Tokens",
      "Cost",
      "Share",
      "Output speed",
      "Cache hit",
      "",
    ]);
    expect(
      within(table).getAllByRole("row")[1].querySelectorAll("td"),
    ).toHaveLength(7);
    if (name === "Project") {
      expect(
        within(table).getByTitle(data.composition.project[0].title),
      ).toBeTruthy();
      expect(
        within(table).getByText(data.composition.project[0].subtitle!),
      ).toBeTruthy();
    }
    if (name === "Provider" || name === "Model") {
      const before = within(table).getAllByRole("row").length;
      const parent = within(table).getAllByRole("row")[1];
      fireEvent.click(parent);
      expect(within(table).getAllByRole("row").length).toBeGreaterThan(before);
      const dimension = name.toLowerCase() as "provider" | "model";
      const item = [
        ...data.composition[dimension][0].models,
        ...data.composition[dimension][0].sources,
      ][0];
      const child = within(table)
        .getByTitle(`unique-${dimension}-child`)
        .closest("tr")!;
      const cells = child.querySelectorAll("td");
      expect(cells).toHaveLength(7);
      expect(cells[1].textContent).toBe(
        formatTokens(item.totals.totalTokens, "en"),
      );
      expect(cells[2].textContent).toBe(item.totals.costDisplay);
      expect(cells[4].textContent).toBe("123 t/s");
      fireEvent.click(parent);
      expect(within(table).getAllByRole("row")).toHaveLength(before);
    }
  }
});

it("formats period titles using civil calendar arithmetic", () => {
  expect(periodTitle("2026-03-09", "day")).toBe("2026-03-09");
  expect(periodTitle("2026-12-28", "week")).toBe("2026-12-28 – 2027-01-03");
  expect(periodTitle("2026-03-01", "month")).toBe("2026-03");
});

it("shows host cost and token totals in separate tooltip rows", async () => {
  const data = structuredClone(
    usage["window.usage.overview"],
  ) as unknown as UsageOverview;
  render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <OverviewPage
          data={data}
          query={{ range: "today", granularity: "day" }}
          onService={() => {}}
          navigate={() => {}}
        />
      </TooltipProvider>
    </LanguageProvider>,
  );
  const bar = document.querySelector(
    '[data-slot="usage-chart"] button',
  ) as HTMLElement;
  fireEvent.focus(bar);
  await waitFor(() =>
    expect(
      document.querySelector('[data-slot="chart-data-tooltip"]'),
    ).not.toBeNull(),
  );
  const tooltip = document.querySelector('[data-slot="chart-data-tooltip"]')!;
  const total = within(tooltip as HTMLElement).getByText(
    "Total",
  ).parentElement!;
  const tokens = within(tooltip as HTMLElement).getByText(
    "Tokens",
  ).parentElement!;
  expect(total.textContent).toBe(`Total${data.samples[0].totals.costDisplay}`);
  expect(tokens.textContent).toBe(
    `Tokens${formatTokens(data.samples[0].totals.totalTokens, "en")}`,
  );
  expect(total).not.toBe(tokens);
});

it("links row hover to visible segments and clears stale hover across scope and data changes", () => {
  const data = structuredClone(
    usage["window.usage.overview"],
  ) as unknown as UsageOverview;
  data.composition.service.push({
    ...data.composition.service[1],
    id: "zero",
    title: "Zero",
    share: 0,
    action: { type: "none" },
  });
  const view = (range: "today" | "thisWeek", value: UsageOverview) => (
    <LanguageProvider language="en">
      <TooltipProvider>
        <OverviewPage
          data={value}
          query={{ range, granularity: "day" }}
          onService={() => {}}
          navigate={() => {}}
        />
      </TooltipProvider>
    </LanguageProvider>
  );
  const { container, rerender } = render(view("today", data));
  const rows = () =>
    within(screen.getByRole("table")).getAllByRole("row").slice(1);
  const states = () =>
    Array.from(
      container.querySelectorAll('[data-slot="composition-segment"]'),
    ).map((node) => node.getAttribute("data-state"));
  fireEvent.mouseEnter(rows()[0]);
  expect(states()).toEqual(["highlighted", "dimmed"]);
  expect(rows()[0].getAttribute("data-hovered")).toBe("true");
  expect(
    rows()[0].querySelector('[data-slot="composition-icon"]'),
  ).not.toBeNull();
  fireEvent.mouseEnter(rows()[1]);
  fireEvent.mouseLeave(rows()[0]);
  expect(states()).toEqual(["dimmed", "highlighted"]);
  fireEvent.mouseLeave(rows()[1]);
  expect(states()).toEqual(["normal", "normal"]);
  fireEvent.mouseEnter(rows()[2]);
  expect(rows()[2].getAttribute("data-hovered")).toBe("true");
  expect(states()).toEqual(["normal", "normal"]);
  fireEvent.mouseEnter(rows()[0]);
  const refreshed = structuredClone(data);
  rerender(view("today", refreshed));
  expect(states()).toEqual(["highlighted", "dimmed"]);
  rerender(view("thisWeek", refreshed));
  expect(states()).toEqual(["normal", "normal"]);
  fireEvent.mouseEnter(rows()[0]);
  fireEvent.click(
    screen.getByRole("button", { name: "Provider", exact: true }),
  );
  expect(states()).toEqual(["normal"]);
  fireEvent.mouseEnter(rows()[0]);
  const removed = structuredClone(refreshed);
  removed.composition.provider = [];
  rerender(view("thisWeek", removed));
  rerender(view("thisWeek", refreshed));
  expect(states()).toEqual(["normal"]);
  fireEvent.mouseEnter(rows()[0]);
  expect(states()).toEqual(["highlighted"]);
  for (const name of ["Model", "Project"]) {
    fireEvent.click(screen.getByRole("button", { name, exact: true }));
    fireEvent.mouseEnter(rows()[0]);
    expect(states()[0]).toBe("highlighted");
  }
});
