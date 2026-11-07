import { useState } from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import type { SettingsPatch } from "@ccbar/host-api/window";
import { StatsViewDrawer } from "@/features/stats/stats-view-drawer";
import type { StatsView } from "@/features/stats/stats-page";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { bootstrap, makeAPI, settings } from "./fixtures";

const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));

function mount(autoScan = true) {
  const session = makeAPI();
  sessions.push(session);
  const current = structuredClone(settings);
  current.data.usageAutoScanEnabled = autoScan;
  const onSync = vi.fn();
  session.transport.handler = (request) => {
    if (request.method === "window.bootstrap") return bootstrap;
    if (request.method === "window.settings.update") {
      const patch = (request.params as { patch: SettingsPatch }).patch;
      if (patch.usageAutoScanEnabled !== undefined)
        current.data.usageAutoScanEnabled = patch.usageAutoScanEnabled;
      if (patch.usageInterval) current.data.usageInterval = patch.usageInterval;
      if (patch.statsChartType)
        current.appearance.statsChartType = patch.statsChartType;
    }
    return current;
  };
  function Harness() {
    const [view, setView] = useState<StatsView>("overview");
    return (
      <>
        <p>Current view: {view}</p>
        <StatsViewDrawer
          view={view}
          onView={setView}
          onSync={onSync}
          syncing={false}
          status={current.data.usage}
        />
      </>
    );
  }
  render(
    <LanguageProvider language="en">
      <HostProvider api={session.api}>
        <Harness />
      </HostProvider>
    </LanguageProvider>,
  );
  return { ...session, onSync };
}

async function chooseOption(name: string) {
  const option = await screen.findByRole("option", { name });
  fireEvent.pointerDown(option, { pointerType: "mouse", button: 0 });
  fireEvent.click(option, { detail: 1 });
}

it("closes the drawer after selecting another statistics view", async () => {
  mount();
  fireEvent.click(
    await screen.findByRole("button", { name: "Usage settings" }),
  );
  fireEvent.click(await screen.findByRole("combobox", { name: "Switch view" }));
  await chooseOption("Projects");
  expect(await screen.findByText("Current view: projects")).toBeTruthy();
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});

it("persists scan controls and chart preference while allowing manual sync with scanning off", async () => {
  const { transport, onSync } = mount(false);
  fireEvent.click(
    await screen.findByRole("button", { name: "Usage settings" }),
  );
  expect(
    (
      (await screen.findByRole("combobox", {
        name: "Scan interval",
      })) as HTMLButtonElement
    ).disabled,
  ).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Sync now" }));
  expect(onSync).toHaveBeenCalledOnce();
  fireEvent.click(
    screen.getByRole("switch", { name: "Automatically scan session logs" }),
  );
  await waitFor(() =>
    expect(
      (
        screen.getByRole("combobox", {
          name: "Scan interval",
        }) as HTMLButtonElement
      ).disabled,
    ).toBe(false),
  );
  fireEvent.click(screen.getByRole("combobox", { name: "Scan interval" }));
  await chooseOption("10 min");
  await waitFor(() =>
    expect(
      (
        screen.getByRole("combobox", {
          name: "Chart type",
        }) as HTMLButtonElement
      ).disabled,
    ).toBe(false),
  );
  fireEvent.click(screen.getByRole("combobox", { name: "Chart type" }));
  await chooseOption("Area chart");
  await waitFor(() =>
    expect(
      transport.requests
        .filter((request) => request.method === "window.settings.update")
        .map((request) => request.params),
    ).toEqual([
      { patch: { usageAutoScanEnabled: true } },
      { patch: { usageInterval: "m10" } },
      { patch: { statsChartType: "area" } },
    ]),
  );
});
