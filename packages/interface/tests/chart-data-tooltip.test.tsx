import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import {
  ChartDataTooltip,
  ChartDataTooltipContent,
  ChartDataTooltipTrigger,
  createChartDataTooltipHandle,
} from "@/components/chart-data-tooltip";
import { TooltipProvider } from "@/components/ui/tooltip";

afterEach(() => vi.restoreAllMocks());

const setup = (
  left = 100,
  top = 80,
  placement: "cursor" | "cell" = "cursor",
) => {
  const rectangle = (x: number, y: number, width: number, height: number) =>
    ({
      x,
      y,
      width,
      height,
      top: y,
      left: x,
      right: x + width,
      bottom: y + height,
      toJSON: () => ({}),
    }) as DOMRect;
  const isCard = (element: HTMLElement) =>
    element.dataset.slot === "chart-data-tooltip" ||
    element.firstElementChild?.getAttribute("data-slot") ===
      "chart-data-tooltip";
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(
    function (this: HTMLElement) {
      if (this.dataset.testid === "column")
        return rectangle(left, top, 100, 160);
      if (this.dataset.testid === "next-column")
        return rectangle(left + 100, top, 100, 160);
      return isCard(this) ? rectangle(0, 0, 260, 180) : rectangle(0, 0, 0, 0);
    },
  );
  vi.spyOn(HTMLElement.prototype, "offsetWidth", "get").mockImplementation(
    function (this: HTMLElement) {
      return isCard(this) ? 260 : 0;
    },
  );
  vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockImplementation(
    function (this: HTMLElement) {
      return isCard(this) ? 180 : 0;
    },
  );
  vi.spyOn(document.documentElement, "clientWidth", "get").mockReturnValue(
    1024,
  );
  vi.spyOn(document.documentElement, "clientHeight", "get").mockReturnValue(
    768,
  );
  const handle = createChartDataTooltipHandle<string>();
  render(
    <TooltipProvider>
      <ChartDataTooltipTrigger
        handle={handle}
        payload="Existing details"
        render={<button data-testid="column">Column</button>}
      />
      <ChartDataTooltipTrigger
        handle={handle}
        payload="Next details"
        render={<button data-testid="next-column">Next column</button>}
      />
      <ChartDataTooltip handle={handle} placement={placement}>
        {({ payload }) => (
          <ChartDataTooltipContent className="w-[260px]">
            <strong>Existing heading</strong>
            <span>{payload}</span>
          </ChartDataTooltipContent>
        )}
      </ChartDataTooltip>
    </TooltipProvider>,
  );
  return screen.getByRole("button", { name: "Column" });
};

it.each([
  { top: 80, pointerY: 140, side: "bottom", cardTop: 252 },
  { top: 500, pointerY: 580, side: "top", cardTop: 308 },
])(
  "places a cell card on the $side without covering its cell",
  async ({ top, pointerY, side, cardTop }) => {
    const trigger = setup(300, top, "cell");
    fireEvent.mouseEnter(trigger, { clientX: 350, clientY: pointerY });
    const positioner = (await screen.findByText("Existing details"))
      .parentElement!.parentElement!;
    await waitFor(() =>
      expect(positioner.style.transform).toBe(`translate(220px, ${cardTop}px)`),
    );
    expect(positioner.getAttribute("data-side")).toBe(side);
    expect(cardTop >= top + 160 + 12 || cardTop + 180 <= top - 12).toBe(true);
    fireEvent.mouseMove(trigger, { clientX: 380, clientY: pointerY });
    await waitFor(() =>
      expect(positioner.style.transform).toBe(`translate(250px, ${cardTop}px)`),
    );
  },
);

it("follows the pointer on both axes with a 12px gap", async () => {
  const trigger = setup();
  fireEvent.mouseMove(trigger, { clientX: 120, clientY: 140 });
  fireEvent.mouseEnter(trigger, { clientX: 120, clientY: 140 });
  const details = await screen.findByText("Existing details");
  const positioner = details.parentElement!.parentElement!;
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(132px, 140px)"),
  );
  fireEvent.mouseMove(trigger, { clientX: 180, clientY: 200 });
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(192px, 200px)"),
  );
  expect(positioner.style.position).toBe("fixed");
  expect(details.parentElement!.querySelector("svg")).toBeNull();
  fireEvent.mouseLeave(trigger);
  await waitFor(() =>
    expect(screen.queryByText("Existing details")).toBeNull(),
  );
});

it("flips left at the right edge while preserving the pointer gap", async () => {
  const trigger = setup(900);
  fireEvent.mouseMove(trigger, { clientX: 920, clientY: 140 });
  fireEvent.mouseEnter(trigger, { clientX: 920, clientY: 140 });
  const details = await screen.findByText("Existing details");
  const positioner = details.parentElement!.parentElement!;
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(648px, 140px)"),
  );
  expect(positioner.getAttribute("data-side")).toBe("left");
});

