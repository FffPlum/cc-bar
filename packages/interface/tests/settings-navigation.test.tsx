import { fireEvent, render, screen, within } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import type { Route } from "@ccbar/host-api/window";
import { App } from "@/App";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { bootstrap, makeAPI, settings } from "./fixtures";

vi.mock("@/features/applications/application-detail-page", () => ({
  ApplicationDetailPage: ({ application }: { application: string }) => (
    <h1>Application {application}</h1>
  ),
}));
vi.mock("@/features/stats/stats-page", () => ({
  StatsPage: () => <h1>Usage overview</h1>,
}));

const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));

function mount(route: Route) {
  const session = makeAPI();
  sessions.push(session);
  let current = { ...bootstrap, route };
  session.transport.handler = (request) => {
    if (request.method === "window.bootstrap") return current;
    if (request.method === "window.settings.get") return settings;
    if (request.method === "window.navigate") {
      current = {
        ...current,
        route: (request.params as { route: Route }).route,
      };
      return current;
    }
    throw new Error(`Unexpected request: ${request.method}`);
  };
  render(
    <LanguageProvider language="en">
      <HostProvider api={session.api}>
        <App />
      </HostProvider>
    </LanguageProvider>,
  );
  return session;
}

it("replaces the sidebar with settings sections and returns to the same application", async () => {
  const { transport } = mount({ page: "application", application: "codex" });
  await screen.findByRole("heading", { name: "Application codex" });
  fireEvent.click(screen.getByRole("button", { name: "Settings" }));
  await screen.findByRole("heading", {
    name: "Appearance & Display",
    level: 1,
  });
  const sidebar = screen.getByRole("navigation", { name: "Settings" });
  expect(within(sidebar).getAllByRole("button")).toHaveLength(3);
  expect(screen.queryByRole("navigation", { name: "Workspace" })).toBeNull();
  expect(screen.queryByRole("tablist")).toBeNull();

  fireEvent.click(
    within(sidebar).getByRole("button", { name: "Data & Refresh" }),
  );
  expect(
    screen.getByRole("heading", { name: "Data & Refresh", level: 1 }),
  ).toBeTruthy();
  expect(
    within(sidebar)
      .getByRole("button", { name: "Data & Refresh" })
      .getAttribute("aria-current"),
  ).toBe("page");
  fireEvent.click(within(sidebar).getByRole("button", { name: "General" }));
  expect(screen.getByRole("switch", { name: "Launch at login" })).toBeTruthy();

  fireEvent.click(screen.getByRole("button", { name: "Back" }));
  await screen.findByRole("heading", { name: "Application codex" });
  expect(screen.getByRole("navigation", { name: "Workspace" })).toBeTruthy();
  expect(
    transport.requests
      .filter((request) => request.method === "window.navigate")
      .at(-1)?.params,
  ).toEqual({ route: { page: "application", application: "codex" } });
});

it("returns to usage statistics when the window opens directly in settings", async () => {
  const { transport } = mount({ page: "settings" });
  fireEvent.click(await screen.findByRole("button", { name: "Back" }));
  await screen.findByRole("heading", { name: "Usage overview" });
  expect(
    transport.requests.find((request) => request.method === "window.navigate")
      ?.params,
  ).toEqual({ route: { page: "stats" } });
});
