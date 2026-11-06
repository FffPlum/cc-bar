import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, expect, it } from "vitest";
import { HostError } from "@ccbar/host-api";
import type { Request } from "@ccbar/host-api";
import type { ApplicationInventory, ApplicationOperationPlan } from "@ccbar/host-api/window";
import { ApplicationsPage } from "@/features/applications/applications-page";
import { ApplicationDetailPage } from "@/features/applications/application-detail-page";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { applicationInventory, configuredCodex, installation, managedApplication } from "./application-fixtures";
import { bootstrap, deferred, makeAPI, settings } from "./fixtures";

const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));

function setup(initial: ApplicationInventory) {
  const session = makeAPI();
  sessions.push(session);
  const state = {
    inventory: initial,
    summary: configuredCodex,
    action: (request: Request): unknown => { throw new Error(`Unexpected request: ${request.method}`); },
  };
  session.transport.handler = (request) => {
    if (request.method === "window.bootstrap") return bootstrap;
    if (request.method === "window.settings.get") return settings;
    if (request.method === "applications.list") return { applications: [state.summary], error: null };
    if (request.method === "applications.inventory") return state.inventory;
    return state.action(request);
  };
  const view = (detail = false) => (
    <LanguageProvider language="en">
      <HostProvider api={session.api}>
        {detail ? <ApplicationDetailPage application="codex" /> : <ApplicationsPage />}
      </HostProvider>
    </LanguageProvider>
  );
  return { ...session, state, view };
}

function plan(patch: Partial<ApplicationOperationPlan> = {}): ApplicationOperationPlan {
  return {
    id: "plan-fixture", catalogID: "codex", installationID: "codex-npm", action: "uninstall",
    name: "Codex CLI", sourceLabel: "npm", steps: ["Remove the selected npm installation."],
    preservesData: true, expiresAt: "2026-11-06T01:00:00Z", ...patch,
  };
}

const checkVersionsLabel = "Check updates";

async function openActions(container: HTMLElement, applicationName: string) {
  fireEvent.click(within(container).getByRole("button", { name: `${applicationName} More actions` }));
  return screen.findByRole("menu");
}

async function dismissActions() {
  const menu = screen.queryByRole("menu");
  if (menu) fireEvent.keyDown(menu, { key: "Escape" });
  await waitFor(() => expect(screen.queryByRole("menu")).toBeNull());
}

