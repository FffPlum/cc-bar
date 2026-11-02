import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { HostError } from "@ccbar/host-api";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { ProviderCatalogView } from "@/features/applications/provider-catalog-view";
import { CodexImportDialog } from "@/features/quota/account-dialogs";
import { ApplicationsPage } from "@/features/applications/applications-page";
import { SearchInput } from "@/components/search-input";
import { bootstrap, deferred, makeAPI, settings } from "./fixtures";
import type { ProviderCatalog } from "@ccbar/host-api/window";
const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));
function session() {
  const value = makeAPI();
  sessions.push(value);
  return value;
}
const catalog: ProviderCatalog = {
  application: "codex",
  apiKeys: [],
  suppliers: [
    {
      id: "openai",
      name: "OpenAI",
      endpoint: "https://api.openai.com/v1",
      website: "https://platform.openai.com/api-keys",
    },
  ],
  supportsCustom: true,
  error: null,
};
describe("forms through fake transport", () => {
  it("validates required key fields, retains errors and refreshes the catalog after a successful save", async () => {
    const { api, transport } = session();
    let fail = true;
    const onChanged = vi.fn();
    const choice = {
      id: "new-key",
      name: "Example",
      supplier: "custom",
      endpoint: "https://example.invalid",
      sourceApplications: [],
    };
    transport.handler = (request) => {
      if (request.method === "window.bootstrap") return bootstrap;
      if (request.method === "window.settings.get") return settings;
      if (request.method === "authorizations.saveAPIKey") {
        if (fail) throw new HostError("operation_failed", "Save failed");
        return choice;
      }
      if (request.method === "providers.catalog")
        return { ...catalog, apiKeys: [choice] };
      throw new Error(request.method);
    };
    render(
      <LanguageProvider language="en">
        <HostProvider api={api}>
          <ProviderCatalogView
            catalog={catalog}
            applicationName="Codex"
            supportedAPIs={["responses"]}
            supportsConfiguration
            onBack={() => {}}
            onChanged={onChanged}
            onProviderAdded={() => {}}
          />
        </HostProvider>
      </LanguageProvider>,
    );
    fireEvent.click(
      await screen.findByText("Add API Key", { selector: "button" }),
    );
    expect(
      (screen.getByRole("button", { name: "Save" }) as HTMLButtonElement)
        .disabled,
    ).toBe(true);
    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Example" },
    });
    fireEvent.change(screen.getByLabelText("API endpoint"), {
      target: { value: "https://example.invalid" },
    });
    fireEvent.change(screen.getByLabelText("API Key"), {
      target: { value: "test-key-only" },
    });
    fireEvent.submit(screen.getByLabelText("Name").closest("form")!);
    await screen.findByText("Save failed");
    expect((screen.getByLabelText("Name") as HTMLInputElement).value).toBe(
      "Example",
    );
    fail = false;
    fireEvent.submit(screen.getByLabelText("Name").closest("form")!);
    await waitFor(() =>
      expect(onChanged).toHaveBeenCalledWith({ ...catalog, apiKeys: [choice] }),
    );
  });
  it("freezes the Codex payload while its preview is pending", async () => {
    const { api, transport } = session();
    const preview = deferred<unknown>();
    transport.handler = (request) =>
      request.method === "window.bootstrap"
        ? bootstrap
        : request.method === "window.settings.get"
          ? settings
          : preview.promise;
    render(
      <LanguageProvider language="en">
        <HostProvider api={api}>
          <CodexImportDialog
            privacyMode
            onClose={() => {}}
            onImported={() => {}}
          />
        </HostProvider>
      </LanguageProvider>,
    );
    const input = await screen.findByLabelText("Paste auth.json content");
    fireEvent.change(input, { target: { value: "fake-payload" } });
    fireEvent.click(screen.getByRole("button", { name: "Preview" }));
    expect((input as HTMLTextAreaElement).disabled).toBe(true);
    expect(screen.queryByRole("button", { name: "Close" })).toBeNull();
    await act(async () =>
      preview.resolve({ kind: "personalAccessToken", accounts: [] }),
    );
    expect((input as HTMLTextAreaElement).disabled).toBe(false);
    expect(
      (screen.getByRole("button", { name: "Save" }) as HTMLButtonElement)
        .disabled,
    ).toBe(false);
  });
  it("shows real empty application state", async () => {
    const { api, transport } = session();
    transport.handler = (request) =>
      request.method === "window.bootstrap"
        ? bootstrap
        : request.method === "window.settings.get"
          ? settings
          : { applications: [], error: null };
    render(
      <LanguageProvider language="en">
        <HostProvider api={api}>
          <ApplicationsPage />
        </HostProvider>
      </LanguageProvider>,
    );
    expect(await screen.findByText("No applications detected")).toBeTruthy();
  });
  it("masks a privacy-mode search without changing its actual query", () => {
    const onChange = vi.fn();
    render(
      <SearchInput
        value="sensitive-project"
        onChange={onChange}
        placeholder="Search"
        privateValue
      />,
    );
    const input = screen.getByLabelText("Search") as HTMLInputElement;
    expect(input.type).toBe("password");
    expect(input.value).toBe("sensitive-project");
    fireEvent.change(input, { target: { value: "new-query" } });
    expect(onChange).toHaveBeenCalledWith("new-query");
  });
});
