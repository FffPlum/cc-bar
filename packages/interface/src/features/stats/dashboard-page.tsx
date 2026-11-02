import { useEffect, useRef, useState } from "react";
import {
  keepPreviousData,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { HostError } from "@ccbar/host-api";
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
import { DashboardFilters, civilInput } from "./dashboard-filters";
import { DashboardChart, HeatmapBlocks } from "./dashboard-charts";
import { DashboardTable } from "./dashboard-table";

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
  return (
    <DashboardQueryScope>
      <DashboardContent {...props} />
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
  const [collapsed, setCollapsed] = useState(false);
  const [activeTab, setActiveTab] = useState<
    "requests" | "providers" | "models"
  >("providers");
  const [cursors, setCursors] = useState<string[]>([]);
  const cursor = cursors.at(-1);
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
  const requestIdentity = JSON.stringify([
    requestKey,
    activeTab,
    cursor,
    requestSort.sort,
    requestSort.direction,
  ]);
  const currentRequestIdentity = useRef(requestIdentity);
  currentRequestIdentity.current = requestIdentity;
  const requestGeneration = useRef(0);
  useEffect(
    () => () => {
      requestGeneration.current += 1;
    },
    [],
  );
  const dashboard = useQuery({
    queryKey: ["dashboard", key],
    queryFn: () => api.usageDashboard(query),
    placeholderData: keepPreviousData,
    refetchInterval: range === "custom" && !custom?.followNow ? false : 60000,
    refetchIntervalInBackground: false,
  });
  const requests = useQuery({
    queryKey: ["requests", requestKey, cursor, requestSort],
    enabled: activeTab === "requests",
    placeholderData: keepPreviousData,
    queryFn: ({ signal }) => {
      const generation = ++requestGeneration.current;
      const identity = requestIdentity;
      return api
        .usageRequests({
          ...requestQuery,
          ...requestSort,
          ...(cursor && { cursor }),
        })
        .catch((reason) => {
          if (
            cursor &&
            !signal.aborted &&
            reason instanceof HostError &&
            reason.code === "invalid_cursor" &&
            currentRequestIdentity.current === identity &&
            requestGeneration.current === generation
          ) {
            // A database revision can invalidate the whole pagination chain.
            // Returning to a fresh cached first page would reuse its old cursor.
            void queryClient.invalidateQueries({
              queryKey: ["requests", requestKey, undefined, requestSort],
              exact: true,
              refetchType: "none",
            });
            setCursors([]);
          }
          throw reason;
        });
    },
    refetchInterval:
      !cursor && (range !== "custom" || custom?.followNow) ? 60000 : false,
    refetchIntervalInBackground: false,
  });
  const dashboardResult = useRetainedResult(dashboard);
  const requestResult = useRetainedResult(requests);
  useEffect(() => {
    setSource(undefined);
    setModel(undefined);
  }, [service]);
  useEffect(() => {
    setCursors([]);
  }, [requestKey]);
  useEffect(() => {
    if (
      cursor &&
      !requests.isPlaceholderData &&
      !dashboard.isPlaceholderData &&
      requests.data &&
      dashboard.data &&
      requests.data.revision !== dashboard.data.revision
    )
      setCursors([]);
  }, [
    cursor,
    requests.data,
    requests.isPlaceholderData,
    dashboard.data,
    dashboard.isPlaceholderData,
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
  return (
    <div className="h-full overflow-auto p-5 text-[13px] space-y-4">
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
        onRetry={() => void dashboard.refetch()}
      >
        {(data) => {
          const values = metrics.map((metric) => data.kpiDisplay[metric]);
          return (
            <>
              {data.coverage.refreshing && (
                <p role="status" className="text-muted-foreground">
                  {t("Updating request details…", "正在更新请求明细…")}
                </p>
              )}
              {dashboardResult.isPreviousData && (
                <p role="status" className="text-muted-foreground">
                  {dashboard.isError
                    ? t(
                        "Filters could not be applied; showing previous results.",
                        "筛选未能完成，显示的是上次结果。",
                      )
                    : t(
                        "Changing filters; showing previous results temporarily.",
                        "正在切换筛选，暂显示上次结果。",
                      )}
                </p>
              )}
              <div
                aria-busy={dashboard.isFetching}
                className="space-y-4 motion-safe:transition-opacity motion-safe:duration-150 motion-safe:ease-[cubic-bezier(0.23,1,0.32,1)]"
                style={{ opacity: dashboardResult.isPreviousData ? 0.6 : 1 }}
              >
                {data.coverage.incomplete && !data.coverage.refreshing && (
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
                {range === "all" &&
                  (!service || service === "cursor") &&
                  (!sourceID ||
                    data.facets.sources.some(
                      (source) =>
                        source.id === sourceID && source.service === "cursor",
                    )) &&
                  (service === "cursor" ||
                    data.facets.services.some(
                      (item) => item.id === "cursor",
                    )) && (
                    <p className="text-muted-foreground">
                      {t(
                        "Cursor totals include only remote history loaded so far. Older records can be loaded.",
                        "Cursor 汇总仅包含已加载的远端历史，可加载更早记录。",
                      )}
                    </p>
                  )}
                <section className="overflow-hidden rounded-lg border">
                  <div className="grid grid-cols-4">
                    {metrics.map((item, i) => (
                      <button
                        key={item}
                        type="button"
                        aria-pressed={metric === item}
                        onClick={() => setMetric(item)}
                        className={`p-4 text-left border-b-2 ${metric === item ? "border-foreground" : "border-transparent text-muted-foreground"}`}
                      >
                        <div>{labels[i]}</div>
                        <div className="cc-number mt-2 text-[24px] font-semibold">
                          {values[i]}
                        </div>
                      </button>
                    ))}
                  </div>
                  <div className="flex justify-center border-t">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setCollapsed(!collapsed)}
                      aria-expanded={!collapsed}
                    >
                      {collapsed
                        ? t("Show chart", "展开图表")
                        : t("Hide chart", "收起图表")}
                    </Button>
                  </div>
                  <div inert={dashboardResult.isPreviousData}>
                    {!collapsed &&
                      (range === "all" ? (
                        <HeatmapResource
                          key={key}
                          query={query}
                          revision={data.revision}
                          today={civilInput(
                            new Date(data.resolvedRange.asOf),
                            data.resolvedRange.timeZone,
                          ).slice(0, 10)}
                        />
                      ) : (
                        <DashboardChart
                          data={data}
                          title={labels[metrics.indexOf(metric)]!}
                        />
                      ))}
                  </div>
                </section>
                <div inert={dashboardResult.isPreviousData}>
                  <DashboardTable
                    data={data}
                    tab={activeTab}
                    onTabChange={setActiveTab}
                    requestSort={requestSort}
                    onRequestSort={(value) => {
                      setCursors([]);
                      setRequestSort(value);
                    }}
                    requests={requestResult.data ?? null}
                    loading={requests.isFetching}
                    previousData={requestResult.isPreviousData}
                    error={requests.error ? errorMessage(requests.error) : null}
                    retry={() => void requests.refetch()}
                    cursor={cursor}
                    next={(value) => setCursors((old) => [...old, value])}
                    previous={() => setCursors((old) => old.slice(0, -1))}
                    reset={() => setCursors([])}
                  />
                </div>
              </div>
              <span className="sr-only">{bootstrap.timeZone}</span>
            </>
          );
        }}
      </ResourceFeedback>
    </div>
  );
}

export function HeatmapResource({
  query,
  today,
  revision,
}: {
  query: DashboardQuery;
  today: string;
  revision: string;
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
    <>
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
      {visibleBlocks.length > 0 && (
        <HeatmapBlocks
          blocks={visibleBlocks}
          onOlder={() => setPageCount((old) => old + 1)}
          loading={heatmap.isFetching}
          today={today}
        />
      )}{" "}
      {heatmap.isLoading && (
        <p role="status" className="p-3">
          {t("Loading…", "正在加载…")}
        </p>
      )}
    </>
  );
}
