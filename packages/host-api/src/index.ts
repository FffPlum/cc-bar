import {
  HostError,
  parseEvent,
  parseResponse,
  type StateChanged,
  type Transport,
} from "./transport.js";
export * from "./transport.js";
export interface UsageTotals {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  totalTokens: number;
  costUSD: string;
  requestCount: number;
  hasUnpricedUsage: boolean;
  costIncomplete: boolean;
}
export interface UsageOverview {
  totals: UsageTotals;
  samples: { date: string; totals: UsageTotals }[];
}
export interface UsageQuery {
  from: string;
  to: string;
  service?: string;
}
export interface Settings {
  privacyMode: boolean;
  useInstalledAppIcons: boolean;
}
export interface HostDescription {
  platform: string;
  timeZone: string;
  capabilities: string[];
}
export interface QuotaLimit {
  id: string;
  kind: string;
  displayName: string | null;
  usedPercent: number;
  resetsAt: string | null;
  windowSeconds: number | null;
  isActive: boolean | null;
}
export interface QuotaSnapshot {
  fetchedAt: string;
  planType: string | null;
  isUnlimited: boolean | null;
  limits: QuotaLimit[];
}
export interface QuotaRefreshState {
  inFlight: boolean;
  backoffUntil: string | null;
  lastSuccessAt: string | null;
  lastAttemptAt: string | null;
  failed: boolean;
  source: string | null;
}
export interface QuotaResult {
  services: {
    service: string;
    snapshot: QuotaSnapshot | null;
    refresh: QuotaRefreshState;
  }[];
}
export interface LaunchAtLoginResult {
  enabled: boolean;
  requiresApproval: boolean;
}
function createRequestPrefix(): string {
  const crypto = globalThis.crypto;
  if (typeof crypto?.randomUUID === "function") return crypto.randomUUID();
  if (typeof crypto?.getRandomValues === "function") {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = [...bytes].map((value) => value.toString(16).padStart(2, "0"));
    return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10).join("")}`;
  }
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}
export class HostAPI {
  private nextId = 0;
  private readonly prefix = createRequestPrefix();
  private disposed = false;
  private readonly pending = new Set<(error: HostError) => void>();
  private readonly listeners = new Set<(event: StateChanged) => void>();
  private readonly unsubscribe: () => void;
  constructor(
    private readonly transport: Transport,
    private readonly timeoutMs = 15000,
  ) {
    this.unsubscribe = transport.subscribe((raw) => {
      const event = parseEvent(raw);
      if (event) for (const listener of [...this.listeners]) listener(event);
    });
  }
  request<T>(method: string, params: object = {}, timeoutMs = this.timeoutMs): Promise<T> {
    if (this.disposed)
      return Promise.reject(new HostError("disposed", "Host API is disposed"));
    const id = `${this.prefix}:${++this.nextId}`;
    return new Promise<T>((resolve, reject) => {
      let settled = false;
      const finish = (fn: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this.pending.delete(cancel);
        fn();
      };
      const cancel = (error: HostError) => finish(() => reject(error));
      const timer = setTimeout(
        () => cancel(new HostError("timeout", "Host request timed out")),
        timeoutMs,
      );
      this.pending.add(cancel);
      Promise.resolve()
        .then(() => {
          if (settled) throw new HostError("disposed", "Host API is disposed");
          return this.transport.send({ version: 1, id, method, params });
        })
        .then(
          (raw) =>
            finish(() => {
              try {
                resolve(parseResponse(raw, id) as T);
              } catch (error) {
                reject(error);
              }
            }),
          (error) => finish(() => reject(error)),
        );
    });
  }
  private async checked<T>(
    method: string,
    params: object,
    validate: (x: unknown) => x is T,
  ): Promise<T> {
    const value = await this.request<unknown>(method, params);
    if (!validate(value))
      throw new HostError("invalid_response", `Invalid ${method} result`);
    return value;
  }
  describe(): Promise<HostDescription> {
    return this.checked("host.describe", {}, isDescription);
  }
  quotaSnapshot(): Promise<QuotaResult> {
    return this.checked("quota.snapshot", {}, isQuota);
  }
  quotaRefresh(): Promise<QuotaResult> {
    return this.checked("quota.refresh", {}, isQuota);
  }
  pickDirectory(): Promise<{ path: string | null }> {
    return this.checked("platform.pickDirectory", {}, isPath);
  }
  revealPath(path: string): Promise<Record<string, never>> {
    return this.checked("platform.revealPath", { path }, isEmpty);
  }
  setLaunchAtLogin(enabled: boolean): Promise<LaunchAtLoginResult> {
    return this.checked("platform.setLaunchAtLogin", { enabled }, isLaunch);
  }
  async usageOverview(params: UsageQuery): Promise<UsageOverview> {
    const value = await this.request<unknown>("usage.overview", { ...params });
    if (!isUsage(value))
      throw new HostError("invalid_response", "Invalid usage overview");
    return value;
  }
  async settingsGet(): Promise<Settings> {
    const value = await this.request<unknown>("settings.get");
    if (!isSettings(value))
      throw new HostError("invalid_response", "Invalid settings");
    return value;
  }
  async settingsUpdate(patch: Partial<Settings>): Promise<Settings> {
    const value = await this.request<unknown>("settings.update", { patch });
    if (!isSettings(value))
      throw new HostError("invalid_response", "Invalid settings");
    return value;
  }
  subscribe(listener: (event: StateChanged) => void): () => void {
    if (this.disposed) throw new HostError("disposed", "Host API is disposed");
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    for (const cancel of [...this.pending])
      cancel(new HostError("disposed", "Host API is disposed"));
    this.listeners.clear();
    this.unsubscribe();
    this.transport.dispose();
  }
}

const record = (x: unknown): x is Record<string, unknown> =>
  typeof x === "object" && x !== null && !Array.isArray(x);
function isSettings(x: unknown): x is Settings {
  return (
    record(x) &&
    typeof x.privacyMode === "boolean" &&
    typeof x.useInstalledAppIcons === "boolean"
  );
}
function isTotals(x: unknown): x is UsageTotals {
  return (
    record(x) &&
    [
      "inputTokens",
      "outputTokens",
      "cacheReadTokens",
      "cacheCreationTokens",
      "totalTokens",
      "requestCount",
    ].every((k) => typeof x[k] === "number" && Number.isFinite(x[k])) &&
    typeof x.costUSD === "string" &&
    typeof x.hasUnpricedUsage === "boolean" &&
    typeof x.costIncomplete === "boolean"
  );
}
function isUsage(x: unknown): x is UsageOverview {
  return (
    record(x) &&
    isTotals(x.totals) &&
    Array.isArray(x.samples) &&
    x.samples.every(
      (v) => record(v) && typeof v.date === "string" && isTotals(v.totals),
    )
  );
}

const nullable = (x: unknown, type: string) => x === null || typeof x === type;
function isDescription(x: unknown): x is HostDescription {
  return (
    record(x) &&
    typeof x.platform === "string" &&
    typeof x.timeZone === "string" &&
    Array.isArray(x.capabilities) &&
    x.capabilities.every((v) => typeof v === "string")
  );
}
function isQuota(x: unknown): x is QuotaResult {
  return (
    record(x) &&
    Array.isArray(x.services) &&
    x.services.every(
      (v) =>
        record(v) &&
        typeof v.service === "string" &&
        record(v.refresh) &&
        typeof v.refresh.inFlight === "boolean" &&
        nullable(v.refresh.backoffUntil, "string") &&
        nullable(v.refresh.lastSuccessAt, "string") &&
        nullable(v.refresh.lastAttemptAt, "string") &&
        typeof v.refresh.failed === "boolean" &&
        nullable(v.refresh.source, "string") &&
        (v.snapshot === null ||
          (record(v.snapshot) &&
            typeof v.snapshot.fetchedAt === "string" &&
            nullable(v.snapshot.planType, "string") &&
            nullable(v.snapshot.isUnlimited, "boolean") &&
            Array.isArray(v.snapshot.limits) &&
            v.snapshot.limits.every(
              (l: unknown) =>
                record(l) &&
                typeof l.id === "string" &&
                typeof l.kind === "string" &&
                nullable(l.displayName, "string") &&
                typeof l.usedPercent === "number" &&
                Number.isFinite(l.usedPercent) &&
                nullable(l.resetsAt, "string") &&
                (l.windowSeconds === null ||
                  (typeof l.windowSeconds === "number" &&
                    Number.isFinite(l.windowSeconds))) &&
                nullable(l.isActive, "boolean"),
            ))),
    )
  );
}
function isPath(x: unknown): x is { path: string | null } {
  return record(x) && nullable(x.path, "string");
}
function isEmpty(x: unknown): x is Record<string, never> {
  return record(x) && Object.keys(x).length === 0;
}
function isLaunch(x: unknown): x is LaunchAtLoginResult {
  return (
    record(x) &&
    typeof x.enabled === "boolean" &&
    typeof x.requiresApproval === "boolean"
  );
}
