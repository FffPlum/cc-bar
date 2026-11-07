import { useEffect, useId, useRef, useState } from "react";
import { UserRound } from "lucide-react";
import type {
  CycleSummary,
  QuotaAccount,
  QuotaAnalytics,
} from "@ccbar/host-api/window";
import { quotaStatusClass } from "@/components/quota-progress";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Popover,
  PopoverContent,
  PopoverTitle,
  PopoverTrigger,
} from "@/components/ui/popover";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { formatDate, formatTokens, serviceDisplayName } from "@/lib/display";
import { cn } from "@/lib/utils";
import {
  QuotaPlanBadge,
  quotaAccountSubtitle,
  quotaSupportsKind,
} from "./quota-account-presentation";

type StandardKind = "fiveHour" | "weekly";

export interface QuotaAccountCardProps {
  account: QuotaAccount;
  fiveHour?: QuotaAnalytics | null;
  weekly?: QuotaAnalytics | null;
  color: string;
  loading?: boolean;
  error?: boolean;
  detailed?: boolean;
}

function matchingAnalytics(
  account: QuotaAccount,
  value: QuotaAnalytics | null | undefined,
): QuotaAnalytics | undefined {
  return value?.account.id === account.id &&
    value.account.service === account.service
    ? value
    : undefined;
}

function currentSummary(value: QuotaAnalytics | undefined, kind: StandardKind) {
  // The host already sorts current cycles by sample precedence.
  return value?.cycles.find(
    (summary) =>
      summary.cycle.current &&
      summary.cycle.kind === kind &&
      summary.cycle.service === value.account.service,
  );
}

/** The avatar ring and its detail panel always use the same official source. */
function officialUsage(
  account: QuotaAccount,
  value: QuotaAnalytics | undefined,
  summary: CycleSummary | undefined,
  kind: StandardKind,
) {
  const limit = account.snapshot?.limits.find((item) => item.kind === kind);
  const window = value?.window?.kind === kind ? value.window : null;
  const snapshotAt = Date.parse(account.snapshot?.fetchedAt ?? "") || 0;
  const sampledAt = Date.parse(window?.latestSampleAt ?? "") || 0;
  const preferWindow =
    window !== null && (limit === undefined || sampledAt > snapshotAt);
  const official = preferWindow
    ? window.remainingPercent == null
      ? null
      : 100 - window.remainingPercent
    : (limit?.usedPercent ?? summary?.cycle.latestUsedPercent);
  return {
    used:
      official != null && Number.isFinite(official)
        ? Math.max(0, official)
        : null,
    reset:
      (preferWindow ? window.resetsAt : limit?.resetsAt) ??
      summary?.cycle.endAt,
    window,
  };
}

