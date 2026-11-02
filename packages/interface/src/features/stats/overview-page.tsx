import { useEffect, useState } from "react";
import { ChevronDown, ChevronRight, ChevronUp, Zap } from "lucide-react";
import type {
  CompositionRow,
  ConversationSummary,
  TopConversation,
  UsageOverview,
  UsageSample,
  UsageService,
  UsageTotals,
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
import {
  ChartLegend,
  StackedBarChart,
  type ChartColumn,
} from "@/components/stacked-bar-chart";
import { Segmented } from "@/components/segmented";
import { ServiceIcon, ServiceMark } from "@/components/service-icon";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import {
  brandColor,
  delta,
  formatInteger,
  formatPercent,
  formatTokens,
  rankColor,
  serviceDisplayName,
} from "@/lib/display";
import type { StatsNavigation, StatsView } from "@/features/stats/stats-page";
import type { StatsQuery } from "@ccbar/host-api/window";
import { cn } from "@/lib/utils";

type Dimension = "service" | "provider" | "model" | "project";

export function OverviewPage({
  data,
  query,
  onService,
  navigate,
}: {
  data: UsageOverview;
  query: StatsQuery;
  onService: (service?: UsageService) => void;
  navigate: (view: StatsView, request: StatsNavigation) => void;
}) {
  const { settings, bootstrap } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  const dark = bootstrap.appearance === "dark";
  const series = data.visibleServices.map((service) => ({
    id: service,
    name: serviceDisplayName(service),
    color: brandColor(service, settings, dark),
  }));
  const columns: ChartColumn[] = data.samples.map((sample) =>
    chartColumn(
      sample,
      data.visibleServices,
      language,
      query.granularity,
      bootstrap.timeZone,
    ),
  );
  return (
    <div className="cc-scrollbar h-full">
      <div className="flex min-h-full flex-col gap-3 p-5">
        <div className="flex gap-3 overflow-x-auto">
          <KpiCard
            label={t("Total tokens", "总 Tokens")}
            value={formatTokens(data.totals.totalTokens, language)}
            delta={delta(data.comparison, "tokens")}
          />
          <KpiCard
            label={t("Cost", "费用")}
            value={data.totals.costDisplay}
            delta={delta(data.comparison, "costUSD")}
          />
          {data.services.map((item) => (
            <KpiCard
              key={item.service}
              label={serviceDisplayName(item.service)}
              value={
                query.service && query.service !== item.service
                  ? "—"
                  : item.totals.costDisplay
              }
              delta={
                query.service && query.service !== item.service
                  ? null
                  : delta(item.comparison, "costUSD")
              }
              icon={
                <ServiceIcon
                  name={serviceDisplayName(item.service)}
                  color={brandColor(item.service, settings, dark)}
                  size={12}
                />
              }
              dimmed={Boolean(query.service && query.service !== item.service)}
            />
          ))}
        </div>
        <div className="@container">
          <div className="grid gap-3 @min-[880px]:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
            <Panel
              title={
                query.granularity === "day"
                  ? t("Daily usage", "每日用量")
                  : query.granularity === "week"
                    ? t("Weekly usage", "每周用量")
                    : t("Monthly usage", "每月用量")
              }
              actions={<ChartLegend series={series} />}
              className="min-h-[260px]"
            >
              <StackedBarChart
                columns={columns}
                series={series}
                height={190}
                barWidth={data.barWidth}
              />
            </Panel>
            <TokenBreakdown totals={data.totals} speed={data.speed} />
          </div>
        </div>
        <div className="@container">
          <div className="grid items-stretch gap-3 @min-[960px]:grid-cols-[minmax(0,5fr)_minmax(0,4fr)]">
            <CompositionPanel
              data={data}
              query={query}
              onService={onService}
              navigate={navigate}
            />
            <Panel
              title={t("Top conversations", "高消耗对话")}
              actions={
                <div className="flex items-center gap-2">
                  <span className="cc-tertiary cc-number text-[10.5px]">
                    {data.topConversationsShare !== null
                      ? `${t("Top", "前")} ${data.topConversations.length} = ${formatPercent(data.topConversationsShare)}`
                      : ""}
                  </span>
                  <Button
                    variant="link"
                    size="sm"
                    onClick={() =>
                      navigate("conversations", { conversationsByRank: true })
                    }
                  >
                    {t("All conversations ›", "全部对话 ›")}
                  </Button>
                </div>
              }
              contentClassName="p-0"
            >
              {data.topConversations.length ? (
                data.topConversations.map((row, index) => (
                  <TopConversationRow
                    key={row.summary.id}
                    row={row}
                    index={index}
                    share={row.share}
                    metric={settings.appearance.statsRankMetric}
                    onClick={() =>
                      navigate("conversations", {
                        conversationID: row.summary.id,
                      })
                    }
                  />
                ))
              ) : (
                <EmptyState
                  title={t(
                    "No local conversations in this range",
                    "该范围内没有本机对话",
                  )}
                />
              )}
            </Panel>
          </div>
        </div>
      </div>
    </div>
  );
}

export function periodTitle(
  key: string,
  granularity: StatsQuery["granularity"],
): string {
  if (granularity === "month") return key.slice(0, 7);
  if (granularity === "day") return key.slice(0, 10);
  const start = key.slice(0, 10);
  const end = new Date(`${start}T00:00:00Z`);
  end.setUTCDate(end.getUTCDate() + 6);
  return `${start} – ${end.toISOString().slice(0, 10)}`;
}

function chartColumn(
  sample: UsageSample,
  services: UsageService[],
  language: "zh" | "en",
  granularity: StatsQuery["granularity"],
  timeZone: string,
): ChartColumn {
  const date = new Date(sample.start);
  const label = new Intl.DateTimeFormat(
    language === "zh" ? "zh-CN" : "en-US",
    granularity === "month"
      ? { year: "numeric", month: "short", timeZone }
      : { month: "short", day: "numeric", timeZone },
  ).format(date);
  return {
    key: sample.key,
    label,
    total: sample.totals.totalTokens,
    totalLabel: `${formatTokens(sample.totals.totalTokens, language)} Tokens · ${sample.totals.costDisplay}`,
    tooltipTitle: periodTitle(sample.key, granularity),
    tooltipTokens: formatTokens(sample.totals.totalTokens, language),
    tooltipTotal: sample.totals.costDisplay,
    highlighted: sample.highlighted,
    segments: services.map((service) => ({
      seriesID: service,
      value: sample.byService[service]?.totalTokens ?? 0,
      label: sample.byService[service]?.costDisplay ?? "—",
    })),
    tooltip: (
      <span className="mt-1 block space-y-1 text-muted-foreground">
        {[
          [
            language === "zh" ? "输入" : "Input",
            formatTokens(sample.totals.inputTokens, language),
          ],
          [
            language === "zh" ? "输出" : "Output",
            formatTokens(sample.totals.outputTokens, language),
          ],
          [
            language === "zh" ? "缓存命中" : "Cache hit",
            formatTokens(sample.totals.cacheReadTokens, language),
          ],
          [
            language === "zh" ? "缓存命中率" : "Hit rate",
            formatPercent(sample.totals.cacheHitRate),
          ],
        ].map(([label, value]) => (
          <span key={label} className="flex justify-between">
            <span>{label}</span>
            <span className="cc-number">{value}</span>
          </span>
        ))}
      </span>
    ),
  };
}

function TokenBreakdown({
  totals,
  speed,
}: {
  totals: UsageTotals;
  speed: UsageOverview["speed"];
}) {
  const t = useTranslation();
  const { bootstrap } = useHost();
  const language = bootstrap.resolvedLanguage;
  const values = [
    totals.inputTokens,
    totals.outputTokens,
    totals.cacheReadTokens,
  ];
  const sum = values.reduce((a, b) => a + b, 0);
  const labels = [
    t("Input", "输入"),
    t("Output", "输出"),
    t("Cache hit", "缓存命中"),
  ];
  return (
    <Panel title={t("Token breakdown", "Token 拆分")}>
      <div className="flex items-baseline gap-2">
        <span className="cc-number text-[24px] font-semibold text-green-700 dark:text-green-400">
          {formatPercent(totals.cacheHitRate)}
        </span>
        <span className="text-[11px] text-muted-foreground">
          {t("Cache hit rate", "缓存命中率")}
        </span>
      </div>
      <div className="mt-3 flex h-2 overflow-hidden rounded-full bg-secondary">
        {values.map((value, index) => (
          <span
            key={labels[index]}
            style={{
              width: `${sum ? (value / sum) * 100 : 0}%`,
              backgroundColor: `currentColor`,
              opacity: [0.85, 0.6, 0.4][index],
            }}
          />
        ))}
      </div>
      <div className="mt-2 divide-y">
        {values.map((value, index) => (
          <div
            key={labels[index]}
            className="flex items-center gap-2 py-[7px] text-[12px]"
          >
            <span
              className="size-2 rounded-full bg-current"
              style={{ opacity: [0.85, 0.6, 0.4][index] }}
            />
            <span>{labels[index]}</span>
            <span className="flex-1" />
            <span className="cc-number font-semibold">
              {formatTokens(value, language)}
            </span>
            <span className="cc-number w-12 text-right text-[11px] text-muted-foreground">
              {formatPercent(sum ? value / sum : 0)}
            </span>
          </div>
        ))}
      </div>
      {speed.fast.requestCount > 0 && (
        <div className="mt-2 flex items-center gap-1.5 border-t pt-3 text-[11px] text-muted-foreground">
          <Zap className="size-3" />
          <span className="cc-number">
            Fast {formatTokens(speed.fast.totalTokens, language)} ·{" "}
            {t("equiv.", "等效")}{" "}
            {formatTokens(Number(speed.fastBillingEquivalentTokens), language)}{" "}
            · {speed.fast.costDisplay}
          </span>
        </div>
      )}
    </Panel>
  );
}

export function positiveShares<T extends { share: number }>(
  rows: readonly T[],
): T[] {
  return rows.filter((row) => row.share > 0 && Number.isFinite(row.share));
}

function CompositionPanel({
  data,
  query,
  onService,
  navigate,
}: {
  data: UsageOverview;
  query: StatsQuery;
  onService: (service?: UsageService) => void;
  navigate: (view: StatsView, request: StatsNavigation) => void;
}) {
  const t = useTranslation();
  const { settings, bootstrap } = useHost();
  const [dimension, setDimension] = useState<Dimension>("service");
  const [expanded, setExpanded] = useState<string | null>(null);
  const [hovered, setHovered] = useState<string | null>(null);
  const scope = JSON.stringify([
    query.range,
    query.granularity,
    query.service,
    query.customFrom,
    query.customTo,
  ]);
  const rows = data.composition[dimension];
  useEffect(() => {
    setHovered(null);
  }, [scope, dimension]);
  useEffect(() => {
    setHovered((id) => (id && !rows.some((row) => row.id === id) ? null : id));
  }, [rows]);
  const positive = positiveShares(rows);
  const highlighted = positive.some((row) => row.id === hovered)
    ? hovered
    : null;
  const shareTotal = positive.reduce((sum, row) => sum + row.share, 0);
  const language = bootstrap.resolvedLanguage;
  const dark = bootstrap.appearance === "dark";
  const perform = (row: CompositionRow) => {
    if (row.action.type === "selectService") onService(row.services[0]);
    if (
      row.action.type === "expandProvider" ||
      row.action.type === "expandModel"
    )
      setExpanded(expanded === row.id ? null : row.id);
    if (row.action.type === "openProject" && row.action.value)
      navigate("projects", { projectKey: row.action.value });
    if (row.action.type === "openUnattributed")
      navigate("projects", { unattributed: true });
  };
  return (
    <Panel
      title={t("Usage composition", "用量构成")}
      actions={
        <Segmented
          value={dimension}
          options={[
            { value: "service", label: t("Application", "应用") },
            { value: "provider", label: t("Provider", "提供商") },
            { value: "model", label: t("Model", "模型") },
            { value: "project", label: t("Project", "项目") },
          ]}
          onChange={(value) => {
            setDimension(value);
            setExpanded(null);
          }}
          ariaLabel={t("Composition dimension", "构成维度")}
        />
      }
      contentClassName="p-0"
    >
      {rows.length === 0 ? (
        <EmptyState title={t("No data", "无数据")} />
      ) : (
        <>
          <div className="px-4 pt-3">
            <div data-slot="composition-share" className="flex h-2 gap-0.5">
              {positive.map((row) => (
                <span
                  key={row.id}
                  data-slot="composition-segment"
                  data-state={
                    highlighted === row.id
                      ? "highlighted"
                      : highlighted
                        ? "dimmed"
                        : "normal"
                  }
                  className="cc-composition-segment"
                  style={{
                    flex: row.share / shareTotal,
                    minWidth: 0,
                    backgroundColor: compositionColor(row, settings, dark),
                    color: compositionColor(row, settings, dark),
                  }}
                />
              ))}
            </div>
          </div>
          <div className="cc-scrollbar mx-1 mt-2 h-[240px] overflow-y-auto overflow-x-hidden">
            <Table className="table-fixed text-[11.5px] [&_th]:h-8 [&_th]:px-1 [&_th]:text-[10.5px] [&_td]:px-1 [&_td]:py-1.5">
              <colgroup>
                <col />
                <col style={{ width: 76 }} />
                <col style={{ width: 76 }} />
                <col style={{ width: 46 }} />
                <col style={{ width: 70 }} />
                <col style={{ width: 64 }} />
                <col style={{ width: 16 }} />
              </colgroup>
              <TableHeader>
                <TableRow>
                  <TableHead>
                    {t(
                      dimension === "service"
                        ? "Application"
                        : dimension === "provider"
                          ? "Provider"
                          : dimension === "model"
                            ? "Model"
                            : "Project",
                      dimension === "service"
                        ? "应用"
                        : dimension === "provider"
                          ? "提供商"
                          : dimension === "model"
                            ? "模型"
                            : "项目",
                    )}
                  </TableHead>
                  <TableHead className="text-right">Tokens</TableHead>
                  <TableHead className="text-right">
                    {t("Cost", "费用")}
                  </TableHead>
                  <TableHead className="text-right">
                    {t("Share", "占比")}
                  </TableHead>
                  <TableHead className="text-right">
                    {t("Output speed", "输出速度")}
                  </TableHead>
                  <TableHead className="text-right">
                    {t("Cache hit", "缓存命中率")}
                  </TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <CompositionTableRow
                    key={row.id}
                    row={row}
                    expanded={expanded === row.id}
                    hovered={hovered === row.id}
                    onHover={(active) =>
                      setHovered((current) =>
                        active ? row.id : current === row.id ? null : current,
                      )
                    }
                    onClick={() => perform(row)}
                    language={language}
                  />
                ))}
              </TableBody>
            </Table>
          </div>
          <div className="flex items-center border-t px-4 py-2 text-[11px] text-muted-foreground">
            <span className="cc-number">
              {t("Total", "合计")}{" "}
              {formatTokens(data.totals.totalTokens, language)} Tokens ·{" "}
              {data.totals.costDisplay}
            </span>
            <span className="flex-1" />
            {dimension === "project" && (
              <Button
                variant="link"
                size="sm"
                onClick={() => navigate("projects", {})}
              >
                {t("All projects ›", "全部项目 ›")}
              </Button>
            )}
          </div>
        </>
      )}
    </Panel>
  );
}

