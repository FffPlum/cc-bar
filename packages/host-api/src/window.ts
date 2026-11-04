import { HostAPI, HostError } from "./index.js";

export type ISODateTime = string;
export type LocalDate = string;
export type DecimalString = string;
export type ApplicationID = "codex" | "claude" | "kimi" | "dsh" | "gemini" | "grok" | "opencode" | "pi" | "cursor" | "antigravity" | "commandCode";
export type UsageService = "codex" | "claude" | "cursor" | "pi" | "opencode" | "dsh" | "antigravity" | "kimi";
export type QuotaService = "codex" | "claude" | "antigravity" | "cursor" | "commandCode" | "opencodeGo" | "kimi";
export type ServiceBrand = "codex" | "claude" | "antigravity" | "cursor" | "commandCode" | "opencode" | "kimi" | "pi" | "dsh" | "deepseek" | "grok" | "gemini";
export type Supplier = "openai" | "anthropic" | "kimi" | "deepseek" | "grok" | "gemini" | "custom";
export type ProviderProtocol = "responses" | "chatCompletions" | "anthropic" | "gemini";
export type Route = { page: "application"; application: ApplicationID } | { page: "applications" | "quotaManagement" | "stats" | "settings" };

export interface WindowBootstrap {
  route: Route;
  language: "system" | "zh" | "en";
  resolvedLanguage: "zh" | "en";
  platform: string;
  timeZone: string;
  appearance: "light" | "dark";
  version: string;
  sidebarApplications: ApplicationSummary[];
  visibleUsageServices: UsageService[];
  capabilities: string[];
}

export interface BrandIcon {
  brand: ServiceBrand;
  kind: "installedApp" | "favicon" | "brand" | "fallback";
  dataURI: string | null;
  fillsTile: boolean;
  lightHex: string;
  darkHex: string;
}
export interface ApplicationSummary {
  id: ApplicationID;
  name: string;
  detected: boolean;
  addedToSidebar: boolean;
  usageService: UsageService | null;
  usageVisible: boolean;
  supportsProviderConfiguration: boolean;
  supportedAPIs: ProviderProtocol[];
  defaultSupplier: Supplier;
  icon: BrandIcon;
}
export interface ApplicationsResult { applications: ApplicationSummary[]; error: string | null }
export interface ApplicationVisibilityPatch { addedToSidebar?: boolean; usageVisible?: boolean }
export interface ProviderConnection {
  id: string;
  name: string;
  supplier: Supplier;
  endpoint: string;
  models: string[];
  protocol: ProviderProtocol;
  contextWindow: number;
  official: boolean;
  active: boolean;
  authorizationID: string | null;
}
export interface ApplicationDetail extends ApplicationSummary {
  loginSummary: string | null;
  error: string | null;
  connections: ProviderConnection[];
}
export interface APIKeyChoice {
  id: string;
  name: string;
  supplier: Supplier;
  endpoint: string;
  sourceApplications: ApplicationID[];
}
export interface SupplierChoice { id: Supplier; name: string; endpoint: string; website: string }
export interface ProviderCatalog {
  application: ApplicationID;
  apiKeys: APIKeyChoice[];
  suppliers: SupplierChoice[];
  supportsCustom: true;
  error: string | null;
}
export interface SaveAPIKeyInput { supplier: Supplier; name: string; endpoint: string; key: string }
export interface AddProviderInput {
  application: ApplicationID;
  authorizationID: string;
  name: string;
  supplier: Supplier;
  endpoint: string;
  model: string;
  protocol: ProviderProtocol;
  contextWindow: number;
}
export interface MutationResult { ok: true }

export type QuotaLimitKind = "fiveHour" | "weekly" | "modelWeekly" | "unknown";
export interface QuotaLimit {
  id: string;
  kind: QuotaLimitKind;
  displayName: string | null;
  usedPercent: number;
  resetsAt: ISODateTime | null;
  windowSeconds: number | null;
  active: boolean | null;
}
export interface QuotaSnapshot {
  fetchedAt: ISODateTime;
  planType: string | null;
  unlimited: boolean | null;
  limits: QuotaLimit[];
}
export interface RefreshState {
  inFlight: boolean;
  backoffUntil: ISODateTime | null;
  lastSuccessAt: ISODateTime | null;
  lastAttemptAt: ISODateTime | null;
  failed: boolean;
  source: string | null;
  error: string | null;
}
export interface BalanceWallet { currency: string; total: DecimalString; toppedUp: DecimalString; granted: DecimalString; displayTotal: string }
export interface AccountBalance { wallets: BalanceWallet[]; available: boolean | null; fetchedAt: ISODateTime }
export type QuotaAccountKind = "primary" | "importedCodex" | "managedKimi" | "deepSeek" | "moonshot" | "localLogin";
export interface QuotaAccount {
  id: string;
  kind: QuotaAccountKind;
  service: QuotaService | "deepSeek" | "moonshot" | "gemini" | "grok";
  name: string;
  subtitle: string;
  plan: string | null;
  region: "china" | "global" | null;
  detected: boolean;
  current: boolean;
  personalAccessToken: boolean;
  enabled: boolean;
  showInMenuBar: boolean;
  showInFloatingHUD: boolean;
  supportsMenuBar: boolean;
  supportsFloatingHUD: boolean;
  keychainAccessBlocked: boolean;
  authorizationRequired: "claudeDesktop" | "cursor" | null;
  sourceLines: string[];
  sourceOwned: boolean;
  sourceApplication: ApplicationID | null;
  needsRefresh: boolean;
  snapshot: QuotaSnapshot | null;
  balance: AccountBalance | null;
  refresh: RefreshState;
}
export interface DeviceAuthorizationState {
  inProgress: boolean;
  awaitingBrowser: boolean;
  error: string | null;
  region: "china" | "global" | null;
  replacingAccountID: string | null;
}
export interface QuotaAccountsResult {
  accounts: QuotaAccount[];
  serviceOrder: QuotaService[];
  floatingEnabled: boolean;
  kimiAuthorization: DeviceAuthorizationState;
  deepSeekAuthorization: DeviceAuthorizationState;
  operationError: string | null;
}
export interface AccountDisplayPatch { enabled?: boolean; showInMenuBar?: boolean; showInFloatingHUD?: boolean }
export interface QuotaResetCredit {
  id: string;
  title: string;
  status: string;
  grantedAt: ISODateTime | null;
  expiresAt: ISODateTime | null;
}
export interface QuotaResetCreditsResult { accountID: string; availableCount: number; credits: QuotaResetCredit[]; error: string | null }
export interface CodexPreviewAccount { id: string; email: string | null; plan: string | null; chatgptAccountID: string }
export interface CodexImportPreview { kind: "oauth" | "personalAccessToken"; accounts: CodexPreviewAccount[] }
export interface CodexImportInput { payload: string; visibleInPopover: boolean; alias?: string }
export interface CodexImportResult { imported: number; failed: number; error: string | null }
export interface KimiAuthorizationInput { region: "china" | "global"; replacingAccountID?: string }
export interface DeepSeekAuthorizationInput { name: string; accountID?: string }
export interface AuthorizationStartResult { started: boolean }

