import { useLayoutEffect, useRef, useState } from "react";
import type {
  DashboardRequests,
  DashboardRow,
  UsageDashboard,
} from "@ccbar/host-api/window";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { formatTokensCompact, serviceDisplayName } from "@/lib/display";
import { Button } from "@/components/ui/button";
import { RequestPagination } from "./request-pagination";
import {
  BackgroundLoadingBar,
  LoadingBlock,
  TableSkeleton,
} from "./dashboard-loading";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";

function modelDisplayName(model: string): string {
  return model.replace(/^(?:kimi-code|deepseek)\//, "");
}

function DashboardNameLabel({ title }: { title: string }) {
  const labelRef = useRef<HTMLSpanElement>(null);
  const [truncated, setTruncated] = useState(false);
  useLayoutEffect(() => {
    const label = labelRef.current;
    if (!label) return;
    const update = () => setTruncated(label.scrollWidth > label.clientWidth);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(label);
    return () => observer.disconnect();
  }, [title]);
  return (
    <Tooltip disabled={!truncated}>
      <TooltipTrigger
        render={
          <span
            ref={labelRef}
            data-slot="dashboard-name-label"
            data-truncated={truncated}
            tabIndex={truncated ? 0 : undefined}
            className="block max-w-full truncate rounded-sm outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            {title}
          </span>
        }
      />
      <TooltipContent
        align="start"
        className="max-w-sm whitespace-normal break-words"
      >
        {title}
      </TooltipContent>
    </Tooltip>
  );
}

type Tab = "requests" | "providers" | "models";
type Field =
  | "title"
  | "time"
  | "requests"
  | "cost"
  | "tokens"
  | "success"
  | "speed"
  | "first";
export function DashboardTable({
  data,
  dashboardLoading = false,
  dashboardPreviousData = false,
  tab,
  onTabChange,
  requests,
  error,
  loading,
  previousData = false,
  empty = false,
  retry,
  page,
  pageSize,
  onPageChange,
  onPageSizeChange,
  requestSort,
  onRequestSort,
}: {
  data: UsageDashboard | undefined;
  dashboardLoading?: boolean;
  dashboardPreviousData?: boolean;
  tab: Tab;
  onTabChange: (tab: Tab) => void;
  requests: DashboardRequests | null;
  error: string | null;
  loading: boolean;
  previousData?: boolean;
  empty?: boolean;
  retry?: () => void;
  page: number;
  pageSize: number;
  onPageChange: (page: number) => void;
  onPageSizeChange: (pageSize: number) => void;
  requestSort: { sort: "time" | "cost" | "tokens"; direction: "asc" | "desc" };
  onRequestSort: (value: {
    sort: "time" | "cost" | "tokens";
    direction: "asc" | "desc";
  }) => void;
}) {
  const { bootstrap } = useHost();
  const t = useTranslation();
  const [field, setField] = useState<Field>("requests");
  const [ascending, setAscending] = useState(false);
  const setSort = (value: Field) => {
    if (field === value) setAscending(!ascending);
    else {
      setField(value);
      setAscending(value === "title" || value === "time");
    }
  };
  const compare = (a: string | number | null, b: string | number | null) => {
    if (a === null) return b === null ? 0 : 1;
    if (b === null) return -1;
    const n =
      typeof a === "string" && typeof b === "string"
        ? a.localeCompare(b)
        : Number(a) - Number(b);
    return ascending ? n : -n;
  };
  const aggValue = (row: DashboardRow): string | number | null =>
    field === "title"
      ? tab === "models"
        ? modelDisplayName(row.title)
        : row.title
      : field === "requests"
        ? row.totals.requestCount
        : field === "cost"
          ? Number(row.totals.costUSD)
          : field === "tokens"
            ? row.totals.totalTokens
            : field === "success"
              ? row.successRate
              : field === "speed"
                ? row.totals.outputTokensPerSecond
                : field === "first"
                  ? row.totals.averageFirstTokenSeconds
                  : null;
  const rows = [
    ...(tab === "models"
      ? (data?.modelRows ?? [])
      : (data?.providerRows ?? [])),
  ].sort((a, b) => compare(aggValue(a), aggValue(b)));
  const logs = empty ? [] : (requests?.rows ?? []);
  const requestWaiting = tab === "requests" && loading && !requests;
  const showSkeleton = dashboardLoading || requestWaiting;
  const oldResults = dashboardPreviousData || previousData;
  const requestHeading = (label: string, sort: "time" | "cost" | "tokens") => (
    <button
      type="button"
      onClick={() =>
        onRequestSort({
          sort,
          direction:
            requestSort.sort === sort && requestSort.direction === "desc"
              ? "asc"
              : "desc",
        })
      }
    >
      {label}
      {requestSort.sort === sort
        ? requestSort.direction === "asc"
          ? " ↑"
          : " ↓"
        : ""}
    </button>
  );
  const heading = (label: string, key: Field) => (
    <button type="button" onClick={() => setSort(key)}>
      {label}
      {field === key ? (ascending ? " ↑" : " ↓") : ""}
    </button>
  );
  return (
    <section
      data-slot="dashboard-table"
      aria-busy={showSkeleton || (tab === "requests" && loading)}
      className="relative overflow-hidden rounded-lg border"
    >
      {tab === "requests" && loading && !showSkeleton && (
        <BackgroundLoadingBar />
      )}
      <div
        className="flex gap-5 border-b px-4"
        role="tablist"
        aria-label={t("Usage details", "用量明细")}
      >
        {(["requests", "providers", "models"] as const).map((item) => (
          <button
            type="button"
            role="tab"
            aria-selected={tab === item}
            key={item}
            onClick={() => {
              onTabChange(item);
              setField(item === "requests" ? "time" : "requests");
              setAscending(false);
            }}
            className={`py-3 ${tab === item ? "border-b-2 border-foreground font-semibold" : "text-muted-foreground"}`}
          >
            {item === "requests"
              ? t("Request logs", "请求日志")
              : item === "providers"
                ? t("Providers", "供应商")
                : t("Models", "模型")}{" "}
            <span className="rounded bg-muted px-1.5 py-0.5 text-muted-foreground">
              {!data ? (
                <LoadingBlock className="inline-block h-3 w-3" />
              ) : item === "requests" ? (
                (data.requestLogCount ?? "—")
              ) : item === "providers" ? (
                (data?.providerRows.length ?? 0)
              ) : (
                (data?.modelRows.length ?? 0)
              )}
            </span>
          </button>
        ))}
      </div>
      {tab === "requests" ? (
        <div aria-busy={loading}>
          {error && (
            <p role="alert" className="p-3">
              {error}{" "}
              {retry && (
                <Button size="sm" variant="outline" onClick={retry}>
                  {t("Retry", "重试")}
                </Button>
              )}
              {page > 1 && (
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => onPageChange(1)}
                >
                  {t("Return to first page", "返回首页")}
                </Button>
              )}
            </p>
          )}
          {previousData && error && !empty && (
            <p role="status" className="px-4 py-2 text-muted-foreground">
              {t(
                "Request records could not be updated; showing previous results.",
                "请求记录未能更新，显示的是上次结果。",
              )}
            </p>
          )}
          {requests?.coverage.incomplete && !empty && (
            <p className="px-4 py-2 text-muted-foreground">
              {t(
                "Request records are incomplete or unavailable.",
                "请求记录不完整或暂不可用。",
              )}
            </p>
          )}
          <div className="relative min-h-[196px]">
            {showSkeleton && <TableSkeleton columns={6} />}
            <table className="w-full table-fixed text-left">
              <thead className="bg-muted text-muted-foreground">
                <tr>
                  {[
                    requestHeading(t("Time", "时间"), "time"),
                    t("Application", "应用"),
                    t("Provider", "供应商"),
                    t("Model", "模型"),
                    requestHeading(t("Cost", "成本"), "cost"),
                    requestHeading("Tokens", "tokens"),
                  ].map((label, i) => (
                    <th key={i} className="px-3 py-2 font-medium">
                      {label}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody
                aria-hidden={showSkeleton}
                inert={showSkeleton || dashboardPreviousData}
              >
                {(empty ||
                  (requests &&
                    !logs.length &&
                    !requests.coverage.incomplete &&
                    !loading &&
                    !error &&
                    !previousData)) && (
                  <tr>
                    <td
                      colSpan={6}
                      className="h-40 px-3 text-center text-muted-foreground"
                    >
                      {t("No data", "暂无数据")}
                    </td>
                  </tr>
                )}
                {logs.map((row) => (
                  <tr key={row.id} className="border-t">
                    <td className="px-3 py-2">
                      {new Intl.DateTimeFormat("en-GB", {
                        timeZone: bootstrap.timeZone,
                        hour: "2-digit",
                        minute: "2-digit",
                        second: "2-digit",
                        hour12: false,
                      }).format(new Date(row.timestamp))}
                    </td>
                    <td className="px-3">{serviceDisplayName(row.service)}</td>
                    <td
                      className="truncate px-3"
                      title={
                        data?.facets.sources.find(
                          (source) => source.id === row.sourceID,
                        )?.title ??
                        (row.service === "cursor"
                          ? t("Remote metering", "远端计量")
                          : t("Session logs", "会话日志"))
                      }
                    >
                      {data?.facets.sources.find(
                        (source) => source.id === row.sourceID,
                      )?.title ??
                        (row.service === "cursor"
                          ? t("Remote metering", "远端计量")
                          : t("Session logs", "会话日志"))}
                    </td>
                    <td
                      className="truncate px-3"
                      title={modelDisplayName(row.modelID)}
                    >
                      {modelDisplayName(row.modelID)}
                    </td>
                    <td className="px-3">{row.totals.costDisplay}</td>
                    <td className="px-3">
                      {formatTokensCompact(row.totals.totalTokens)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <RequestPagination
            totalCount={
              empty
                ? 0
                : requests && !requests.coverage.refreshing
                  ? requests.totalCount
                  : (data?.requestLogCount ?? null)
            }
            page={page}
            pageSize={pageSize}
            disabled={
              loading ||
              oldResults ||
              showSkeleton ||
              Boolean(error) ||
              Boolean(requests?.coverage.refreshing)
            }
            onPageChange={onPageChange}
            onPageSizeChange={onPageSizeChange}
          />
        </div>
      ) : (
        <div className="relative min-h-[196px]">
          {showSkeleton && <TableSkeleton columns={7} />}
          <table className="w-full table-fixed text-left">
            <colgroup>
              <col className="w-[28%]" />
              {Array.from({ length: 6 }, (_, index) => (
                <col key={index} className="w-[12%]" />
              ))}
            </colgroup>
            <thead className="bg-muted text-muted-foreground">
              <tr>
                {[
                  heading(t("Name", "名称"), "title"),
                  heading(t("Requests", "请求数"), "requests"),
                  heading(t("Cost", "成本"), "cost"),
                  heading("Tokens", "tokens"),
                  heading(t("Success", "成功率"), "success"),
                  heading(t("Speed", "速度"), "speed"),
                  heading(t("First token", "首字"), "first"),
                ].map((label, i) => (
                  <th key={i} className="px-3 py-2 font-medium">
                    {label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody
              aria-hidden={showSkeleton}
              inert={showSkeleton || dashboardPreviousData}
            >
              {empty && !rows.length && (
                <tr>
                  <td
                    colSpan={7}
                    className="h-40 px-3 text-center text-muted-foreground"
                  >
                    {t("No data", "暂无数据")}
                  </td>
                </tr>
              )}
              {rows.map((row) => (
                <tr key={row.id} className="border-t">
                  <td className="px-3 py-3">
                    <DashboardNameLabel
                      title={
                        tab === "models" ? modelDisplayName(row.title) : row.title
                      }
                    />
                  </td>
                  <td className="px-3">
                    {row.totals.requestCount.toLocaleString()}
                  </td>
                  <td className="px-3">{row.totals.costDisplay}</td>
                  <td className="px-3">
                    {formatTokensCompact(row.totals.totalTokens)}
                  </td>
                  <td className="px-3">
                    {row.successRate == null
                      ? "—"
                      : `${(row.successRate * 100).toFixed(1)}%`}
                  </td>
                  <td className="px-3">
                    {row.totals.outputTokensPerSecond == null
                      ? "—"
                      : `${row.totals.usesEstimatedSpeed ? "≈" : ""}${row.totals.outputTokensPerSecond.toFixed(1)} tok/s`}
                  </td>
                  <td className="px-3">
                    {row.totals.averageFirstTokenSeconds == null
                      ? "—"
                      : `${row.totals.averageFirstTokenSeconds.toFixed(1)}s`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