export function QuotaAccountCard({
  account,
  fiveHour,
  weekly,
  color,
  loading = false,
  error = false,
  detailed = false,
}: QuotaAccountCardProps) {
  const { settings } = useHost();
  const t = useTranslation();
  const triggerID = useId();
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const popupRef = useRef<HTMLDivElement>(null);
  const restoringFocus = useRef(false);
  const fiveHourValue = matchingAnalytics(account, fiveHour);
  const weeklyValue = matchingAnalytics(account, weekly);
  const serviceName = serviceDisplayName(account.service);
  const freshest = [account, fiveHourValue?.account, weeklyValue?.account]
    .filter((candidate): candidate is QuotaAccount => candidate !== undefined)
    .reduce((latest, candidate) =>
      Date.parse(candidate.snapshot?.fetchedAt ?? "") >
        Date.parse(latest.snapshot?.fetchedAt ?? "") ||
      (!latest.snapshot && candidate.snapshot)
        ? candidate
        : latest,
    );
  const primaryIdentity =
    account.kind === "primary" && account.detected && account.current
      ? quotaAccountSubtitle(account).trim()
      : undefined;
  const hasPrimaryIdentity =
    primaryIdentity &&
    ![
      "Signed in",
      "Not signed in",
      "已登录",
      "未登录",
      "Local sign-in detected",
      "已识别本机登录",
    ].includes(primaryIdentity);
  // Account rows are refreshed independently of cached analytics. Prefer their
  // current, already privacy-masked identity over an earlier analytics name.
  const name =
    (account.name !== serviceName
      ? account.name
      : hasPrimaryIdentity
        ? primaryIdentity
        : account.current
          ? freshest.name || account.name
          : account.name) || serviceName;
  const displayAccount = { ...account, snapshot: freshest.snapshot };
  const identitySubtitle = quotaAccountSubtitle(displayAccount);
  const subtitle = [
    ...(name === serviceName ? [] : [serviceName]),
    ...(identitySubtitle === name ? [] : identitySubtitle.split(" · ")),
  ]
    .filter(
      (part, index, parts) =>
        part && part !== name && parts.indexOf(part) === index,
    )
    .join(" · ");
  const avatarName = name.startsWith(`${serviceName} · `)
    ? name.slice(serviceName.length + 3).trim()
    : name;
  const initial =
    name === serviceName
      ? null
      : Array.from(avatarName)[0]?.toLocaleUpperCase();
  const fiveHourSummary = currentSummary(fiveHourValue, "fiveHour");
  const weeklySummary = currentSummary(weeklyValue, "weekly");
  const showFiveHour =
    quotaSupportsKind(displayAccount, "fiveHour") &&
    (displayAccount.snapshot !== null ||
      fiveHourValue?.window?.kind === "fiveHour" ||
      fiveHourSummary !== undefined ||
      (loading && fiveHourValue === undefined));
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (settings.appearance.resetTimeDisplay !== "relative") return;
    const timer = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(timer);
  }, [settings.appearance.resetTimeDisplay]);
  const hasData = Boolean(
    displayAccount.snapshot ||
    fiveHourSummary ||
    weeklySummary ||
    fiveHourValue?.window ||
    weeklyValue?.window,
  );
  const fiveHourUsed = officialUsage(
    displayAccount,
    fiveHourValue,
    fiveHourSummary,
    "fiveHour",
  ).used;
  const weeklyUsed = officialUsage(
    displayAccount,
    weeklyValue,
    weeklySummary,
    "weekly",
  ).used;
  const ringLabel = (label: string, used: number | null) =>
    `${label}: ${used === null ? t("unavailable", "暂无数据") : `${t("used", "已用")} ${used.toFixed(1)}%`}`;
  const usageLabel = showFiveHour
    ? `${ringLabel(t("Left, 5 hours", "左侧 5 小时"), fiveHourUsed)}; ${ringLabel(t("Right, weekly", "右侧周额度"), weeklyUsed)}`
    : ringLabel(t("Weekly quota", "周额度"), weeklyUsed);
  const statusText = error
    ? t("Update failed", "更新失败")
    : loading
      ? t("Updating…", "更新中…")
      : !account.detected && !hasData
        ? t("Not signed in", "未登录")
        : null;

  return (
    <section
      className="flex min-w-0 items-center gap-3 rounded-lg border bg-card p-3"
      aria-label={name}
    >
      <Popover
        open={open}
        onOpenChange={(nextOpen, details) => {
          setOpen(nextOpen);
          const popup = popupRef.current;
          if (
            !nextOpen &&
            details.reason === "escape-key" &&
            popup?.contains(popup.ownerDocument.activeElement)
          ) {
            // Return keyboard focus without reopening on the resulting focus event.
            restoringFocus.current = true;
            try {
              triggerRef.current?.focus({ preventScroll: true });
            } finally {
              restoringFocus.current = false;
            }
          }
        }}
        triggerId={triggerID}
      >
        <PopoverTrigger
          ref={triggerRef}
          id={triggerID}
          openOnHover
          delay={150}
          closeDelay={120}
          onFocus={(event) => {
            if (
              !restoringFocus.current &&
              event.currentTarget.matches(":focus-visible")
            )
              setOpen(true);
          }}
          className="group/quota-avatar relative flex size-16 shrink-0 items-center justify-center rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          aria-label={`${name}. ${usageLabel}. ${t("Quota details", "额度详情")}`}
        >
          <QuotaAvatarRing
            fiveHour={showFiveHour ? fiveHourUsed : undefined}
            weekly={weeklyUsed}
            loading={loading}
          />
          <span
            className="relative flex size-[42px] items-center justify-center rounded-full bg-secondary text-[20px] font-medium text-secondary-foreground"
            aria-hidden="true"
          >
            {initial ?? <UserRound className="size-5" />}
          </span>
        </PopoverTrigger>
        <PopoverContent
          ref={popupRef}
          side="bottom"
          align="start"
          sideOffset={8}
          initialFocus={false}
          finalFocus={false}
          className="max-h-[min(80vh,40rem)] w-[340px] max-w-[calc(100vw-24px)] overflow-y-auto bg-white p-4 text-foreground dark:bg-black"
        >
          <div className="space-y-1">
            <PopoverTitle className="break-words text-[13px] font-semibold">
              {name}
            </PopoverTitle>
            <p className="text-[11px] text-muted-foreground">
              {showFiveHour
                ? t(
                    "Left: 5 hours · Right: weekly",
                    "左侧：5 小时 · 右侧：周额度",
                  )
                : t("Ring: weekly quota", "圆环：周额度")}
            </p>
          </div>
          <div className="divide-y border-t pt-3">
            {(showFiveHour
              ? (["fiveHour", "weekly"] as const)
              : (["weekly"] as const)
            ).map((kind) => (
              <QuotaPeriodMetrics
                key={kind}
                account={displayAccount}
                value={kind === "fiveHour" ? fiveHourValue : weeklyValue}
                summary={kind === "fiveHour" ? fiveHourSummary : weeklySummary}
                kind={kind}
                loading={loading}
                detailed={detailed}
                now={now}
              />
            ))}
          </div>
          {error && (
            <p className="text-[11px] text-muted-foreground" role="status">
              {hasData
                ? t(
                    "Refresh failed. Showing saved data.",
                    "刷新失败，显示已有数据。",
                  )
                : t(
                    "Usage couldn’t be loaded. Try refreshing.",
                    "用量暂时无法加载，请刷新重试。",
                  )}
            </p>
          )}
          {!account.detected && !hasData && !loading && !error && (
            <p className="text-[11px] text-muted-foreground">
              {t("Not signed in", "未登录")}
            </p>
          )}
        </PopoverContent>
      </Popover>
      <div className="min-w-0 flex-1">
        <div className="flex min-w-0 items-center gap-2">
          <h3
            className="min-w-0 flex-1 truncate text-[13px] font-semibold"
            title={name}
          >
            {name}
          </h3>
          <QuotaPlanBadge account={displayAccount} />
        </div>
        <div className="mt-1 flex min-w-0 items-center gap-1.5 text-[11px] text-muted-foreground">
          <span
            aria-hidden="true"
            className="size-1.5 shrink-0 rounded-full"
            style={{ backgroundColor: color }}
          />
          <span className="min-w-0 truncate" title={subtitle || serviceName}>
            {subtitle || serviceName}
          </span>
          {statusText && (
            <span className="shrink-0" role="status">
              · {statusText}
            </span>
          )}
        </div>
      </div>
    </section>
  );
}

