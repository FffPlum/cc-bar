import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { cn } from "@/lib/utils";
import "./chart-view-transition.css";

/** Crossfade two keyed chart layers, then activate only the latest choice. */
export function ChartViewTransition<View extends string>({
  view,
  className,
  children,
}: {
  view: View;
  className?: string;
  children: (displayedView: View, interactive: boolean) => ReactNode;
}) {
  const [display, setDisplay] = useState({ from: view, to: view });
  const [reduceMotion, setReduceMotion] = useState(
    () =>
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false,
  );
  const latestView = useRef(view);
  const layers = useRef(new Map<View, HTMLDivElement>());
  const transitioning = display.from !== display.to;

  useEffect(() => {
    const preference = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    if (!preference) return;
    const update = () => setReduceMotion(preference.matches);
    preference.addEventListener("change", update);
    return () => preference.removeEventListener("change", update);
  }, []);

  useLayoutEffect(() => {
    latestView.current = view;
    if (display.from === display.to && display.to !== view) {
      setDisplay({ from: display.to, to: view });
    }
  }, [view, display.from, display.to]);

  useLayoutEffect(() => {
    if (display.from === display.to) return;
    const outgoing = layers.current.get(display.from);
    const incoming = layers.current.get(display.to);
    if (!outgoing || !incoming) return;
    let cancelled = false;
    const complete = () => {
      if (cancelled) return;
      // If selection changed mid-flight, begin the next crossfade directly.
      // An obsolete target never becomes interactive between transitions.
      setDisplay((current) => ({ from: current.to, to: latestView.current }));
    };
    const duration = reduceMotion ? 120 : 240;
    if (!outgoing.animate || !incoming.animate) {
      // Older renderers still get the same visible transition through CSS.
      for (const element of [outgoing, incoming]) {
        element.style.setProperty(
          "--cc-chart-crossfade-duration",
          `${duration}ms`,
        );
        element.dataset.motionFallback = "";
      }
      const fallback = window.setTimeout(complete, duration);
      return () => {
        cancelled = true;
        window.clearTimeout(fallback);
        for (const element of [outgoing, incoming]) {
          delete element.dataset.motionFallback;
          element.style.removeProperty("--cc-chart-crossfade-duration");
        }
      };
    }

    // Opacity guarantees a visible fade while clipping advances left to right.
    // A linear sweep uses the full duration instead of finishing in a few frames.
    const exitFrames: Keyframe[] = reduceMotion
      ? [{ opacity: 1 }, { opacity: 0 }]
      : [
          { opacity: 1, clipPath: "inset(0 0 0 0)" },
          { opacity: 0, clipPath: "inset(0 0 0 100%)" },
        ];
    const enterFrames: Keyframe[] = reduceMotion
      ? [{ opacity: 0 }, { opacity: 1 }]
      : [
          { opacity: 0, clipPath: "inset(0 100% 0 0)" },
          { opacity: 1, clipPath: "inset(0 0 0 0)" },
        ];
    const options: KeyframeAnimationOptions = {
      duration,
      easing: "linear",
      fill: "both",
    };
    const animations = [
      outgoing.animate(exitFrames, options),
      incoming.animate(enterFrames, options),
    ];
    // Wait for both actual playbacks; no timer or empty stage separates them.
    void Promise.all(animations.map((animation) => animation.finished)).then(
      complete,
      () => {},
    );
    return () => {
      cancelled = true;
      for (const animation of animations) animation.cancel();
    };
  }, [display.from, display.to, reduceMotion]);

  const interactive = !transitioning && display.to === view;
  const visibleViews = transitioning
    ? [display.from, display.to]
    : [display.to];
  return (
    <div
      className={cn("cc-chart-view-transition", className)}
      data-slot="chart-view-transition"
      data-phase={transitioning ? "crossfade" : "idle"}
      aria-busy={!interactive}
    >
      {visibleViews.map((displayedView) => (
        <div
          key={displayedView}
          ref={(element) => {
            if (element) layers.current.set(displayedView, element);
            else layers.current.delete(displayedView);
          }}
          className="cc-chart-view-transition-content"
          data-view={displayedView}
          data-phase={
            !transitioning
              ? "idle"
              : displayedView === display.from
                ? "exit"
                : "enter"
          }
          inert={!interactive}
          aria-hidden={!interactive || undefined}
        >
          {children(displayedView, interactive)}
        </div>
      ))}
    </div>
  );
}
