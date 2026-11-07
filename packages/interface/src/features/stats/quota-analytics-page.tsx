import { useEffect, useState } from "react";
import { useQueries, useQueryClient } from "@tanstack/react-query";
import type {
  CycleSummary,
  QuotaAccount,
  QuotaAnalytics,
  QuotaAccountsResult,
  QuotaTimelinePeriod,
  UsageService,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { SelectField } from "@/components/select-field";
import { useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { LoadingBlock } from "./dashboard-loading";
import { QuotaAccountCard } from "./quota-account-card";
import { QuotaDailyChart } from "./quota-daily-chart";
import {
  quotaAccountColors,
  quotaSupportsKind,
} from "./quota-account-presentation";

const domains = ["usage", "quota", "settings"] as const;
const ALL_ACCOUNTS = "__all_accounts__";
type StandardKind = "fiveHour" | "weekly";

/** Statistics visibility is independent of menu bar visibility. Mirror accounts
 * share the primary history and are omitted while that primary account exists. */
export function analyticsAccounts(
  accounts: QuotaAccount[],
  visibleServices: UsageService[],
  service?: UsageService,
): QuotaAccount[] {
  return accounts.filter((account) => {
    if (
      !["codex", "claude", "kimi"].includes(account.service) ||
      !visibleServices.includes(account.service as UsageService)
    )
      return false;
    if (service && account.service !== service) return false;
    if (account.kind === "managedKimi" && !account.enabled) return false;
    return (
      account.kind === "primary" ||
      !account.current ||
      !accounts.some(
        (primary) =>
          primary.kind === "primary" &&
          primary.service === account.service &&
          primary.detected,
      )
    );
  });
}

export function QuotaAnalyticsPage({
  visibleServices,
}: {
  visibleServices: UsageService[];
}) {
  const { api } = useHost();
  const t = useTranslation();
  const [selection, setSelection] = useState(ALL_ACCOUNTS);
  const accounts = useHostResource<QuotaAccountsResult>(
    () => api.quotaAccounts(),
    domains,
    [api],
  );
  const eligible = analyticsAccounts(
    accounts.data?.accounts ?? [],
    visibleServices,
  );
  const selectedID = eligible.some((account) => account.id === selection)
    ? selection
    : ALL_ACCOUNTS;
  return (
    <div className="flex h-full min-h-0 min-w-0 flex-col gap-4 p-5 text-[13px]">
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-3">
        <h2 className="text-[15px] font-semibold">{t("Quota", "额度")}</h2>
        <SelectField
          value={selectedID}
          options={[
            { value: ALL_ACCOUNTS, label: t("All accounts", "全部账号") },
            ...eligible.map((account) => ({
              value: account.id,
              label: [account.name, account.subtitle]
                .filter(Boolean)
                .join(" · "),
            })),
          ]}
          onChange={setSelection}
          ariaLabel={t("Quota account", "额度账号")}
          className="h-8 max-w-[min(28rem,70vw)]"
          contentAlign="end"
          disabled={!accounts.data}
        />
      </div>
      <div className="cc-scrollbar min-h-0 min-w-0 flex-1 [scrollbar-gutter:stable]">
        <ResourceFeedback
          {...accounts}
          loadingFallback={<QuotaLoading />}
          onRetry={() => void accounts.reload()}
        >
          {() =>
            eligible.length ? (
              <AnalyticsCollection
                accounts={eligible}
                selectedID={selectedID}
              />
            ) : (
              <EmptyState
                title={t("No quota accounts", "暂无额度账号")}
                description={t(
                  "Enable usage statistics for a Codex, Claude Code or Kimi Code account.",
                  "开启 Codex、Claude Code 或 Kimi Code 的用量统计后查看。",
                )}
              />
            )
          }
        </ResourceFeedback>
      </div>
    </div>
  );
}

function AnalyticsCollection({
  accounts,
  selectedID,
}: {
  accounts: QuotaAccount[];
  selectedID: string;
}) {
  const { api, settings } = useHost();
  const t = useTranslation();
  const client = useQueryClient();
  const selected = accounts.find((account) => account.id === selectedID);
  const displayed = selected ? [selected] : accounts;
  const colors = quotaAccountColors(accounts);
  const requests = displayed.flatMap((account) => {
    // Weekly history also supplies daily estimates when the current snapshot
    // does not yet contain a weekly window. Never invent a missing 5H window.
    const periods: StandardKind[] = quotaSupportsKind(account, "fiveHour")
      ? ["fiveHour", "weekly"]
      : ["weekly"];
    return periods.map((kind) => ({ account, kind }));
  });
  const queries = useQueries({
    queries: requests.map(({ account, kind }) => {
      const queryKey = [
        "quota-analytics",
        account.id,
        account.name,
        account.subtitle,
        kind,
        settings.appearance.cycleIncludesOtherAgents,
      ];
      return {
        queryKey,
        queryFn: async () => {
          const value = await api.quotaAnalytics({
            accountID: account.id,
            kind,
          });
          const previous = client.getQueryData<QuotaAnalytics>(queryKey);
          // The official snapshot can refresh while the local index is busy or
          // unavailable. Retain only this exact query's last daily observations.
          if (
            value.dailyUsage.state !== "ready" &&
            previous?.dailyUsage.points.length
          ) {
            return {
              ...value,
              dailyUsage: {
                ...value.dailyUsage,
                points: previous.dailyUsage.points,
              },
            };
          }
          return value;
        },
        staleTime: 60_000,
      };
    }),
  });
  useEffect(
    () =>
      api.subscribe((event) => {
        if (event.domains.includes("quota"))
          void client.invalidateQueries({ queryKey: ["quota-analytics"] });
      }),
    [api, client],
  );
  const queryFor = (accountID: string, kind: StandardKind) => {
    const index = requests.findIndex(
      (request) => request.account.id === accountID && request.kind === kind,
    );
    return index < 0 ? undefined : queries[index];
  };
  const failed = queries.some((query) => query.isError);

  return (
    <div className="space-y-4 pb-1">
      {failed && (
        <div
          role="status"
          className="flex flex-wrap items-center justify-between gap-2 rounded-lg border px-4 py-2 text-[12px] text-muted-foreground"
        >
          <span>
            {t(
              "Some account data couldn’t be updated. Available records are still shown.",
              "部分账号数据暂未更新，保留已有记录。",
            )}
          </span>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              queries
                .filter((query) => query.isError)
                .forEach((query) => void query.refetch());
            }}
          >
            {t("Retry", "重试")}
          </Button>
        </div>
      )}
      <section
        className="grid min-w-0 grid-cols-[repeat(auto-fit,minmax(min(100%,260px),1fr))] gap-3"
        aria-label={t("Account quotas", "账号额度")}
      >
        {displayed.map((account) => {
          const fiveHour = queryFor(account.id, "fiveHour");
          const weekly = queryFor(account.id, "weekly");
          return (
            <QuotaAccountCard
              key={account.id}
              account={account}
              fiveHour={fiveHour?.data}
              weekly={weekly?.data}
              color={colors.get(account.id)!}
              loading={Boolean(fiveHour?.isFetching || weekly?.isFetching)}
              error={Boolean(
                fiveHour?.isError || weekly?.isError || account.refresh.failed,
              )}
              detailed={Boolean(selected)}
            />
          );
        })}
      </section>
      <QuotaDailyChart
        rows={displayed.map((account) => {
          const weekly = queryFor(account.id, "weekly");
          return {
            account,
            points: weekly?.data?.dailyUsage.points ?? [],
            color: colors.get(account.id)!,
            unavailable: weekly?.data?.dailyUsage.state === "unavailable",
            loading:
              weekly?.isFetching ||
              weekly?.data?.dailyUsage.state === "loading",
            error:
              weekly?.isError ||
              (weekly?.data?.dailyUsage.state === "unavailable" &&
                weekly.data.dailyUsage.points.some(
                  (point) => point.estimatedUsedPercent !== null,
                )),
          };
        })}
      />
    </div>
  );
}

/** Host order resolves overlapping current records by sample time and boundary quality. */
export function currentCycle(value: QuotaAnalytics): CycleSummary | undefined {
  return value.cycles.find((item) => item.cycle.current);
}
export function timelineEntries(periods: QuotaTimelinePeriod[]) {
  return periods
    .flatMap((period) => period.entries)
    .sort(
      (left, right) => Date.parse(left.sampledAt) - Date.parse(right.sampledAt),
    );
}
function QuotaLoading() {
  const t = useTranslation();
  return (
    <div role="status" className="space-y-4">
      <span className="sr-only">
        {t("Loading quota data…", "正在读取额度数据…")}
      </span>
      <div className="grid grid-cols-[repeat(auto-fit,minmax(min(100%,260px),1fr))] gap-3">
        {[0, 1].map((key) => (
          <LoadingBlock key={key} className="h-[90px] rounded-lg" />
        ))}
      </div>
      <LoadingBlock className="h-80 rounded-lg" />
    </div>
  );
}
