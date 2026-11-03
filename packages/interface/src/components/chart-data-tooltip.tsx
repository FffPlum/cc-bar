import { Tooltip as TooltipPrimitive } from "@base-ui/react/tooltip";
import { cn } from "@/lib/utils";

// Match shadcn ChartTooltipContent's surface while keeping our DOM chart content.
// Base UI supplies cursor tracking, keyboard focus, portals and edge avoidance.
export function ChartDataTooltip(props: TooltipPrimitive.Root.Props) {
  return (
    <TooltipPrimitive.Root
      trackCursorAxis="y"
      disableHoverablePopup
      {...props}
    />
  );
}

export const ChartDataTooltipTrigger = TooltipPrimitive.Trigger;

export function ChartDataTooltipContent({
  className,
  children,
  ...props
}: TooltipPrimitive.Popup.Props) {
  return (
    <TooltipPrimitive.Portal>
      <TooltipPrimitive.Positioner
        positionMethod="fixed"
        side="right"
        align="start"
        // Snap to the column/cell center rather than its full-width hit area's edge.
        sideOffset={({ anchor }) => 10 - anchor.width / 2}
        collisionPadding={8}
        className="pointer-events-none isolate z-50"
      >
        <TooltipPrimitive.Popup
          data-slot="chart-data-tooltip"
          className={cn(
            "pointer-events-none grid min-w-[8rem] max-w-[calc(100vw-16px)] items-start gap-1.5 rounded-lg border border-border/50 bg-background px-2.5 py-1.5 text-xs text-foreground shadow-xl",
            className,
          )}
          {...props}
        >
          {children}
        </TooltipPrimitive.Popup>
      </TooltipPrimitive.Positioner>
    </TooltipPrimitive.Portal>
  );
}