function QuotaAvatarRing({
  fiveHour,
  weekly,
  loading,
}: {
  fiveHour: number | null | undefined;
  weekly: number | null;
  loading: boolean;
}) {
  // Both half-rings begin beside 12 o’clock and run down their own side.
  // Eight degrees at either end leaves equal gaps at the top and bottom.
  const inset = 28 * Math.sin((8 * Math.PI) / 180);
  const height = 28 * Math.cos((8 * Math.PI) / 180);
  const split = fiveHour !== undefined;
  const segments = split
    ? [
        {
          key: "fiveHour",
          used: fiveHour,
          path: `M ${32 - inset} ${32 - height} A 28 28 0 0 0 ${32 - inset} ${32 + height}`,
        },
        {
          key: "weekly",
          used: weekly,
          path: `M ${32 + inset} ${32 - height} A 28 28 0 0 1 ${32 + inset} ${32 + height}`,
        },
      ]
    : [{ key: "weekly", used: weekly, path: null }];
  return (
    <svg
      viewBox="0 0 64 64"
      className="pointer-events-none absolute inset-0 size-16 origin-center [transform:scale(1)] motion-safe:transition-transform motion-safe:duration-180 motion-safe:ease-[ease] motion-safe:[@media(hover:hover)_and_(pointer:fine)]:group-hover/quota-avatar:[transform:scale(1.08)]"
      fill="none"
      aria-hidden="true"
    >
      {segments.map(({ key, used, path }) => {
        const shared = {
          pathLength: 100,
          strokeWidth: 4,
          strokeLinecap: "round" as const,
        };
        const value = used === null ? null : Math.max(0, Math.min(100, used));
        const trackClass = cn(
          "stroke-border",
          loading &&
            used === null &&
            "animate-pulse motion-reduce:animate-none",
        );
        const fillClass =
          used === null ? undefined : quotaStatusClass(100 - used);
        const dash = value !== null && value < 100 ? `${value} 100` : undefined;
        return (
          <g key={key} data-quota-ring={key}>
            {path ? (
              <path {...shared} d={path} className={trackClass} />
            ) : (
              <circle
                {...shared}
                cx={32}
                cy={32}
                r={28}
                className={trackClass}
              />
            )}
            {value !== null &&
              value > 0 &&
              (path ? (
                <path
                  {...shared}
                  d={path}
                  stroke="currentColor"
                  strokeDasharray={dash}
                  className={fillClass}
                />
              ) : (
                <circle
                  {...shared}
                  cx={32}
                  cy={32}
                  r={28}
                  transform="rotate(-90 32 32)"
                  stroke="currentColor"
                  strokeDasharray={dash}
                  className={fillClass}
                />
              ))}
          </g>
        );
      })}
    </svg>
  );
}

