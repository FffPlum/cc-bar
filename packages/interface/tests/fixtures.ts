import {
  HostAPI,
  type Domain,
  type Request,
  type Transport,
} from "@ccbar/host-api";
import {
  WindowAPI,
  type WindowBootstrap,
  type WindowSettings,
} from "@ccbar/host-api/window";
export const bootstrap: WindowBootstrap = {
  route: { page: "applications" },
  language: "en",
  resolvedLanguage: "en",
  platform: "macos",
  timeZone: "Asia/Shanghai",
  appearance: "light",
  version: "test",
  sidebarApplications: [],
  visibleUsageServices: [],
  capabilities: [],
};
export const settings: WindowSettings = {
  appearance: {
    menuBarWindow: "primary",
    useInstalledAppIcons: true,
    floatingEnabled: false,
    resetTimeDisplay: "relative",
    showServiceStatus: true,
    privacyMode: false,
    statsRankMetric: "tokens",
    statsChartType: "bar",
    cycleIncludesOtherAgents: true,
    piEstimatedOutputSpeed: false,
    brandColors: [],
    recentBrandColors: [],
  },
  data: {
    quotaInterval: "m5",
    usageInterval: "m5",
    usageAutoScanEnabled: true,
    proxyMode: "system",
    proxyType: "http",
    proxyHost: "",
    proxyPort: 0,
    currency: {
      selected: "USD",
      rates: {},
      fetchedAt: null,
      sourceUpdatedAt: null,
      refreshing: false,
      lastRefreshFailedAt: null,
    },
    usage: {
      scanning: false,
      rebuildingHistory: false,
      rebuildingCycles: false,
      refreshingPricing: false,
      lastScanAt: null,
      error: null,
      progress: null,
      lastRebuildOutcome: null,
      lastRebuildMessage: null,
      lastRebuildDiagnostic: null,
      historyNotice: null,
    },
    piTimingGuide: {
      title: "Timing",
      instructions: "Install the plugin",
      copyText: "example",
    },
  },
  general: {
    language: "en",
    launchAtLogin: false,
    launchAtLoginRequiresApproval: false,
    quotaAlertsEnabled: false,
    quotaAlertThresholdPercent: 20,
    quotaAlertFiveHourEnabled: true,
    quotaAlertWeeklyEnabled: true,
    quotaAlertBillingCycleEnabled: true,
    quotaAlertSoundEnabled: false,
    notifications: {
      authorization: "notDetermined",
      canSubmit: false,
      alertsAllowed: null,
      soundAllowed: null,
      statusText: null,
      requesting: false,
      authorizationFailed: false,
      permissionReadFailed: false,
      storagePaused: false,
      rebuilding: false,
    },
    verboseLogging: false,
    updates: {
      version: "test",
      automaticChecks: false,
      canCheck: true,
      hasUpdate: false,
      isWorking: false,
      lastCheckedAt: null,
    },
  },
};
export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
export class FakeTransport implements Transport {
  requests: Request[] = [];
  handler: (request: Request) => unknown | Promise<unknown> = (request) => {
    if (request.method === "window.bootstrap") return bootstrap;
    if (request.method === "window.settings.get") return settings;
    throw new Error(`Unexpected request: ${request.method}`);
  };
  listeners = new Set<(event: unknown) => void>();
  async send(request: Request) {
    this.requests.push(request);
    return { version: 1, id: request.id, result: await this.handler(request) };
  }
  subscribe(listener: (event: unknown) => void) {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
  emit(domains: Domain[]) {
    for (const listener of this.listeners)
      listener({
        version: 1,
        event: "state.changed",
        revision: "test",
        domains,
      });
  }
  dispose() {
    this.listeners.clear();
  }
}
export function makeAPI() {
  const transport = new FakeTransport();
  const host = new HostAPI(transport);
  const api = new WindowAPI(host);
  return {
    transport,
    api,
    close: () => {
      api.dispose();
      host.dispose();
    },
  };
}
