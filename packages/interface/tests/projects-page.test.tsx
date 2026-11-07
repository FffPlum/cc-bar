import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import type { StatsQuery, WindowBootstrap } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { TooltipProvider } from "@/components/ui/tooltip";
import { ProjectsPage } from "@/features/stats/projects-page";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { bootstrap, makeAPI, settings } from "./fixtures";

const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));

const query: StatsQuery = {
  range: "last7",
  granularity: "day",
  service: "codex",
};
const source = usage["projects.detail"];
const seed = source.topConversations[0]!;
const titles = [
  "Zebra discussion",
  "Delta discussion",
  "Alpha discussion",
  "Foxtrot discussion",
  "Bravo discussion",
  "Echo discussion",
];
const detail = {
  ...source,
  topConversations: titles.map((title, index) => ({
    ...seed,
    summary: {
      ...seed.summary,
      id: `conversation.opaque-rank-${index}`,
      conversationID: `native-session-${index}`,
      title,
      totals: {
        ...seed.summary.totals,
        totalTokens: 60_000 - index * 10_000,
      },
    },
  })),
};

async function renderProjects(responses?: {
  bootstrap?: () => WindowBootstrap;
  list?: () => unknown;
  detail?: () => unknown;
  query?: StatsQuery;
}) {
  const session = makeAPI();
  sessions.push(session);
  session.transport.handler = (request) => {
    if (request.method === "window.bootstrap")
      return responses?.bootstrap?.() ?? bootstrap;
    if (request.method === "window.settings.get") return settings;
    if (request.method === "projects.list")
      return responses?.list?.() ?? usage["projects.list"];
    if (request.method === "projects.detail")
      return responses?.detail?.() ?? detail;
    throw new Error(`Unexpected request: ${request.method}`);
  };
  const navigate = vi.fn();
  const view = render(
    <LanguageProvider language="en">
      <HostProvider api={session.api}>
        <TooltipProvider>
          <ProjectsPage
            query={responses?.query ?? query}
            navigation={{}}
            navigate={navigate}
            onNavigationConsumed={() => {}}
          />
        </TooltipProvider>
      </HostProvider>
    </LanguageProvider>,
  );
  const title = await screen.findByRole("heading", {
    name: "Top conversations",
  });
  const section = within(title.closest("section")!);
  return { ...session, navigate, section, container: view.container };
}

async function selectLimit(label: "Top 3" | "Top 5") {
  const trigger = screen.getByRole("combobox", {
    name: "Top conversations limit",
  });
  fireEvent.click(trigger);
  const option = await screen.findByRole("option", { name: label });
  fireEvent.pointerDown(option, { pointerType: "mouse", button: 0 });
  fireEvent.click(option, { detail: 1 });
  await waitFor(() => expect(trigger.textContent).toContain(label));
  await waitFor(() => expect(screen.queryByRole("listbox")).toBeNull());
}

it("shows the host-ranked top three and switches to five and back without another query", async () => {
  const { section, transport } = await renderProjects();
  const cards = () => section.getAllByRole("button", { name: /discussion/ });
  const displayedTitles = () =>
    cards().map((card) => card.querySelector("[title]")?.textContent);
  expect(
    section.getByRole("combobox", { name: "Top conversations limit" })
      .textContent,
  ).toContain("Top 3");
  expect(displayedTitles()).toEqual(titles.slice(0, 3));
  expect(section.queryByText("View in Conversations ›")).toBeNull();
  const detailRequests = () =>
    transport.requests.filter(
      (request) => request.method === "projects.detail",
    );
  expect(detailRequests()).toHaveLength(1);
  expect(detailRequests()[0]?.params).toEqual({
    ...query,
    projectKey: source.project.key,
  });

  await selectLimit("Top 5");
  expect(displayedTitles()).toEqual(titles.slice(0, 5));
  expect(section.queryByText(titles[5]!)).toBeNull();
  await selectLimit("Top 3");
  expect(displayedTitles()).toEqual(titles.slice(0, 3));
  expect(detailRequests()).toHaveLength(1);
});

it("navigates a whole conversation card using its opaque id", async () => {
  const { navigate, section } = await renderProjects();
  await selectLimit("Top 5");
  const target = section.getByRole("button", { name: /Bravo discussion/ });
  expect(within(target).queryByRole("button")).toBeNull();
  fireEvent.click(target);
  expect(navigate).toHaveBeenCalledExactlyOnceWith("conversations", {
    conversationID: detail.topConversations[4]!.summary.id,
    conversationTitle: detail.topConversations[4]!.summary.title,
  });
});

it("keeps list and daily colors ordered through usage refreshes and follows application reordering", async () => {
  let liveBootstrap: WindowBootstrap = {
    ...bootstrap,
    visibleUsageServices: ["codex", "claude", "pi"],
  };
  let reverseKeys = false;
  const bucket = source.daily[0]!;
  const codex = bucket.byService.codex;
  const claude = bucket.byService.claude;
  const daily = [
    { ...bucket, byService: { claude, codex } },
    {
      ...bucket,
      key: "2026-03-10",
      start: "2026-03-09T16:00:00.000Z",
      totals: codex,
      byService: { codex },
    },
    {
      ...bucket,
      key: "2026-03-11",
      start: "2026-03-10T16:00:00.000Z",
      byService: { codex, claude },
    },
  ];
  const { container, transport } = await renderProjects({
    bootstrap: () => liveBootstrap,
    query: { range: "last7", granularity: "day" },
    list: () => ({
      ...usage["projects.list"],
      rows: usage["projects.list"].rows.map((row) => ({
        ...row,
        totalsByService: reverseKeys
          ? {
              codex: row.totalsByService.codex,
              claude: row.totalsByService.claude,
            }
          : {
              claude: row.totalsByService.claude,
              codex: row.totalsByService.codex,
            },
      })),
    }),
    detail: () => ({
      ...detail,
      daily: daily.map((item) => ({
        ...item,
        byService: reverseKeys
          ? Object.fromEntries(Object.entries(item.byService).reverse())
          : item.byService,
      })),
    }),
  });
  const servicesIn = (element: Element) =>
    Array.from(element.querySelectorAll("[data-service]")).map((segment) =>
      segment.getAttribute("data-service"),
    );
  const listServices = () =>
    servicesIn(screen.getByRole("region", { name: "Projects" }));
  const dailyServices = () =>
    Array.from(container.querySelectorAll('[data-slot="dashboard-bar"]')).map(
      servicesIn,
    );
  const initialDailyOrder = [
    ["codex", "claude"],
    ["codex"],
    ["codex", "claude"],
  ];
  expect(listServices()).toEqual(["codex", "claude"]);
  expect(dailyServices()).toEqual(initialDailyOrder);

  reverseKeys = true;
  await act(async () => transport.emit(["usage"]));
  expect(
    transport.requests.filter(
      (request) => request.method === "projects.detail",
    ),
  ).toHaveLength(2);
  expect(
    transport.requests.filter((request) => request.method === "projects.list"),
  ).toHaveLength(2);
  expect(listServices()).toEqual(["codex", "claude"]);
  expect(dailyServices()).toEqual(initialDailyOrder);

  liveBootstrap = {
    ...liveBootstrap,
    visibleUsageServices: ["claude", "pi", "codex"],
  };
  await act(async () => transport.emit(["applications"]));
  await waitFor(() => {
    expect(listServices()).toEqual(["claude", "codex"]);
    expect(dailyServices()).toEqual([
      ["claude", "codex"],
      ["codex"],
      ["claude", "codex"],
    ]);
  });
});