export type StatsRange = "today" | "yesterday" | "last7" | "last30" | "thisWeek" | "lastWeek" | "last4Weeks" | "last12Weeks" | "thisMonth" | "lastMonth" | "last6Months" | "thisYear" | "all" | "custom";
export type StatsGranularity = "day" | "week" | "month";
export type RankMetric = "tokens" | "cost";
export interface StatsQuery { range: StatsRange; granularity: StatsGranularity; customFrom?: LocalDate; customTo?: LocalDate; service?: UsageService }
export interface UsageTotals {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  inputWithCacheTokens: number;
  totalTokens: number;
  costUSD: DecimalString;
  costDisplay: string;
  requestCount: number;
  cacheHitRate: number;
  hasUnpricedUsage: boolean;
  costIncomplete: boolean;
  averageFirstTokenSeconds: number | null;
  outputTokensPerSecond: number | null;
  usesEstimatedSpeed: boolean;
}
export type DashboardMetric = "cost" | "requests" | "tokens" | "cacheHitRate";
export interface DashboardQuery { range: "today" | "last24h" | "last7" | "last14" | "last30" | "all" | "custom"; customFrom?: ISODateTime; customTo?: ISODateTime; followNow?: boolean; service?: UsageService; sourceID?: string; modelID?: string; metric: DashboardMetric }
export interface DashboardCoverage { precision: "event" | "day" | "mixed"; incomplete: boolean; refreshing: boolean; unlocatedTotals: UsageTotals; message: string | null }
export interface DashboardFacet { id: string; title: string; requestCount: number }
export interface DashboardSourceFacet extends DashboardFacet { service: UsageService; models: DashboardFacet[] }
export interface DashboardRow { id: string; title: string; service: UsageService; sourceID: string; modelID: string | null; totals: UsageTotals; successRate: number | null }
export interface DashboardSampleSegment { service: UsageService; totals: UsageTotals; value: number; label: string; share: number }
export interface DashboardSample { segments: DashboardSampleSegment[]; key: string; start: ISODateTime; totals: UsageTotals; value: number; label: string; normalizedValue: number }
export interface UsageDashboard { requestLogCount: number | null; kpiDisplay: Record<DashboardMetric, string>; revision: string; resolvedRange: { from: ISODateTime; to: ISODateTime; timeZone: string; granularity: "hour" | "day" | "month"; asOf: ISODateTime }; coverage: DashboardCoverage; totals: UsageTotals; facets: { services: DashboardFacet[]; sources: DashboardSourceFacet[]; models: DashboardFacet[] }; providerRows: DashboardRow[]; modelRows: DashboardRow[]; samples: DashboardSample[]; axisTicks: { position: number; label: string }[]; status: UsageOperationStatus }
export interface DashboardRequest { id: string; timestamp: ISODateTime; service: UsageService; sourceID: string; modelID: string; totals: UsageTotals; status: "unknown"; conversationID: string | null }
export interface DashboardRequests { revision: string; resolvedRange: UsageDashboard["resolvedRange"]; totalCount: number; page: number; pageSize: number; rows: DashboardRequest[]; nextCursor: string | null; coverage: DashboardCoverage; status: UsageOperationStatus }
export interface DashboardHeatmap {
  fromDay: LocalDate;
  toDay: LocalDate;
  timeZone: string;
  // First recorded day across the filtered history, including before this window.
  cumulativeFromDay: LocalDate | null;
  days: {
    day: LocalDate;
    totals: UsageTotals;
    value: number;
    label: string;
    normalizedValue: number;
    // Host-computed history total through this day; never a window-local sum.
    cumulativeTokens: number;
  }[];
  totals: UsageTotals;
  nextBeforeDay: LocalDate | null;
  coverage: DashboardCoverage;
  status: UsageOperationStatus;
}
export interface UsageSpeedBreakdown {
  summary: "standard" | "fast" | "mixed" | "unknown";
  standard: UsageTotals;
  fast: UsageTotals;
  unknown: UsageTotals;
  fastBillingEquivalentTokens: DecimalString;
  fastMinimumMultiplier: DecimalString | null;
  fastMaximumMultiplier: DecimalString | null;
  hasUnpricedFastEquivalent: boolean;
}
export interface Comparison {
  tokens: number | null;
  costUSD: DecimalString | null;
  requests: number | null;
}
export interface UsageSample { key: string; start: ISODateTime; totals: UsageTotals; byService: Partial<Record<UsageService, UsageTotals>>; highlighted: boolean }
export interface CompositionRow {
  id: string;
  kind: "item" | "unattributed";
  title: string;
  subtitle: string;
  totals: UsageTotals;
  speed: UsageSpeedBreakdown | null;
  share: number;
  color: { role: "service" | "rank" | "rest" | "unattributed"; service?: UsageService; rank?: number };
  action: { type: "none" | "selectService" | "expandProvider" | "expandModel" | "openProject" | "openUnattributed"; value?: string };
  models: ModelUsage[];
  sources: ModelUsage[];
  services: UsageService[];
  projectStatus: ProjectStatus | null;
}
export interface ModelUsage { model: string; service: UsageService; totals: UsageTotals; speed: UsageSpeedBreakdown }
export interface ConversationSummary {
  id: string;
  conversationID: string;
  service: UsageService;
  title: string | null;
  project: ProjectIdentity;
  gitBranch: string | null;
  firstAt: ISODateTime;
  lastAt: ISODateTime;
  rangeLastAt: ISODateTime;
  includesSubtasks: boolean;
  cacheCreationAvailable: boolean;
  totals: UsageTotals;
  costs: ConversationCosts;
  speed: UsageSpeedBreakdown;
  models: string[];
}
export interface ConversationCosts { input: DecimalString; output: DecimalString; cacheRead: DecimalString; cacheCreation: DecimalString; total: DecimalString; displayInput: string; displayOutput: string; displayCacheRead: string; displayCacheCreation: string; displayTotal: string; hasUnpricedUsage: boolean }
export interface TopConversation { summary: ConversationSummary; project: ProjectIdentity; share: number }
export interface ServiceUsageKPI { service: UsageService; totals: UsageTotals; previousTotals: UsageTotals | null; comparison: Comparison; speed: UsageSpeedBreakdown; models: ModelUsage[] }
export interface UsageOverview {
  revision: string;
  range: { from: ISODateTime; to: ISODateTime; previousFrom: ISODateTime | null; previousTo: ISODateTime | null; chartFrom: ISODateTime; chartTo: ISODateTime };
  visibleServices: UsageService[];
  totals: UsageTotals;
  previousTotals: UsageTotals | null;
  comparison: Comparison;
  speed: UsageSpeedBreakdown;
  services: ServiceUsageKPI[];
  samples: UsageSample[];
  barWidth: number;
  composition: Record<"service" | "provider" | "model" | "project", CompositionRow[]>;
  unattributed: UsageTotals;
  topConversations: TopConversation[];
  topConversationsShare: number | null;
  models: ModelUsage[];
  status: UsageOperationStatus;
}
export interface UsageOperationStatus {
  historyNotice: { message: string; restoredAt: ISODateTime | null; canOpenSettings: boolean } | null;
  scanning: boolean;
  rebuildingHistory: boolean;
  rebuildingCycles: boolean;
  refreshingPricing: boolean;
  lastScanAt: ISODateTime | null;
  error: string | null;
  progress: { service: UsageService; filesCompleted: number; filesTotal: number; linesParsed: number } | null;
  lastRebuildOutcome: "replaced" | "rejectedUsageChanged" | "rejectedIncompleteSources" | "commitFailed" | "partiallyCommitted" | "recoveredFromRestrictedHistory" | "restrictedRecoveryRejected" | null;
  lastRebuildMessage: string | null;
  lastRebuildDiagnostic: string | null;
}
export interface ConversationListQuery extends StatsQuery { search?: string; projectKey?: string; sort?: "recent" | "tokens" | "cost"; offset?: number; limit?: number }
export interface ProjectOption { key: string; name: string; path: string; status: ProjectStatus; conversationCount: number; lastAt: ISODateTime; duplicateName: boolean }
export interface ConversationListResult { rows: ConversationSummary[]; total: number; offset: number; limit: number; projects: ProjectOption[]; status: UsageOperationStatus }
export interface ConversationModel extends ModelUsage { costs: ConversationCosts }
export interface ConversationDetail {
  summary: ConversationSummary;
  models: ConversationModel[];
}
export type ProjectStatus = "available" | "unavailable" | "unverified" | "unassigned" | "system";
export interface ProjectIdentity { key: string; name: string; path: string; status: ProjectStatus }
export interface ProjectUsage {
  identity: ProjectIdentity;
  totals: UsageTotals;
  speed: UsageSpeedBreakdown;
  totalsByService: Partial<Record<UsageService, UsageTotals>>;
  sharesByService: Partial<Record<UsageService, number>>;
  conversationCount: number;
  lastAt: ISODateTime;
  worktreeCount: number;
}
export interface UnattributedUsage {
  total: UsageTotals;
  cursor: UsageTotals;
  local: UsageTotals;
  localServices: UsageService[];
  localFirstDay: ISODateTime | null;
  localLastDay: ISODateTime | null;
  dailyCursor: UsageSample[];
  dailyLocal: UsageSample[];
  overviewTotals: UsageTotals;
  overviewShare: number | null;
}
export interface ProjectListQuery extends StatsQuery { search?: string; sort?: "cost" | "tokens" | "recent"; offset?: number; limit?: number }
export interface ProjectListResult { rows: ProjectUsage[]; total: number; offset: number; limit: number; unattributed: UnattributedUsage; status: UsageOperationStatus }
export interface ProjectDetailQuery extends StatsQuery { projectKey: string }
export interface ProjectModel { model: string; services: UsageService[]; totals: UsageTotals }
export interface ProjectBranch { branch: string | null; conversationCount: number; totals: UsageTotals }
export interface ProjectWorktree { path: string; branch: string | null; main: boolean; totals: UsageTotals }
export interface ProjectDetail {
  project: ProjectIdentity;
  totals: UsageTotals;
  previousTotals: UsageTotals | null;
  comparison: Comparison;
  conversationCount: number;
  activeDays: number;
  rangeDayCount: number;
  daily: UsageSample[];
  totalsByService: Partial<Record<UsageService, UsageTotals>>;
  sharesByService: Partial<Record<UsageService, number>>;
  models: ProjectModel[];
  branches: ProjectBranch[];
  topConversations: TopConversation[];
  worktrees: ProjectWorktree[];
  allTimeTotals: UsageTotals;
  firstUsedDay: ISODateTime | null;
  gitRepository: boolean | null;
}
export interface QuotaAnalyticsQuery { accountID: string; kind: QuotaLimitKind }
export interface QuotaCycle {
  id: string;
  service: UsageService;
  limitID: string;
  kind: QuotaLimitKind;
  startAt: ISODateTime;
  endAt: ISODateTime;
  scheduledEndAt: ISODateTime;
  firstSampleAt: ISODateTime | null;
  lastSampleAt: ISODateTime | null;
  latestUsedPercent: number;
  reportedUsedPercent: number;
  boundaryQuality: "observed" | "inferred";
  current: boolean;
  extraResetCount: number;
}
export interface CycleSummary {
  cycle: QuotaCycle;
  totals: UsageTotals;
  currentAllowanceTotals: UsageTotals;
  quality: "exact" | "estimated" | "incomplete";
  estimatedFullAllowanceTokens: number | null;
  estimatedFullAllowanceCostUSD: DecimalString | null;
  estimatedFullAllowanceCostDisplay: string | null;
  forecastConfidence: "early" | "rough" | "reference" | "reliable" | null;
}
export interface QuotaTimelineEntry { id: string; source: "change" | "sample"; sampledAt: ISODateTime; remainingPercent: number; deltaPercent: number | null; resetsAt: ISODateTime | null; windowIndex: number }
export interface QuotaTimelinePeriod { id: string; kind: "today" | "currentCycle" | "previousCycle"; start: ISODateTime; end: ISODateTime; totalDelta: number; entries: QuotaTimelineEntry[] }
export interface QuotaAnalytics { account: QuotaAccount; cycles: CycleSummary[]; timeline: QuotaTimelinePeriod[]; window: { kind: QuotaLimitKind; remainingPercent: number | null; latestSampleAt: ISODateTime | null; resetsAt: ISODateTime | null } | null; status: UsageOperationStatus }