it("keeps the card available to keyboard users and dismisses it with Escape", async () => {
  const trigger = setup();
  fireEvent.focus(trigger);
  const details = await screen.findByText("Existing details");
  expect(details.parentElement!.textContent).toBe(
    "Existing headingExisting details",
  );
  expect(details.parentElement!.className).toContain("bg-background");
  expect(
    details.parentElement!.parentElement!.hasAttribute("data-animated"),
  ).toBe(false);
  fireEvent.keyDown(trigger, { key: "Escape" });
  await waitFor(() =>
    expect(screen.queryByText("Existing details")).toBeNull(),
  );
});

it("keeps one moving card when crossing columns and retargets without remounting", async () => {
  const first = setup();
  const next = screen.getByRole("button", { name: "Next column" });
  fireEvent.mouseMove(first, { clientX: 120, clientY: 140 });
  fireEvent.mouseEnter(first, { clientX: 120, clientY: 140 });
  const card = (await screen.findByText("Existing details")).parentElement!;
  const positioner = card.parentElement!;
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(132px, 140px)"),
  );

  fireEvent.mouseLeave(first, { relatedTarget: next });
  expect(card.isConnected).toBe(true);
  fireEvent.mouseEnter(next, {
    relatedTarget: first,
    clientX: 230,
    clientY: 180,
  });
  fireEvent.mouseMove(next, { clientX: 230, clientY: 180 });
  expect((await screen.findByText("Next details")).parentElement).toBe(card);
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(242px, 180px)"),
  );
  expect(positioner.hasAttribute("data-animated")).toBe(true);
  expect(
    document.querySelectorAll('[data-slot="chart-data-tooltip"]'),
  ).toHaveLength(1);

  fireEvent.focus(first);
  await waitFor(() =>
    expect(positioner.hasAttribute("data-animated")).toBe(false),
  );
  expect((await screen.findByText("Existing details")).parentElement).toBe(
    card,
  );
});

it("keeps a tall card visible at the bottom viewport edge", async () => {
  const trigger = setup(100, 620);
  fireEvent.mouseMove(trigger, { clientX: 120, clientY: 700 });
  fireEvent.mouseEnter(trigger, { clientX: 120, clientY: 700 });
  const details = await screen.findByText("Existing details");
  const positioner = details.parentElement!.parentElement!;
  await waitFor(() => {
    const match = positioner.style.transform.match(
      /translate\(132px, ([-\d.]+)px\)/,
    );
    expect(match).not.toBeNull();
    const top = Number(match![1]);
    expect(top).toBeGreaterThanOrEqual(8);
    expect(top + 180).toBeLessThanOrEqual(768 - 8);
  });
});

it("switches the anchor on entry without waiting for another mousemove", async () => {
  const first = setup();
  const next = screen.getByRole("button", { name: "Next column" });
  fireEvent.mouseMove(first, { clientX: 120, clientY: 140 });
  fireEvent.mouseEnter(first, { clientX: 120, clientY: 140 });
  const positioner = (await screen.findByText("Existing details"))
    .parentElement!.parentElement!;
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(132px, 140px)"),
  );
  fireEvent.mouseLeave(first, { relatedTarget: next });
  fireEvent.mouseEnter(next, {
    relatedTarget: first,
    clientX: 230,
    clientY: 180,
  });
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(242px, 180px)"),
  );
  fireEvent.mouseLeave(next, { relatedTarget: first });
  fireEvent.mouseEnter(first, {
    relatedTarget: next,
    clientX: 130,
    clientY: 160,
  });
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(142px, 160px)"),
  );
});

it("does not jump by the card height when the pointer crosses the bottom limit", async () => {
  const trigger = setup(100, 500);
  fireEvent.mouseEnter(trigger, { clientX: 120, clientY: 578 });
  const positioner = (await screen.findByText("Existing details"))
    .parentElement!.parentElement!;
  for (const y of [578, 580, 582, 580, 578]) {
    fireEvent.mouseMove(trigger, { clientX: 120, clientY: y });
    await waitFor(() =>
      expect(positioner.style.transform).toBe(
        `translate(132px, ${Math.min(y, 580)}px)`,
      ),
    );
  }
});

it("changes sides as the pointer crosses the right limit and returns", async () => {
  const first = setup(694);
  const next = screen.getByRole("button", { name: "Next column" });
  fireEvent.mouseMove(first, { clientX: 720, clientY: 140 });
  fireEvent.mouseEnter(first, { clientX: 720, clientY: 140 });
  const positioner = (await screen.findByText("Existing details"))
    .parentElement!.parentElement!;
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(732px, 140px)"),
  );
  fireEvent.mouseLeave(first, { relatedTarget: next });
  fireEvent.mouseEnter(next, {
    relatedTarget: first,
    clientX: 820,
    clientY: 140,
  });
  fireEvent.mouseMove(next, { clientX: 820, clientY: 140 });
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(548px, 140px)"),
  );
  expect(positioner.getAttribute("data-side")).toBe("left");
  expect(positioner.hasAttribute("data-animated")).toBe(true);
  fireEvent.mouseLeave(next, { relatedTarget: first });
  fireEvent.mouseEnter(first, {
    relatedTarget: next,
    clientX: 720,
    clientY: 140,
  });
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(732px, 140px)"),
  );
  expect(positioner.getAttribute("data-side")).toBe("right");
});
