import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ServiceMark } from "@/components/service-icon";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { useTranslation } from "@/lib/i18n";

export interface ChartSeries {
  id: string;
  name: string;
  color: string;
}
export interface ChartColumn {
  key: string;
  label: string;
  total: number;
  totalLabel: string;
  tooltipTitle?: string;
  tooltipTotal?: string;
  tooltipTokens?: string;
  segments: readonly { seriesID: string; value: number; label: string }[];
  highlighted?: boolean;
  tooltip?: ReactNode;
}

export function chartTickIndices(
  columnCount: number,
  containerWidth: number,
): Set<number> {
  const capacity = Math.max(1, Math.min(8, Math.floor(containerWidth / 80)));
  const count = Math.min(columnCount, capacity);
  if (count < 1) return new Set();
  if (count === 1) return new Set([0]);
  return new Set(
    Array.from({ length: count }, (_, index) =>
      Math.round((index * (columnCount - 1)) / (count - 1)),
    ),
  );
}

export function chartBarWidth(count: number): number {
  return count <= 3 ? 28 : count <= 14 ? 18 : count <= 45 ? 10 : 5;
}

export function StackedBarChart({
  columns,
  series,
  height = 180,
  barWidth,
}: {
  columns: readonly ChartColumn[];
  series: readonly ChartSeries[];
  height?: number;
  barWidth?: number;
}) {
  const t = useTranslation();
  const [selected, setSelected] = useState<string | null>(null);
  const container = useRef<HTMLDivElement>(null);
  const [containerWidth, setContainerWidth] = useState(480);
  const empty = columns.length === 0;
  useEffect(() => {
    const element = container.current;
    if (!element) return;
    const update = (width: number) => {
      if (width > 0) setContainerWidth(width);
    };
    update(element.getBoundingClientRect().width);
    const observer = new ResizeObserver((entries) => {
      if (entries[0]) update(entries[0].contentRect.width);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [empty]);
  const ticks = chartTickIndices(columns.length, containerWidth);
  const max = useMemo(
    () => Math.max(1, ...columns.map((column) => column.total)),
    [columns],
  );
  if (columns.length === 0)
    return (
      <div
        className="flex items-center justify-center text-[12px] text-muted-foreground"
        style={{ height }}
      >
        {t("No data", "无数据")}
      </div>
    );
  const width = barWidth ?? chartBarWidth(columns.length);
  return (
    <div
      ref={container}
      data-slot="usage-chart"
      className="flex items-end justify-around overflow-hidden px-1 pt-2"
      style={{ height }}
      onMouseLeave={() => setSelected(null)}
    >
      {columns.map((column, index) => (
        <Tooltip key={column.key}>
          <TooltipTrigger
            render={
              <button
                type="button"
                className="relative flex h-full min-w-0 flex-1 flex-col pb-6 outline-offset-0"
                style={{
                  maxWidth: width + 12,
                  opacity:
                    selected !== null
                      ? selected === column.key
                        ? 1
                        : 0.35
                      : column.highlighted === false
                        ? 0.35
                        : 1,
                }}
                onMouseEnter={() => setSelected(column.key)}
                onFocus={() => setSelected(column.key)}
                onBlur={() => setSelected(null)}
                aria-label={`${column.label}: ${column.totalLabel}`}
              />
            }
          >
            <span className="flex h-full w-full flex-col items-center justify-end">
              <span
                className="flex max-w-full flex-col-reverse overflow-hidden rounded-[2px]"
                style={{
                  width,
                  height: `${Math.max(column.total > 0 ? 2 : 0, (column.total / max) * 100)}%`,
                }}
              >
                {column.segments.map((segment) => (
                  <span
                    key={segment.seriesID}
                    className="w-full shrink-0"
                    style={{
                      height: `${column.total > 0 ? (segment.value / column.total) * 100 : 0}%`,
                      backgroundColor:
                        series.find((item) => item.id === segment.seriesID)
                          ?.color ?? "#8e8e93",
                    }}
                    aria-hidden="true"
                  />
                ))}
              </span>
            </span>
            {ticks.has(index) && (
              <span
                data-slot="chart-tick"
                aria-hidden="true"
                className={`cc-tertiary cc-number pointer-events-none absolute bottom-0 w-20 whitespace-nowrap text-[9px] ${index === 0 ? "left-0 text-left" : index === columns.length - 1 ? "right-0 text-right" : "left-1/2 -translate-x-1/2 text-center"}`}
              >
                {column.label}
              </span>
            )}
          </TooltipTrigger>
          <TooltipContent
            className="block w-[200px] border bg-popover p-3 text-left text-[11px] text-popover-foreground shadow-md"
            side="top"
          >
            <span className="mb-2 block font-semibold">
              {column.tooltipTitle ?? column.label}
            </span>
            {column.segments.map((segment) => (
              <span
                key={segment.seriesID}
                className="flex items-center gap-2 py-0.5"
              >
                <ServiceMark
                  color={
                    series.find((item) => item.id === segment.seriesID)
                      ?.color ?? "#8e8e93"
                  }
                />
                <span
                  className="min-w-0 flex-1 truncate"
                  title={
                    series.find((item) => item.id === segment.seriesID)?.name ??
                    segment.seriesID
                  }
                >
                  {series.find((item) => item.id === segment.seriesID)?.name ??
                    segment.seriesID}
                </span>
                <span className="cc-number whitespace-nowrap font-medium">
                  {segment.label}
                </span>
              </span>
            ))}
            <span className="my-1.5 block border-t" />
            <span className="flex items-center justify-between gap-3 font-semibold">
              <span>{t("Total", "合计")}</span>
              <span className="cc-number whitespace-nowrap">
                {column.tooltipTotal ?? column.totalLabel}
              </span>
            </span>
            {column.tooltipTokens && (
              <>
                <span className="flex justify-between gap-3 font-semibold">
                  <span>Tokens</span>
                  <span className="cc-number whitespace-nowrap">
                    {column.tooltipTokens}
                  </span>
                </span>
                <span className="my-1.5 block border-t" />
              </>
            )}
            {column.tooltip}
          </TooltipContent>
        </Tooltip>
      ))}
    </div>
  );
}

export function ChartLegend({ series }: { series: readonly ChartSeries[] }) {
  return (
    <div className="flex flex-wrap items-center justify-end gap-x-2 gap-y-1">
      {series.map((item) => (
        <span
          key={item.id}
          className="flex items-center gap-1 text-[10.5px] text-muted-foreground"
        >
          <ServiceMark color={item.color} />
          {item.name}
        </span>
      ))}
    </div>
  );
}