function CompositionTableRow({
  row,
  expanded,
  hovered,
  onHover,
  onClick,
  language,
}: {
  row: CompositionRow;
  expanded: boolean;
  hovered: boolean;
  onHover: (active: boolean) => void;
  onClick: () => void;
  language: "zh" | "en";
}) {
  const { settings, bootstrap } = useHost();
  const dark = bootstrap.appearance === "dark";
  const clickable = row.action.type !== "none";
  const cells = (
    <>
      <TableCell>
        <div className="flex min-w-0 items-center gap-2">
          <span data-slot="composition-icon" className="cc-composition-icon">
            {row.color.role === "service" && row.color.service ? (
              <ServiceIcon
                name={row.title}
                color={brandColor(row.color.service, settings, dark)}
                size={18}
              />
            ) : (
              <ServiceMark color={compositionColor(row, settings, dark)} />
            )}
          </span>
          <div className="min-w-0">
            <div
              className={cn(
                "truncate text-[12.5px]",
                row.kind === "item" ? "font-semibold" : "text-muted-foreground",
              )}
              title={row.title}
            >
              {row.title || (language === "zh" ? "未归属" : "Unattributed")}
            </div>
            {row.subtitle && (
              <div className="cc-tertiary truncate text-[10.5px]">
                {row.subtitle}
              </div>
            )}
          </div>
        </div>
      </TableCell>
      <TableCell className="cc-number text-right font-semibold">
        {formatTokens(row.totals.totalTokens, language)}
      </TableCell>
      <TableCell className="cc-number text-right font-semibold">
        {row.totals.costDisplay}
      </TableCell>
      <TableCell className="cc-number text-right text-muted-foreground">
        {formatPercent(row.share)}
      </TableCell>
      <TableCell className="cc-number text-right text-muted-foreground">
        {row.totals.outputTokensPerSecond === null
          ? "—"
          : `${row.totals.usesEstimatedSpeed ? "≈" : ""}${formatInteger(row.totals.outputTokensPerSecond, language)} t/s`}
      </TableCell>
      <TableCell className="cc-number text-right text-muted-foreground">
        {formatPercent(row.totals.cacheHitRate)}
      </TableCell>
      <TableCell>
        {row.action.type === "expandModel" ||
        row.action.type === "expandProvider" ? (
          expanded ? (
            <ChevronUp className="size-3" />
          ) : (
            <ChevronDown className="size-3" />
          )
        ) : clickable ? (
          <ChevronRight className="size-3" />
        ) : null}
      </TableCell>
    </>
  );
  return (
    <>
      <TableRow
        className={cn("cc-composition-row", clickable && "cursor-pointer")}
        data-hovered={hovered || undefined}
        data-expanded-provider={
          (expanded && row.action.type === "expandProvider") || undefined
        }
        onMouseEnter={() => onHover(true)}
        onMouseLeave={() => onHover(false)}
        tabIndex={clickable ? 0 : undefined}
        onKeyDown={(event) => {
          if (clickable && (event.key === "Enter" || event.key === " ")) {
            event.preventDefault();
            onClick();
          }
        }}
        onClick={clickable ? onClick : undefined}
      >
        {cells}
      </TableRow>
      {expanded && (row.models.length > 0 || row.sources.length > 0) && (
        <>
          {[...row.models, ...row.sources].map((model) => (
            <TableRow
              key={`${model.service}:${model.model}`}
              className="bg-black/[0.02] dark:bg-white/[0.02]"
            >
              <TableCell>
                <div className="flex min-w-0 items-center gap-1 pl-3">
                  <ServiceIcon
                    name={serviceDisplayName(model.service)}
                    color={brandColor(model.service, settings, dark)}
                    size={12}
                  />
                  <span className="truncate font-mono" title={model.model}>
                    {model.model}
                  </span>
                </div>
              </TableCell>
              <TableCell className="cc-number text-right">
                {formatTokens(model.totals.totalTokens, language)}
              </TableCell>
              <TableCell className="cc-number text-right">
                {model.totals.costDisplay}
              </TableCell>
              <TableCell />
              <TableCell className="cc-number text-right">
                {model.totals.outputTokensPerSecond === null
                  ? "—"
                  : `${model.totals.usesEstimatedSpeed ? "≈" : ""}${formatInteger(model.totals.outputTokensPerSecond, language)} t/s`}
              </TableCell>
              <TableCell />
              <TableCell />
            </TableRow>
          ))}
        </>
      )}
    </>
  );
}