it("groups the complete catalog by installation state and searches across both groups without exposing paths", async () => {
  const { view } = setup(applicationInventory([
    managedApplication({ installed: false, installations: [] }),
    managedApplication({ id: "future-agent", name: "Future Agent", configurationApplication: null, icon: null, configurationFound: false }),
  ]));
  render(view());
  const installed = await screen.findByRole("region", { name: "Installed (1)" });
  const notInstalled = screen.getByRole("region", { name: "Not installed (1)" });
  const codex = within(notInstalled).getByRole("article", { name: "Codex CLI" });
  expect(within(codex).getByText("Configuration found; application is not installed.")).toBeTruthy();
  expect(within(codex).getByRole("button", { name: "Install" })).toBeTruthy();
  const future = within(installed).getByRole("article", { name: "Future Agent" });
  expect(within(future).queryByRole("switch")).toBeNull();
  expect(within(future).getByText("F")).toBeTruthy();
  expect(screen.queryByRole("combobox", { name: "Installation status" })).toBeNull();
  expect(document.body.textContent).not.toContain("/fixture/");
  expect(screen.queryByRole("region", { name: /\/fixture\// })).toBeNull();

  fireEvent.change(screen.getByRole("searchbox", { name: "Search applications" }), { target: { value: "future" } });
  expect(screen.getByRole("article", { name: "Future Agent" })).toBeTruthy();
  expect(screen.queryByRole("article", { name: "Codex CLI" })).toBeNull();
  expect(screen.queryByRole("region", { name: /^Not installed/ })).toBeNull();
  fireEvent.change(screen.getByRole("searchbox", { name: "Search applications" }), { target: { value: "missing agent" } });
  expect(screen.getByText("No matching applications")).toBeTruthy();
  expect(screen.queryByRole("region", { name: /^Installed/ })).toBeNull();
});

it("prefers the active installation, keeps other instances collapsed and only offers a confirmed available upgrade", async () => {
  const { view, state, transport } = setup(applicationInventory([managedApplication({ installations: [
    installation({ id: "codex-manual", source: "manual", sourceLabel: "Manual", path: "/fixture/manual/codex", resolvedPath: "/fixture/manual/codex", active: false, version: null, canUpgrade: false, canUninstall: false, unavailableReason: "Installation source is unknown" }),
    installation({ versionCheck: { status: "failed", latestVersion: "9.0.0", checkedAt: "2026-11-06T00:00:00Z", error: "Registry unavailable" } }),
  ] })]));
  render(view());
  const npm = await screen.findByRole("region", { name: "Codex CLI npm Installation 2" });
  expect(within(npm).getByText("Version check failed")).toBeTruthy();
  expect(screen.queryByText("Up to date")).toBeNull();
  expect(within(npm).queryByRole("button", { name: "Upgrade" })).toBeNull();
  expect(screen.queryByRole("region", { name: "Codex CLI Manual Installation 1" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: /^1 other installation/ }));
  const manual = screen.getByRole("region", { name: "Codex CLI Manual Installation 1" });
  expect(within(manual).getByText("Version unknown")).toBeTruthy();
  expect(within(manual).queryByRole("button", { name: "Upgrade" })).toBeNull();
  const menu = await openActions(manual, "Codex CLI Manual Installation 1");
  expect(within(menu).getByRole("menuitem", { name: "Uninstall" }).getAttribute("aria-disabled")).toBe("true");
  await dismissActions();
  state.action = (request) => {
    if (request.method === "applications.planOperation") return plan({ action: "upgrade" });
    throw new Error(request.method);
  };
  state.inventory = applicationInventory([managedApplication({ installations: [
    state.inventory.applications[0]!.installations[0]!,
    installation({ versionCheck: { status: "updateAvailable", latestVersion: "9.0.0", checkedAt: "2026-11-06T00:01:00Z", error: null } }),
  ] })]);
  act(() => transport.emit(["applications"]));
  fireEvent.click(await within(npm).findByRole("button", { name: "Upgrade" }));
  await waitFor(() => expect(transport.requests.find((request) => request.method === "applications.planOperation")?.params).toEqual({ catalogID: "codex", installationID: "codex-npm", action: "upgrade" }));
});

it("previews uninstall for the selected installation and retains an expired-plan error without executing another target", async () => {
  const { view, state, transport } = setup(applicationInventory([managedApplication({ installations: [
    installation(), installation({ id: "codex-brew", path: "/fixture/brew/codex", resolvedPath: "/fixture/brew/codex", sourceLabel: "Homebrew", active: false }),
  ] })]));
  state.action = (request) => {
    if (request.method === "applications.planOperation") return plan({ installationID: "codex-brew", sourceLabel: "Homebrew", steps: ["Remove the selected Homebrew installation."] });
    if (request.method === "applications.executeOperation") throw new HostError("operation_failed", "Plan expired. Review a new plan.");
    throw new Error(request.method);
  };
  render(view());
  fireEvent.click(await screen.findByRole("button", { name: /^1 other installation/ }));
  const brew = screen.getByRole("region", { name: "Codex CLI Homebrew Installation 2" });
  let menu = await openActions(brew, "Codex CLI Homebrew Installation 2");
  fireEvent.click(within(menu).getByRole("menuitem", { name: "Uninstall" }));
  let dialog = await screen.findByRole("alertdialog");
  expect(within(dialog).getByText("Your configuration and history will be kept.")).toBeTruthy();
  expect(within(dialog).getByText("Homebrew")).toBeTruthy();
  expect(within(dialog).getByText("1.0.0")).toBeTruthy();
  expect(within(dialog).getByText("Installation 2")).toBeTruthy();
  const details = within(dialog).getByText("Operation details").closest("details");
  expect(details?.open).toBe(false);
  expect(details?.textContent).toContain("Remove the selected Homebrew installation.");
  expect(within(dialog).getByText("/fixture/brew/codex").closest("details")).toBe(details);
  expect(transport.requests.find((request) => request.method === "applications.planOperation")?.params).toEqual({ catalogID: "codex", installationID: "codex-brew", action: "uninstall" });
  expect(transport.requests.some((request) => request.method === "applications.executeOperation")).toBe(false);
  fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("alertdialog")).toBeNull());
  menu = await openActions(brew, "Codex CLI Homebrew Installation 2");
  fireEvent.click(within(menu).getByRole("menuitem", { name: "Uninstall" }));
  dialog = await screen.findByRole("alertdialog");
  fireEvent.click(within(dialog).getByRole("button", { name: "Uninstall" }));
  expect(await within(dialog).findByRole("alert")).toHaveProperty("textContent", "Plan expired. Review a new plan.");
  expect(transport.requests.filter((request) => request.method === "applications.executeOperation").map((request) => request.params)).toEqual([{ planID: "plan-fixture" }]);
});

it("starts installation once after confirmation and restores native operation progress after navigation", async () => {
  const app = managedApplication({ installed: false, installations: [] });
  const { view, state, transport } = setup(applicationInventory([app]));
  const execution = deferred<ApplicationInventory>();
  state.action = (request) => {
    if (request.method === "applications.planOperation") return plan({ action: "install", installationID: null, steps: ["Install Codex CLI using npm."] });
    if (request.method === "applications.executeOperation") return execution.promise;
    throw new Error(request.method);
  };
  const mounted = render(view());
  const notInstalled = await screen.findByRole("region", { name: "Not installed (1)" });
  expect(within(notInstalled).getByRole("article", { name: "Codex CLI" })).toBeTruthy();
  fireEvent.click(await screen.findByRole("button", { name: "Install" }));
  const dialog = await screen.findByRole("alertdialog");
  const confirm = within(dialog).getByRole("button", { name: "Install" }) as HTMLButtonElement;
  fireEvent.click(confirm);
  expect(confirm.disabled).toBe(true);
  fireEvent.click(confirm);
  await waitFor(() => expect(transport.requests.filter((request) => request.method === "applications.executeOperation")).toHaveLength(1));
  state.inventory = applicationInventory([app], { operation: { id: "operation", catalogID: "codex", installationID: null, action: "install", status: "running", startedAt: "2026-11-06T00:00:00Z", finishedAt: null, error: null, output: "Installing…" } });
  await act(async () => execution.resolve(state.inventory));
  expect(await screen.findByText("Codex CLI · Installation · In progress")).toBeTruthy();
  mounted.unmount();
  render(view());
  expect(await screen.findByText("Codex CLI · Installation · In progress")).toBeTruthy();
  expect((screen.getByRole("button", { name: "Install" }) as HTMLButtonElement).disabled).toBe(true);
  state.inventory = applicationInventory([managedApplication()], { operation: { ...state.inventory.operation!, status: "succeeded", finishedAt: "2026-11-06T00:01:00Z", output: "Installed" } });
  act(() => transport.emit(["applications"]));
  expect(await screen.findByText("Codex CLI · Installation · Completed")).toBeTruthy();
  expect(screen.queryByRole("button", { name: "Install" })).toBeNull();
  expect(within(screen.getByRole("region", { name: "Installed (1)" })).getByRole("article", { name: "Codex CLI" })).toBeTruthy();
  expect(screen.queryByRole("region", { name: /^Not installed/ })).toBeNull();
});

it("uses targeted version checks and explicit rescans while legacy visibility stays mapped to the configuration app", async () => {
  const { view, state, transport } = setup(applicationInventory([managedApplication({ id: "codex-desktop", name: "Codex Desktop", kind: "desktop" })]));
  state.action = (request) => {
    if (request.method === "applications.checkVersions") {
      state.inventory = { ...state.inventory, checkingVersions: true };
      return state.inventory;
    }
    if (request.method === "applications.setVisibility") {
      state.summary = { ...state.summary, usageVisible: true };
      return { applications: [state.summary], error: null };
    }
    throw new Error(request.method);
  };
  render(view());
  const card = await screen.findByRole("article", { name: "Codex Desktop" });
  expect(within(card).getByRole("switch", { name: "Codex Desktop In sidebar" })).toBeTruthy();
  let menu = await openActions(card, "Codex Desktop");
  fireEvent.click(within(menu).getByRole("menuitemcheckbox", { name: "Usage statistics" }));
  await waitFor(() => expect(transport.requests.find((request) => request.method === "applications.setVisibility")?.params).toEqual({ application: "codex", patch: { usageVisible: true } }));
  await dismissActions();
  menu = await openActions(card, "Codex Desktop");
  fireEvent.click(within(menu).getByRole("menuitem", { name: checkVersionsLabel }));
  await waitFor(() => expect(transport.requests.find((request) => request.method === "applications.checkVersions")?.params).toEqual({ catalogID: "codex-desktop" }));
  expect((await screen.findByRole("button", { name: "Checking…" }) as HTMLButtonElement).disabled).toBe(true);
  state.inventory = { ...state.inventory, checkingVersions: false };
  act(() => transport.emit(["applications"]));
  await waitFor(() => expect((screen.getByRole("button", { name: checkVersionsLabel }) as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(screen.getByRole("button", { name: "Application actions" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: "Rescan" }));
  await waitFor(() => expect(transport.requests.filter((request) => request.method === "applications.inventory").some((request) => (request.params as { refresh?: boolean }).refresh === true)).toBe(true));
});

it("reconciles a completed version check when its event arrived before the start response", async () => {
  const { view, state, transport } = setup(applicationInventory([managedApplication()]));
  const check = deferred<ApplicationInventory>();
  const running = { ...state.inventory, checkingVersions: true };
  state.action = (request) => {
    if (request.method === "applications.checkVersions") return check.promise;
    throw new Error(request.method);
  };
  render(view());
  const card = await screen.findByRole("article", { name: "Codex CLI" });
  const menu = await openActions(card, "Codex CLI");
  fireEvent.click(within(menu).getByRole("menuitem", { name: checkVersionsLabel }));
  await waitFor(() => expect(transport.requests.filter((request) => request.method === "applications.checkVersions")).toHaveLength(1));
  state.inventory = applicationInventory([managedApplication({ installations: [installation({ version: "2.0.0", versionCheck: { status: "current", latestVersion: "2.0.0", checkedAt: "2026-11-06T00:00:00Z", error: null } })] })]);
  act(() => transport.emit(["applications"]));
  expect(await within(card).findByText("2.0.0")).toBeTruthy();
  await act(async () => check.resolve(running));
  await waitFor(() => expect((screen.getByRole("button", { name: checkVersionsLabel }) as HTMLButtonElement).disabled).toBe(false));
  expect(within(card).getByText("2.0.0")).toBeTruthy();
  expect(within(card).queryByRole("button", { name: "Upgrade" })).toBeNull();
});

it("adds installation information to configuration details without treating catalog-only apps as providers", async () => {
  const { view, state } = setup(applicationInventory([
    managedApplication(),
    managedApplication({ id: "catalog-only", name: "Other Agent", configurationApplication: null }),
  ]));
  state.action = (request) => {
    if (request.method === "applications.detail") return { ...configuredCodex, loginSummary: "Signed in", error: null, connections: [] };
    if (request.method === "providers.catalog") return { application: "codex", apiKeys: [], suppliers: [], supportsCustom: true, error: null };
    throw new Error(request.method);
  };
  render(view(true));
  expect(await screen.findByRole("article", { name: "Codex CLI" })).toBeTruthy();
  expect(screen.queryByRole("article", { name: "Other Agent" })).toBeNull();
  expect(screen.getByText("Signed in")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Add provider" })).toBeTruthy();
});
