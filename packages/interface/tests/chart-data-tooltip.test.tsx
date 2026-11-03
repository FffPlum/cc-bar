import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import {
  ChartDataTooltip,
  ChartDataTooltipContent,
  ChartDataTooltipTrigger,
} from "@/components/chart-data-tooltip";
import { TooltipProvider } from "@/components/ui/tooltip";

afterEach(() => vi.restoreAllMocks());

const setup = (left = 100, top = 80) => {
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
  render(
    <TooltipProvider>
      <ChartDataTooltip>
        <ChartDataTooltipTrigger
          render={<button data-testid="column">Column</button>}
        />
        <ChartDataTooltipContent className="w-[260px]">
          <strong>Existing heading</strong>
          <span>Existing details</span>
        </ChartDataTooltipContent>
      </ChartDataTooltip>
    </TooltipProvider>,
  );
  return screen.getByRole("button", { name: "Column" });
};

it("snaps horizontally to the column center while following the pointer vertically", async () => {
  const trigger = setup();
  fireEvent.mouseMove(trigger, { clientX: 120, clientY: 140 });
  fireEvent.mouseEnter(trigger, { clientX: 120, clientY: 140 });
  const details = await screen.findByText("Existing details");
  const positioner = details.parentElement!.parentElement!;
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(160px, 140px)"),
  );
  fireEvent.mouseMove(trigger, { clientX: 180, clientY: 200 });
  await waitFor(() =>
    expect(positioner.style.transform).toBe("translate(160px, 200px)"),
  );
  expect(positioner.style.position).toBe("fixed");
  expect(details.parentElement!.querySelector("svg")).toBeNull();
  fireEvent.mouseLeave(trigger);
  await waitFor(() =>
    expect(screen.queryByText("Existing details")).toBeNull(),
  );
});

it("flips left near the right edge and keeps the card within the viewport", async () => {
  const trigger = setup(900);
  fireEvent.mouseMove(trigger, { clientX: 920, clientY: 140 });
  fireEvent.mouseEnter(trigger, { clientX: 920, clientY: 140 });
  const details = await screen.findByText("Existing details");
  const positioner = details.parentElement!.parentElement!;
  await waitFor(() =>
    expect(positioner.getAttribute("data-side")).toBe("left"),
  );
  expect(positioner.style.transform).toBe("translate(680px, 140px)");
});

it("keeps the card available to keyboard users and dismisses it with Escape", async () => {
  const trigger = setup();
  fireEvent.focus(trigger);
  const details = await screen.findByText("Existing details");
  expect(details.parentElement!.textContent).toBe(
    "Existing headingExisting details",
  );
  expect(details.parentElement!.className).toContain("bg-background");
  fireEvent.keyDown(trigger, { key: "Escape" });
  await waitFor(() =>
    expect(screen.queryByText("Existing details")).toBeNull(),
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
      /translate\(160px, ([-\d.]+)px\)/,
    );
    expect(match).not.toBeNull();
    const top = Number(match![1]);
    expect(top).toBeGreaterThanOrEqual(8);
    expect(top + 180).toBeLessThanOrEqual(768 - 8);
  });
});
