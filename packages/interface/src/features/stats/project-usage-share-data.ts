import type {
  ProjectDetail,
  UsageService,
  UsageTotals,
} from "@ccbar/host-api/window";
import { serviceDisplayName } from "@/lib/display";

export type ProjectShareDimension = "service" | "model" | "branch";

export interface ProjectShareRow {
  id: string;
  title: string;
  services: UsageService[];
  totals: UsageTotals;
  conversationCount?: number;
  share: number;
  service?: UsageService;
}

export function projectUsageShareRows(
  detail: ProjectDetail,
  dimension: ProjectShareDimension,
  metric: "tokens" | "cost",
): ProjectShareRow[] {
  // All three host aggregations partition the same project-range buckets.
  // Keep this denominator independent of any preview limit in the UI.
  const total = metricValue(detail.totals, metric);
  const share = (totals: UsageTotals) =>
    total > 0 ? Math.min(1, metricValue(totals, metric) / total) : 0;

  if (dimension === "service") {
    return (Object.keys(detail.totalsByService) as UsageService[])
      .flatMap((service): ProjectShareRow[] => {
        const totals = detail.totalsByService[service];
        return totals
          ? [
              {
                id: `service:${service}`,
                title: serviceDisplayName(service),
                services: [service],
                service,
                totals,
                share: share(totals),
              },
            ]
          : [];
      })
      .sort((left, right) => {
        const difference =
          metricValue(right.totals, metric) - metricValue(left.totals, metric);
        return (
          difference || (left.id < right.id ? -1 : left.id > right.id ? 1 : 0)
        );
      });
  }

  if (dimension === "model") {
    return detail.models.map((model) => ({
      id: `model:${model.model}`,
      title: model.model,
      services: model.services,
      totals: model.totals,
      share: share(model.totals),
    }));
  }

  return detail.branches.map((branch, index) => ({
    // Privacy mode can redact several different branches to null.
    id:
      branch.branch === null
        ? `branch:null:${index}`
        : `branch:name:${branch.branch}`,
    title: branch.branch ?? "",
    services: [],
    totals: branch.totals,
    conversationCount: branch.conversationCount,
    share: share(branch.totals),
  }));
}

function metricValue(totals: UsageTotals, metric: "tokens" | "cost"): number {
  // USD decimal strings are used only for a display ratio, never arithmetic
  // on localized/rounded money labels. Unknown zero costs do not become Tokens.
  const value =
    metric === "tokens" ? totals.totalTokens : Number(totals.costUSD);
  return Number.isFinite(value) && value > 0 ? value : 0;
}
