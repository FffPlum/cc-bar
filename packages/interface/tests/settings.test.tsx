import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it } from "vitest";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { SettingsPage } from "@/features/settings/settings-page";
import { bootstrap, makeAPI, settings } from "./fixtures";
const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));
function mount() {
  const session = makeAPI();
  sessions.push(session);
  session.transport.handler = (request) => {
    if (request.method === "window.bootstrap") return bootstrap;
    if (request.method === "settings.copyPiTimingGuide") return { ok: true };
    return settings;
  };
  render(
    <LanguageProvider language="en">
      <HostProvider api={session.api}>
        <SettingsPage />
      </HostProvider>
    </LanguageProvider>,
  );
  return session;
}
it("uses the separate launch-at-login action", async () => {
  const { transport } = mount();
  fireEvent.click(await screen.findByRole("tab", { name: "General" }));
  fireEvent.click(
    await screen.findByRole("switch", { name: "Launch at login" }),
  );
  await waitFor(() =>
    expect(
      transport.requests.some(
        (request) => request.method === "window.settings.setLaunchAtLogin",
      ),
    ).toBe(true),
  );
  expect(
    transport.requests.some(
      (request) => request.method === "window.settings.update",
    ),
  ).toBe(false);
});
it("requests system permission after enabling quota alerts", async () => {
  const { transport } = mount();
  fireEvent.click(await screen.findByRole("tab", { name: "General" }));
  fireEvent.click(
    await screen.findByRole("switch", { name: "Enable quota alerts" }),
  );
  await waitFor(() =>
    expect(
      transport.requests.some(
        (request) => request.method === "notifications.requestPermission",
      ),
    ).toBe(true),
  );
  const methods = transport.requests.map((request) => request.method);
  expect(methods.indexOf("window.settings.update")).toBeLessThan(
    methods.indexOf("notifications.requestPermission"),
  );
});
it("opens the actual Pi guide and delegates copying to the host", async () => {
  const { transport } = mount();
  fireEvent.click(
    await screen.findByRole("button", { name: "Timing plugin instructions" }),
  );
  expect(await screen.findByText("Install the plugin")).toBeTruthy();
  fireEvent.click(
    screen.getByRole("button", { name: "Copy setup instructions" }),
  );
  await waitFor(() =>
    expect(
      transport.requests.some(
        (request) => request.method === "settings.copyPiTimingGuide",
      ),
    ).toBe(true),
  );
});
