import type { DashboardHeatmap } from "@ccbar/host-api/window";

export interface HeatmapSeriesPoint {
  /** Monday for weekly points; the observation date for cumulative points. */
  day: string;
  tokens: number;
  /** Calendar window bounds, both inclusive, even when some days are missing. */
  fromDay: string;
  toDay: string;
  /** Weekly coverage only; historical cumulative points have no seven-day window. */
  dayCount?: number;
  partial?: boolean;
}

export interface HeatmapSeries {
  weekly: HeatmapSeriesPoint[];
  cumulative: HeatmapSeriesPoint[];
}

type HeatmapSeriesBlock = Pick<
  DashboardHeatmap,
  "fromDay" | "toDay" | "days" | "cumulativeFromDay"
>;

export function buildHeatmapSeries(
  blocks: readonly HeatmapSeriesBlock[],
  today: string,
): HeatmapSeries {
  const dailyTokens = new Map<string, number>();
  const cumulative = new Map<string, HeatmapSeriesPoint>();
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
        if (block.cumulativeFromDay && day.day >= block.cumulativeFromDay) {
          // The host includes history before this display window. Never re-sum
          // just the visible days or replace a missing history value with zero.
          cumulative.set(day.day, {
            day: day.day,
            fromDay: block.cumulativeFromDay,
            toDay: day.day,
            tokens: day.cumulativeTokens,
          });
        }
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
    cumulative: days.flatMap((day) => {
      const point = cumulative.get(day);
      return point ? [point] : [];
    }),
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
