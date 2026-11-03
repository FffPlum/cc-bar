import { act, cleanup, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { ChartViewTransition } from "@/components/chart-view-transition";

type View = "daily" | "weekly" | "rolling";
const animationDescriptor = Object.getOwnPropertyDescriptor(
  HTMLElement.prototype,
  "animate",
);
const animations: {
  element: HTMLElement;
  finish: () => void;
  cancel: ReturnType<typeof vi.fn>;
}[] = [];
const animate = vi.fn(function (this: HTMLElement) {
  let finish!: () => void;
  const finished = new Promise<void>((resolve) => {
    finish = resolve;
  });
  const cancel = vi.fn();
  animations.push({ element: this, finish, cancel });
  return { finished, cancel } as unknown as Animation;
});

const chart = (view: View) => (
  <ChartViewTransition view={view}>
    {(displayed, interactive) => (
      <button data-testid="chart" data-interactive={interactive}>
        {displayed}
      </button>
    )}
  </ChartViewTransition>
);

const phase = () =>
  document
    .querySelector('[data-slot="chart-view-transition"]')
    ?.getAttribute("data-phase");
const renderedViews = () =>
  screen.getAllByTestId("chart").map((element) => element.textContent);
const finish = async (...indices: number[]) => {
  await act(async () => {
    for (const index of indices) animations[index]!.finish();
  });
};

beforeEach(() => {
  vi.useFakeTimers();
  animations.length = 0;
  animate.mockClear();
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
  );
  Object.defineProperty(HTMLElement.prototype, "animate", {
    configurable: true,
    writable: true,
    value: animate,
  });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  if (animationDescriptor) {
    Object.defineProperty(
      HTMLElement.prototype,
      "animate",
      animationDescriptor,
    );
  } else {
    Reflect.deleteProperty(HTMLElement.prototype, "animate");
  }
  vi.useRealTimers();
});

it("starts exit and entry together and activates only the completed target", async () => {
  const result = render(chart("daily"));
  const daily = screen.getByRole("button", { name: "daily" });
  expect(animate).not.toHaveBeenCalled();
  result.rerender(chart("weekly"));
  expect(phase()).toBe("crossfade");
  expect(renderedViews()).toEqual(["daily", "weekly"]);
  expect(screen.getAllByTestId("chart")[0]).toBe(daily);
  const weekly = screen.getAllByTestId("chart")[1];
  expect(animations).toHaveLength(2);
  expect(animations[0]!.element.dataset.phase).toBe("exit");
  expect(animations[1]!.element.dataset.phase).toBe("enter");
  for (const item of screen.getAllByTestId("chart")) {
    expect(item.dataset.interactive).toBe("false");
    expect(item.parentElement!.hasAttribute("inert")).toBe(true);
  }
  expect(screen.queryByRole("button")).toBeNull();
  const exitFrames = [
    { opacity: 1, clipPath: "inset(0 0 0 0)" },
    { opacity: 0, clipPath: "inset(0 0 0 100%)" },
  ];
  const enterFrames = [
    { opacity: 0, clipPath: "inset(0 100% 0 0)" },
    { opacity: 1, clipPath: "inset(0 0 0 0)" },
  ];
  const options = {
    duration: 240,
    easing: "linear",
    fill: "both",
  };
  expect(animate).toHaveBeenNthCalledWith(1, exitFrames, options);
  expect(animate).toHaveBeenNthCalledWith(2, enterFrames, options);
  await finish(0);
  expect(phase()).toBe("crossfade");
  expect(screen.queryByRole("button")).toBeNull();
  await finish(1);
  expect(phase()).toBe("idle");
  expect(renderedViews()).toEqual(["weekly"]);
  expect(screen.getByRole("button", { name: "weekly" })).toBe(weekly);
  expect(vi.getTimerCount()).toBe(0);
});

