import { render } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import type { UsageDashboard } from "@ccbar/host-api/window";
import { DashboardChart } from "@/features/stats/dashboard-charts";
import { LanguageProvider } from "@/lib/i18n";
import { TooltipProvider } from "@/components/ui/tooltip";

vi.mock("@/host/host-context", async () => {
  const fixtures = await import("./fixtures");
  return {
    useHost: () => ({
      bootstrap: fixtures.bootstrap,
      settings: fixtures.settings,
    }),
  };
});

it("sizes the y-axis to its labels and keeps their scale positions", () => {
  const data = {
    samples: [],
    axisTicks: [
      { position: 0, label: "0" },
      { position: 0.5, label: "450" },
      { position: 1, label: "900" },
    ],
    resolvedRange: { granularity: "day" },
    coverage: { precision: "event" },
  } as unknown as UsageDashboard;
  const { container } = render(
    <LanguageProvider language="en">
      <TooltipProvider>
        <DashboardChart data={data} title="Tokens" />
      </TooltipProvider>
    </LanguageProvider>,
  );
  const axis = container.querySelector('[data-slot="dashboard-y-axis"]')!;
  expect(axis.classList.contains("w-max")).toBe(true);
  expect(axis.classList.contains("w-20")).toBe(false);
  const measure = axis.querySelector('[data-slot="dashboard-axis-measure"]')!;
  expect(measure.getAttribute("aria-hidden")).toBe("true");
  expect(measure.textContent).toBe("0450900");
  const ticks = Array.from(
    axis.querySelectorAll<HTMLElement>('[data-slot="dashboard-axis-tick"]'),
  );
  expect(ticks.map((tick) => tick.textContent)).toEqual(["0", "450", "900"]);
  expect(ticks.map((tick) => tick.style.bottom)).toEqual(["0%", "50%", "100%"]);
});