export interface BrandColorSetting { brand: ServiceBrand; mode: "brand" | "custom"; customHex: string | null; defaultLightHex: string; defaultDarkHex: string }
export interface CurrencyState {
  selected: "USD" | "CNY" | "JPY" | "KRW" | "HKD" | "AUD" | "SGD" | "GBP";
  rates: Partial<Record<CurrencyState["selected"], DecimalString>>;
  fetchedAt: ISODateTime | null;
  sourceUpdatedAt: ISODateTime | null;
  refreshing: boolean;
  lastRefreshFailedAt: ISODateTime | null;
}
export interface NotificationState {
  authorization: "notDetermined" | "denied" | "authorized" | "provisional" | "ephemeral" | "unknown";
  canSubmit: boolean;
  alertsAllowed: boolean | null;
  soundAllowed: boolean | null;
  statusText: string | null;
  requesting: boolean;
  authorizationFailed: boolean;
  permissionReadFailed: boolean;
  storagePaused: boolean;
  rebuilding: boolean;
}
export interface UpdateState { version: string; automaticChecks: boolean; canCheck: boolean; hasUpdate: boolean; isWorking: boolean; lastCheckedAt: ISODateTime | null }
export interface WindowSettings {
  appearance: {
    menuBarWindow: "primary" | "weekly" | "both";
    useInstalledAppIcons: boolean;
    floatingEnabled: boolean;
    resetTimeDisplay: "relative" | "absolute";
    showServiceStatus: boolean;
    privacyMode: boolean;
    statsRankMetric: RankMetric;
    cycleIncludesOtherAgents: boolean;
    piEstimatedOutputSpeed: boolean;
    brandColors: BrandColorSetting[];
    recentBrandColors: string[];
  };
  data: {
    quotaInterval: "m1" | "m2" | "m3" | "m5" | "m10";
    usageInterval: "m1" | "m2" | "m3" | "m5" | "m10";
    proxyMode: "system" | "manual";
    proxyType: "http" | "socks5";
    proxyHost: string;
    proxyPort: number;
    currency: CurrencyState;
    usage: UsageOperationStatus;
    piTimingGuide: { title: string; instructions: string; copyText: string };
  };
  general: {
    language: "system" | "zh" | "en";
    launchAtLogin: boolean;
    launchAtLoginRequiresApproval: boolean;
    quotaAlertsEnabled: boolean;
    quotaAlertThresholdPercent: number;
    quotaAlertFiveHourEnabled: boolean;
    quotaAlertWeeklyEnabled: boolean;
    quotaAlertBillingCycleEnabled: boolean;
    quotaAlertSoundEnabled: boolean;
    notifications: NotificationState;
    verboseLogging: boolean;
    updates: UpdateState;
  };
}
export interface BrandColorPatch { brand: ServiceBrand; mode: "brand" | "custom"; customHex?: string }
export interface SettingsPatch {
  menuBarWindow?: WindowSettings["appearance"]["menuBarWindow"];
  useInstalledAppIcons?: boolean;
  floatingEnabled?: boolean;
  resetTimeDisplay?: WindowSettings["appearance"]["resetTimeDisplay"];
  showServiceStatus?: boolean;
  privacyMode?: boolean;
  statsRankMetric?: RankMetric;
  cycleIncludesOtherAgents?: boolean;
  piEstimatedOutputSpeed?: boolean;
  brandColor?: BrandColorPatch;
  quotaInterval?: WindowSettings["data"]["quotaInterval"];
  usageInterval?: WindowSettings["data"]["usageInterval"];
  proxyMode?: WindowSettings["data"]["proxyMode"];
  proxyType?: WindowSettings["data"]["proxyType"];
  proxyHost?: string;
  proxyPort?: number;
  currency?: CurrencyState["selected"];
  language?: WindowSettings["general"]["language"];
  quotaAlertsEnabled?: boolean;
  quotaAlertThresholdPercent?: number;
  quotaAlertFiveHourEnabled?: boolean;
  quotaAlertWeeklyEnabled?: boolean;
  quotaAlertBillingCycleEnabled?: boolean;
  quotaAlertSoundEnabled?: boolean;
  verboseLogging?: boolean;
}
export interface ProxyTestResult { ok: boolean; message: string }
export interface Price { input: DecimalString; output: DecimalString; cacheRead: DecimalString; cacheCreation: DecimalString }
export interface PricingModel { id: string; name: string; price: Price; displayPrice: Price }
export interface PricingProvider { id: string; name: string; models: PricingModel[] }
export interface PricingCatalog { providers: PricingProvider[]; fetchedAt: ISODateTime | null; refreshFailed: boolean; usage: UsageOperationStatus }
export interface RecalculateResult { started: boolean; ok: boolean; message: string; usage: UsageOperationStatus }
export interface DiagnosticsResult { path: string }

