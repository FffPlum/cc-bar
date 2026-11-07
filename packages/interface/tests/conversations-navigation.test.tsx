import { useState } from "react";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, expect, it } from "vitest";
import type { ConversationSummary } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { ConversationsPage } from "@/features/stats/conversations-page";
import type { StatsNavigation } from "@/features/stats/stats-page";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { bootstrap, deferred, makeAPI, settings } from "./fixtures";

const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));
const query = { range: "last7", granularity: "day" } as const;
const rows: ConversationSummary[] = ["first", "second", "unrelated"].map(
  (name, index) => ({
    ...(usage["conversations.list"].rows[0] as unknown as ConversationSummary),
    id: `conversation.00000000-0000-4000-8000-00000000000${index + 1}`,
    conversationID: `raw-${name}`,
    title: index < 2 ? "Same title" : "Unrelated title",
  }),
);

function mount({
  privacyMode = false,
  includeTitle = true,
  detailDelay,
}: {
  privacyMode?: boolean;
  includeTitle?: boolean;
  detailDelay?: Promise<unknown>;
} = {}) {
  const session = makeAPI();
  sessions.push(session);
  session.transport.handler = (request) => {
    if (request.method === "window.bootstrap") return bootstrap;
    if (request.method === "window.settings.get")
      return {
        ...settings,
        appearance: { ...settings.appearance, privacyMode },
      };
    if (request.method === "conversations.list") {
      const search = request.params?.search;
      const matching =
        typeof search === "string" && search
          ? rows.filter((row) =>
              row.title?.toLowerCase().includes(search.toLowerCase()),
            )
          : rows;
      return {
        ...usage["conversations.list"],
        rows: matching,
        total: matching.length,
      };
    }
    if (request.method === "conversations.detail")
      return (
        detailDelay ?? {
          ...usage["conversations.detail"],
          summary: rows.find((row) => row.id === request.params?.id),
        }
      );
    throw new Error(`Unexpected request: ${request.method}`);
  };
  function Navigation() {
    const [navigation, setNavigation] = useState<StatsNavigation>({
      conversationID: rows[1]!.id,
      ...(includeTitle ? { conversationTitle: rows[1]!.title } : {}),
    });
    return (
      <>
        <button
          onClick={() =>
            setNavigation({
              conversationID: rows[0]!.id,
              ...(includeTitle ? { conversationTitle: rows[0]!.title } : {}),
            })
          }
        >
          Navigate to first
        </button>
        <ConversationsPage
          query={query}
          services={["claude"]}
          navigation={navigation}
          onNavigationConsumed={() => setNavigation({})}
        />
      </>
    );
  }
  render(
    <LanguageProvider language="en">
      <HostProvider api={session.api}>
        <Navigation />
      </HostProvider>
    </LanguageProvider>,
  );
  return session;
}

it("uses identical text queries for automatic navigation and retyping while selecting the target ID", async () => {
  const { transport } = mount();
  const search = await screen.findByLabelText("Search title, project or ID");
  await waitFor(() => expect(search).toHaveProperty("value", rows[1]!.title));
  const sidebar = screen.getByRole("region", { name: "Conversations" });
  await waitFor(() =>
    expect(
      within(sidebar).getAllByRole("button", { name: /Same title/ }),
    ).toHaveLength(2),
  );
  const listRequests = () =>
    transport.requests.filter(
      (request) => request.method === "conversations.list",
    );
  expect(
    listRequests().every(
      (request) => request.params?.search === rows[1]!.title,
    ),
  ).toBe(true);
  const automaticQuery = listRequests().at(-1)?.params;
  expect(
    within(sidebar).queryByRole("button", { name: /Unrelated title/ }),
  ).toBeNull();
  expect(
    document
      .getElementById(`selectable-${rows[1]!.id}`)
      ?.getAttribute("aria-selected"),
  ).toBe("true");
  expect(
    transport.requests.some(
      (request) =>
        request.method === "conversations.detail" &&
        request.params?.id === rows[1]!.id,
    ),
  ).toBe(true);

  fireEvent.change(search, { target: { value: "" } });
  await waitFor(() =>
    expect(
      within(sidebar).getAllByRole("button", {
        name: /Same title|Unrelated title/,
      }),
    ).toHaveLength(3),
  );
  await waitFor(() => expect(listRequests().at(-1)?.params?.search).toBe(""));
  fireEvent.change(search, { target: { value: rows[1]!.title } });
  await waitFor(() =>
    expect(listRequests().at(-1)?.params).toEqual(automaticQuery),
  );
  await waitFor(() =>
    expect(
      within(sidebar).getAllByRole("button", { name: /Same title/ }),
    ).toHaveLength(2),
  );
  expect(
    within(sidebar).queryByRole("button", { name: /Unrelated title/ }),
  ).toBeNull();
});

it("changes the selected conversation without replacing a same-title text query and masks private input", async () => {
  const { transport } = mount({ privacyMode: true });
  const search = await screen.findByLabelText("Search title, project or ID");
  expect(search.getAttribute("type")).toBe("password");
  fireEvent.click(screen.getByRole("button", { name: "Navigate to first" }));
  await waitFor(() => expect(search).toHaveProperty("value", rows[0]!.title));
  await waitFor(() =>
    expect(
      transport.requests.some(
        (request) =>
          request.method === "conversations.detail" &&
          request.params?.id === rows[0]!.id,
      ),
    ).toBe(true),
  );
  await waitFor(() =>
    expect(
      document
        .getElementById(`selectable-${rows[0]!.id}`)
        ?.getAttribute("aria-selected"),
    ).toBe("true"),
  );
  expect(
    transport.requests
      .filter((request) => request.method === "conversations.list")
      .every((request) => request.params?.search === "Same title"),
  ).toBe(true);
});

it("fills in the title from details for navigation that only supplies an ID", async () => {
  const { transport } = mount({ includeTitle: false });
  const search = await screen.findByLabelText("Search title, project or ID");
  await waitFor(() => expect(search).toHaveProperty("value", "Same title"));
  await waitFor(() =>
    expect(
      transport.requests
        .filter((request) => request.method === "conversations.list")
        .at(-1)?.params?.search,
    ).toBe("Same title"),
  );
});

it("does not overwrite edited text when a missing navigation title arrives late", async () => {
  const delayed = deferred<unknown>();
  const { transport } = mount({
    includeTitle: false,
    detailDelay: delayed.promise,
  });
  const search = await screen.findByLabelText("Search title, project or ID");
  expect(search).toHaveProperty("value", "");
  fireEvent.change(search, { target: { value: "Same" } });
  await waitFor(() =>
    expect(
      transport.requests.some(
        (request) =>
          request.method === "conversations.list" &&
          request.params?.search === "Same",
      ),
    ).toBe(true),
  );
  await act(async () =>
    delayed.resolve({
      ...usage["conversations.detail"],
      summary: rows[1],
    }),
  );
  expect(search).toHaveProperty("value", "Same");
  expect(
    transport.requests
      .filter((request) => request.method === "conversations.list")
      .at(-1)?.params?.search,
  ).toBe("Same");
  expect(
    within(screen.getByRole("region", { name: "Conversations" })).getAllByRole(
      "button",
      { name: /Same title/ },
    ),
  ).toHaveLength(2);
});
