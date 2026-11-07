import { fireEvent, render, screen, within } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import type { ProjectDetail, UsageTotals } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { ProjectUsageShare } from "@/features/stats/project-usage-share";
import { LanguageProvider } from "@/lib/i18n";

vi.mock("@/host/host-context", async () => {
  const fixtures = await import("./fixtures");
  return {
    useHost: () => ({
      bootstrap: fixtures.bootstrap,
      settings: fixtures.settings,
    }),
  };
});

const total = (tokens: number): UsageTotals => ({
  ...usage["window.usage.overview"].totals,
  totalTokens: tokens,
  costUSD: String(tokens / 10),
  costDisplay: `$${tokens / 10}`,
});
const detail: ProjectDetail = {
  project: {
    key: "project",
    name: "Project",
    path: "/project",
    status: "available",
  },
  totals: total(210),
  previousTotals: null,
  comparison: { tokens: null, costUSD: null, requests: null },
  conversationCount: 2,
  activeDays: 1,
  rangeDayCount: 7,
  daily: [],
  totalsByService: { codex: total(140), claude: total(70) },
  sharesByService: { codex: 2 / 3, claude: 1 / 3 },
  models: [60, 50, 40, 30, 20, 10].map((tokens, index) => ({
    model: `model-${index}`,
    services: ["codex"],
    totals: total(tokens),
  })),
  branches: [{ branch: "main", conversationCount: 2, totals: total(210) }],
  topConversations: [],
  worktrees: [],
  allTimeTotals: total(210),
  firstUsedDay: null,
  gitRepository: true,
};
const chart = (data = detail) => (
  <LanguageProvider language="en">
    <ProjectUsageShare
      detail={data}
      query={{ range: "last7", granularity: "day" }}
    />
  </LanguageProvider>
);

it("switches one table between dimensions while the share bar keeps hidden model rows", () => {
  const view = render(chart());
  expect(screen.getAllByRole("table")).toHaveLength(1);
  expect(
    screen.getByRole("table", { name: "Usage share · Application" }),
  ).toBeTruthy();
  fireEvent.click(screen.getByRole("tab", { name: "Model" }));
  const modelTable = screen.getByRole("table", { name: "Usage share · Model" });
  expect(within(modelTable).getAllByRole("row")).toHaveLength(6);
  expect(
    view.container.querySelectorAll('[data-slot="project-share-segment"]'),
  ).toHaveLength(6);
  expect(screen.queryByText("model-5")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Show all 6 models" }));
  expect(screen.getByText("model-5")).toBeTruthy();
  fireEvent.click(screen.getByRole("tab", { name: "Branch" }));
  expect(screen.getAllByRole("table")).toHaveLength(1);
  expect(
    screen.getByRole("columnheader", { name: "Conversations" }),
  ).toBeTruthy();
  expect(screen.getByText("main")).toBeTruthy();
});

it("clears a row's linked highlight when a refresh moves it outside the visible preview", () => {
  const view = render(chart());
  fireEvent.click(screen.getByRole("tab", { name: "Model" }));
  fireEvent.mouseEnter(screen.getByText("model-0").closest("tr")!);
  const highlighted = () =>
    view.container.querySelectorAll(
      '[data-slot="project-share-segment"][data-state="highlighted"]',
    );
  expect(highlighted()).toHaveLength(1);
  expect(highlighted()[0]!.getAttribute("data-row-id")).toBe("model:model-0");
  view.rerender(
    chart({
      ...detail,
      models: [...detail.models.slice(1), detail.models[0]!],
    }),
  );
  expect(screen.queryByText("model-0")).toBeNull();
  expect(highlighted()).toHaveLength(0);
});