export class WindowAPI {
  private readonly listeners = new Set<(event: Parameters<Parameters<HostAPI["subscribe"]>[0]>[0]) => void>();
  private readonly unsubscribe: () => void;
  private disposed = false;

  constructor(private readonly host: HostAPI) {
    this.unsubscribe = host.subscribe((event) => {
      for (const listener of [...this.listeners]) listener(event);
    });
  }

  private async call<T>(method: string, params: object, schema: Schema<T>, timeoutMs?: number): Promise<T> {
    if (this.disposed) throw new HostError("disposed", "Window API is disposed");
    return schema.parse(await this.host.request<unknown>(method, withoutUndefined(params) as object, timeoutMs), method);
  }
  subscribe(listener: (event: Parameters<Parameters<HostAPI["subscribe"]>[0]>[0]) => void): () => void {
    if (this.disposed) throw new HostError("disposed", "Window API is disposed");
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.listeners.clear();
    this.unsubscribe();
  }

  bootstrap(): Promise<WindowBootstrap> { return this.call("window.bootstrap", {}, windowBootstrapSchema); }
  navigate(route: Route): Promise<WindowBootstrap> { return this.call("window.navigate", { route }, windowBootstrapSchema); }
  applicationsList(): Promise<ApplicationsResult> { return this.call("applications.list", {}, applicationsSchema); }
  applicationsDetect(): Promise<ApplicationsResult> { return this.call("applications.detect", {}, applicationsSchema); }
  applicationsSetVisibility(application: ApplicationID, patch: ApplicationVisibilityPatch): Promise<ApplicationsResult> { return this.call("applications.setVisibility", { application, patch }, applicationsSchema); }
  applicationDetail(application: ApplicationID): Promise<ApplicationDetail> { return this.call("applications.detail", { application }, applicationDetailSchema); }
  providersCatalog(application: ApplicationID): Promise<ProviderCatalog> { return this.call("providers.catalog", { application }, providerCatalogSchema); }
  authorizationsSaveAPIKey(input: SaveAPIKeyInput): Promise<APIKeyChoice> { return this.call("authorizations.saveAPIKey", input, apiKeyChoiceSchema); }
  providersAdd(input: AddProviderInput): Promise<ApplicationDetail> { return this.call("providers.add", input, applicationDetailSchema); }
  authorizationsGrantAccess(kind: "claudeDesktop" | "cursor"): Promise<QuotaAccountsResult> { return this.call("authorizations.grantAccess", { kind }, quotaAccountsSchema, 10 * 60 * 1000); }
  quotaAccounts(): Promise<QuotaAccountsResult> { return this.call("quota.accounts", {}, quotaAccountsSchema); }
  quotaUpdateAccount(id: string, patch: AccountDisplayPatch): Promise<QuotaAccountsResult> { return this.call("quota.updateAccount", { id, patch }, quotaAccountsSchema, 2 * 60 * 1000); }
  quotaReorder(serviceOrder: QuotaService[], importedCodexOrder?: string[]): Promise<QuotaAccountsResult> { return this.call("quota.reorder", { serviceOrder, importedCodexOrder }, quotaAccountsSchema); }
  quotaRefresh(id?: string): Promise<QuotaAccountsResult> { return this.call("window.quota.refresh", { id }, quotaAccountsSchema, 2 * 60 * 1000); }
  quotaResetCredits(id: string): Promise<QuotaResetCreditsResult> { return this.call("quota.resetCredits", { id }, quotaResetCreditsSchema, 60 * 1000); }
  codexPreview(payload: string): Promise<CodexImportPreview> { return this.call("codex.preview", { payload }, codexPreviewSchema); }
  codexImport(input: CodexImportInput): Promise<CodexImportResult> { return this.call("codex.import", input, codexImportResultSchema, 10 * 60 * 1000); }
  codexDelete(id: string): Promise<QuotaAccountsResult> { return this.call("codex.delete", { id }, quotaAccountsSchema); }
  codexRetryAccess(id: string): Promise<QuotaAccountsResult> { return this.call("codex.retryAccess", { id }, quotaAccountsSchema, 10 * 60 * 1000); }
  kimiStartAuthorization(input: KimiAuthorizationInput): Promise<AuthorizationStartResult> { return this.call("kimi.startAuthorization", input, authorizationStartSchema); }
  kimiCancelAuthorization(): Promise<QuotaAccountsResult> { return this.call("kimi.cancelAuthorization", {}, quotaAccountsSchema); }
  kimiRetryAccess(id: string): Promise<QuotaAccountsResult> { return this.call("kimi.retryAccess", { id }, quotaAccountsSchema, 10 * 60 * 1000); }
  kimiDelete(id: string): Promise<QuotaAccountsResult> { return this.call("kimi.delete", { id }, quotaAccountsSchema); }
  deepSeekStartAuthorization(input: DeepSeekAuthorizationInput): Promise<AuthorizationStartResult> { return this.call("deepseek.startAuthorization", input, authorizationStartSchema); }
  deepSeekCancelAuthorization(): Promise<QuotaAccountsResult> { return this.call("deepseek.cancelAuthorization", {}, quotaAccountsSchema); }
  deepSeekRename(id: string, name: string): Promise<QuotaAccountsResult> { return this.call("deepseek.rename", { id, name }, quotaAccountsSchema); }
  deepSeekDelete(id: string): Promise<QuotaAccountsResult> { return this.call("deepseek.delete", { id }, quotaAccountsSchema); }
  deepSeekRefresh(id: string): Promise<QuotaAccountsResult> { return this.call("deepseek.refresh", { id }, quotaAccountsSchema); }
  usageDashboard(query: DashboardQuery): Promise<UsageDashboard> { return this.call("window.usage.dashboard", query, dashboardSchema); }
  usageRequests(query: DashboardQuery & { page?: number; pageSize?: number; cursor?: string; limit?: number; sort?: "time" | "cost" | "tokens"; direction?: "asc" | "desc" }): Promise<DashboardRequests> { return this.call("window.usage.requests", query, dashboardRequestsSchema); }
  usageHeatmap(query: DashboardQuery & { beforeDay?: LocalDate }): Promise<DashboardHeatmap> { return this.call("window.usage.heatmap", query, dashboardHeatmapSchema); }
  usageOverview(query: StatsQuery): Promise<UsageOverview> { return this.call("window.usage.overview", query, usageOverviewSchema); }
  usageRefresh(): Promise<UsageOperationStatus> { return this.call("usage.refresh", {}, usageStatusSchema); }
  conversationsList(query: ConversationListQuery): Promise<ConversationListResult> { return this.call("conversations.list", query, conversationListSchema); }
  conversationDetail(id: string, metric?: RankMetric): Promise<ConversationDetail> { return this.call("conversations.detail", { id, metric }, conversationDetailSchema); }
  conversationsCopyID(id: string): Promise<MutationResult> { return this.call("conversations.copyID", { id }, mutationSchema); }
  projectsList(query: ProjectListQuery): Promise<ProjectListResult> { return this.call("projects.list", query, projectListSchema); }
  projectDetail(query: ProjectDetailQuery): Promise<ProjectDetail> { return this.call("projects.detail", query, projectDetailSchema); }
  projectsReveal(projectKey: string): Promise<MutationResult> { return this.call("projects.reveal", { projectKey }, mutationSchema); }
  quotaAnalytics(query: QuotaAnalyticsQuery): Promise<QuotaAnalytics> { return this.call("quota.analytics", query, quotaAnalyticsSchema); }
  settingsGet(): Promise<WindowSettings> { return this.call("window.settings.get", {}, settingsSchema); }
  settingsUpdate(patch: SettingsPatch): Promise<WindowSettings> { return this.call("window.settings.update", { patch }, settingsSchema); }
  settingsSetLaunchAtLogin(enabled: boolean): Promise<WindowSettings> { return this.call("window.settings.setLaunchAtLogin", { enabled }, settingsSchema); }
  settingsResetBrandColors(): Promise<WindowSettings> { return this.call("settings.resetBrandColors", {}, settingsSchema); }
  settingsCopyPiTimingGuide(): Promise<MutationResult> { return this.call("settings.copyPiTimingGuide", {}, mutationSchema); }
  settingsTestProxy(): Promise<ProxyTestResult> { return this.call("settings.testProxy", {}, proxyTestSchema); }
  settingsRefreshCurrency(): Promise<WindowSettings> { return this.call("settings.refreshCurrency", {}, settingsSchema); }
  pricingCatalog(): Promise<PricingCatalog> { return this.call("pricing.catalog", {}, pricingCatalogSchema); }
  pricingRefreshAndRecalculate(): Promise<RecalculateResult> { return this.call("pricing.refreshAndRecalculate", {}, recalculateSchema, 30 * 60 * 1000); }
  notificationsRequestPermission(): Promise<WindowSettings> { return this.call("notifications.requestPermission", {}, settingsSchema); }
  notificationsRebuild(): Promise<WindowSettings> { return this.call("notifications.rebuild", {}, settingsSchema); }
  notificationsOpenSettings(): Promise<MutationResult> { return this.call("notifications.openSettings", {}, mutationSchema); }
  diagnosticsExport(): Promise<DiagnosticsResult> { return this.call("diagnostics.export", {}, diagnosticsSchema, 10 * 60 * 1000); }
  diagnosticsRevealLogs(): Promise<MutationResult> { return this.call("diagnostics.revealLogs", {}, mutationSchema); }
  updatesStatus(): Promise<UpdateState> { return this.call("updates.status", {}, updateStateSchema); }
  updatesCheck(): Promise<UpdateState> { return this.call("updates.check", {}, updateStateSchema); }
  updatesSetAutomatic(enabled: boolean): Promise<UpdateState> { return this.call("updates.setAutomatic", { enabled }, updateStateSchema); }
  platformOpenExternal(url: string): Promise<MutationResult> { return this.call("platform.openExternal", { url }, mutationSchema); }
}

