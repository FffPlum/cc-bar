import { useLayoutEffect, type RefObject } from "react";

export interface BarTooltipMotion {
  // Keep the entrance origin across portal unmounts, relative to the plot.
  position: { x: number; y: number } | null;
  hide?: () => void;
}

export function useBarTooltipMotion(
  positioner: HTMLElement | null,
  enabled: boolean,
  animatePosition: boolean,
  plotRef: RefObject<HTMLElement | null> | undefined,
  history: RefObject<BarTooltipMotion> | undefined,
) {
  useLayoutEffect(() => {
    if (!enabled || !positioner || !history) return;
    const ownerWindow = positioner.ownerDocument.defaultView;
    if (!ownerWindow) return;
    const preference = ownerWindow.matchMedia(
      "(hover: hover) and (pointer: fine) and (prefers-reduced-motion: no-preference)",
    );
    let animation: Animation | undefined;
    let target: string | undefined;

    const hide = () => {
      const plot = plotRef?.current?.getBoundingClientRect();
      if (target && plot && positioner.style.opacity !== "0") {
        // Read before cancelling: an interrupted flight may not reach its target.
        const current = positioner.getBoundingClientRect();
        history.current.position = {
          x: current.left - plot.left,
          y: current.top - plot.top,
        };
      }
      animation?.cancel();
      animation = undefined;
      target = undefined;
    };
    history.current.hide = hide;

    const update = () => {
      if (!positioner.hasAttribute("data-open")) {
        hide();
        return;
      }
      const next = positioner.style.transform;
      // Base UI first mounts an invisible, unpositioned wrapper. Wait for its
      // measured destination; WAAPI then bypasses its mount transition:none.
      if (positioner.style.opacity === "0" || !next || next === target) return;
      const plot = plotRef?.current?.getBoundingClientRect();
      const canAnimate =
        animatePosition &&
        preference.matches &&
        typeof positioner.animate === "function" &&
        plot;
      if (canAnimate) {
        let from = animation
          ? ownerWindow.getComputedStyle(positioner).transform
          : target;
        if (!from) {
          const saved = history.current.position;
          const destination = positioner.getBoundingClientRect();
          // Choose the farthest corner that can hold the whole card. If the
          // card exceeds the plot on an axis, keep that axis at its leading edge.
          const maxX = Math.max(0, plot.width - destination.width);
          const maxY = Math.max(0, plot.height - destination.height);
          const x =
            saved?.x ?? (destination.left - plot.left < maxX / 2 ? maxX : 0);
          const y =
            saved?.y ?? (destination.top - plot.top < maxY / 2 ? maxY : 0);
          const left = parseFloat(positioner.style.left) || 0;
          const top = parseFloat(positioner.style.top) || 0;
          from = `translate(${plot.left + x - left}px, ${plot.top + y - top}px)`;
        }
        // Keep the finished fill until the next move so the inline destination
        // cannot jump ahead of the current visual position before this callback.
        animation?.cancel();
        animation = positioner.animate(
          [{ transform: from }, { transform: next }],
          { duration: 400, easing: "ease", fill: "both" },
        );
      } else {
        animation?.cancel();
        animation = undefined;
      }
      target = next;
    };
    const preferenceChanged = () => {
      // Changing the accessibility preference takes effect during a flight too.
      animation?.cancel();
      animation = undefined;
    };
    const observer = new MutationObserver(update);
    observer.observe(positioner, {
      attributes: true,
      attributeFilter: ["style", "data-open"],
    });
    preference.addEventListener("change", preferenceChanged);
    update();
    return () => {
      observer.disconnect();
      preference.removeEventListener("change", preferenceChanged);
      hide();
      if (history.current.hide === hide) history.current.hide = undefined;
    };
  }, [positioner, enabled, animatePosition, plotRef, history]);
}
