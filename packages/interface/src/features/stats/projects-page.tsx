import { useEffect, useMemo, useRef, useState } from "react";
import { Folder, FolderOpen } from "lucide-react";
import type {
  ProjectDetail,
  ProjectDetailQuery,
  ProjectListResult,
  StatsQuery,
  UnattributedUsage,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { ProjectUsageShare } from "@/features/stats/project-usage-share";
import { EmptyState, KpiCard, Panel } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { SearchInput } from "@/components/search-input";
import { StatsSortMenu } from "@/features/stats/stats-sort-menu";
import { StackedBarChart } from "@/components/stacked-bar-chart";
import { DashboardChart } from "@/features/stats/dashboard-charts";
import { projectUsageChartData } from "@/features/stats/project-usage-chart";
import { ServiceIcon } from "@/components/service-icon";
import { errorMessage, useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import {
  brandColor,
  delta,
  formatDate,
  formatInteger,
  formatPercent,
  formatTokens,
  formatTokensCompact,
  serviceDisplayName,
} from "@/lib/display";
import { useListKeyboard } from "@/hooks/list-keyboard";
import type { StatsNavigation, StatsView } from "@/features/stats/stats-page";

const usageDomains = ["usage"] as const;
type Sort = "cost" | "tokens" | "recent";
const UNATTRIBUTED = "special:__unattributed__";

export function ProjectsPage({
  query,
  navigation,
  navigate,
  onNavigationConsumed,
}: {
  query: StatsQuery;
  navigation: StatsNavigation;
  navigate: (view: StatsView, request: StatsNavigation) => void;
  onNavigationConsumed: () => void;
}) {
  const { api, settings } = useHost();
  const t = useTranslation();
  const [search, setSearch] = useState("");
  const [sort, setSort] = useState<Sort>(settings.appearance.statsRankMetric);
  const [selection, setSelection] = useState<string | null>(null);
  const [limit, setLimit] = useState(200);
  const requested = useRef<string | null>(null);
  useEffect(() => {
    setLimit(200);
  }, [query, search, sort]);
  const listQuery = useMemo(
    () => ({ ...query, search, sort, offset: 0, limit }),
    [query, search, sort, limit],
  );
  const list = useHostResource<ProjectListResult>(
    () => api.projectsList(listQuery),
    usageDomains,
    [api, listQuery],
  );
  const detailQuery = useMemo<ProjectDetailQuery | null>(
    () =>
      selection && selection !== UNATTRIBUTED
        ? { ...query, projectKey: selection }
        : null,
    [selection, query],
  );
  const detail = useHostResource<ProjectDetail | null>(
    () =>
      detailQuery ? api.projectDetail(detailQuery) : Promise.resolve(null),
    usageDomains,
    [api, detailQuery],
  );
  const rows = useMemo(() => list.data?.rows ?? [], [list.data?.rows]);

  useEffect(() => {
    setSort(settings.appearance.statsRankMetric);
  }, [settings.appearance.statsRankMetric]);
  useEffect(() => {
    if (navigation.projectKey) {
      requested.current = navigation.projectKey;
      setSearch("");
      setSelection(navigation.projectKey);
    }
    if (navigation.unattributed) setSelection(UNATTRIBUTED);
    if (navigation.projectKey || navigation.unattributed)
      onNavigationConsumed();
  }, [navigation, onNavigationConsumed]);
  useEffect(() => {
    if (
      !list.data ||
      list.loading ||
      selection === UNATTRIBUTED ||
      (selection && selection === requested.current)
    )
      return;
    if (selection && rows.some((row) => row.identity.key === selection)) return;
    setSelection(rows[0]?.identity.key ?? null);
  }, [rows, selection, list.data, list.loading]);

  const keyboard = useListKeyboard(
    [...rows.map((row) => row.identity.key), UNATTRIBUTED],
    selection,
    setSelection,
  );
  return (
    <div className="grid h-full min-h-0 min-w-0 grid-cols-[440px_minmax(0,1fr)] max-[1100px]:grid-cols-[minmax(0,9fr)_minmax(0,11fr)]">
      <section
        className="flex min-h-0 min-w-0 flex-col gap-1 border-r"
        onKeyDown={keyboard}
        tabIndex={0}
        aria-label={t("Projects", "项目")}
      >
        <div
          className="flex flex-col gap-1.5 px-2 pt-2.5"
          onKeyDown={(event) => {
            if (event.key === "ArrowDown" || event.key === "ArrowUp")
              event.stopPropagation();
          }}
        >
          <div className="flex items-center gap-1.5">
            <SearchInput
              value={search}
              onChange={setSearch}
              privateValue={settings.appearance.privacyMode}
              placeholder={t("Search project name or path", "搜索项目名或路径")}
              className="flex-1"
            />
            <span className="cc-number shrink-0 whitespace-nowrap text-[11px] text-muted-foreground">
              {list.data?.total ?? 0} {t("projects", "个项目")}
            </span>
          </div>
          <div className="flex items-center justify-end">
            <StatsSortMenu
              value={sort}
              options={[
                { value: "cost", label: t("Cost", "费用") },
                { value: "tokens", label: "Tokens" },
                { value: "recent", label: t("Recently active", "最近活跃") },
              ]}
              onChange={setSort}
              ariaLabel={t("Sort projects", "项目排序")}
            />
          </div>
        </div>
        <div className="cc-scrollbar flex-1 px-2 pb-2">
          <ResourceFeedback {...list} onRetry={() => void list.reload()}>
            {(result) =>
              result.rows.length === 0 &&
              result.unattributed.total.totalTokens === 0 ? (
                <EmptyState
                  title={
                    search
                      ? t("No matching projects", "没有匹配的项目")
                      : query.range === "today"
                        ? t("No project usage today", "今天还没有项目用量")
                        : t(
                            "No project usage in this range",
                            "该范围内没有项目用量",
                          )
                  }
                  icon={<Folder className="size-7 text-muted-foreground" />}
                />
              ) : (
                <>
                  {result.rows.map((row) => (
                    <ProjectRow
                      key={row.identity.key}
                      row={row}
                      selected={selection === row.identity.key}
                      onSelect={() => {
                        requested.current = null;
                        setSelection(row.identity.key);
                      }}
                    />
                  ))}
                  {result.total > result.rows.length && (
                    <Button
                      variant="ghost"
                      className="w-full"
                      onClick={() => setLimit((value) => value + 200)}
                    >
                      {t("Show more", "显示更多")}
                    </Button>
                  )}
                  <UnattributedRow
                    totals={result.unattributed.total}
                    selected={selection === UNATTRIBUTED}
                    onClick={() => setSelection(UNATTRIBUTED)}
                  />
                </>
              )
            }
          </ResourceFeedback>
        </div>
      </section>
      <section className="cc-scrollbar min-h-0 min-w-0">
        {selection === UNATTRIBUTED && list.data ? (
          <UnattributedDetail
            value={list.data.unattributed}
            granularity={query.granularity}
            onShowCursor={() => navigate("overview", { service: "cursor" })}
          />
        ) : selection ? (
          <ResourceFeedback {...detail} onRetry={() => void detail.reload()}>
            {(value) =>
              value ? (
                <ProjectDetailView
                  detail={value}
                  query={query}
                  navigate={navigate}
                />
              ) : null
            }
          </ResourceFeedback>
        ) : (
          rows.length > 0 && (
            <EmptyState title={t("Select a project", "选择项目查看详情")} />
          )
        )}
      </section>
    </div>
  );
}

function ProjectRow({
  row,
  selected,
  onSelect,
}: {
  row: ProjectListResult["rows"][number];
  selected: boolean;
  onSelect: () => void;
}) {
  const { settings, bootstrap } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  return (
    <button
      id={`selectable-${row.identity.key}`}
      type="button"
      aria-selected={selected}
      onClick={onSelect}
      className="cc-list-row mb-0.5 flex w-full flex-col gap-1 px-2.5 py-2 text-left"
    >
      <span className="flex items-center gap-1.5">
        <span className="truncate text-[12.5px] font-semibold">
          {row.identity.name}
        </span>
        {row.worktreeCount > 0 && (
          <span className="rounded-full bg-secondary px-1.5 text-[9.5px] text-muted-foreground">
            {row.worktreeCount} worktree
          </span>
        )}
        {row.identity.status === "unavailable" && (
          <span className="rounded-full bg-secondary px-1.5 text-[9.5px] text-muted-foreground">
            {t("Unavailable", "已不存在")}
          </span>
        )}
        <span className="flex-1" />
        <span className="cc-number text-[12.5px] font-semibold">
          {formatTokens(row.totals.totalTokens, language)}
        </span>
      </span>
      <span className="flex items-center gap-1 text-[10.5px] text-muted-foreground">
        <span className="min-w-0 flex-1 truncate font-mono">
          {row.identity.path}
        </span>
        <span className="cc-number">
          {row.totals.costDisplay} ·{" "}
          {formatDate(row.lastAt, language, bootstrap.timeZone)}
        </span>
      </span>
      <span className="flex h-[3px] gap-0.5">
        {Object.keys(row.totalsByService).map((service) => (
          <span
            key={service}
            className="rounded-full"
            style={{
              width: `${(row.sharesByService[service as import("@ccbar/host-api/window").UsageService] ?? 0) * 100}%`,
              backgroundColor: brandColor(
                service as import("@ccbar/host-api/window").UsageService,
                settings,
                bootstrap.appearance === "dark",
              ),
            }}
          />
        ))}
      </span>
    </button>
  );
}

function UnattributedRow({
  totals,
  selected,
  onClick,
}: {
  totals: UnattributedUsage["total"];
  selected: boolean;
  onClick: () => void;
}) {
  const { bootstrap } = useHost();
  const t = useTranslation();
  return (
    <button
      id={`selectable-${UNATTRIBUTED}`}
      type="button"
      aria-selected={selected}
      onClick={onClick}
      className="cc-list-row mt-2 flex w-full items-center gap-2 border-t px-2.5 py-3 text-left"
    >
      <span className="size-2.5 rounded-sm bg-neutral-400" />
      <span className="min-w-0 flex-1">
        <span className="block text-[12px] font-semibold text-muted-foreground">
          {t("Unattributed", "未归属")}
        </span>
        <span className="block truncate text-[10px] text-muted-foreground">
          {t(
            "Cursor remote usage, backfilled and early history have no project",
            "Cursor 远端用量、补录和早期历史没有项目信息",
          )}
        </span>
      </span>
      <span className="cc-number text-[12px] font-semibold">
        {totals.costDisplay}
      </span>
      <span className="cc-number text-[10.5px] text-muted-foreground">
        {formatTokens(totals.totalTokens, bootstrap.resolvedLanguage)}
      </span>
    </button>
  );
}

function ProjectDetailView({
  detail,
  query,
  navigate,
}: {
  detail: ProjectDetail;
  query: StatsQuery;
  navigate: (view: StatsView, request: StatsNavigation) => void;
}) {
  const [revealError, setRevealError] = useState<string | null>(null);
  const { api, settings, bootstrap } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  const dark = bootstrap.appearance === "dark";
  const worktreeCount = detail.worktrees.filter(
    (worktree) => !worktree.main,
  ).length;
  const chartData = useMemo(
    () => projectUsageChartData(detail.daily, query.granularity, language),
    [detail.daily, query.granularity, language],
  );
  return (
    <div className="p-5">
      {revealError && (
        <p role="alert" className="pb-3 text-xs text-red-600">
          {revealError}
        </p>
      )}
      <div className="@container">
        <section className="flex flex-col gap-3 pb-3">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <h2 className="min-w-0 break-words text-[18px] font-semibold">
              {detail.project.name}
            </h2>
            {!settings.appearance.privacyMode &&
              (detail.project.status === "available" ||
                detail.project.status === "unverified") &&
              detail.project.path && (
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={t(
                    "Reveal project in Finder",
                    "在 Finder 中显示项目",
                  )}
                  onClick={() =>
                    void api
                      .projectsReveal(detail.project.key)
                      .then(() => setRevealError(null))
                      .catch((reason: unknown) =>
                        setRevealError(errorMessage(reason)),
                      )
                  }
                >
                  <FolderOpen />
                </Button>
              )}
            {detail.gitRepository === true && (
              <span className="rounded-full bg-secondary px-2 py-0.5 text-[10px] text-muted-foreground">
                Git
                {worktreeCount > 0 ? ` · ${worktreeCount} worktree` : ""}
              </span>
            )}
            {detail.project.status === "unavailable" && (
              <span className="rounded-full bg-secondary px-2 py-0.5 text-[10px] text-muted-foreground">
                {t("Unavailable", "已不存在")}
              </span>
            )}
          </div>
          <dl className="grid grid-cols-[max-content_minmax(0,1fr)] items-baseline gap-x-3 gap-y-1.5 text-[11px] text-muted-foreground">
            <dt>{t("Project directory", "项目目录")}</dt>
            <dd className="break-all font-mono">
              {settings.appearance.privacyMode
                ? t("Hidden", "已隐藏")
                : detail.project.path || "—"}
            </dd>
            <dt>{t("First used", "首次使用")}</dt>
            <dd className="cc-number">
              {formatDate(detail.firstUsedDay, language, bootstrap.timeZone)}
            </dd>
          </dl>
        </section>
        <section className="flex flex-col gap-3 border-y py-3">
          <h3 className="text-[13px] font-semibold">
            {t("Usage", "用量信息")}
          </h3>
          <dl className="grid grid-cols-2 @min-[640px]:grid-cols-4">
            <ProjectUsageValue
              label={t("Total tokens", "总 Token")}
              value={formatTokensCompact(detail.totals.totalTokens)}
              change={delta(detail.comparison, "tokens")}
              className="pr-3 pb-3 @min-[640px]:pb-0"
            />
            <ProjectUsageValue
              label={t("Estimated cost", "估算费用")}
              value={detail.totals.costDisplay}
              change={delta(detail.comparison, "costUSD")}
              className="border-l pb-3 pl-3 @min-[640px]:pr-3 @min-[640px]:pb-0"
            />
            <ProjectUsageValue
              label={t("Conversations", "对话数")}
              value={formatInteger(detail.conversationCount, language)}
              className="border-t pt-3 pr-3 @min-[640px]:border-t-0 @min-[640px]:border-l @min-[640px]:pt-0 @min-[640px]:pl-3"
            />
            <ProjectUsageValue
              label={t("Active days", "活跃天数")}
              value={`${formatInteger(detail.activeDays, language)} / ${formatInteger(detail.rangeDayCount, language)}`}
              className="border-t border-l pt-3 pl-3 @min-[640px]:border-t-0 @min-[640px]:pt-0"
            />
          </dl>
          <p className="cc-number text-[11px] text-muted-foreground">
            {t("All-time tokens", "累计 Token")}{" "}
            {formatTokensCompact(detail.allTimeTotals.totalTokens)}
            {" · "}
            {t("All-time cost", "累计费用")} {detail.allTimeTotals.costDisplay}
          </p>
        </section>
      </div>
      <div className="flex min-w-0 flex-col gap-4 pt-3">
        <section className="min-w-0">
          <DashboardChart
            data={chartData}
            title="Tokens"
            metric="tokens"
            className="p-0"
            headerTitle={
              query.granularity === "day"
                ? t("Daily usage", "每日用量")
                : query.granularity === "week"
                  ? t("Weekly usage", "每周用量")
                  : t("Monthly usage", "每月用量")
            }
          />
        </section>
        <ProjectUsageShare detail={detail} query={query} />
        <section className="flex min-w-0 flex-col gap-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="text-[13px] font-semibold">
              {t("Top conversations", "高消耗对话")}
            </h3>
            <Button
              variant="link"
              size="sm"
              className="h-auto p-0"
              onClick={() =>
                navigate("conversations", { projectKey: detail.project.key })
              }
            >
              {t("View in Conversations ›", "在对话页查看 ›")}
            </Button>
          </div>
          <ul className="flex min-w-0 flex-col gap-2">
            {detail.topConversations.slice(0, 3).map(({ summary }) => (
              <li key={summary.id}>
                <Card className="gap-0 rounded-lg py-0">
                  <button
                    type="button"
                    className="grid w-full grid-cols-[minmax(0,1fr)_max-content] items-center gap-3 rounded-lg p-2 text-left transition-colors hover:bg-muted/50 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring"
                    onClick={() =>
                      navigate("conversations", { conversationID: summary.id })
                    }
                  >
                    <span className="flex min-w-0 flex-col gap-0.5">
                      <span className="flex min-w-0 items-center gap-1.5">
                        <ServiceIcon
                          name={serviceDisplayName(summary.service)}
                          color={brandColor(summary.service, settings, dark)}
                          size={14}
                        />
                        <span
                          className="truncate text-[12.5px] font-medium"
                          title={summary.title ?? undefined}
                        >
                          {summary.title ?? t("Untitled", "未命名")}
                        </span>
                      </span>
                      <span className="flex min-w-0 items-center gap-1.5 text-[10.5px] text-muted-foreground">
                        <span
                          className="min-w-0 truncate font-mono"
                          title={summary.gitBranch ?? undefined}
                        >
                          {summary.gitBranch ??
                            t("(no branch info)", "（无分支信息）")}
                        </span>
                        <span aria-hidden="true" className="shrink-0">
                          ·
                        </span>
                        <span className="cc-number shrink-0 whitespace-nowrap">
                          {formatDate(
                            summary.rangeLastAt,
                            language,
                            bootstrap.timeZone,
                          )}
                        </span>
                      </span>
                    </span>
                    <span className="cc-number flex flex-col gap-0.5 text-right">
                      <span className="whitespace-nowrap text-[12.5px] font-semibold">
                        {formatTokensCompact(summary.totals.totalTokens)} Tokens
                      </span>
                      <span className="whitespace-nowrap text-[11.5px] text-muted-foreground">
                        {summary.costs.displayTotal}
                      </span>
                    </span>
                  </button>
                </Card>
              </li>
            ))}
          </ul>
        </section>
        {detail.worktrees.length > 0 && (
          <Panel
            title={t("Repository & worktrees", "仓库与 worktree")}
            contentClassName="p-3"
          >
            {detail.worktrees.map((item) => (
              <div
                key={item.path}
                className="flex items-center gap-2 border-b py-2 last:border-0"
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate font-mono text-[11px]">
                    {item.path}
                    {item.main ? ` · ${t("Main repository", "主仓库")}` : ""}
                  </p>
                  <p className="font-mono text-[10.5px] text-muted-foreground">
                    {item.branch ?? t("(branch unknown)", "（分支未知）")}
                  </p>
                </div>
                <span className="cc-number">
                  {formatTokens(item.totals.totalTokens, language)}
                </span>
                <span className="cc-number w-20 text-right">
                  {item.totals.costDisplay}
                </span>
              </div>
            ))}
          </Panel>
        )}
      </div>
    </div>
  );
}

function UnattributedDetail({
  value,
  granularity,
  onShowCursor,
}: {
  value: UnattributedUsage;
  granularity: StatsQuery["granularity"];
  onShowCursor: () => void;
}) {
  const { bootstrap } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  const days = [
    ...new Set([
      ...value.dailyCursor.map((sample) => sample.key),
      ...value.dailyLocal.map((sample) => sample.key),
    ]),
  ].sort();
  const columns = days.map((key) => {
    const cursor = value.dailyCursor.find((sample) => sample.key === key);
    const local = value.dailyLocal.find((sample) => sample.key === key);
    const total =
      (cursor?.totals.totalTokens ?? 0) + (local?.totals.totalTokens ?? 0);
    return {
      key,
      label: key.slice(5),
      total,
      totalLabel: `${formatTokens(total, language)} Tokens`,
      segments: [
        {
          seriesID: "cursor",
          value: cursor?.totals.totalTokens ?? 0,
          label: cursor?.totals.costDisplay ?? "—",
        },
        {
          seriesID: "local",
          value: local?.totals.totalTokens ?? 0,
          label: local?.totals.costDisplay ?? "—",
        },
      ],
    };
  });
  return (
    <div className="space-y-3.5 p-5">
      <header>
        <h2 className="text-[18px] font-semibold">
          {t("Unattributed", "未归属")}
        </h2>
        <p className="mt-1 text-[11.5px] text-muted-foreground">
          {t(
            "This usage counts toward the Overview total but does not appear in any project.",
            "这些用量计入概览总量，但不出现在任何项目里。",
          )}
        </p>
      </header>
      <div className="flex gap-3">
        <KpiCard
          label="Tokens"
          value={formatTokens(value.total.totalTokens, language)}
        />
        <KpiCard label={t("Cost", "费用")} value={value.total.costDisplay} />
        <KpiCard
          label={t("Share of Overview", "占概览总额")}
          value={
            value.overviewShare === null
              ? "—"
              : formatPercent(value.overviewShare)
          }
        />
      </div>
      <Panel title={t("Sources", "来源")} contentClassName="p-3">
        <SourceRow
          title={t("Cursor remote usage", "Cursor 远端用量")}
          description={t(
            "Cursor only reports account-level metering.",
            "Cursor 只提供账号级计量。",
          )}
          totals={value.cursor}
          action={
            <Button variant="link" size="sm" onClick={onShowCursor}>
              {t("Filter Cursor in Overview ›", "在概览中筛选 Cursor ›")}
            </Button>
          }
        />
        <SourceRow
          title={t("Backfilled and early history", "补录与早期历史")}
          description={`${t("Only daily totals are available.", "只有按天汇总的数据。")} ${formatDate(value.localFirstDay, language, bootstrap.timeZone)} – ${formatDate(value.localLastDay, language, bootstrap.timeZone)} · ${value.localServices.map(serviceDisplayName).join(" · ")}`}
          totals={value.local}
        />
      </Panel>
      <Panel
        title={
          granularity === "day"
            ? t("Daily usage", "每日用量")
            : granularity === "week"
              ? t("Weekly usage", "每周用量")
              : t("Monthly usage", "每月用量")
        }
      >
        <StackedBarChart
          columns={columns}
          series={[
            { id: "cursor", name: "Cursor", color: "#6c6c70" },
            {
              id: "local",
              name: t("Backfilled and early history", "补录与早期历史"),
              color: "#9a94d6",
            },
          ]}
          height={180}
        />
      </Panel>
    </div>
  );
}

function SourceRow({
  title,
  description,
  totals,
  action,
}: {
  title: string;
  description: string;
  totals: UnattributedUsage["total"];
  action?: React.ReactNode;
}) {
  const { bootstrap } = useHost();
  return (
    <div className="flex items-start gap-2 border-b py-2 last:border-0">
      <div className="min-w-0 flex-1">
        <h3 className="text-[12.5px] font-semibold">{title}</h3>
        <p className="mt-1 text-[11px] text-muted-foreground">{description}</p>
        {action}
      </div>
      <span className="cc-number font-semibold">{totals.costDisplay}</span>
      <span className="cc-number text-muted-foreground">
        {formatTokens(totals.totalTokens, bootstrap.resolvedLanguage)} Tokens
      </span>
    </div>
  );
}

function ProjectUsageValue({
  label,
  value,
  change,
  className,
}: {
  label: string;
  value: string;
  change?: ReturnType<typeof delta>;
  className?: string;
}) {
  return (
    <div className={cn("min-w-0", className)}>
      <dt className="flex flex-wrap items-baseline justify-between gap-x-2 gap-y-0.5 text-[11px] text-muted-foreground">
        <span>{label}</span>
        {change && (
          <span
            className={cn(
              "cc-number font-semibold",
              change.direction === "up"
                ? "text-red-600 dark:text-red-400"
                : "text-green-700 dark:text-green-400",
            )}
          >
            {change.text}
          </span>
        )}
      </dt>
      <dd className="cc-number mt-1 break-all text-[22px] leading-tight font-semibold">
        {value}
      </dd>
    </div>
  );
}
