import { useEffect, useMemo, useState } from "react";
import type { ProjectDetail, StatsQuery } from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import {
  createDataTableColumnHelper,
  DataTable,
} from "@/components/ui/data-table";
import { SlidingTabsList } from "@/components/sliding-tabs-list";
import { Tabs, TabsContent } from "@/components/ui/tabs";
import { ServiceIcon, ServiceMark } from "@/components/service-icon";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import {
  brandColor,
  formatInteger,
  formatPercent,
  formatTokensCompact,
  rankColor,
  serviceDisplayName,
} from "@/lib/display";
import {
  projectUsageShareRows,
  type ProjectShareDimension,
  type ProjectShareRow,
} from "./project-usage-share-data";

const columnHelper = createDataTableColumnHelper<ProjectShareRow>();
const rowId = (row: ProjectShareRow) => row.id;

export function ProjectUsageShare({
  detail,
  query,
}: {
  detail: ProjectDetail;
  query: StatsQuery;
}) {
  const { settings, bootstrap } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  const dark = bootstrap.appearance === "dark";
  const metric = settings.appearance.statsRankMetric;
  const [dimension, setDimension] = useState<ProjectShareDimension>("service");
  const [showAll, setShowAll] = useState(false);
  const [hovered, setHovered] = useState<{ scope: string; id: string } | null>(
    null,
  );
  const scope = JSON.stringify([
    detail.project.key,
    dimension,
    metric,
    query.range,
    query.granularity,
    query.customFrom,
    query.customTo,
    query.service,
  ]);
  const rows = useMemo(
    () => projectUsageShareRows(detail, dimension, metric),
    [detail, dimension, metric],
  );
  const colors = useMemo(
    () =>
      new Map(
        rows.map((row, index) => [
          row.id,
          row.service
            ? brandColor(row.service, settings, dark)
            : rankColor(index, dark),
        ]),
      ),
    [rows, settings, dark],
  );
  const visibleRows = useMemo(
    () => (dimension === "service" || showAll ? rows : rows.slice(0, 5)),
    [dimension, showAll, rows],
  );
  useEffect(() => {
    setHovered(null);
    setShowAll(false);
  }, [scope]);
  useEffect(() => {
    setHovered((current) =>
      current && visibleRows.some((row) => row.id === current.id)
        ? current
        : null,
    );
  }, [visibleRows]);

  const positiveRows = rows.filter((row) => row.share > 0);
  const shareTotal = positiveRows.reduce((sum, row) => sum + row.share, 0);
  const activeId =
    hovered?.scope === scope &&
    visibleRows.some((row) => row.id === hovered.id) &&
    positiveRows.some((row) => row.id === hovered.id)
      ? hovered.id
      : null;
  const title = t("Usage share", "用量占比");
  const applicationLabel = t("Application", "应用");
  const modelLabel = t("Model", "模型");
  const branchLabel = t("Branch", "分支");
  const nameLabel =
    dimension === "service"
      ? applicationLabel
      : dimension === "model"
        ? modelLabel
        : branchLabel;
  const costLabel = t("Cost", "费用");
  const conversationLabel = t("Conversations", "对话数");
  const shareLabel =
    metric === "tokens"
      ? t("Token share", "Token 占比")
      : t("Cost share", "费用占比");
  const missingBranchLabel = t("(no branch info)", "（无分支信息）");
  const columns = useMemo(
    () =>
      columnHelper.columns([
        columnHelper.accessor("title", {
          id: "name",
          header: nameLabel,
          cell: ({ row }) => {
            const item = row.original;
            const name =
              item.title || (dimension === "branch" ? missingBranchLabel : "—");
            return (
              <span className="flex min-w-0 items-center gap-1.5">
                {item.service ? (
                  <ServiceIcon
                    name={name}
                    color={colors.get(item.id)!}
                    size={12}
                  />
                ) : (
                  <ServiceMark color={colors.get(item.id)!} />
                )}
                <span
                  className={`block max-w-60 truncate ${dimension === "service" ? "" : "font-mono"}`}
                  title={name}
                >
                  {name}
                </span>
              </span>
            );
          },
        }),
        ...(dimension === "model"
          ? [
              columnHelper.accessor("services", {
                id: "services",
                header: applicationLabel,
                cell: ({ getValue }) => (
                  <span className="text-muted-foreground">
                    {getValue().map(serviceDisplayName).join(" · ")}
                  </span>
                ),
              }),
            ]
          : []),
        ...(dimension === "branch"
          ? [
              columnHelper.accessor("conversationCount", {
                id: "conversations",
                header: () => (
                  <div className="text-right">{conversationLabel}</div>
                ),
                cell: ({ getValue }) => (
                  <div className="cc-number text-right">
                    {formatInteger(getValue() ?? 0, language)}
                  </div>
                ),
              }),
            ]
          : []),
        columnHelper.accessor((row) => row.totals.totalTokens, {
          id: "tokens",
          header: () => <div className="text-right">Tokens</div>,
          cell: ({ getValue }) => (
            <div className="cc-number text-right">
              {formatTokensCompact(getValue())}
            </div>
          ),
        }),
        columnHelper.accessor((row) => row.totals.costDisplay, {
          id: "cost",
          header: () => <div className="text-right">{costLabel}</div>,
          cell: ({ getValue }) => (
            <div className="cc-number text-right">{getValue()}</div>
          ),
        }),
        columnHelper.accessor("share", {
          id: "share",
          header: () => <div className="text-right">{shareLabel}</div>,
          cell: ({ getValue }) => (
            <div className="cc-number text-right text-muted-foreground">
              {formatPercent(getValue())}
            </div>
          ),
        }),
      ]),
    [
      nameLabel,
      dimension,
      missingBranchLabel,
      colors,
      applicationLabel,
      conversationLabel,
      language,
      costLabel,
      shareLabel,
    ],
  );

  return (
    <Tabs
      render={<section />}
      value={dimension}
      onValueChange={(value) => {
        if (value !== "service" && value !== "model" && value !== "branch")
          return;
        setHovered(null);
        setShowAll(false);
        setDimension(value);
      }}
      className="min-w-0 gap-3"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-[13px] font-semibold">{title}</h3>
        <SlidingTabsList
          ariaLabel={t("Usage share dimension", "用量占比维度")}
          options={[
            { value: "service", label: applicationLabel },
            { value: "model", label: modelLabel },
            { value: "branch", label: branchLabel },
          ]}
        />
      </div>
      <TabsContent value={dimension} className="flex flex-col gap-3">
        <div
          role="img"
          aria-label={
            positiveRows.length
              ? `${shareLabel}: ${positiveRows.map((row) => `${row.title || missingBranchLabel} ${formatPercent(row.share)}`).join("; ")}`
              : t("No usage share data", "暂无占比数据")
          }
          className={`flex h-2 gap-0.5 ${positiveRows.length ? "" : "rounded-sm bg-secondary"}`}
        >
          {positiveRows.map((row) => (
            <span
              key={row.id}
              data-slot="project-share-segment"
              data-row-id={row.id}
              data-state={activeId === row.id ? "highlighted" : "normal"}
              className="cc-composition-segment"
              style={{
                flex: row.share / shareTotal,
                minWidth: 0,
                backgroundColor: colors.get(row.id),
                color: colors.get(row.id),
              }}
            />
          ))}
        </div>
        <DataTable
          stickyFirstColumn
          columns={columns}
          data={visibleRows}
          getRowId={rowId}
          ariaLabel={`${title} · ${nameLabel}`}
          emptyMessage={t("No data", "暂无数据")}
          tableClassName="text-[11.5px] [&_th]:h-8 [&_th]:text-[10.5px] [&_td]:py-1.5"
          getRowProps={(row) => ({
            onMouseEnter: () => setHovered({ scope, id: row.id }),
            onMouseLeave: () =>
              setHovered((current) => (current?.id === row.id ? null : current)),
          })}
        />
        {dimension !== "service" && rows.length > 5 && (
          <Button
            variant="link"
            size="sm"
            className="h-auto self-start p-0 text-[11px]"
            onClick={() => {
              setHovered(null);
              setShowAll(!showAll);
            }}
          >
            {showAll
              ? t("Show less", "收起")
              : dimension === "model"
                ? t(
                    `Show all ${rows.length} models`,
                    `显示全部 ${rows.length} 个模型`,
                  )
                : t(
                    `Show all ${rows.length} branches`,
                    `显示全部 ${rows.length} 个分支`,
                  )}
          </Button>
        )}
      </TabsContent>
    </Tabs>
  );
}
