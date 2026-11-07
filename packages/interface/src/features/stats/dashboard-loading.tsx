import { Skeleton } from "@/components/ui/skeleton";
import "./dashboard-heatmap.css";

export function LoadingBlock({ className }: { className: string }) {
  return (
    <Skeleton
      aria-hidden="true"
      className={`motion-reduce:animate-none ${className}`}
    />
  );
}

export function BackgroundLoadingBar() {
  return (
    <LoadingBlock className="pointer-events-none absolute inset-x-0 top-0 z-10 h-0.5 rounded-none" />
  );
}

export function ChartSkeleton({ heatmap = false }: { heatmap?: boolean }) {
  if (heatmap)
    return (
      <div
        aria-hidden="true"
        data-slot="heatmap-skeleton"
        className="min-w-0 space-y-3 p-4"
      >
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <LoadingBlock className="h-5 w-32" />
            <LoadingBlock className="h-5 w-56" />
          </div>
          <LoadingBlock className="h-8 w-48 rounded-lg" />
        </div>
        <div className="cc-token-chart-window">
          <div className="cc-token-chart-plot">
            <div className="grid h-full w-full min-w-0 grid-flow-col grid-rows-7 grid-cols-[repeat(53,minmax(0,1fr))] gap-[3px]">
              {Array.from({ length: 371 }, (_, index) => (
                <LoadingBlock
                  key={index}
                  className="aspect-square w-full min-w-0 max-h-4 rounded-[3px]"
                />
              ))}
            </div>
          </div>
          <div className="mt-1 flex h-5 min-w-0 justify-between">
            {[0, 1, 2, 3, 4, 5].map((index) => (
              <LoadingBlock key={index} className="h-2 w-5" />
            ))}
          </div>
        </div>
      </div>
    );
  return (
    <div aria-hidden="true" data-slot="chart-skeleton" className="p-4">
      <LoadingBlock className="h-5 w-32" />
      <div className="mt-4 flex gap-2">
        <div className="flex h-40 w-20 shrink-0 flex-col items-end justify-between">
          {[0, 1, 2].map((index) => (
            <LoadingBlock key={index} className="h-3 w-10" />
          ))}
        </div>
        <div className="min-w-[5rem] flex-1">
          <LoadingBlock className="h-40 rounded-none" />
          <div className="flex h-5 items-end justify-between">
            {[0, 1, 2, 3].map((index) => (
              <LoadingBlock key={index} className="h-3 w-10" />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

export function TableSkeleton({ columns }: { columns: number }) {
  return (
    <div
      aria-hidden="true"
      data-slot="table-skeleton"
      className="pointer-events-none absolute inset-x-0 bottom-0 top-9 z-10 grid grid-rows-4 gap-5 bg-background px-3 py-4"
    >
      {[0, 1, 2, 3].map((row) => (
        <div
          key={row}
          className="grid items-center gap-5"
          style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
        >
          {Array.from({ length: columns }, (_, column) => (
            <LoadingBlock key={column} className="h-3 w-4/5" />
          ))}
        </div>
      ))}
    </div>
  );
}