it("coalesces rapid selections without activating the obsolete target or inserting a gap", async () => {
  const result = render(chart("daily"));
  result.rerender(chart("weekly"));
  const weekly = screen.getAllByTestId("chart")[1];
  result.rerender(chart("daily"));
  result.rerender(chart("rolling"));
  expect(animations).toHaveLength(2);
  await finish(0, 1);
  expect(phase()).toBe("crossfade");
  expect(renderedViews()).toEqual(["weekly", "rolling"]);
  expect(screen.getAllByTestId("chart")[0]).toBe(weekly);
  expect(animations).toHaveLength(4);
  expect(screen.queryByRole("button")).toBeNull();
  expect(vi.getTimerCount()).toBe(0);
  await finish(2, 3);
  expect(renderedViews()).toEqual(["rolling"]);
  expect(screen.getByRole("button", { name: "rolling" })).toBeTruthy();
});

it("retains distinct keyed layers when switching back to the outgoing view", async () => {
  const result = render(chart("daily"));
  const daily = screen.getByRole("button", { name: "daily" });
  result.rerender(chart("weekly"));
  result.rerender(chart("daily"));
  await finish(0, 1);
  expect(renderedViews()).toEqual(["weekly", "daily"]);
  expect(screen.getAllByTestId("chart")[1]).toBe(daily);
  expect(screen.queryByRole("button")).toBeNull();
  await finish(2, 3);
  expect(renderedViews()).toEqual(["daily"]);
  expect(screen.getByRole("button", { name: "daily" })).toBe(daily);
});

it("starts short opacity-only exit and entry together with reduced motion", async () => {
  vi.mocked(window.matchMedia).mockReturnValue({
    matches: true,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  } as unknown as MediaQueryList);
  const result = render(chart("daily"));
  result.rerender(chart("weekly"));
  expect(animations).toHaveLength(2);
  expect(animate).toHaveBeenNthCalledWith(1, [{ opacity: 1 }, { opacity: 0 }], {
    duration: 120,
    easing: "linear",
    fill: "both",
  });
  expect(animate).toHaveBeenNthCalledWith(2, [{ opacity: 0 }, { opacity: 1 }], {
    duration: 120,
    easing: "linear",
    fill: "both",
  });
  await finish(0, 1);
  expect(screen.getByRole("button", { name: "weekly" })).toBeTruthy();
});

it("cancels both animations on unmount and ignores their late completion", async () => {
  const result = render(chart("daily"));
  result.rerender(chart("weekly"));
  result.unmount();
  expect(animations).toHaveLength(2);
  for (const animation of animations)
    expect(animation.cancel).toHaveBeenCalled();
  await finish(0, 1);
  expect(animate).toHaveBeenCalledTimes(2);
  expect(vi.getTimerCount()).toBe(0);
});

it("uses and cleans up CSS motion when Web Animations are unavailable", () => {
  Object.defineProperty(HTMLElement.prototype, "animate", { value: undefined });
  const result = render(chart("daily"));
  result.rerender(chart("weekly"));
  expect(renderedViews()).toEqual(["daily", "weekly"]);
  const layers = Array.from(
    result.container.querySelectorAll<HTMLElement>(
      ".cc-chart-view-transition-content",
    ),
  );
  for (const layer of layers) {
    expect(layer.hasAttribute("data-motion-fallback")).toBe(true);
    expect(layer.style.getPropertyValue("--cc-chart-crossfade-duration")).toBe(
      "240ms",
    );
  }
  act(() => vi.advanceTimersByTime(239));
  expect(renderedViews()).toEqual(["daily", "weekly"]);
  act(() => vi.advanceTimersByTime(1));
  expect(renderedViews()).toEqual(["weekly"]);
  expect(layers[1]!.hasAttribute("data-motion-fallback")).toBe(false);
  expect(screen.getByRole("button", { name: "weekly" })).toBeTruthy();
  result.unmount();
  expect(vi.getTimerCount()).toBe(0);
});
