import { useEffect, useRef, useState } from "react";
import {
  keepPreviousData,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import type {
  DashboardHeatmap,
  DashboardMetric,
  DashboardQuery,
  UsageService,
  UsageDashboard,
} from "@ccbar/host-api/window";
import { useHost, errorMessage } from "@/host/host-context";
import { ResourceFeedback } from "@/components/resource-feedback";
import { DashboardQueryScope, useRetainedResult } from "./dashboard-query";
import { Button } from "@/components/ui/button";
import { useTranslation } from "@/lib/i18n";
import { formatTokensCompact } from "@/lib/display";
import { DashboardFilters, civilInput } from "./dashboard-filters";
import { DashboardChart, HeatmapBlocks } from "./dashboard-charts";
import { DashboardTable } from "./dashboard-table";
import {
  BackgroundLoadingBar,
  ChartSkeleton,
  LoadingBlock,
} from "./dashboard-loading";

const metrics: DashboardMetric[] = [
  "cost",
  "requests",
  "tokens",
  "cacheHitRate",
];
export function DashboardPage(props: {
  service?: UsageService;
  onService: (value?: UsageService) => void;
}) {
  const { bootstrap } = useHost();
  const { service, onService } = props;
  const enabledService =
    service && bootstrap.visibleUsageServices.includes(service)
      ? service
      : undefined;
  useEffect(() => {
    if (service && !enabledService) onService(undefined);
  }, [service, enabledService, onService]);
  return (
    <DashboardQueryScope>
      <DashboardContent service={enabledService} onService={onService} />
    </DashboardQueryScope>
  );
}
function DashboardContent({
  service,
  onService,
}: {
  service?: UsageService;
  onService: (value?: UsageService) => void;
}) {
  const { api, bootstrap } = useHost();
  const queryClient = useQueryClient();
  const t = useTranslation();
  const [range, setRange] = useState<DashboardQuery["range"]>("last7");
  const [metric, setMetric] = useState<DashboardMetric>("tokens");
  const [sourceID, setSource] = useState<string>();
  const [modelID, setModel] = useState<string>();
  const [activeTab, setActiveTab] = useState<
    "requests" | "providers" | "models"
  >("providers");
  const [pagination, setPagination] = useState({
    key: "",
    page: 1,
    pageSize: 12,
  });
  const [requestSort, setRequestSort] = useState<{
    sort: "time" | "cost" | "tokens";
    direction: "asc" | "desc";
  }>({ sort: "time", direction: "desc" });
  const [custom, setCustom] = useState<{
    customFrom: string;
    customTo: string;
    followNow: boolean;
  }>();
  const query: DashboardQuery = {
    range,
    metric,
    ...(service && { service }),
    ...(sourceID && { sourceID }),
    ...(modelID && { modelID }),
    ...(range === "custom" && custom ? custom : {}),
  };
  const key = JSON.stringify(query);
  const requestQuery = { ...query, metric: "tokens" as const };
  const requestKey = JSON.stringify(requestQuery);
  // Reset synchronously on filter changes, before issuing a request for the new key.
  const page = pagination.key === requestKey ? pagination.page : 1;
  const pageSize = pagination.pageSize;
  const setPage = (value: number) =>
    setPagination({ key: requestKey, page: value, pageSize });
  const dashboard = useQuery({
    queryKey: ["dashboard", key],
    queryFn: () => api.usageDashboard(query),
    placeholderData: keepPreviousData,
    refetchInterval: range === "custom" && !custom?.followNow ? false : 60000,
    refetchIntervalInBackground: false,
  });
  const requests = useQuery({
    queryKey: ["requests", requestKey, page, pageSize, requestSort],
    enabled: activeTab === "requests",
    placeholderData: keepPreviousData,
    queryFn: () =>
      api.usageRequests({ ...requestQuery, ...requestSort, page, pageSize }),
    refetchInterval: range !== "custom" || custom?.followNow ? 60000 : false,
    refetchIntervalInBackground: false,
  });
  const dashboardResult = useRetainedResult(dashboard);
  const requestResult = useRetainedResult(requests);
  useEffect(() => {
    setSource(undefined);
    setModel(undefined);
  }, [service]);
  useEffect(() => {
    setPagination((current) =>
      current.key === requestKey
        ? current
        : { ...current, key: requestKey, page: 1 },
    );
  }, [requestKey]);
  useEffect(() => {
    const result = requests.data;
    if (!requests.isPlaceholderData && result && result.page !== page) {
      // The host clamps pages after records disappear. Reuse that exact response.
      queryClient.setQueryData(
        ["requests", requestKey, result.page, pageSize, requestSort],
        result,
      );
      setPagination({ key: requestKey, page: result.page, pageSize });
    }
  }, [
    page,
    pageSize,
    requestKey,
    requestSort,
    requests.data,
    requests.isPlaceholderData,
    queryClient,
  ]);
  const labels = [
    t("Cost", "总成本"),
    t("Requests", "总请求数"),
    t("Tokens", "Tokens"),
    t("Cache hit rate", "缓存命中率"),
  ];
  const lastFilterData = useRef<Pick<
    UsageDashboard,
    "facets" | "resolvedRange"
  > | null>(null);
  if (dashboard.data && !dashboard.isPlaceholderData)
    lastFilterData.current = dashboard.data;
  const currentTime = new Date().toISOString();
  const filterData = dashboard.data ??
    lastFilterData.current ?? {
      facets: { services: [], sources: [], models: [] },
      resolvedRange: {
        from: currentTime,
        to: currentTime,
        asOf: currentTime,
        timeZone: bootstrap.timeZone,
        granularity: "day" as const,
      },
    };
  const loadingMessage = dashboard.isFetching
    ? dashboardResult.isPreviousData
      ? t("Changing filters; loading results…", "正在切换筛选并加载结果…")
      : t("Loading usage statistics…", "正在加载用量统计…")
    : dashboard.isError && dashboardResult.isPreviousData
      ? t(
          "Filters could not be applied; showing previous results.",
          "筛选未能完成，显示的是上次结果。",
        )
      : activeTab === "requests" && requests.isFetching
        ? requestResult.data
          ? t("Updating request records…", "正在更新请求记录…")
          : t("Loading request records…", "正在加载请求记录…")
        : dashboardResult.data?.coverage.refreshing
          ? t("Updating request details…", "正在更新请求明细…")
          : null;
  const renderContent = (data: UsageDashboard | undefined) => {
    const values = metrics.map((metric) => {
      if (!data) return undefined;
      if (data.kpiDisplay[metric] === "—") return "—";
      return metric === "tokens"
        ? formatTokensCompact(data.totals.totalTokens)
        : data.kpiDisplay[metric];
    });
    const waiting = !data;
    const background = Boolean(data && dashboard.isFetching);
    const empty = Boolean(
      data &&
      !dashboardResult.isPreviousData &&
      !dashboard.isError &&
      !data.coverage.refreshing &&
      !data.coverage.incomplete &&
      data.totals.requestCount === 0 &&
      data.totals.totalTokens === 0 &&
      Number(data.totals.costUSD) === 0,
    );
    return (
      <>
        <div className="space-y-4">
          {data?.coverage.incomplete && !data.coverage.refreshing && (
            <div
              role="status"
              className="rounded border p-3 text-muted-foreground"
            >
              {t(
                "Some request timestamps or source data are unavailable; totals and trends may be incomplete.",
                "部分请求时间或来源数据不可用，汇总和趋势可能不完整。",
              )}
              {(data.coverage.unlocatedTotals.requestCount > 0 ||
                data.coverage.unlocatedTotals.totalTokens > 0) && (
                <span>
                  {" "}
                  {t(
                    "Usage without precise timestamps",
                    "无法精确定位时间的用量",
                  )}
                  :{" "}
                  {data.coverage.unlocatedTotals.requestCount.toLocaleString()}{" "}
                  {t("requests", "次请求")} ·{" "}
                  {data.coverage.unlocatedTotals.totalTokens.toLocaleString()}{" "}
                  tokens · {data.coverage.unlocatedTotals.costDisplay}
                </span>
              )}
            </div>
          )}
          {data &&
            range === "all" &&
            (!service || service === "cursor") &&
            (!sourceID ||
              data.facets.sources.some(
                (source) =>
                  source.id === sourceID && source.service === "cursor",
              )) &&
            (service === "cursor" ||
              data.facets.services.some((item) => item.id === "cursor")) && (
              <p className="text-muted-foreground">
                {t(
                  "Cursor totals include only remote history loaded so far. Older records can be loaded.",
                  "Cursor 汇总仅包含已加载的远端历史，可加载更早记录。",
                )}
              </p>
            )}
          <section
            data-slot="dashboard-summary"
            className="relative overflow-hidden rounded-lg border"
          >
            {loadingMessage && (
              <p
                role="status"
                className={
                  dashboard.isError && dashboardResult.isPreviousData
                    ? "px-4 py-2 text-muted-foreground"
                    : "sr-only"
                }
              >
                {loadingMessage}
              </p>
            )}
            {background && <BackgroundLoadingBar />}
            <div className="grid grid-cols-4" aria-busy={dashboard.isFetching}>
              {metrics.map((item, i) => (
                <button
                  key={item}
                  type="button"
                  aria-pressed={metric === item}
                  onClick={() => setMetric(item)}
                  className={`p-4 text-left border-b-2 ${metric === item ? "border-foreground" : "border-transparent text-muted-foreground"}`}
                >
                  <div>{labels[i]}</div>
                  <div className="cc-number relative mt-2 min-h-9 text-[24px] font-semibold">
                    <span
                      className={waiting ? "invisible" : undefined}
                      aria-hidden={waiting}
                    >
                      {values[i] ?? "\u00a0"}
                    </span>
                    {waiting && (
                      <LoadingBlock className="absolute inset-y-1 left-0 w-24 max-w-full" />
                    )}
                  </div>
                </button>
              ))}
            </div>
            <div
              data-slot="dashboard-chart-region"
              className="relative border-t"
              aria-busy={dashboard.isFetching}
            >
              {!data ? (
                <ChartSkeleton heatmap={range === "all"} />
              ) : (
                <div inert={dashboardResult.isPreviousData}>
                  {range === "all" ? (
                    <HeatmapResource
                      query={query}
                      announceLoading={!loadingMessage}
                      revision={data.revision}
                      today={civilInput(
                        new Date(data.resolvedRange.asOf),
                        data.resolvedRange.timeZone,
                      ).slice(0, 10)}
                    />
                  ) : (
                    <DashboardChart
                      data={data}
                      metric={metric}
                      title={labels[metrics.indexOf(metric)]!}
                      empty={empty}
                    />
                  )}
                </div>
              )}
            </div>
          </section>
          <div>
            <DashboardTable
              data={data}
              dashboardLoading={waiting}
              dashboardPreviousData={dashboardResult.isPreviousData}
              tab={activeTab}
              onTabChange={setActiveTab}
              requestSort={requestSort}
              onRequestSort={(value) => {
                setPage(1);
                setRequestSort(value);
              }}
              requests={requestResult.data ?? null}
              empty={empty}
              loading={requests.isFetching}
              previousData={requestResult.isPreviousData}
              error={requests.error ? errorMessage(requests.error) : null}
              retry={() => void requests.refetch()}
              page={page}
              pageSize={pageSize}
              onPageChange={setPage}
              onPageSizeChange={(value) =>
                setPagination({ key: requestKey, page: 1, pageSize: value })
              }
            />
          </div>
        </div>
        <span className="sr-only">{bootstrap.timeZone}</span>
      </>
    );
  };
  return (
    <div className="h-full overflow-auto [scrollbar-gutter:stable] p-5 text-[13px] space-y-4">
      <DashboardFilters
        data={filterData}
        range={range}
        custom={custom}
        service={service}
        sourceID={sourceID}
        modelID={modelID}
        onRange={(next, value) => {
          setCustom(value);
          setRange(next);
        }}
        onService={(value) => {
          onService(value);
          setSource(undefined);
          setModel(undefined);
        }}
        onSource={(value) => {
          setSource(value);
          setModel(undefined);
        }}
        onModel={setModel}
      />
      <ResourceFeedback
        data={dashboardResult.data ?? null}
        error={dashboard.error ? errorMessage(dashboard.error) : null}
        loading={dashboard.isLoading}
        loadingFallback={renderContent(undefined)}
        onRetry={() => void dashboard.refetch()}
      >
        {(data) => renderContent(data)}
      </ResourceFeedback>
    </div>
  );
}

export function HeatmapResource({
  query,
  today,
  revision,
  announceLoading = true,
}: {
  query: DashboardQuery;
  today: string;
  revision: string;
  announceLoading?: boolean;
}) {
  const { api } = useHost();
  const t = useTranslation();
  const [blocks, setBlocks] = useState<DashboardHeatmap[]>([]);
  const [pageCount, setPageCount] = useState(1);
  const heatmap = useQuery({
    queryKey: ["heatmap", query, pageCount, revision, today],
    placeholderData: keepPreviousData,
    queryFn: async ({ signal }) => {
      const results: DashboardHeatmap[] = [];
      let before: string | undefined;
      const seen = new Set<string>();
      for (let i = 0; i < pageCount; i++) {
        const result = await api.usageHeatmap({
          ...query,
          ...(before && { beforeDay: before }),
        });
        if (signal.aborted) throw signal.reason;
        results.push(result);
        const next = result.nextBeforeDay;
        if (!next || seen.has(next)) break;
        seen.add(next);
        before = next;
      }
      return results;
    },
  });
  useEffect(() => {
    if (heatmap.data && !heatmap.isPlaceholderData) setBlocks(heatmap.data);
  }, [heatmap.data, heatmap.isPlaceholderData]);
  const visibleBlocks = heatmap.data ?? blocks;
  return (
    <div className="relative">
      {announceLoading && heatmap.isFetching && (
        <p role="status" className="sr-only">
          {t("Loading heatmap…", "正在加载用量热力图…")}
        </p>
      )}
      {heatmap.isFetching && visibleBlocks.length > 0 && (
        <BackgroundLoadingBar />
      )}
      {heatmap.error && (
        <p role="alert" className="p-3">
          {errorMessage(heatmap.error)}{" "}
          <Button
            size="sm"
            onClick={() => {
              void heatmap.refetch();
            }}
          >
            {t("Retry", "重试")}
          </Button>
        </p>
      )}
      <div aria-busy={heatmap.isFetching}>
        {visibleBlocks.length > 0 && (
          <HeatmapBlocks
            blocks={visibleBlocks}
            onOlder={() => setPageCount((old) => old + 1)}
            loading={heatmap.isFetching}
            today={today}
          />
        )}
        {heatmap.isLoading && visibleBlocks.length === 0 && (
          <ChartSkeleton heatmap />
        )}
      </div>
    </div>
  );
}
