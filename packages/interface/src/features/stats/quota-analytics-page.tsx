import { useMemo, useState } from "react";
import { ChevronDown, ChevronRight, Clock } from "lucide-react";
import type { CycleSummary, QuotaAccount, QuotaAnalytics, QuotaAccountsResult, QuotaTimelinePeriod, UsageService } from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState, Panel } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { Segmented } from "@/components/segmented";
import { ServiceIcon } from "@/components/service-icon";
import { quotaStatusClass } from "@/components/quota-progress";
import { useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { brandColor, formatDate, formatTime, formatTokens, serviceDisplayName } from "@/lib/display";
import { cn } from "@/lib/utils";

const domains = ["usage", "quota", "settings"] as const;
const kinds = ["fiveHour", "weekly"] as const;
type StandardKind = typeof kinds[number];
interface AccountAnalytics { account: QuotaAccount; fiveHour: QuotaAnalytics; weekly: QuotaAnalytics }

/** Statistics visibility is independent of menu bar visibility. Mirror accounts
 * share the primary history and are omitted while that primary account exists. */
export function analyticsAccounts(accounts: QuotaAccount[], visibleServices: UsageService[], service?: UsageService): QuotaAccount[] {
  return accounts.filter((account) => {
    if (!["codex", "claude", "kimi"].includes(account.service) || !visibleServices.includes(account.service as UsageService)) return false;
    if (service && account.service !== service) return false;
    if (account.kind === "managedKimi" && !account.enabled) return false;
    return account.kind === "primary" || !account.current || !accounts.some((primary) => primary.kind === "primary" && primary.service === account.service && primary.detected);
  });
}

export function QuotaAnalyticsPage({ service, visibleServices }: { service?: UsageService; visibleServices: UsageService[] }) {
  const { api } = useHost();
  const t = useTranslation();
  const accounts = useHostResource<QuotaAccountsResult>(() => api.quotaAccounts(), domains, [api]);
  return <ResourceFeedback {...accounts} onRetry={() => void accounts.reload()}>{(result) => {
    const eligible = analyticsAccounts(result.accounts, visibleServices, service);
    if (service && !["codex", "claude", "kimi"].includes(service)) return <EmptyState title={t("No quota data", "暂无额度数据")} description={t("Only Codex, Claude Code and Kimi Code report standard quota cycles.", "只有 Codex、Claude Code 与 Kimi Code 提供标准额度周期。")} />;
    if (!eligible.length) return <EmptyState title={t("No accounts", "暂无账号")} />;
    return <AnalyticsCollection accounts={eligible} />;
  }}</ResourceFeedback>;
}

function AnalyticsCollection({ accounts }: { accounts: QuotaAccount[] }) {
  const { api, bootstrap } = useHost();
  const t = useTranslation();
  const [kind, setKind] = useState<StandardKind>("fiveHour");
  const ids = useMemo(() => accounts.map((account) => account.id).join("|"), [accounts]);
  // Both current-cycle cards remain visible when the timeline selector changes.
  const resource = useHostResource<AccountAnalytics[]>(() => Promise.all(accounts.map(async (account) => {
    const [fiveHour, weekly] = await Promise.all(kinds.map((kind) => api.quotaAnalytics({ accountID: account.id, kind })));
    return { account, fiveHour: fiveHour!, weekly: weekly! };
  })), domains, [api, ids]);
  return <ResourceFeedback {...resource} onRetry={() => void resource.reload()}>{(analytics) => {
    const timelines = analytics.map((item) => item[kind]).filter((item) => item.window !== null);
    return <div className="cc-scrollbar h-full"><div className="space-y-4">
      <CycleCards analytics={analytics} />
      <section><div className="mb-3 flex items-center"><h2 className="text-[13px] font-semibold">{kind === "fiveHour" ? t("Quota changes today", "今日额度变化") : t("Weekly quota changes", "每周额度变化")}</h2><span className="flex-1" /><Segmented value={kind} options={[{ value: "fiveHour", label: "5H" }, { value: "weekly", label: "WK" }]} onChange={setKind} ariaLabel={t("Quota window", "额度窗口")} /><span className="cc-number ml-3 text-[11px] text-muted-foreground">{formatDate(new Date().toISOString(), bootstrap.resolvedLanguage, bootstrap.timeZone)}</span></div>
        {timelines.length ? <div className="grid items-start gap-3 min-[880px]:grid-cols-2">{timelines.map((item) => <TimelineAccount key={item.account.id + ":" + kind} value={item} kind={kind} />)}</div> : <EmptyState title={t("No data for this window", "该窗口暂无数据")} />}
      </section>
    </div></div>;
  }}</ResourceFeedback>;
}

/** Host order resolves overlapping current records by sample time and boundary quality. */
export function currentCycle(value: QuotaAnalytics): CycleSummary | undefined {
  return value.cycles.find((item) => item.cycle.current);
}

function CycleCards({ analytics }: { analytics: AccountAnalytics[] }) {
  const { settings } = useHost();
  const t = useTranslation();
  const primary = analytics.filter((item) => item.account.kind === "primary");
  const includeOthers = settings.appearance.cycleIncludesOtherAgents && primary.some((item) => item.account.service === "codex");
  const rebuilding = analytics.some((item) => item.fiveHour.status.rebuildingCycles);
  return <section><div className="mb-3 flex items-center gap-2"><h2 className="text-[13px] font-semibold">{t("Full-quota estimate", "额度用满预估")}</h2><p className="truncate text-[11px] text-muted-foreground">{includeOthers ? t("Estimated from local usage, including Codex subscriptions in Pi, OpenCode and DSH, and official usage. For reference only.", "按本机用量（含 Pi、OpenCode、DSH 中的 Codex 订阅用量）和官方已用比例估算，仅供参考。") : t("Estimated from local usage and the official used percentage. For reference only.", "按本机用量和官方已用比例估算，仅供参考。")}</p>{rebuilding && <span role="status" className="text-[11px] text-muted-foreground">{t("Rebuilding current cycle data…", "正在补算当前周期数据…")}</span>}</div><div className="grid gap-3 min-[880px]:grid-cols-4 min-[520px]:grid-cols-2">
    {primary.flatMap((item) => kinds.map((kind) => <CycleCard key={item.account.id + ":" + kind} account={item.account} kind={kind} summary={currentCycle(item[kind])} />))}
  </div></section>;
}

function CycleCard({ summary, account, kind }: { summary?: CycleSummary; account: QuotaAccount; kind: StandardKind }) {
  const { settings, bootstrap } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  const service = account.service as UsageService;
  const used = Math.max(0, Math.min(100, summary?.cycle.latestUsedPercent ?? 0));
  const confidence = summary?.forecastConfidence === "early" ? t("Early estimate", "早期估算") : summary?.forecastConfidence === "rough" ? t("Rough estimate", "粗略估算") : summary?.forecastConfidence === "reference" ? t("Reference", "参考") : summary?.forecastConfidence === "reliable" ? t("More reliable", "较可靠") : null;
  const reset = summary ? resetLabel(summary.cycle.endAt, settings.appearance.resetTimeDisplay, bootstrap.timeZone, language) : null;
  return <article className="cc-panel flex h-[132px] flex-col p-3.5"><div className="flex items-center gap-1"><ServiceIcon name={serviceDisplayName(service)} color={brandColor(service, settings, bootstrap.appearance === "dark")} size={12} /><span className="truncate text-[11px] text-muted-foreground">{serviceDisplayName(service)} · {kind === "fiveHour" ? t("5-hour", "5 小时") : t("Weekly", "周")}</span><span className="flex-1" /><span className="cc-number text-[11px] text-muted-foreground">{reset}</span></div>
    {summary ? <><div className="mt-2"><div className="cc-number truncate text-[22px] font-semibold tracking-[-0.5px]">{summary.estimatedFullAllowanceTokens === null ? "—" : formatTokens(summary.estimatedFullAllowanceTokens, language)} · {summary.estimatedFullAllowanceCostDisplay ?? "—"}</div><p className="cc-tertiary text-[10.5px]">{t("Full-use estimate", "用满预估")}{confidence ? " · " + confidence : ""}</p></div><div className="flex-1" /><div className="h-1.5 overflow-hidden rounded-full bg-secondary" role="progressbar" aria-label={t("Quota used", "已用额度")} aria-valuemin={0} aria-valuemax={100} aria-valuenow={used}><div className={cn("h-full rounded-full bg-current", quotaStatusClass(100 - used))} style={{ width: used + "%" }} /></div><div className="mt-2 flex items-center text-[11px]"><span className="cc-number text-muted-foreground">{t("Used", "已用")} {formatTokens(summary.currentAllowanceTotals.totalTokens, language)} · {summary.currentAllowanceTotals.costDisplay}</span><span className="flex-1" /><span className={cn("cc-number font-semibold", quotaStatusClass(100 - used))}>{used.toFixed(0)}%</span></div></> : <div className="flex flex-1 items-center justify-center gap-1 text-[12px] text-muted-foreground"><Clock className="size-3" />{account.detected ? t("Waiting for the current cycle", "等待当前周期") : t("Not signed in", "未登录")}</div>}
  </article>;
}

function resetLabel(value: string, mode: "relative" | "absolute", timeZone: string, language: "zh" | "en"): string {
  if (mode === "absolute") return formatDate(value, language, timeZone) + " " + formatTime(value, timeZone);
  const minutes = Math.max(0, Math.ceil((Date.parse(value) - Date.now()) / 60_000));
  if (!minutes) return language === "zh" ? "即将重置" : "Resets soon";
  const hours = Math.floor(minutes / 60), days = Math.floor(hours / 24);
  const duration = days ? days + "d " + hours % 24 + "h" : hours ? hours + "h " + minutes % 60 + "m" : minutes + "m";
  return language === "zh" ? duration + " 后重置" : "in " + duration;
}

export function timelineEntries(periods: QuotaTimelinePeriod[]) {
  return periods.flatMap((period) => period.entries).sort((left, right) => Date.parse(left.sampledAt) - Date.parse(right.sampledAt));
}

function TimelineAccount({ value, kind }: { value: QuotaAnalytics; kind: StandardKind }) {
  const { settings, bootstrap } = useHost();
  const t = useTranslation();
  const [expanded, setExpanded] = useState(false);
  const entries = timelineEntries(value.timeline);
  const delta = value.timeline[0]?.totalDelta ?? 0;
  const stamp = (date: string | null) => date ? (kind === "weekly" || formatDate(date, "en", bootstrap.timeZone) !== formatDate(new Date().toISOString(), "en", bootstrap.timeZone) ? formatDate(date, bootstrap.resolvedLanguage, bootstrap.timeZone) + " " : "") + formatTime(date, bootstrap.timeZone) : "—";
  return <Panel title={<span className="flex items-center gap-2"><ServiceIcon name={value.account.name} color={brandColor(value.account.service as UsageService, settings, bootstrap.appearance === "dark")} size={14} />{value.account.name}<span className="text-[9px] text-muted-foreground">{kind === "fiveHour" ? "5H" : "WK"}</span></span>} actions={<div className="flex gap-4 text-[11px]"><Metric label={t("Remaining", "剩余")} value={value.window?.remainingPercent == null ? "—" : value.window.remainingPercent + "%"} /><Metric label={kind === "fiveHour" ? t("Today", "今天") : t("Current cycle", "当前周期")} value={(delta > 0 ? "+" : "") + delta + "%"} /><Metric label={t("Updated", "更新")} value={stamp(value.window?.latestSampleAt ?? null)} /></div>}>
    <div className="mb-2 space-y-1">{value.timeline.map((period) => <div key={period.id} className="flex items-baseline gap-2 text-[10px] text-muted-foreground"><span className="font-semibold">{period.kind === "today" ? t("Today", "今天") : period.kind === "currentCycle" ? t("Current cycle", "当前周期") : t("Previous cycle", "上一周期")}</span><span className="cc-number">{stamp(period.start)} → {stamp(period.end)}</span><span className="cc-number ml-auto">{period.totalDelta > 0 ? "+" : ""}{period.totalDelta}%</span></div>)}</div>
    <TimelineChart value={value} kind={kind} color={brandColor(value.account.service as UsageService, settings, bootstrap.appearance === "dark")} />
    {entries.length > 0 && <Button variant="ghost" size="sm" className="mt-2 px-0" onClick={() => setExpanded(!expanded)} aria-expanded={expanded}>{expanded ? <ChevronDown /> : <ChevronRight />}{t("Changes", "变动明细")} · {entries.filter((entry) => entry.source === "change").length}</Button>}
    {expanded && <div className="cc-scrollbar max-h-60"><Table><TableHeader><TableRow><TableHead>{t("Time", "时间")}</TableHead><TableHead className="text-right">{t("Change", "变动值")}</TableHead><TableHead className="text-right">{t("After", "变动后剩余")}</TableHead><TableHead className="text-right">{t("Reset", "重置时间")}</TableHead></TableRow></TableHeader><TableBody>{[...entries].reverse().map((entry) => <TableRow key={entry.id}><TableCell className="cc-number">{stamp(entry.sampledAt)}</TableCell><TableCell className={cn("cc-number text-right", entry.deltaPercent === null ? "text-muted-foreground" : entry.deltaPercent < 0 ? "text-red-600" : "text-green-700")}>{entry.deltaPercent === null ? "—" : (entry.deltaPercent > 0 ? "+" : "") + entry.deltaPercent + "%"}</TableCell><TableCell className={cn("cc-number text-right", quotaStatusClass(entry.remainingPercent))}>{entry.remainingPercent}%</TableCell><TableCell className="cc-number text-right">{stamp(entry.resetsAt)}</TableCell></TableRow>)}</TableBody></Table></div>}
  </Panel>;
}

function Metric({ label, value }: { label: string; value: string }) {
  return <span className="text-right"><span className="block text-muted-foreground">{label}</span><span className="cc-number font-semibold">{value}</span></span>;
}

function TimelineChart({ value, kind, color }: { value: QuotaAnalytics; kind: StandardKind; color: string }) {
  const t = useTranslation();
  const { bootstrap } = useHost();
  const periods = value.timeline;
  const entries = timelineEntries(periods);
  if (!entries.length) return <div className="flex h-[200px] items-center justify-center text-[12px] text-muted-foreground">{value.account.refresh.inFlight ? t("Loading…", "正在读取…") : t("No data for this window", "该窗口暂无数据")}</div>;
  const start = Math.min(...periods.map((period) => Date.parse(period.start)));
  const end = Math.max(...periods.map((period) => Date.parse(period.end)));
  const span = Math.max(1, end - start);
  const x = (timestamp: number) => 36 + (timestamp - start) / span * 564;
  const y = (remaining: number) => 180 - Math.max(0, Math.min(100, remaining)) / 100 * 160;
  const groups = new Map<string, typeof entries>();
  for (const period of periods) for (const entry of period.entries) {
    const key = period.id + ":" + entry.windowIndex;
    const group = groups.get(key) ?? [];
    group.push(entry); groups.set(key, group);
  }
  let reset = kind === "weekly" ? periods.find((period) => period.kind === "currentCycle")?.start : undefined;
  if (kind === "fiveHour") {
    const next = value.window?.resetsAt ?? [...entries].reverse().find((entry) => entry.resetsAt !== null)?.resetsAt;
    if (next) {
      let boundary = Date.parse(next);
      if (boundary > Date.now()) boundary -= Math.ceil((boundary - Date.now()) / (5 * 3_600_000)) * 5 * 3_600_000;
      if (boundary >= start && boundary < end) reset = new Date(boundary).toISOString();
    }
  }
  const dateLabel = (timestamp: number) => (kind === "weekly" ? formatDate(new Date(timestamp).toISOString(), bootstrap.resolvedLanguage, bootstrap.timeZone) + " " : "") + formatTime(new Date(timestamp).toISOString(), bootstrap.timeZone);
  return <svg viewBox="0 0 620 215" className="h-[200px] w-full" role="img" aria-label={t("Quota remaining over time", "剩余额度随时间变化")}>
    {[0, 20, 50, 80, 100].map((percent) => <g key={percent}><line x1="36" x2="600" y1={y(percent)} y2={y(percent)} stroke="currentColor" opacity="0.12" /><text x="30" y={y(percent) + 3} textAnchor="end" fontSize="9" fill="currentColor" opacity="0.55">{percent}</text></g>)}
    {reset && <g><line x1={x(Date.parse(reset))} x2={x(Date.parse(reset))} y1="12" y2="180" stroke="currentColor" strokeDasharray="4 3" opacity="0.4" /><text x={x(Date.parse(reset))} y="9" textAnchor="middle" fontSize="9" fill="currentColor">{t("Window reset", "窗口重置")}</text></g>}
    {[...groups.values()].map((group, index) => <polyline key={index} fill="none" stroke={color} strokeWidth="2" points={group.map((entry) => x(Date.parse(entry.sampledAt)) + "," + y(entry.remainingPercent)).join(" ")} />)}
    {entries.map((entry) => <circle key={entry.id} cx={x(Date.parse(entry.sampledAt))} cy={y(entry.remainingPercent)} r="3" fill={color}><title>{dateLabel(Date.parse(entry.sampledAt)) + " · " + entry.remainingPercent + "%" + (entry.deltaPercent === null ? "" : " · " + entry.deltaPercent + "%")}</title></circle>)}
    {[0, 0.25, 0.5, 0.75, 1].map((position) => <text key={position} x={x(start + span * position)} y="200" textAnchor={position === 0 ? "start" : position === 1 ? "end" : "middle"} fontSize="9" fill="currentColor" opacity="0.55">{dateLabel(start + span * position)}</text>)}
  </svg>;
}
