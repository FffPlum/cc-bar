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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { EmptyState, KpiCard, Panel } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { SearchInput } from "@/components/search-input";
import { SelectField } from "@/components/select-field";
import { ChartLegend, StackedBarChart } from "@/components/stacked-bar-chart";
import { ServiceIcon } from "@/components/service-icon";
import { errorMessage, useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import {
  brandColor,
  delta,
  formatDate,
  formatInteger,
  formatPercent,
  formatTokens,
  serviceDisplayName,
} from "@/lib/display";
import { TopConversationRow } from "@/features/stats/overview-page";
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
    <div className="grid h-full min-h-0 grid-cols-[400px_minmax(480px,1fr)] max-[1100px]:grid-cols-[360px_minmax(480px,1fr)]">
      <section
        className="flex min-h-0 flex-col border-r"
        onKeyDown={keyboard}
        tabIndex={0}
        aria-label={t("Projects", "项目")}
      >
        <div className="flex items-center gap-1.5 px-2 pt-2.5">
          <SearchInput
            value={search}
            onChange={setSearch}
            privateValue={settings.appearance.privacyMode}
            placeholder={t("Search project name or path", "搜索项目名或路径")}
            className="flex-1"
          />
          <span className="cc-number whitespace-nowrap text-[11px] text-muted-foreground">
            {list.data?.total ?? 0} {t("projects", "个项目")}
          </span>
          <SelectField
            value={sort}
            options={[
              { value: "cost", label: t("Cost", "费用") },
              { value: "tokens", label: "Tokens" },
              { value: "recent", label: t("Recently active", "最近活跃") },
            ]}
            onChange={setSort}
            ariaLabel={t("Sort", "排序")}
          />
        </div>
        <div className="cc-scrollbar mt-2 flex-1 p-2">
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
      <section className="cc-scrollbar min-h-0">
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
  const [allModels, setAllModels] = useState(false);
  const [allBranches, setAllBranches] = useState(false);
  const { api, settings, bootstrap } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  const dark = bootstrap.appearance === "dark";
  const services = Object.keys(
    detail.totalsByService,
  ) as import("@ccbar/host-api/window").UsageService[];
  const series = services.map((service) => ({
    id: service,
    name: serviceDisplayName(service),
    color: brandColor(service, settings, dark),
  }));
  const columns = detail.daily.map((sample) => ({
    key: sample.key,
    label: sample.key.slice(5),
    total: sample.totals.totalTokens,
    totalLabel: formatTokens(sample.totals.totalTokens, language),
    highlighted: sample.highlighted,
    segments: services.flatMap((service) => {
      const totals = sample.byService[service];
      return totals
        ? [
            {
              seriesID: service,
              value: totals.totalTokens,
              label: totals.costDisplay,
            },
          ]
        : [];
    }),
  }));
  return (
    <div className="space-y-3.5 p-5">
      {revealError && (
        <p role="alert" className="text-xs text-red-600">
          {revealError}
        </p>
      )}
      <header>
        <div className="flex items-center gap-2">
          <h2 className="text-[18px] font-semibold">{detail.project.name}</h2>
          <Button
            variant="ghost"
            size="icon-sm"
            disabled={detail.project.status === "unavailable"}
            aria-label={t("Reveal project in Finder", "在 Finder 中显示项目")}
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
          {detail.worktrees.length > 0 && (
            <span className="rounded-full bg-secondary px-2 py-0.5 text-[10px] text-muted-foreground">
              Git · {detail.worktrees.length} worktree
            </span>
          )}
        </div>
        <p className="mt-1 truncate font-mono text-[11px] text-muted-foreground">
          {detail.project.path}
        </p>
      </header>
      <div className="flex gap-3">
        <KpiCard
          label="Tokens"
          value={formatTokens(detail.totals.totalTokens, language)}
          delta={delta(detail.comparison, "tokens")}
        />
        <KpiCard
          label={t("Cost", "费用")}
          value={detail.totals.costDisplay}
          delta={delta(detail.comparison, "costUSD")}
        />
        <KpiCard
          label={t("Conversations", "对话数")}
          value={formatInteger(detail.conversationCount, language)}
        />
        <KpiCard
          label={t("Active days", "活跃天数")}
          value={`${formatInteger(detail.activeDays, language)} / ${formatInteger(detail.rangeDayCount, language)}`}
        />
      </div>
      <p className="cc-number text-[11px] text-muted-foreground">
        {t("All time", "全部时间")}:{" "}
        {formatTokens(detail.allTimeTotals.totalTokens, language)} Tokens ·{" "}
        {detail.allTimeTotals.costDisplay} · {t("first used", "首次使用")}{" "}
        {formatDate(detail.firstUsedDay, language, bootstrap.timeZone)}
      </p>
      <div className="grid items-start gap-3 min-[760px]:grid-cols-[58fr_42fr]">
        <Panel
          title={
            query.granularity === "day"
              ? t("Daily usage", "每日用量")
              : query.granularity === "week"
                ? t("Weekly usage", "每周用量")
                : t("Monthly usage", "每月用量")
          }
          actions={<ChartLegend series={series} />}
        >
          <StackedBarChart columns={columns} series={series} height={170} />
        </Panel>
        <Panel title={t("Tools & models", "工具与模型")} contentClassName="p-3">
          <div className="mb-2 flex flex-wrap gap-2">
            {services.map((service) => (
              <span
                key={service}
                className="flex items-center gap-1 text-[10.5px] text-muted-foreground"
              >
                <ServiceIcon
                  name={serviceDisplayName(service)}
                  color={brandColor(service, settings, dark)}
                  size={12}
                />
                {serviceDisplayName(service)}{" "}
                {formatPercent(detail.sharesByService[service] ?? 0)}
              </span>
            ))}
          </div>
          {detail.models.slice(0, allModels ? undefined : 5).map((model) => (
            <div
              key={model.model}
              className="flex items-center gap-1.5 border-t py-2"
            >
              <span className="min-w-0 flex-1 truncate font-mono text-[11.5px]">
                {model.model}
              </span>
              <span className="cc-number text-[10.5px] text-muted-foreground">
                {formatTokens(model.totals.totalTokens, language)}
              </span>
              <span className="cc-number w-[76px] text-right font-semibold">
                {model.totals.costDisplay}
              </span>
            </div>
          ))}
          {detail.models.length > 5 && (
            <Button
              variant="link"
              size="sm"
              onClick={() => setAllModels(!allModels)}
            >
              {allModels
                ? t("Show less", "收起")
                : t(
                    `Show all ${detail.models.length} models`,
                    `显示全部 ${detail.models.length} 个模型`,
                  )}
            </Button>
          )}
        </Panel>
      </div>
      <div className="grid items-start gap-3 min-[760px]:grid-cols-2">
        <Panel title={t("Branches", "分支")} contentClassName="p-3">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("Branch", "分支")}</TableHead>
                <TableHead className="text-right">
                  {t("Chats", "对话数")}
                </TableHead>
                <TableHead className="text-right">Tokens</TableHead>
                <TableHead className="text-right">
                  {t("Cost", "费用")}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {detail.branches
                .slice(0, allBranches ? undefined : 5)
                .map((branch, index) => (
                  <TableRow key={branch.branch ?? index}>
                    <TableCell className="max-w-40 truncate font-mono">
                      {branch.branch ?? t("(no branch info)", "（无分支信息）")}
                    </TableCell>
                    <TableCell className="cc-number text-right">
                      {branch.conversationCount}
                    </TableCell>
                    <TableCell className="cc-number text-right">
                      {formatTokens(branch.totals.totalTokens, language)}
                    </TableCell>
                    <TableCell className="cc-number text-right">
                      {branch.totals.costDisplay}
                    </TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          {detail.branches.length > 5 && (
            <Button
              variant="link"
              size="sm"
              onClick={() => setAllBranches(!allBranches)}
            >
              {allBranches
                ? t("Show less", "收起")
                : t(
                    `Show all ${detail.branches.length} branches`,
                    `显示全部 ${detail.branches.length} 个分支`,
                  )}
            </Button>
          )}
        </Panel>
        <Panel
          title={t("Top conversations", "高消耗对话")}
          actions={
            <Button
              variant="link"
              size="sm"
              onClick={() =>
                navigate("conversations", { projectKey: detail.project.key })
              }
            >
              {t("View in Conversations ›", "在对话页查看 ›")}
            </Button>
          }
          contentClassName="p-0"
        >
          {detail.topConversations.slice(0, 3).map((row, index) => (
            <TopConversationRow
              key={row.summary.id}
              row={row}
              index={index}
              share={row.share}
              metric={settings.appearance.statsRankMetric}
              showProject={false}
              onClick={() =>
                navigate("conversations", { conversationID: row.summary.id })
              }
            />
          ))}
        </Panel>
      </div>
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