function QuotaPeriodMetrics({
  account,
  value,
  summary,
  kind,
  loading,
  detailed,
  now,
}: {
  account: QuotaAccount;
  value: QuotaAnalytics | undefined;
  summary: CycleSummary | undefined;
  kind: StandardKind;
  loading: boolean;
  detailed: boolean;
  now: number;
}) {
  const { bootstrap, settings } = useHost();
  const t = useTranslation();
  const language = bootstrap.resolvedLanguage;
  const { used, reset, window } = officialUsage(account, value, summary, kind);
  const estimate = summary?.estimatedFullAllowanceTokens;
  const validEstimate =
    estimate != null && Number.isFinite(estimate) && estimate > 0
      ? estimate
      : null;
  const pending = loading && value === undefined && !summary;
  const latestSample = [window?.latestSampleAt, summary?.cycle.lastSampleAt]
    .filter((sample): sample is string => Boolean(sample))
    .reduce<string | null>(
      (latest, sample) =>
        latest === null || Date.parse(sample) > Date.parse(latest)
          ? sample
          : latest,
      null,
    );
  const resetText =
    reset && Number.isFinite(Date.parse(reset))
      ? resetLabel(
          reset,
          settings.appearance.resetTimeDisplay,
          bootstrap.timeZone,
          language,
          now,
        )
      : pending
        ? t("Loading…", "正在读取…")
        : t("Reset time unavailable", "暂无重置时间");

  return (
    <div className="min-w-0 space-y-2 py-3 first:pt-0 last:pb-0">
      <div className="flex min-w-0 items-baseline justify-between gap-3">
        <p className="text-[12px] font-medium">
          {kind === "fiveHour"
            ? t("5-hour quota", "5 小时额度")
            : t("Weekly quota", "周额度")}
        </p>
        <div className="flex items-baseline gap-1.5">
          <span className="text-[11px] text-muted-foreground">
            {t("Official used", "官方已用")}
          </span>
          {pending && used === null ? (
            <Skeleton
              className="h-6 w-16 motion-reduce:animate-none"
              aria-hidden="true"
            />
          ) : (
            <span
              className={cn(
                "cc-number text-[20px] font-semibold leading-none",
                used === null
                  ? "text-muted-foreground"
                  : quotaStatusClass(100 - used),
              )}
            >
              {used === null ? "—" : `${used.toFixed(1)}%`}
            </span>
          )}
        </div>
      </div>
      <p className="cc-number text-[11px] text-muted-foreground">{resetText}</p>
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <span className="text-[11px] text-muted-foreground">
          {t("Estimated full usage", "用满预估")}
        </span>
        {pending && validEstimate === null ? (
          <Skeleton
            className="h-4 w-24 motion-reduce:animate-none"
            aria-hidden="true"
          />
        ) : (
          <span
            className={cn(
              "cc-number text-[12px]",
              validEstimate === null && "text-muted-foreground",
            )}
          >
            {validEstimate === null
              ? "—"
              : `≈ ${formatTokens(validEstimate, language)} Tokens`}
          </span>
        )}
      </div>
      {detailed && summary && (
        <dl className="space-y-1.5 pt-1 text-[11px]">
          <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <dt className="text-muted-foreground">
              {t("Current cycle", "当前周期")}
            </dt>
            <dd className="cc-number text-right">
              {formatDate(
                summary.cycle.startAt,
                language,
                bootstrap.timeZone,
                true,
              )}
              {" – "}
              {formatDate(
                summary.cycle.endAt,
                language,
                bootstrap.timeZone,
                true,
              )}
            </dd>
          </div>
          <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <dt className="text-muted-foreground">
              {t("Latest sample", "最近采样")}
            </dt>
            <dd className="cc-number">
              {formatDate(latestSample, language, bootstrap.timeZone, true)}
            </dd>
          </div>
          <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <dt className="text-muted-foreground">
              {t("Recorded locally", "本机已记录")}
            </dt>
            <dd className="cc-number">
              {formatTokens(
                summary.currentAllowanceTotals.totalTokens,
                language,
              )}{" "}
              Tokens
            </dd>
          </div>
          <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <dt className="text-muted-foreground">
              {t("Local usage cost", "本机用量费用")}
            </dt>
            <dd className="cc-number">
              {summary.currentAllowanceTotals.costDisplay}
            </dd>
          </div>
          {summary.estimatedFullAllowanceCostDisplay && (
            <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
              <dt className="text-muted-foreground">
                {t("Estimated full cost", "用满费用预估")}
              </dt>
              <dd className="cc-number">
                ≈ {summary.estimatedFullAllowanceCostDisplay}
              </dd>
            </div>
          )}
        </dl>
      )}
      {summary?.quality === "incomplete" && (
        <p className="text-[11px] text-muted-foreground">
          {t(
            "Local records cover only part of this cycle.",
            "本机记录仅覆盖此周期的部分用量。",
          )}
        </p>
      )}
    </div>
  );
}

function resetLabel(
  value: string,
  mode: "relative" | "absolute",
  timeZone: string,
  language: "zh" | "en",
  now: number,
) {
  if (mode === "absolute") {
    const date = formatDate(value, language, timeZone, true);
    return language === "zh" ? `${date} 重置` : `Resets ${date}`;
  }
  const minutes = Math.max(0, Math.ceil((Date.parse(value) - now) / 60_000));
  if (!minutes) return language === "zh" ? "即将重置" : "Resets soon";
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);
  const duration =
    language === "zh"
      ? days
        ? `${days} 天 ${hours % 24} 小时`
        : hours
          ? `${hours} 小时 ${minutes % 60} 分钟`
          : `${minutes} 分钟`
      : days
        ? `${days}d ${hours % 24}h`
        : hours
          ? `${hours}h ${minutes % 60}m`
          : `${minutes}m`;
  return language === "zh" ? `${duration}后重置` : `Resets in ${duration}`;
}
