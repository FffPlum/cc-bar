import { useEffect, useMemo, useRef, useState } from "react";
import { ChevronDown, Copy, Folder } from "lucide-react";
import type {
  ConversationDetail,
  ConversationListResult,
  ProjectOption,
  StatsQuery,
  UsageService,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
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
import { ServiceIcon } from "@/components/service-icon";
import { errorMessage, useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import {
  brandColor,
  formatDate,
  formatInteger,
  formatPercent,
  formatTime,
  formatTokens,
  serviceDisplayName,
} from "@/lib/display";
import { SpeedBadge } from "@/features/stats/overview-page";
import { useListKeyboard } from "@/hooks/list-keyboard";
import type { StatsNavigation } from "@/features/stats/stats-page";
import { cn } from "@/lib/utils";

const usageDomains = ["usage"] as const;

type Sort = "recent" | "tokens" | "cost";

export function ConversationsPage({
  query,
  navigation,
  onNavigationConsumed,
}: {
  query: StatsQuery;
  services: UsageService[];
  navigation: StatsNavigation;
  onNavigationConsumed: () => void;
}) {
  const { api, settings } = useHost();
  const t = useTranslation();
  const [search, setSearch] = useState("");
  const [sort, setSort] = useState<Sort>("recent");
  const [projectKey, setProjectKey] = useState<string | undefined>();
  const [selection, setSelection] = useState<string | null>(null);
  const [limit, setLimit] = useState(200);
  const requested = useRef<string | null>(null);
  const listQuery = useMemo(
    () => ({ ...query, search, sort, projectKey, offset: 0, limit }),
    [query, search, sort, projectKey, limit],
  );
  const list = useHostResource<ConversationListResult>(
    () => api.conversationsList(listQuery),
    usageDomains,
    [api, listQuery],
  );
  const detail = useHostResource<ConversationDetail | null>(
    () =>
      selection
        ? api.conversationDetail(selection, settings.appearance.statsRankMetric)
        : Promise.resolve(null),
    usageDomains,
    [api, selection, settings.appearance.statsRankMetric],
  );
  const rows = useMemo(() => list.data?.rows ?? [], [list.data?.rows]);

  useEffect(() => {
    if (navigation.conversationID) {
      requested.current = navigation.conversationID;
      setSearch("");
      setProjectKey(undefined);
      setSelection(navigation.conversationID);
    }
    if (navigation.conversationsByRank) {
      setSearch("");
      setProjectKey(undefined);
      setSort(settings.appearance.statsRankMetric);
    }
    if (navigation.projectKey) {
      setSearch("");
      setProjectKey(navigation.projectKey);
    }
    if (
      navigation.conversationID ||
      navigation.conversationsByRank ||
      navigation.projectKey
    )
      onNavigationConsumed();
  }, [navigation, onNavigationConsumed, settings.appearance.statsRankMetric]);
  useEffect(() => {
    setLimit(200);
  }, [query, search, sort, projectKey]);
  useEffect(() => {
    if (
      !list.data ||
      list.loading ||
      (selection && requested.current === selection)
    )
      return;
    if (selection && rows.some((row) => row.id === selection)) return;
    setSelection(rows[0]?.id ?? null);
  }, [rows, selection, list.data, list.loading]);

  const keyboard = useListKeyboard(
    rows.map((row) => row.id),
    selection,
    setSelection,
  );
  const privacy = settings.appearance.privacyMode;
  return (
    <div className="grid h-full min-h-0 min-w-0 grid-cols-[400px_minmax(480px,1fr)] max-[1100px]:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
      <section
        className="flex min-h-0 min-w-0 flex-col border-r"
        onKeyDown={keyboard}
        tabIndex={0}
        aria-label={t("Conversations", "对话")}
      >
        <div className="flex items-center gap-1.5 px-2 pt-2.5">
          <SearchInput
            value={search}
            onChange={setSearch}
            privateValue={privacy}
            placeholder={t("Search title or project", "搜索标题或项目")}
            className="flex-1"
          />
          <ProjectFilter
            projects={list.data?.projects ?? []}
            value={projectKey}
            onChange={setProjectKey}
          />
          <SelectField
            value={sort}
            options={[
              { value: "recent", label: t("Recent", "最近") },
              { value: "tokens", label: "Tokens" },
              { value: "cost", label: t("Cost", "费用") },
            ]}
            onChange={setSort}
            ariaLabel={t("Sort", "排序")}
          />
        </div>
        <div className="cc-scrollbar mt-2 flex-1 p-2">
          <ResourceFeedback
            {...list}
            onRetry={() => void list.reload()}
            empty={
              <EmptyState
                title={t("No conversations in this range", "该范围内没有对话")}
              />
            }
          >
            {(result) =>
              result.rows.length === 0 ? (
                <EmptyState
                  title={
                    search
                      ? t("No matching conversations", "没有匹配的对话")
                      : query.range === "today"
                        ? t("No conversations today", "今天还没有对话")
                        : t(
                            "No conversations in this range",
                            "该范围内没有对话",
                          )
                  }
                  description={t(
                    "Conversations come from local application logs.",
                    "对话来自本机应用日志。",
                  )}
                />
              ) : (
                <>
                  {result.rows.map((row) => (
                    <ConversationRow
                      key={row.id}
                      row={row}
                      selected={selection === row.id}
                      onSelect={() => {
                        requested.current = null;
                        setSelection(row.id);
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
                </>
              )
            }
          </ResourceFeedback>
        </div>
      </section>
      <section className="cc-scrollbar min-h-0">
        {selection ? (
          <ResourceFeedback {...detail} onRetry={() => void detail.reload()}>
            {(value) =>
              value ? <ConversationDetailView detail={value} /> : null
            }
          </ResourceFeedback>
        ) : (
          rows.length > 0 && (
            <EmptyState
              title={t("Select a conversation", "选择对话查看详情")}
            />
          )
        )}
      </section>
    </div>
  );
}

function ProjectFilter({
  projects,
  value,
  onChange,
}: {
  projects: ProjectOption[];
  value?: string;
  onChange: (key?: string) => void;
}) {
  const t = useTranslation();
  const selected = projects.find((project) => project.key === value);
  const recent = projects
    .filter(
      (project) =>
        project.status === "available" || project.status === "unverified",
    )
    .slice(0, 5);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={<Button variant="ghost" size="sm" className="max-w-[150px]" />}
      >
        <Folder />
        <span className="truncate">
          {selected?.name ?? t("All projects", "全部项目")}
        </span>
        <ChevronDown />
      </DropdownMenuTrigger>
      <DropdownMenuContent className="w-64">
        <DropdownMenuItem onClick={() => onChange(undefined)}>
          {t("All projects", "全部项目")}
        </DropdownMenuItem>
        {recent.length > 0 && (
          <DropdownMenuGroup>
            <DropdownMenuLabel>{t("Recent", "最近使用")}</DropdownMenuLabel>
            {recent.map((project) => (
              <DropdownMenuItem
                key={project.key}
                onClick={() => onChange(project.key)}
              >
                <span className="truncate">
                  {project.name}
                  {project.duplicateName ? ` · ${project.path}` : ""}
                </span>
                <span className="ml-auto">{project.conversationCount}</span>
              </DropdownMenuItem>
            ))}
          </DropdownMenuGroup>
        )}
        <DropdownMenuSeparator />
        {projects.map((project) => (
          <DropdownMenuItem
            key={project.key}
            onClick={() => onChange(project.key)}
          >
            <span className="truncate">
              {project.name}
              {project.duplicateName ? ` · ${project.path}` : ""}
              {project.status === "unavailable"
                ? ` · ${t("Unavailable", "已不存在")}`
                : ""}
            </span>
            <span className="ml-auto">{project.conversationCount}</span>
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function ConversationRow({
  row,
  selected,
  onSelect,
}: {
  row: ConversationListResult["rows"][number];
  selected: boolean;
  onSelect: () => void;
}) {
  const { settings, bootstrap } = useHost();
  return (
    <button
      id={`selectable-${row.id}`}
      type="button"
      aria-selected={selected}
      onClick={onSelect}
      className={cn(
        "cc-list-row mb-0.5 flex w-full flex-col gap-1.5 px-2.5 py-2 text-left",
      )}
    >
      <span className="flex items-center gap-1.5">
        <ServiceIcon
          name={serviceDisplayName(row.service)}
          color={brandColor(
            row.service,
            settings,
            bootstrap.appearance === "dark",
          )}
          size={14}
        />
        <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium">
          {row.title}
        </span>
        <span className="cc-tertiary cc-number text-[10.5px]">
          {row.rangeLastAt.slice(0, 10)}
        </span>
      </span>
      <span className="flex items-center gap-1 text-[10.5px] text-muted-foreground">
        <span className="shrink-0">{row.project.name}</span>
        <span>·</span>
        <span className="truncate">{row.models.join(", ")}</span>
        <SpeedBadge summary={row.speed.summary} />
      </span>
      <span className="cc-number flex items-center gap-2 text-[10.5px] text-muted-foreground">
        <span>
          {row.totals.requestCount}{" "}
          {bootstrap.resolvedLanguage === "zh" ? "次请求" : "requests"}
        </span>
        <span className="flex-1" />
        <span>
          {formatTokens(row.totals.totalTokens, bootstrap.resolvedLanguage)}{" "}
          Tokens
        </span>
        <span className="text-[11.5px] font-semibold text-foreground">
          {row.costs.displayTotal}
        </span>
      </span>
    </button>
  );
}

function ConversationDetailView({ detail }: { detail: ConversationDetail }) {
  const [copyError, setCopyError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const { api, settings, bootstrap } = useHost();
  const t = useTranslation();
  const row = detail.summary;
  const language = bootstrap.resolvedLanguage;
  const totals = row.totals;
  const tokenSum =
    totals.inputTokens + totals.outputTokens + totals.cacheReadTokens;
  return (
    <div className="space-y-3.5 p-5">
      {copyError && (
        <p role="alert" className="text-xs text-red-600">
          {copyError}
        </p>
      )}
      <header className="space-y-1.5">
        <div className="flex items-center gap-2">
          <ServiceIcon
            name={serviceDisplayName(row.service)}
            color={brandColor(
              row.service,
              settings,
              bootstrap.appearance === "dark",
            )}
            size={14}
          />
          <span className="text-[11.5px] font-semibold text-muted-foreground">
            {serviceDisplayName(row.service)}
          </span>
          <span
            className="rounded-full bg-secondary px-1.5 py-0.5 text-[9.5px] text-muted-foreground"
            title={t(
              "This detail shows the conversation’s full history.",
              "该详情展示该对话的全部时间数据。",
            )}
          >
            {t("All time", "全部时间")}
          </span>
          <SpeedBadge summary={row.speed.summary} />
        </div>
        <h2 className="text-[18px] font-semibold">{row.title}</h2>
        <p
          className="truncate font-mono text-[11px] text-muted-foreground"
          title={row.project.path}
        >
          {row.project.path || row.project.name}
        </p>
        <div className="cc-number flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-muted-foreground">
          <span>{row.gitBranch}</span>
          <span>
            {formatDate(row.firstAt, language, bootstrap.timeZone)}{" "}
            {formatTime(row.firstAt, bootstrap.timeZone)} –{" "}
            {formatDate(row.lastAt, language, bootstrap.timeZone)}{" "}
            {formatTime(row.lastAt, bootstrap.timeZone)}
          </span>
          {row.includesSubtasks && (
            <span>{t("Includes subtask usage", "包含子任务用量")}</span>
          )}
          <span className="flex items-center gap-1">
            {t("Conversation ID", "对话 ID")}{" "}
            <span className="font-mono">{row.conversationID}</span>
            {!settings.appearance.privacyMode && (
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label={
                  copied
                    ? t("Copied", "已复制")
                    : t("Copy conversation ID", "复制对话 ID")
                }
                onClick={() =>
                  void api
                    .conversationsCopyID(row.id)
                    .then(() => {
                      setCopied(true);
                      setCopyError(null);
                    })
                    .catch((reason: unknown) =>
                      setCopyError(errorMessage(reason)),
                    )
                }
              >
                <Copy />
              </Button>
            )}
          </span>
        </div>
      </header>
      <div className="flex gap-3">
        <KpiCard
          label={t("Total tokens", "总 Tokens")}
          value={formatTokens(totals.totalTokens, language)}
        />
        <KpiCard
          label={t("Estimated cost", "估算费用")}
          value={row.costs.displayTotal}
        />
        <KpiCard
          label={t("Requests", "请求数")}
          value={formatInteger(totals.requestCount, language)}
        />
        <KpiCard
          label={t("Cache hit rate", "缓存命中率")}
          value={formatPercent(totals.cacheHitRate)}
        />
      </div>
      <div className="grid gap-3 min-[760px]:grid-cols-2">
        <Panel title={t("Token composition", "Token 构成")}>
          <DetailValue
            label={t("Input", "输入")}
            value={formatTokens(totals.inputTokens, language)}
            share={tokenSum ? totals.inputTokens / tokenSum : 0}
          />
          <DetailValue
            label={t("Output", "输出")}
            value={formatTokens(totals.outputTokens, language)}
            share={tokenSum ? totals.outputTokens / tokenSum : 0}
          />
          <DetailValue
            label={t("Cache read", "缓存读取")}
            value={formatTokens(totals.cacheReadTokens, language)}
            share={tokenSum ? totals.cacheReadTokens / tokenSum : 0}
          />
          <DetailValue
            label={t("Cache write", "缓存写入")}
            value={
              row.cacheCreationAvailable
                ? formatTokens(totals.cacheCreationTokens, language)
                : "N/A"
            }
          />
        </Panel>
        <Panel title={t("Estimated cost breakdown", "估算费用构成")}>
          <DetailValue
            label="Standard"
            value={row.speed.standard.costDisplay}
          />
          <DetailValue label="Fast" value={row.speed.fast.costDisplay} />
          <div className="my-1 border-t" />
          <DetailValue
            label={t("Input", "输入")}
            value={row.costs.displayInput}
          />
          <DetailValue
            label={t("Output", "输出")}
            value={row.costs.displayOutput}
          />
          <DetailValue
            label={t("Cache read", "缓存读取")}
            value={row.costs.displayCacheRead}
          />
          <DetailValue
            label={t("Cache write", "缓存写入")}
            value={
              row.cacheCreationAvailable
                ? row.costs.displayCacheCreation
                : "N/A"
            }
          />
        </Panel>
      </div>
      <div className="grid items-start gap-3 min-[760px]:grid-cols-[58fr_42fr]">
        <Panel title={t("By model", "按模型")} contentClassName="p-3">
          {detail.models.map((model) => (
            <div
              key={`${model.service}:${model.model}`}
              className="border-b py-2 last:border-0"
            >
              <div className="flex items-center gap-1.5">
                <span className="truncate font-mono text-[11.5px]">
                  {model.model}
                </span>
                <SpeedBadge summary={model.speed.summary} />
                <span className="flex-1" />
                <span className="cc-number text-[10.5px] text-muted-foreground">
                  {formatTokens(model.totals.totalTokens, language)}
                </span>
                <span className="cc-number w-[76px] text-right text-[11.5px] font-semibold">
                  {model.costs.displayTotal}
                </span>
              </div>
              <p className="cc-number mt-1 text-[10.5px] text-muted-foreground">
                in {formatTokens(model.totals.inputTokens, language)} · out{" "}
                {formatTokens(model.totals.outputTokens, language)} · cache{" "}
                {formatTokens(model.totals.cacheReadTokens, language)}
              </p>
              <p className="cc-number mt-1 text-[10.5px] text-muted-foreground">
                {model.totals.averageFirstTokenSeconds !== null
                  ? `${t("First token", "首字")} ${model.totals.averageFirstTokenSeconds.toFixed(1)}s · `
                  : ""}
                {t("Output speed", "输出速度")}{" "}
                {model.totals.outputTokensPerSecond === null
                  ? "—"
                  : `${model.totals.usesEstimatedSpeed ? "≈" : ""}${formatInteger(model.totals.outputTokensPerSecond, language)} t/s`}
              </p>
            </div>
          ))}
        </Panel>
        <Panel title={t("Speed tiers", "速度档位")} contentClassName="p-3">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("Tier", "档位")}</TableHead>
                <TableHead className="text-right">Tokens</TableHead>
                <TableHead className="text-right">
                  {t("Requests", "请求")}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(
                [
                  ["Standard", row.speed.standard],
                  ["Fast", row.speed.fast],
                  [t("Unrecognized", "未识别"), row.speed.unknown],
                ] as const
              ).map(([label, value]) => (
                <TableRow key={label}>
                  <TableCell>{label}</TableCell>
                  <TableCell className="cc-number text-right">
                    {formatTokens(value.totalTokens, language)}
                  </TableCell>
                  <TableCell className="cc-number text-right">
                    {formatInteger(value.requestCount, language)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <p className="cc-number mt-2 text-[11px] text-muted-foreground">
            {t("Billing equivalent", "计费等效")}{" "}
            {formatTokens(
              Number(row.speed.fastBillingEquivalentTokens),
              language,
            )}{" "}
            Tokens
          </p>
        </Panel>
      </div>
    </div>
  );
}

function DetailValue({
  label,
  value,
  share,
}: {
  label: string;
  value: string;
  share?: number;
}) {
  return (
    <div className="flex items-center border-b py-[7px] text-[12px] last:border-0">
      <span>{label}</span>
      <span className="flex-1" />
      <span className="cc-number font-semibold">{value}</span>
      {share !== undefined && (
        <span className="cc-number w-12 text-right text-[11px] text-muted-foreground">
          {formatPercent(share)}
        </span>
      )}
    </div>
  );
}
