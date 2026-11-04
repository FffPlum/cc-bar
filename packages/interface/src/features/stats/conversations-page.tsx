import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ChevronDown, CircleHelp, Copy, Folder } from "lucide-react";
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
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { EmptyState } from "@/components/workspace";
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
  formatTokensCompact,
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
    <div className="grid h-full min-h-0 min-w-0 grid-cols-[440px_minmax(0,1fr)] max-[1100px]:grid-cols-[minmax(0,9fr)_minmax(0,11fr)]">
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
      <section className="cc-scrollbar min-h-0 min-w-0">
        {selection ? (
          <ResourceFeedback {...detail} onRetry={() => void detail.reload()}>
            {(value) =>
              value ? (
                <ConversationDetailView key={value.summary.id} detail={value} />
              ) : null
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
        <span>{formatTokensCompact(row.totals.totalTokens)} Tokens</span>
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
    <div className="@container flex flex-col p-5">
      {copyError && (
        <p role="alert" className="mb-4 text-xs text-red-600">
          {copyError}
        </p>
      )}
      <header className="space-y-3 pb-3">
        <div className="flex flex-wrap items-center gap-2">
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
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5">
          <h2 className="min-w-0 break-words text-[18px] font-semibold">
            {row.title ?? t("Untitled conversation", "未命名对话")}
          </h2>
          {row.includesSubtasks && (
            <span className="inline-flex items-center gap-1 text-[11px] text-muted-foreground">
              {t("Includes subtask usage", "包含子任务用量")}
              <Tooltip>
                <TooltipTrigger
                  render={
                    <button
                      type="button"
                      className="inline-flex size-5 items-center justify-center rounded-sm outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring"
                      aria-label={t("About subtask usage", "子任务用量说明")}
                    />
                  }
                >
                  <CircleHelp className="size-3.5" aria-hidden="true" />
                </TooltipTrigger>
                <TooltipContent>
                  {t(
                    "Tokens, estimated costs and requests include usage from subtasks belonging to this conversation.",
                    "此处的 Token、估算费用和请求数已包含归属于该对话的子任务用量。",
                  )}
                </TooltipContent>
              </Tooltip>
            </span>
          )}
        </div>
        <dl className="grid grid-cols-[max-content_minmax(0,1fr)] items-baseline gap-x-3 gap-y-1.5 text-[11px] text-muted-foreground">
          <dt>{t("Working directory", "工作目录")}</dt>
          <dd
            className="break-all font-mono"
            title={t(
              "Project directory recorded for this conversation. Git worktrees are grouped under the main repository.",
              "此对话归属的项目目录；Git worktree 会归到主仓库。",
            )}
          >
            {row.project.path || row.project.name}
          </dd>
          <dt>{t("Git branch", "Git 分支")}</dt>
          <dd className="break-all font-mono">
            {row.gitBranch ||
              (settings.appearance.privacyMode
                ? t("Hidden", "已隐藏")
                : t("Not recorded", "未记录"))}
          </dd>
          <dt>{t("Time", "时间")}</dt>
          <dd className="cc-number">
            {formatDate(row.firstAt, language, bootstrap.timeZone)}{" "}
            {formatTime(row.firstAt, bootstrap.timeZone)} –{" "}
            {formatDate(row.lastAt, language, bootstrap.timeZone)}{" "}
            {formatTime(row.lastAt, bootstrap.timeZone)}
          </dd>
          <dt>{t("Conversation ID", "对话 ID")}</dt>
          <dd className="flex min-w-0 items-center gap-1">
            <span className="min-w-0 break-all font-mono">
              {row.conversationID}
            </span>
            {!settings.appearance.privacyMode && (
              <Button
                variant="ghost"
                size="icon-xs"
                className="shrink-0"
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
          </dd>
        </dl>
      </header>
      <DetailSection title={t("Usage", "用量信息")} className="border-y py-3">
        <dl className="grid grid-cols-2 @min-[640px]:grid-cols-4">
          <UsageValue
            label={t("Total tokens", "总 Token")}
            value={formatTokensCompact(totals.totalTokens)}
            className="pr-3 pb-3 @min-[640px]:pb-0"
          />
          <UsageValue
            label={t("Estimated cost", "估算费用")}
            value={row.costs.displayTotal}
            className="border-l pb-3 pl-3 @min-[640px]:pr-3 @min-[640px]:pb-0"
          />
          <UsageValue
            label={t("Requests", "请求数")}
            value={formatInteger(totals.requestCount, language)}
            className="border-t pt-3 pr-3 @min-[640px]:border-t-0 @min-[640px]:border-l @min-[640px]:pt-0 @min-[640px]:pl-3"
          />
          <UsageValue
            label={t("Cache hits (tokens)", "缓存命中数（Token）")}
            value={formatTokensCompact(totals.cacheReadTokens)}
            className="border-t border-l pt-3 pl-3 @min-[640px]:border-t-0 @min-[640px]:pt-0"
          />
        </dl>
      </DetailSection>
      <div className="flex flex-col gap-4">
        <DetailSection
          title={t("Token composition", "Token 构成")}
          className="pt-3"
        >
          <div className="divide-y">
            <DetailValue
              label={t("Input", "输入")}
              value={formatTokensCompact(totals.inputTokens)}
              share={tokenSum ? totals.inputTokens / tokenSum : 0}
            />
            <DetailValue
              label={t("Output", "输出")}
              value={formatTokensCompact(totals.outputTokens)}
              share={tokenSum ? totals.outputTokens / tokenSum : 0}
            />
            <DetailValue
              label={t("Cache read", "缓存读取")}
              value={formatTokensCompact(totals.cacheReadTokens)}
              share={tokenSum ? totals.cacheReadTokens / tokenSum : 0}
            />
            <DetailValue
              label={t("Cache write", "缓存写入")}
              value={
                row.cacheCreationAvailable
                  ? formatTokensCompact(totals.cacheCreationTokens)
                  : "N/A"
              }
            />
          </div>
        </DetailSection>
        <DetailSection title={t("Estimated cost", "估算费用")} className="pb-3">
          <div className="divide-y">
            <DetailValue
              label={t("Standard", "标准档位")}
              value={row.speed.standard.costDisplay}
            />
            <DetailValue
              label={t("Fast", "快速档位")}
              value={row.speed.fast.costDisplay}
            />
            {row.speed.unknown.requestCount > 0 && (
              <DetailValue
                label={t("Unrecognized tier", "未识别档位")}
                value={row.speed.unknown.costDisplay}
              />
            )}
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
          </div>
        </DetailSection>
      </div>
    </div>
  );
}

function DetailSection({
  title,
  children,
  className,
}: {
  title: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={cn("flex flex-col gap-3", className)}>
      <h3 className="text-[13px] font-semibold">{title}</h3>
      {children}
    </section>
  );
}

function UsageValue({
  label,
  value,
  className,
}: {
  label: string;
  value: string;
  className?: string;
}) {
  return (
    <div className={cn("min-w-0", className)}>
      <dt className="text-[11px] text-muted-foreground">{label}</dt>
      <dd className="cc-number mt-1 break-all text-[22px] leading-tight font-semibold">
        {value}
      </dd>
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
    <div className="flex items-center py-2 text-[12px] first:pt-0 last:pb-0">
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
