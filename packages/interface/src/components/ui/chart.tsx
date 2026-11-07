import {
  useId,
  type ComponentProps,
  type CSSProperties,
  type ReactNode,
} from "react";
import { ResponsiveContainer } from "recharts";
import { cn } from "@/lib/utils";

export type ChartConfig = Record<string, { label?: ReactNode; color: string }>;

// The host already resolves appearance and custom service colors. Expose the
// shadcn chart color tokens locally without a second theme or tooltip layer.
export function ChartContainer({
  id,
  config,
  className,
  style,
  children,
  ...props
}: ComponentProps<"div"> & {
  config: ChartConfig;
  children: ComponentProps<typeof ResponsiveContainer>["children"];
}) {
  const uniqueID = useId();
  const chartID = `chart-${id ?? uniqueID.replace(/:/g, "")}`;
  const colors = Object.fromEntries(
    Object.entries(config).map(([key, item]) => [`--color-${key}`, item.color]),
  ) as CSSProperties;

  return (
    <div
      data-slot="chart"
      data-chart={chartID}
      className={cn(
        "min-h-0 min-w-0 text-xs [&_.recharts-layer]:outline-none [&_.recharts-surface]:outline-none",
        className,
      )}
      style={{ ...colors, ...style }}
      {...props}
    >
      <ResponsiveContainer width="100%" height="100%" minWidth={0}>
        {children}
      </ResponsiveContainer>
    </div>
  );
}