interface Schema<T> { parse(value: unknown, path: string): T }
interface OptionalSchema<T> extends Schema<T | undefined> { readonly optional: true }
type Infer<S> = S extends Schema<infer T> ? T : never;
const fail = (path: string, expected: string): never => { throw new HostError("invalid_response", `Invalid ${path}: expected ${expected}`); };
const record = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const schema = <T>(parse: (value: unknown, path: string) => T): Schema<T> => ({ parse });
const string = schema((value, path) => typeof value === "string" ? value : fail(path, "string"));
const nonEmpty = schema((value, path) => typeof value === "string" && value.length > 0 ? value : fail(path, "non-empty string"));
const boolean = schema((value, path) => typeof value === "boolean" ? value : fail(path, "boolean"));
const number = schema((value, path) => typeof value === "number" && Number.isFinite(value) ? value : fail(path, "finite number"));
const integer = schema((value, path) => typeof value === "number" && Number.isSafeInteger(value) ? value : fail(path, "safe integer"));
const nonNegativeInteger = schema((value, path) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail(path, "non-negative safe integer"));
const decimal = schema((value, path) => typeof value === "string" && /^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value) ? value : fail(path, "decimal string"));
const isoDate = schema((value, path) => typeof value === "string" && Number.isFinite(Date.parse(value)) ? value : fail(path, "ISO date"));
const localDate = schema((value, path) => {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return fail(path, "local date (YYYY-MM-DD)");
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value ? value : fail(path, "valid local date");
});
const dataImage = schema((value, path) => typeof value === "string" && /^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(value) ? value : fail(path, "PNG data URI"));
const nullable = <T>(inner: Schema<T>) => schema<T | null>((value, path) => value === null ? null : inner.parse(value, path));
const optional = <T>(inner: Schema<T>): OptionalSchema<T> => ({ optional: true, parse: (value, path) => value === undefined ? undefined : inner.parse(value, path) });
const array = <T>(inner: Schema<T>) => schema<T[]>((value, path) => {
  if (!Array.isArray(value)) return fail(path, "array");
  return value.map((item, index) => inner.parse(item, `${path}[${index}]`));
});
const enumeration = <const T extends readonly string[]>(values: T) => schema<T[number]>((value, path) => typeof value === "string" && (values as readonly string[]).includes(value) ? value as T[number] : fail(path, values.join("|")));
const literal = <const T extends string | number | boolean>(expected: T) => schema<T>((value, path) => value === expected ? expected : fail(path, String(expected)));
const object = <S extends Record<string, Schema<unknown>>>(shape: S) => schema<{ [K in keyof S]: Infer<S[K]> }>((value, path) => {
  if (!record(value)) return fail(path, "object");
  const allowed = new Set(Object.keys(shape));
  for (const key of Object.keys(value)) if (!allowed.has(key)) return fail(`${path}.${key}`, "no unknown fields");
  const result: Record<string, unknown> = {};
  for (const [key, inner] of Object.entries(shape)) {
    if (value[key] === undefined && (inner as Partial<OptionalSchema<unknown>>).optional === true) continue;
    result[key] = inner.parse(value[key], `${path}.${key}`);
  }
  return result as { [K in keyof S]: Infer<S[K]> };
});
const keyedDictionary = <const K extends readonly string[], T>(keys: K, inner: Schema<T>) => schema<Partial<Record<K[number], T>>>((value, path) => {
  if (!record(value)) return fail(path, "object");
  for (const key of Object.keys(value)) if (!(keys as readonly string[]).includes(key)) return fail(`${path}.${key}`, "known dictionary key");
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, inner.parse(item, `${path}.${key}`)])) as Partial<Record<K[number], T>>;
});
const withoutUndefined = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(withoutUndefined);
  if (!record(value)) return value;
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined).map(([key, item]) => [key, withoutUndefined(item)]));
};
const mutationSchema = object({ ok: literal(true) });
const applicationID = enumeration(["codex", "claude", "kimi", "dsh", "gemini", "grok", "opencode", "pi", "cursor", "antigravity", "commandCode"] as const);
const usageService = enumeration(["codex", "claude", "cursor", "pi", "opencode", "dsh", "antigravity", "kimi"] as const);
const quotaService = enumeration(["codex", "claude", "antigravity", "cursor", "commandCode", "opencodeGo", "kimi"] as const);
const serviceBrand = enumeration(["codex", "claude", "antigravity", "cursor", "commandCode", "opencode", "kimi", "pi", "dsh", "deepseek", "grok", "gemini"] as const);
const supplier = enumeration(["openai", "anthropic", "kimi", "deepseek", "grok", "gemini", "custom"] as const);
const protocol = enumeration(["responses", "chatCompletions", "anthropic", "gemini"] as const);
const routeSchema: Schema<Route> = schema((value, path) => {
  if (!record(value) || typeof value.page !== "string") return fail(path, "route");
  if (value.page === "application") return object({ page: literal("application"), application: applicationID }).parse(value, path) as Route;
  return object({ page: enumeration(["applications", "quotaManagement", "stats", "settings"] as const) }).parse(value, path) as Route;
});
const brandIconSchema = object({ brand: serviceBrand, kind: enumeration(["installedApp", "favicon", "brand", "fallback"] as const), dataURI: nullable(dataImage), fillsTile: boolean, lightHex: string, darkHex: string });
const applicationFields = { id: applicationID, name: string, detected: boolean, addedToSidebar: boolean, usageService: nullable(usageService), usageVisible: boolean, supportsProviderConfiguration: boolean, supportedAPIs: array(protocol), defaultSupplier: supplier, icon: brandIconSchema };
const applicationSummarySchema = object(applicationFields);
const windowBootstrapSchema = object({ route: routeSchema, language: enumeration(["system", "zh", "en"] as const), resolvedLanguage: enumeration(["zh", "en"] as const), platform: nonEmpty, timeZone: string, appearance: enumeration(["light", "dark"] as const), version: string, sidebarApplications: array(applicationSummarySchema), visibleUsageServices: array(usageService), capabilities: array(string) });
const applicationsSchema = object({ applications: array(applicationSummarySchema), error: nullable(string) });
const providerConnectionSchema = object({ id: string, name: string, supplier, endpoint: string, models: array(string), protocol, contextWindow: integer, official: boolean, active: boolean, authorizationID: nullable(string) });
const applicationDetailSchema = object({ ...applicationFields, loginSummary: nullable(string), error: nullable(string), connections: array(providerConnectionSchema) });
const apiKeyChoiceSchema = object({ id: string, name: string, supplier, endpoint: string, sourceApplications: array(applicationID) });
const providerCatalogSchema = object({ application: applicationID, apiKeys: array(apiKeyChoiceSchema), suppliers: array(object({ id: supplier, name: string, endpoint: string, website: string })), supportsCustom: literal(true), error: nullable(string) });
const quotaLimitSchema = object({ id: string, kind: enumeration(["fiveHour", "weekly", "modelWeekly", "unknown"] as const), displayName: nullable(string), usedPercent: number, resetsAt: nullable(isoDate), windowSeconds: nullable(number), active: nullable(boolean) });
const quotaSnapshotSchema = object({ fetchedAt: isoDate, planType: nullable(string), unlimited: nullable(boolean), limits: array(quotaLimitSchema) });
const refreshStateSchema = object({ inFlight: boolean, backoffUntil: nullable(isoDate), lastSuccessAt: nullable(isoDate), lastAttemptAt: nullable(isoDate), failed: boolean, source: nullable(string), error: nullable(string) });
const accountBalanceSchema = object({ wallets: array(object({ currency: string, total: decimal, toppedUp: decimal, granted: decimal, displayTotal: string })), available: nullable(boolean), fetchedAt: isoDate });
const quotaAccountSchema = object({ id: string, kind: enumeration(["primary", "importedCodex", "managedKimi", "deepSeek", "moonshot", "localLogin"] as const), service: enumeration(["codex", "claude", "antigravity", "cursor", "commandCode", "opencodeGo", "kimi", "deepSeek", "moonshot", "gemini", "grok"] as const), name: string, subtitle: string, plan: nullable(string), region: nullable(enumeration(["china", "global"] as const)), detected: boolean, current: boolean, personalAccessToken: boolean, enabled: boolean, showInMenuBar: boolean, showInFloatingHUD: boolean, supportsMenuBar: boolean, supportsFloatingHUD: boolean, keychainAccessBlocked: boolean, authorizationRequired: nullable(enumeration(["claudeDesktop", "cursor"] as const)), sourceLines: array(string), sourceOwned: boolean, sourceApplication: nullable(applicationID), needsRefresh: boolean, snapshot: nullable(quotaSnapshotSchema), balance: nullable(accountBalanceSchema), refresh: refreshStateSchema });
const deviceAuthorizationSchema = object({ inProgress: boolean, awaitingBrowser: boolean, error: nullable(string), region: nullable(enumeration(["china", "global"] as const)), replacingAccountID: nullable(string) });
const quotaAccountsSchema = object({ accounts: array(quotaAccountSchema), serviceOrder: array(quotaService), floatingEnabled: boolean, kimiAuthorization: deviceAuthorizationSchema, deepSeekAuthorization: deviceAuthorizationSchema, operationError: nullable(string) });
const quotaResetCreditsSchema = object({ accountID: string, availableCount: integer, credits: array(object({ id: string, title: string, status: string, grantedAt: nullable(isoDate), expiresAt: nullable(isoDate) })), error: nullable(string) });
const codexPreviewSchema = object({ kind: enumeration(["oauth", "personalAccessToken"] as const), accounts: array(object({ id: string, email: nullable(string), plan: nullable(string), chatgptAccountID: string })) });
const codexImportResultSchema = object({ imported: integer, failed: integer, error: nullable(string) });
const authorizationStartSchema = object({ started: boolean });
const totalsSchema = object({ inputTokens: integer, outputTokens: integer, cacheReadTokens: integer, cacheCreationTokens: integer, inputWithCacheTokens: integer, totalTokens: integer, costUSD: decimal, costDisplay: string, requestCount: integer, cacheHitRate: number, hasUnpricedUsage: boolean, costIncomplete: boolean, averageFirstTokenSeconds: nullable(number), outputTokensPerSecond: nullable(number), usesEstimatedSpeed: boolean });
const speedSchema = object({ summary: enumeration(["standard", "fast", "mixed", "unknown"] as const), standard: totalsSchema, fast: totalsSchema, unknown: totalsSchema, fastBillingEquivalentTokens: decimal, fastMinimumMultiplier: nullable(decimal), fastMaximumMultiplier: nullable(decimal), hasUnpricedFastEquivalent: boolean });
const comparisonSchema = object({ tokens: nullable(number), costUSD: nullable(decimal), requests: nullable(number) });
const usageStatusSchema = object({ historyNotice: nullable(object({ message: string, restoredAt: nullable(isoDate), canOpenSettings: boolean })), scanning: boolean, rebuildingHistory: boolean, rebuildingCycles: boolean, refreshingPricing: boolean, lastScanAt: nullable(isoDate), error: nullable(string), progress: nullable(object({ service: usageService, filesCompleted: integer, filesTotal: integer, linesParsed: integer })), lastRebuildOutcome: nullable(enumeration(["replaced", "rejectedUsageChanged", "rejectedIncompleteSources", "commitFailed", "partiallyCommitted", "recoveredFromRestrictedHistory", "restrictedRecoveryRejected"] as const)), lastRebuildMessage: nullable(string), lastRebuildDiagnostic: nullable(string) });
const dashboardCoverageSchema = object({ precision: enumeration(["event", "day", "mixed"] as const), incomplete: boolean, refreshing: boolean, unlocatedTotals: totalsSchema, message: nullable(string) });
const dashboardFacetSchema = object({ id: string, title: string, requestCount: integer });
const dashboardRowSchema = object({ id: string, title: string, service: usageService, sourceID: string, modelID: nullable(string), totals: totalsSchema, successRate: nullable(number) });
const dashboardSampleFields = { totals: totalsSchema, value: number, label: string, normalizedValue: number };
const dashboardSchema = object({ requestLogCount: nullable(integer), kpiDisplay: object({ cost: string, requests: string, tokens: string, cacheHitRate: string }), revision: string, resolvedRange: object({ from: isoDate, to: isoDate, timeZone: string, granularity: enumeration(["hour", "day", "month"] as const), asOf: isoDate }), coverage: dashboardCoverageSchema, totals: totalsSchema, facets: object({ services: array(dashboardFacetSchema), sources: array(object({ id: string, title: string, service: usageService, requestCount: integer, models: array(dashboardFacetSchema) })), models: array(dashboardFacetSchema) }), providerRows: array(dashboardRowSchema), modelRows: array(dashboardRowSchema), samples: array(object({ key: string, start: isoDate, ...dashboardSampleFields, segments: array(object({ service: usageService, totals: totalsSchema, value: number, label: string, share: number })) })), axisTicks: array(object({ position: number, label: string })), status: usageStatusSchema });
const dashboardRequestsSchema = object({ revision: string, resolvedRange: object({ from: isoDate, to: isoDate, timeZone: string, granularity: enumeration(["hour", "day", "month"] as const), asOf: isoDate }), totalCount: integer, page: integer, pageSize: integer, rows: array(object({ id: string, timestamp: isoDate, service: usageService, sourceID: string, modelID: string, totals: totalsSchema, status: literal("unknown"), conversationID: nullable(string) })), nextCursor: nullable(string), coverage: dashboardCoverageSchema, status: usageStatusSchema });
const dashboardHeatmapSchema = object({ fromDay: string, toDay: string, timeZone: string, cumulativeFromDay: nullable(localDate), days: array(object({ day: string, ...dashboardSampleFields, cumulativeTokens: nonNegativeInteger })), totals: totalsSchema, nextBeforeDay: nullable(string), coverage: dashboardCoverageSchema, status: usageStatusSchema });
const modelUsageSchema = object({ model: string, service: usageService, totals: totalsSchema, speed: speedSchema });
const usageServiceKeys = ["codex", "claude", "cursor", "pi", "opencode", "dsh", "antigravity", "kimi"] as const;
const serviceTotalsSchema = keyedDictionary(usageServiceKeys, totalsSchema);
const sampleSchema = object({ key: string, start: isoDate, totals: totalsSchema, byService: serviceTotalsSchema, highlighted: boolean });
const compositionRowSchema = object({ id: string, kind: enumeration(["item", "unattributed"] as const), title: string, subtitle: string, totals: totalsSchema, speed: nullable(speedSchema), share: number, color: object({ role: enumeration(["service", "rank", "rest", "unattributed"] as const), service: optional(usageService), rank: optional(integer) }), action: object({ type: enumeration(["none", "selectService", "expandProvider", "expandModel", "openProject", "openUnattributed"] as const), value: optional(string) }), models: array(modelUsageSchema), sources: array(modelUsageSchema), services: array(usageService), projectStatus: nullable(enumeration(["available", "unavailable", "unverified", "unassigned", "system"] as const)) });
const projectIdentitySchema = object({ key: string, name: string, path: string, status: enumeration(["available", "unavailable", "unverified", "unassigned", "system"] as const) });
const costsSchema = object({ input: decimal, output: decimal, cacheRead: decimal, cacheCreation: decimal, total: decimal, displayInput: string, displayOutput: string, displayCacheRead: string, displayCacheCreation: string, displayTotal: string, hasUnpricedUsage: boolean });
const conversationSummarySchema = object({ id: string, conversationID: string, service: usageService, title: nullable(string), project: projectIdentitySchema, gitBranch: nullable(string), firstAt: isoDate, lastAt: isoDate, rangeLastAt: isoDate, includesSubtasks: boolean, cacheCreationAvailable: boolean, totals: totalsSchema, costs: costsSchema, speed: speedSchema, models: array(string) });
const topConversationSchema = object({ summary: conversationSummarySchema, project: projectIdentitySchema, share: number });
const serviceKPISchema = object({ service: usageService, totals: totalsSchema, previousTotals: nullable(totalsSchema), comparison: comparisonSchema, speed: speedSchema, models: array(modelUsageSchema) });
const usageOverviewSchema = object({ revision: string, range: object({ from: isoDate, to: isoDate, previousFrom: nullable(isoDate), previousTo: nullable(isoDate), chartFrom: isoDate, chartTo: isoDate }), visibleServices: array(usageService), totals: totalsSchema, previousTotals: nullable(totalsSchema), comparison: comparisonSchema, speed: speedSchema, services: array(serviceKPISchema), samples: array(sampleSchema), barWidth: number, composition: object({ service: array(compositionRowSchema), provider: array(compositionRowSchema), model: array(compositionRowSchema), project: array(compositionRowSchema) }), unattributed: totalsSchema, topConversations: array(topConversationSchema), topConversationsShare: nullable(number), models: array(modelUsageSchema), status: usageStatusSchema });
const conversationListSchema = object({ rows: array(conversationSummarySchema), total: integer, offset: integer, limit: integer, projects: array(object({ key: string, name: string, path: string, status: enumeration(["available", "unavailable", "unverified", "unassigned", "system"] as const), conversationCount: integer, lastAt: isoDate, duplicateName: boolean })), status: usageStatusSchema });
const conversationDetailSchema = object({ summary: conversationSummarySchema, models: array(object({ model: string, service: usageService, totals: totalsSchema, speed: speedSchema, costs: costsSchema })) });
const projectUsageSchema = object({ identity: projectIdentitySchema, totals: totalsSchema, speed: speedSchema, totalsByService: serviceTotalsSchema, sharesByService: keyedDictionary(usageServiceKeys, number), conversationCount: integer, lastAt: isoDate, worktreeCount: integer });
const unattributedSchema = object({ total: totalsSchema, cursor: totalsSchema, local: totalsSchema, localServices: array(usageService), localFirstDay: nullable(isoDate), localLastDay: nullable(isoDate), dailyCursor: array(sampleSchema), dailyLocal: array(sampleSchema), overviewTotals: totalsSchema, overviewShare: nullable(number) });
const projectListSchema = object({ rows: array(projectUsageSchema), total: integer, offset: integer, limit: integer, unattributed: unattributedSchema, status: usageStatusSchema });
const projectDetailSchema = object({ project: projectIdentitySchema, totals: totalsSchema, previousTotals: nullable(totalsSchema), comparison: comparisonSchema, conversationCount: integer, activeDays: integer, rangeDayCount: integer, daily: array(sampleSchema), totalsByService: serviceTotalsSchema, sharesByService: keyedDictionary(usageServiceKeys, number), models: array(object({ model: string, services: array(usageService), totals: totalsSchema })), branches: array(object({ branch: nullable(string), conversationCount: integer, totals: totalsSchema })), topConversations: array(topConversationSchema), worktrees: array(object({ path: string, branch: nullable(string), main: boolean, totals: totalsSchema })), allTimeTotals: totalsSchema, firstUsedDay: nullable(isoDate), gitRepository: nullable(boolean) });
const cycleSchema = object({ id: string, service: usageService, limitID: string, kind: enumeration(["fiveHour", "weekly", "modelWeekly", "unknown"] as const), startAt: isoDate, endAt: isoDate, scheduledEndAt: isoDate, firstSampleAt: nullable(isoDate), lastSampleAt: nullable(isoDate), latestUsedPercent: number, reportedUsedPercent: number, boundaryQuality: enumeration(["observed", "inferred"] as const), current: boolean, extraResetCount: integer });
const cycleSummarySchema = object({ cycle: cycleSchema, totals: totalsSchema, currentAllowanceTotals: totalsSchema, quality: enumeration(["exact", "estimated", "incomplete"] as const), estimatedFullAllowanceTokens: nullable(integer), estimatedFullAllowanceCostUSD: nullable(decimal), estimatedFullAllowanceCostDisplay: nullable(string), forecastConfidence: nullable(enumeration(["early", "rough", "reference", "reliable"] as const)) });
const quotaAnalyticsSchema = object({ account: quotaAccountSchema, cycles: array(cycleSummarySchema), timeline: array(object({ id: string, kind: enumeration(["today", "currentCycle", "previousCycle"] as const), start: isoDate, end: isoDate, totalDelta: integer, entries: array(object({ id: string, source: enumeration(["change", "sample"] as const), sampledAt: isoDate, remainingPercent: integer, deltaPercent: nullable(integer), resetsAt: nullable(isoDate), windowIndex: integer })) })), window: nullable(object({ kind: enumeration(["fiveHour", "weekly", "modelWeekly", "unknown"] as const), remainingPercent: nullable(number), latestSampleAt: nullable(isoDate), resetsAt: nullable(isoDate) })), status: usageStatusSchema });
const currencyKeys = ["USD", "CNY", "JPY", "KRW", "HKD", "AUD", "SGD", "GBP"] as const;
const currencySchema = object({ selected: enumeration(currencyKeys), rates: keyedDictionary(currencyKeys, decimal), fetchedAt: nullable(isoDate), sourceUpdatedAt: nullable(isoDate), refreshing: boolean, lastRefreshFailedAt: nullable(isoDate) });
const notificationSchema = object({ authorization: enumeration(["notDetermined", "denied", "authorized", "provisional", "ephemeral", "unknown"] as const), canSubmit: boolean, alertsAllowed: nullable(boolean), soundAllowed: nullable(boolean), statusText: nullable(string), requesting: boolean, authorizationFailed: boolean, permissionReadFailed: boolean, storagePaused: boolean, rebuilding: boolean });
const updateStateSchema = object({ version: string, automaticChecks: boolean, canCheck: boolean, hasUpdate: boolean, isWorking: boolean, lastCheckedAt: nullable(isoDate) });
const settingsSchema = object({ appearance: object({ menuBarWindow: enumeration(["primary", "weekly", "both"] as const), useInstalledAppIcons: boolean, floatingEnabled: boolean, resetTimeDisplay: enumeration(["relative", "absolute"] as const), showServiceStatus: boolean, privacyMode: boolean, statsRankMetric: enumeration(["tokens", "cost"] as const), cycleIncludesOtherAgents: boolean, piEstimatedOutputSpeed: boolean, brandColors: array(object({ brand: serviceBrand, mode: enumeration(["brand", "custom"] as const), customHex: nullable(string), defaultLightHex: string, defaultDarkHex: string })), recentBrandColors: array(string) }), data: object({ quotaInterval: enumeration(["m1", "m2", "m3", "m5", "m10"] as const), usageInterval: enumeration(["m1", "m2", "m3", "m5", "m10"] as const), proxyMode: enumeration(["system", "manual"] as const), proxyType: enumeration(["http", "socks5"] as const), proxyHost: string, proxyPort: integer, currency: currencySchema, usage: usageStatusSchema, piTimingGuide: object({ title: string, instructions: string, copyText: string }) }), general: object({ language: enumeration(["system", "zh", "en"] as const), launchAtLogin: boolean, launchAtLoginRequiresApproval: boolean, quotaAlertsEnabled: boolean, quotaAlertThresholdPercent: integer, quotaAlertFiveHourEnabled: boolean, quotaAlertWeeklyEnabled: boolean, quotaAlertBillingCycleEnabled: boolean, quotaAlertSoundEnabled: boolean, notifications: notificationSchema, verboseLogging: boolean, updates: updateStateSchema }) });
const proxyTestSchema = object({ ok: boolean, message: string });
const priceSchema = object({ input: decimal, output: decimal, cacheRead: decimal, cacheCreation: decimal });
const pricingCatalogSchema = object({ providers: array(object({ id: string, name: string, models: array(object({ id: string, name: string, price: priceSchema, displayPrice: object({ input: string, output: string, cacheRead: string, cacheCreation: string }) })) })), fetchedAt: nullable(isoDate), refreshFailed: boolean, usage: usageStatusSchema });
const recalculateSchema = object({ started: boolean, ok: boolean, message: string, usage: usageStatusSchema });
const diagnosticsSchema = object({ path: string });

export const windowDTOValidators = {
  bootstrap: windowBootstrapSchema,
  applications: applicationsSchema,
  applicationDetail: applicationDetailSchema,
  providerCatalog: providerCatalogSchema,
  quotaAccounts: quotaAccountsSchema,
  usageDashboard: dashboardSchema,
  usageRequests: dashboardRequestsSchema,
  usageHeatmap: dashboardHeatmapSchema,
  usageOverview: usageOverviewSchema,
  conversations: conversationListSchema,
  conversationDetail: conversationDetailSchema,
  projects: projectListSchema,
  projectDetail: projectDetailSchema,
  quotaAnalytics: quotaAnalyticsSchema,
  settings: settingsSchema,
  pricingCatalog: pricingCatalogSchema,
} as const;
