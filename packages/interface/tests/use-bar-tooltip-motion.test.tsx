import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  useBarTooltipMotion,
  type BarTooltipMotion,
} from "@/components/use-bar-tooltip-motion";

interface MotionRecord {
  frames: Keyframe[];
  options: KeyframeAnimationOptions;
  visualTransform: string;
  cancel: ReturnType<typeof vi.fn>;
}

const animations: MotionRecord[] = [];
const mediaListeners = new Set<() => void>();
const originalComputedStyle = window.getComputedStyle.bind(window);
let media: {
  matches: boolean;
  addEventListener: ReturnType<typeof vi.fn>;
  removeEventListener: ReturnType<typeof vi.fn>;
};

beforeEach(() => {
  animations.length = 0;
  mediaListeners.clear();
  media = {
    matches: true,
    addEventListener: vi.fn((_type: string, listener: () => void) => {
      mediaListeners.add(listener);
    }),
    removeEventListener: vi.fn((_type: string, listener: () => void) => {
      mediaListeners.delete(listener);
    }),
  };
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => media),
  );
});

afterEach(() => {
  cleanup();
  document
    .querySelectorAll("[data-motion-test]")
    .forEach((node) => node.remove());
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function fixture({
  positioned = true,
  history: existingHistory,
}: {
  positioned?: boolean;
  history?: { current: BarTooltipMotion };
} = {}) {
  const plotBounds = { left: 50, top: 40, width: 800, height: 600 };
  const plot = document.createElement("div");
  plot.dataset.motionTest = "plot";
  plot.getBoundingClientRect = () =>
    new DOMRect(
      plotBounds.left,
      plotBounds.top,
      plotBounds.width,
      plotBounds.height,
    );
  const positioner = document.createElement("div");
  positioner.dataset.motionTest = "positioner";
  positioner.setAttribute("data-open", "");
  positioner.style.position = "fixed";
  positioner.style.left = "0px";
  positioner.style.top = "0px";
  positioner.style.transform = "translate(160px, 150px)";
  if (!positioned) positioner.style.opacity = "0";
  document.body.append(plot, positioner);

  let active: MotionRecord | undefined;
  const visualTransform = () =>
    active?.visualTransform ?? positioner.style.transform;
  positioner.getBoundingClientRect = () => {
    const transform = visualTransform();
    const values = transform.match(/-?\d+(?:\.\d+)?/g)?.map(Number) ?? [0, 0];
    const [x, y] = transform.startsWith("matrix") ? values.slice(4) : values;
    return new DOMRect(x ?? 0, y ?? 0, 260, 180);
  };
  vi.spyOn(window, "getComputedStyle").mockImplementation((element, pseudo) => {
    const style = originalComputedStyle(element, pseudo);
    return element === positioner
      ? ({ ...style, transform: visualTransform() } as CSSStyleDeclaration)
      : style;
  });
  const animate = vi.fn(
    (frames: Keyframe[], options: KeyframeAnimationOptions) => {
      const record: MotionRecord = {
        frames,
        options,
        visualTransform: String(frames[0]!.transform),
        cancel: vi.fn(() => {
          if (active === record) active = undefined;
        }),
      };
      active = record;
      animations.push(record);
      return { cancel: record.cancel } as unknown as Animation;
    },
  );
  positioner.animate = animate as typeof positioner.animate;
  const plotRef = { current: plot };
  const history = existingHistory ?? {
    current: { position: null } as BarTooltipMotion,
  };
  const mount = (animatePosition = true) =>
    renderHook(
      ({ node, hover }) =>
        useBarTooltipMotion(node, true, hover, plotRef, history),
      {
        initialProps: {
          node: positioner as HTMLElement | null,
          hover: animatePosition,
        },
      },
    );
  return { positioner, plotBounds, history, mount, animate };
}

async function mutate(change: () => void) {
  await act(async () => {
    change();
    await Promise.resolve();
  });
}

function changePreference(matches: boolean) {
  act(() => {
    media.matches = matches;
    for (const listener of mediaListeners) listener();
  });
}

it("waits for a measured visible destination, then enters from the farthest fitting corner", async () => {
  const { positioner, mount, animate } = fixture({ positioned: false });
  positioner.style.transition = "none";
  mount();
  expect(animate).not.toHaveBeenCalled();
  await mutate(() => {
    positioner.style.transform = "translate(180px, 170px)";
  });
  expect(animate).not.toHaveBeenCalled();
  await mutate(() => {
    positioner.style.removeProperty("opacity");
  });
  expect(animate).toHaveBeenCalledExactlyOnceWith(
    [
      { transform: "translate(590px, 460px)" },
      { transform: "translate(180px, 170px)" },
    ],
    { duration: 400, easing: "ease", fill: "both" },
  );
  await mutate(() => {
    positioner.style.visibility = "visible";
  });
  expect(animate).toHaveBeenCalledTimes(1);
});

it.each([
  { x: 160, y: 150, fromX: 590, fromY: 460 },
  { x: 500, y: 150, fromX: 50, fromY: 460 },
  { x: 160, y: 400, fromX: 590, fromY: 40 },
  { x: 500, y: 400, fromX: 50, fromY: 40 },
])(
  "enters from the opposite fitting corner for a destination at ($x, $y)",
  ({ x, y, fromX, fromY }) => {
    const { positioner, mount, animate } = fixture();
    positioner.style.transform = `translate(${x}px, ${y}px)`;
    mount();
    expect(animate).toHaveBeenCalledExactlyOnceWith(
      [
        { transform: `translate(${fromX}px, ${fromY}px)` },
        { transform: `translate(${x}px, ${y}px)` },
      ],
      { duration: 400, easing: "ease", fill: "both" },
    );
  },
);

it("keeps an oversized entrance card at the plot's leading edges", () => {
  const { plotBounds, mount, animate } = fixture();
  plotBounds.width = 200;
  plotBounds.height = 120;
  mount();
  expect(animate).toHaveBeenCalledExactlyOnceWith(
    [
      { transform: "translate(50px, 40px)" },
      { transform: "translate(160px, 150px)" },
    ],
    { duration: 400, easing: "ease", fill: "both" },
  );
});

it("retargets an interrupted flight from its computed visual transform", async () => {
  const { positioner, mount, animate } = fixture();
  mount();
  animations[0]!.visualTransform = "matrix(1, 0, 0, 1, 90, 80)";
  await mutate(() => {
    positioner.style.transform = "translate(260px, 190px)";
  });
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
  expect(animate).toHaveBeenLastCalledWith(
    [
      { transform: "matrix(1, 0, 0, 1, 90, 80)" },
      { transform: "translate(260px, 190px)" },
    ],
    { duration: 400, easing: "ease", fill: "both" },
  );
});

it("records the actual closing position before cancellation and resumes relative to a moved plot", async () => {
  const { positioner, history, mount, animate } = fixture();
  const first = mount();
  animations[0]!.visualTransform = "matrix(1, 0, 0, 1, 90, 80)";
  act(() => {
    history.current.hide?.();
    positioner.removeAttribute("data-open");
  });
  expect(history.current.position).toEqual({ x: 40, y: 40 });
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
  await mutate(() => {
    positioner.style.transform = "translate(999px, 999px)";
  });
  expect(animate).toHaveBeenCalledTimes(1);
  first.unmount();
  expect(history.current.position).toEqual({ x: 40, y: 40 });
  expect(history.current.hide).toBeUndefined();

  positioner.remove();
  const next = fixture({ history });
  next.plotBounds.left = 100;
  next.plotBounds.top = 70;
  next.positioner.style.transform = "translate(300px, 250px)";
  next.mount();
  expect(next.animate).toHaveBeenCalledExactlyOnceWith(
    [
      { transform: "translate(140px, 110px)" },
      { transform: "translate(300px, 250px)" },
    ],
    { duration: 400, easing: "ease", fill: "both" },
  );
});

it("also captures and cancels a flight when data-open is removed", async () => {
  const { positioner, history, mount, animate } = fixture();
  mount();
  animations[0]!.visualTransform = "matrix(1, 0, 0, 1, 125, 115)";
  await mutate(() => {
    positioner.removeAttribute("data-open");
  });
  expect(history.current.position).toEqual({ x: 75, y: 75 });
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
  await mutate(() => {
    positioner.style.transform = "translate(400px, 300px)";
  });
  expect(animate).toHaveBeenCalledTimes(1);
});

it("restarts from the saved visual position when the same positioner reopens", async () => {
  const { positioner, history, mount, animate } = fixture();
  mount();
  animations[0]!.visualTransform = "matrix(1, 0, 0, 1, 90, 80)";
  await mutate(() => {
    positioner.removeAttribute("data-open");
  });
  expect(history.current.position).toEqual({ x: 40, y: 40 });
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
  await mutate(() => {
    positioner.style.transform = "translate(260px, 190px)";
  });
  expect(history.current.position).toEqual({ x: 40, y: 40 });
  expect(animate).toHaveBeenCalledTimes(1);
  await mutate(() => {
    positioner.setAttribute("data-open", "");
  });
  expect(animate).toHaveBeenCalledTimes(2);
  expect(animate).toHaveBeenLastCalledWith(
    [
      { transform: "translate(90px, 80px)" },
      { transform: "translate(260px, 190px)" },
    ],
    { duration: 400, easing: "ease", fill: "both" },
  );
});

it.each(["keyboard", "reduced motion"])(
  "positions directly for %s",
  async (reason) => {
    const { positioner, history, mount, animate } = fixture();
    media.matches = reason !== "reduced motion";
    mount(reason !== "keyboard");
    expect(animate).not.toHaveBeenCalled();
    expect(positioner.getBoundingClientRect().left).toBe(160);
    await mutate(() => {
      positioner.style.transform = "translate(260px, 190px)";
    });
    expect(animate).not.toHaveBeenCalled();
    expect(positioner.getBoundingClientRect().top).toBe(190);
    act(() => history.current.hide?.());
    expect(history.current.position).toEqual({ x: 210, y: 150 });
  },
);

it("cancels an active flight immediately when reduced motion is enabled", async () => {
  const { positioner, mount, animate } = fixture();
  mount();
  animations[0]!.visualTransform = "matrix(1, 0, 0, 1, 90, 80)";
  changePreference(false);
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
  expect(positioner.getBoundingClientRect().left).toBe(160);
  expect(positioner.getBoundingClientRect().top).toBe(150);
  await mutate(() => {
    positioner.style.transform = "translate(260px, 190px)";
  });
  expect(animate).toHaveBeenCalledTimes(1);
  changePreference(true);
  await mutate(() => {
    positioner.style.transform = "translate(360px, 290px)";
  });
  expect(animations[1]!.frames[0]?.transform).toBe("translate(260px, 190px)");
});

it("switches an existing hover flight to immediate keyboard positioning", async () => {
  const { positioner, mount, animate } = fixture();
  const result = mount();
  animations[0]!.visualTransform = "matrix(1, 0, 0, 1, 90, 80)";
  result.rerender({ node: positioner, hover: false });
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
  expect(positioner.getBoundingClientRect().left).toBe(160);
  await mutate(() => {
    positioner.style.transform = "translate(260px, 190px)";
  });
  expect(animate).toHaveBeenCalledTimes(1);
});

it("cleans up observers, preference listeners and in-flight animation on unmount", async () => {
  const { positioner, history, mount, animate } = fixture();
  const result = mount();
  animations[0]!.visualTransform = "matrix(1, 0, 0, 1, 120, 100)";
  result.unmount();
  expect(history.current.position).toEqual({ x: 70, y: 60 });
  expect(history.current.hide).toBeUndefined();
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
  expect(mediaListeners.size).toBe(0);
  expect(media.removeEventListener).toHaveBeenCalledWith(
    "change",
    expect.any(Function),
  );
  await mutate(() => {
    positioner.style.transform = "translate(400px, 300px)";
  });
  changePreference(false);
  expect(animate).toHaveBeenCalledTimes(1);
  expect(animations[0]!.cancel).toHaveBeenCalledTimes(1);
});

it("does not replace stored history when closed before first positioning", () => {
  const { history, mount, animate } = fixture({ positioned: false });
  history.current.position = { x: 25, y: 35 };
  const result = mount();
  result.unmount();
  expect(animate).not.toHaveBeenCalled();
  expect(history.current.position).toEqual({ x: 25, y: 35 });
});
