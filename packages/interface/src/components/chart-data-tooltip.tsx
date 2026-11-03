import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useState,
} from "react";
import { Tooltip as TooltipPrimitive } from "@base-ui/react/tooltip";
import { cn } from "@/lib/utils";

interface HoverAnchor {
  element: Element;
  x: number;
  y: number;
}

const ChartTooltipPositionContext = createContext<{
  animatePosition: boolean;
  followCursor: boolean;
  placement: "cursor" | "cell";
  protectedElement?: Element;
  anchor?: TooltipPrimitive.Positioner.Props["anchor"];
}>({ animatePosition: false, followCursor: true, placement: "cursor" });

// Match shadcn ChartTooltipContent's surface while keeping our DOM chart content.
// Base UI supplies keyboard focus, portals and edge avoidance.
export function ChartDataTooltip<Payload>({
  onOpenChange,
  trackCursorAxis = "both",
  placement = "cursor",
  ...props
}: TooltipPrimitive.Root.Props<Payload> & { placement?: "cursor" | "cell" }) {
  const [hover, setHover] = useState<HoverAnchor | null>(null);
  const element = hover?.element;
  useEffect(() => {
    if (!element || trackCursorAxis === "none") return;
    const ownerWindow = element.ownerDocument.defaultView;
    const followPointer = (event: MouseEvent) => {
      setHover((current) =>
        !current || (current.x === event.clientX && current.y === event.clientY)
          ? current
          : { ...current, x: event.clientX, y: event.clientY },
      );
    };
    ownerWindow?.addEventListener("mousemove", followPointer);
    return () => ownerWindow?.removeEventListener("mousemove", followPointer);
  }, [element, trackCursorAxis]);

  const position = useMemo(
    () => ({
      // Retarget the shared card's transition during hover, including side changes.
      // Keyboard focus continues to position immediately.
      animatePosition: hover !== null,
      followCursor: trackCursorAxis !== "none",
      placement,
      protectedElement: placement === "cell" ? hover?.element : undefined,
      // Commit the new trigger and pointer together. Base UI's cursor tracker can
      // otherwise retain the previous column until the next mousemove.
      anchor:
        hover && trackCursorAxis !== "none"
          ? {
              contextElement: hover.element,
              getBoundingClientRect() {
                const rect = hover.element.getBoundingClientRect();
                const trackX =
                  trackCursorAxis === "x" || trackCursorAxis === "both";
                const trackY =
                  placement !== "cell" &&
                  (trackCursorAxis === "y" || trackCursorAxis === "both");
                const x = trackX ? hover.x : rect.x;
                const y = trackY ? hover.y : rect.y;
                const width = trackX ? 0 : rect.width;
                const height = trackY ? 0 : rect.height;
                return {
                  x,
                  y,
                  width,
                  height,
                  top: y,
                  left: x,
                  right: x + width,
                  bottom: y + height,
                };
              },
            }
          : undefined,
    }),
    [hover, trackCursorAxis, placement],
  );
  return (
    <ChartTooltipPositionContext.Provider value={position}>
      <TooltipPrimitive.Root
        trackCursorAxis="none"
        disableHoverablePopup
        {...props}
        onOpenChange={(open, details) => {
          onOpenChange?.(open, details);
          if (!details.isCanceled) {
            setHover(
              open && details.reason === "trigger-hover" && details.trigger
                ? {
                    element: details.trigger,
                    x: details.event.clientX,
                    y: details.event.clientY,
                  }
                : null,
            );
          }
        }}
      />
    </ChartTooltipPositionContext.Provider>
  );
}

export const createChartDataTooltipHandle = TooltipPrimitive.createHandle;
export const ChartDataTooltipTrigger = TooltipPrimitive.Trigger;

export function ChartDataTooltipContent({
  className,
  children,
  ...props
}: TooltipPrimitive.Popup.Props) {
  const { animatePosition, followCursor, placement, protectedElement, anchor } =
    useContext(ChartTooltipPositionContext);
  const [positioner, setPositioner] = useState<HTMLDivElement | null>(null);
  useLayoutEffect(() => {
    if (!positioner || !protectedElement) return;
    let previousTransform = "";
    const avoidCellDuringMotion = () => {
      const transform = positioner.style.transform;
      if (!transform || transform === previousTransform) return;
      previousTransform = transform;
      // Base UI avoids the cell at the destination. Also check the animation's
      // swept bounds so a cross-row move or side flip cannot pass over it.
      if (typeof DOMMatrixReadOnly === "undefined") {
        positioner.style.setProperty("--cc-chart-tooltip-transition", "none");
        return;
      }
      const matrix = new DOMMatrixReadOnly(transform);
      const current = positioner.getBoundingClientRect();
      const cell = protectedElement.getBoundingClientRect();
      const left = (parseFloat(positioner.style.left) || 0) + matrix.m41;
      const top = (parseFloat(positioner.style.top) || 0) + matrix.m42;
      const crossesCell =
        Math.min(current.left, left) < cell.right + 4 &&
        Math.max(current.right, left + current.width) > cell.left - 4 &&
        Math.min(current.top, top) < cell.bottom + 4 &&
        Math.max(current.bottom, top + current.height) > cell.top - 4;
      if (crossesCell) {
        positioner.style.setProperty("--cc-chart-tooltip-transition", "none");
      } else {
        positioner.style.removeProperty("--cc-chart-tooltip-transition");
      }
    };
    avoidCellDuringMotion();
    const observer = new MutationObserver(avoidCellDuringMotion);
    observer.observe(positioner, { attributes: true, attributeFilter: ["style"] });
    return () => {
      observer.disconnect();
      positioner.style.removeProperty("--cc-chart-tooltip-transition");
    };
  }, [positioner, protectedElement, anchor]);
  return (
    <TooltipPrimitive.Portal>
      <TooltipPrimitive.Positioner
        ref={setPositioner}
        data-slot="chart-data-tooltip-positioner"
        data-animated={animatePosition ? "" : undefined}
        anchor={anchor}
        positionMethod="fixed"
        side={placement === "cell" ? "bottom" : "right"}
        align={placement === "cell" ? "center" : "start"}
        sideOffset={
          placement === "cell" || followCursor
            ? 12
            : ({ anchor }) => 10 - anchor.width / 2
        }
        collisionPadding={8}
        // Cells retain their full height: flipping above/below cannot cover them.
        collisionAvoidance={{
          side: placement === "cell" || followCursor ? "flip" : "shift",
          align: "shift",
          fallbackAxisSide: "none",
        }}
        // One persistent wrapper preserves 400ms ease motion across data points.
        className="cc-chart-tooltip-positioner pointer-events-none isolate z-50"
      >
        <TooltipPrimitive.Popup
          data-slot="chart-data-tooltip"
          className={cn(
            "pointer-events-none grid min-w-[8rem] max-w-[calc(100vw-16px)] items-start gap-1.5 rounded-lg border border-border/50 bg-background px-2.5 py-1.5 text-xs text-foreground shadow-xl",
            followCursor &&
              "min-w-0 max-w-[min(calc(100vw-16px),var(--available-width))]",
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
