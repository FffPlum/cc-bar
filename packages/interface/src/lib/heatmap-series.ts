import type { DashboardHeatmap } from "@ccbar/host-api/window";

export interface HeatmapSeriesPoint {
  /** Monday for weekly points; the window's last day for rolling points. */
  day: string;
  tokens: number;
  /** Calendar window bounds, both inclusive, even when some days are missing. */
  fromDay: string;
  toDay: string;
  /** Loaded calendar days, including known zero-usage days. */
  dayCount: number;
  /** Describes missing days, independently of the host's usage coverage flag. */
  partial: boolean;
}

export interface HeatmapSeries {
  weekly: HeatmapSeriesPoint[];
  rolling: HeatmapSeriesPoint[];
}

type HeatmapSeriesBlock = Pick<DashboardHeatmap, "fromDay" | "toDay" | "days">;

export function buildHeatmapSeries(
  blocks: readonly HeatmapSeriesBlock[],
  today: string,
): HeatmapSeries {
  const dailyTokens = new Map<string, number>();
  for (const block of blocks) {
    for (const day of block.days) {
      if (
        day.day >= block.fromDay &&
        day.day < block.toDay &&
        day.day <= today &&
        !dailyTokens.has(day.day)
      ) {
        // Pages arrive newest first; an overlapping date is counted only once.
        dailyTokens.set(day.day, day.totals.totalTokens);
      }
    }
  }
  const days = [...dailyTokens.keys()].sort();
  const weekStarts = [...new Set(days.map(startOfWeek))];

  const windowPoint = (
    day: string,
    fromDay: string,
    toDay: string,
  ): HeatmapSeriesPoint => {
    let tokens = 0;
    let dayCount = 0;
    for (let offset = 0; offset < 7; offset += 1) {
      const value = dailyTokens.get(addDays(fromDay, offset));
      if (value !== undefined) {
        tokens += value;
        dayCount += 1;
      }
    }
    return { day, tokens, fromDay, toDay, dayCount, partial: dayCount < 7 };
  };

  return {
    weekly: weekStarts.map((day) => windowPoint(day, day, addDays(day, 6))),
    rolling: days.map((day) => windowPoint(day, addDays(day, -6), day)),
  };
}

function startOfWeek(day: string): string {
  const weekday = new Date(`${day}T00:00:00Z`).getUTCDay();
  return addDays(day, -((weekday + 6) % 7));
}

function addDays(day: string, amount: number): string {
  // DTO dates are local calendar labels. UTC arithmetic preserves those labels
  // across daylight-saving changes without converting them into another zone.
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + amount);
  return date.toISOString().slice(0, 10);
}