function compositionColor(
  row: CompositionRow,
  settings: ReturnType<typeof useHost>["settings"],
  dark: boolean,
): string {
  if (row.color.role === "service" && row.color.service)
    return brandColor(row.color.service, settings, dark);
  if (row.color.role === "rank") return rankColor(row.color.rank, dark);
  return dark ? "#48484a" : "#c7c7cc";
}

export function TopConversationRow({
  row,
  index,
  share,
  metric,
  onClick,
  showProject = true,
}: {
  row: TopConversation;
  index: number;
  share: number;
  metric: "tokens" | "cost";
  onClick: () => void;
  showProject?: boolean;
}) {
  const { settings, bootstrap } = useHost();
  const language = bootstrap.resolvedLanguage;
  const summary = row.summary;
  return (
    <button
      type="button"
      className="flex w-full items-center gap-2 border-b px-4 py-[11px] text-left last:border-0 hover:bg-black/[0.04] dark:hover:bg-white/[0.04]"
      onClick={onClick}
    >
      <span className="cc-tertiary cc-number w-3.5 text-right text-[11px]">
        {index + 1}
      </span>
      <ServiceIcon
        name={serviceDisplayName(summary.service)}
        color={brandColor(
          summary.service,
          settings,
          bootstrap.appearance === "dark",
        )}
        size={14}
      />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[12.5px] font-medium">
          {summary.title ?? "Untitled"}
        </span>
        <span className="block truncate text-[10.5px] text-muted-foreground">
          {showProject ? `${row.project.name} · ` : ""}
          {summary.gitBranch ? `${summary.gitBranch} · ` : ""}
          {summary.rangeLastAt.slice(0, 10)}
        </span>
        <span className="mt-1 block h-[3px] rounded-full bg-secondary">
          <span
            className="block h-full rounded-full bg-neutral-400"
            style={{ width: `${Math.min(100, share * 100)}%` }}
          />
        </span>
      </span>
      <span className="min-w-24 text-right">
        <span className="cc-number block text-[12.5px] font-semibold">
          {metric === "tokens"
            ? formatTokens(summary.totals.totalTokens, language)
            : summary.costs.displayTotal}
        </span>
        <span className="cc-number block text-[10.5px] text-muted-foreground">
          {metric === "tokens"
            ? summary.costs.displayTotal
            : `${formatTokens(summary.totals.totalTokens, language)} Tokens`}{" "}
          · {formatPercent(share)}
        </span>
      </span>
    </button>
  );
}

export function SpeedBadge({
  summary,
}: {
  summary: ConversationSummary["speed"]["summary"];
}) {
  if (summary !== "fast" && summary !== "mixed") return null;
  return (
    <span className="rounded-full bg-secondary px-1.5 py-0.5 text-[9.5px] font-semibold text-muted-foreground">
      {summary === "fast" ? "Fast" : "Mixed"}
    </span>
  );
}

export { TokenBreakdown, compositionColor };
