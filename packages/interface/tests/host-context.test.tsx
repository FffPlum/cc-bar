import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { HostError } from "@ccbar/host-api";
import { HostProvider, useHost, useHostResource } from "@/host/host-context";
import { bootstrap, deferred, makeAPI, settings } from "./fixtures";
const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => {
  sessions.splice(0).forEach((session) => session.close());
});
function session() {
  const value = makeAPI();
  sessions.push(value);
  return value;
}
function Probe() {
  const host = useHost();
  return (
    <>
      <span data-testid="route">{host.bootstrap.route.page}</span>
      <span data-testid="pending">{String(host.routePending)}</span>
      <span data-testid="error">{host.hostError}</span>
      <button onClick={() => void host.navigate({ page: "settings" })}>
        Navigate
      </button>
    </>
  );
}
describe("HostProvider via the real SDK and isolated transport", () => {
  it("keeps settings failure visible when bootstrap succeeds later, and retries", async () => {
    const { api, transport } = session();
    const delayed = deferred<typeof bootstrap>();
    let fail = true;
    transport.handler = (request) =>
      request.method === "window.bootstrap"
        ? delayed.promise
        : fail
          ? Promise.reject(
              new HostError("unavailable", "hidden internal message"),
            )
          : settings;
    render(
      <HostProvider api={api}>
        <Probe />
      </HostProvider>,
    );
    await screen.findByRole("alert");
    await act(async () => delayed.resolve(bootstrap));
    expect(screen.queryByTestId("route")).toBeNull();
    expect(screen.getByRole("alert")).toBeTruthy();
    fail = false;
    fireEvent.click(screen.getByRole("button"));
    expect(await screen.findByTestId("route")).toHaveProperty(
      "textContent",
      "applications",
    );
  });
  it("honors navigation events and clears pending when an event supersedes a slow navigation", async () => {
    const { api, transport } = session();
    const delayed = deferred<typeof bootstrap>();
    let eventRoute = false;
    transport.handler = (request) =>
      request.method === "window.settings.get"
        ? settings
        : request.method === "window.navigate"
          ? delayed.promise
          : {
              ...bootstrap,
              route: { page: eventRoute ? "stats" : "applications" },
            };
    render(
      <HostProvider api={api}>
        <Probe />
      </HostProvider>,
    );
    await screen.findByTestId("route");
    fireEvent.click(screen.getByText("Navigate"));
    await waitFor(() =>
      expect(screen.getByTestId("pending").textContent).toBe("true"),
    );
    eventRoute = true;
    act(() => transport.emit(["navigation"]));
    await waitFor(() =>
      expect(screen.getByTestId("route").textContent).toBe("stats"),
    );
    await act(async () =>
      delayed.resolve({ ...bootstrap, route: { page: "settings" } }),
    );
    expect(screen.getByTestId("route").textContent).toBe("stats");
    expect(screen.getByTestId("pending").textContent).toBe("false");
  });
  it("invalidates slow resource reads after a mutation", async () => {
    const { api } = session();
    const delayed = deferred<string>();
    function Resource() {
      const resource = useHostResource(
        () => delayed.promise,
        ["applications"],
        [],
      );
      return (
        <>
          <p data-testid="value">{resource.data}</p>
          <button onClick={() => resource.setData("new")}>Mutate</button>
        </>
      );
    }
    render(
      <HostProvider api={api}>
        <Resource />
      </HostProvider>,
    );
    fireEvent.click(await screen.findByText("Mutate"));
    await act(async () => delayed.resolve("old"));
    expect(screen.getByTestId("value").textContent).toBe("new");
  });
  it("removes sensitive cached content immediately on privacy change", async () => {
    const { api, transport } = session();
    let privacy = false;
    const delayed = deferred<string>();
    transport.handler = (request) =>
      request.method === "window.bootstrap"
        ? bootstrap
        : {
            ...settings,
            appearance: { ...settings.appearance, privacyMode: privacy },
          };
    function Resource() {
      const host = useHost();
      const resource = useHostResource(
        () =>
          host.settings.appearance.privacyMode
            ? delayed.promise
            : Promise.resolve("private-name"),
        ["usage"],
        [],
      );
      return <p data-testid="value">{resource.data}</p>;
    }
    render(
      <HostProvider api={api}>
        <Resource />
      </HostProvider>,
    );
    await screen.findByText("private-name");
    privacy = true;
    act(() => transport.emit(["settings"]));
    await waitFor(() => expect(screen.queryByText("private-name")).toBeNull());
    await act(async () => delayed.resolve("Hidden"));
    expect(await screen.findByText("Hidden")).toBeTruthy();
  });
});

it("shows a retryable error if the first private resource refresh fails", async () => {
  const { api, transport } = session();
  let privacy = false;
  transport.handler = (request) =>
    request.method === "window.bootstrap"
      ? bootstrap
      : {
          ...settings,
          appearance: { ...settings.appearance, privacyMode: privacy },
        };
  function Resource() {
    const host = useHost();
    const resource = useHostResource(
      () =>
        host.settings.appearance.privacyMode
          ? Promise.reject(
              new HostError("operation_failed", "Private refresh failed"),
            )
          : Promise.resolve("Private name"),
      ["usage"],
      [],
    );
    return (
      <>
        <p>{resource.data}</p>
        <p>{resource.error}</p>
        <p data-testid="loading">{String(resource.loading)}</p>
      </>
    );
  }
  render(
    <HostProvider api={api}>
      <Resource />
    </HostProvider>,
  );
  await screen.findByText("Private name");
  privacy = true;
  act(() => transport.emit(["settings"]));
  expect(await screen.findByText("Private refresh failed")).toBeTruthy();
  expect(screen.queryByText("Private name")).toBeNull();
  expect(screen.getByTestId("loading").textContent).toBe("false");
});
