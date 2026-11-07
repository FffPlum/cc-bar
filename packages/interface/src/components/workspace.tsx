import { AlertTriangle, LoaderCircle } from "lucide-react";
import {
  Children,
  cloneElement,
  isValidElement,
  useId,
  type ReactNode,
} from "react";
import { Switch } from "@/components/ui/switch";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { useTranslation } from "@/lib/i18n";
import { cn } from "@/lib/utils";

export function WorkspaceHeader({
  title,
  leading,
  actions,
}: {
  title: string;
  leading?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <div className="flex min-h-8 items-center gap-3">
      {leading}
      <h1 className="text-[22px] font-semibold tracking-[-0.4px]">{title}</h1>
      <div className="flex-1" />
      {actions}
    </div>
  );
}

export function Panel({
  title,
  actions,
  children,
  className,
  contentClassName,
}: {
  title?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
  contentClassName?: string;
}) {
  return (
    <Card className={cn("cc-panel min-w-0 gap-0 py-0", className)}>
      {title !== undefined && (
        <CardHeader className="flex flex-row items-center gap-3 space-y-0 px-4 pb-0 pt-4">
          <CardTitle className="text-[12.5px] font-semibold">{title}</CardTitle>
          <div className="flex-1" />
          {actions}
        </CardHeader>
      )}
      <CardContent
        className={cn("p-4", title !== undefined && "pt-3", contentClassName)}
      >
        {children}
      </CardContent>
    </Card>
  );
}

export function SettingsGroup({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <section>
      <div className="px-1 pb-2">
        <h2 className="text-[13px] font-semibold tracking-[-0.05px]">
          {title}
        </h2>
        {description && (
          <p className="cc-tertiary mt-0.5 text-[10.5px]">{description}</p>
        )}
      </div>
      <div className="cc-panel divide-y divide-black/[0.06] overflow-hidden dark:divide-white/[0.06]">
        {children}
      </div>
    </section>
  );
}

export function SettingsRow({
  label,
  description,
  detail,
  leading,
  children,
}: {
  label: ReactNode;
  description?: ReactNode;
  detail?: ReactNode;
  leading?: ReactNode;
  children?: ReactNode;
}) {
  const labelID = useId();
  const controls = Children.map(children, (child) =>
    isValidElement(child) && child.type === Switch
      ? cloneElement(
          child as React.ReactElement<{ "aria-labelledby"?: string }>,
          { "aria-labelledby": labelID },
        )
      : child,
  );
  return (
    <div className="flex min-h-12 items-center gap-3 px-4 py-3">
      {leading}
      <div className="min-w-0 flex-1 space-y-0.5">
        <div id={labelID} className="text-[13px]">
          {label}
        </div>
        {description && (
          <div className="cc-tertiary text-[11px] leading-[1.45]">
            {description}
          </div>
        )}
        {detail && <div className="pt-1 text-[11px]">{detail}</div>}
      </div>
      {children && (
        <div className="flex shrink-0 items-center gap-2">{controls}</div>
      )}
    </div>
  );
}

export function KpiCard({
  label,
  value,
  delta,
  icon,
  dimmed = false,
}: {
  label: ReactNode;
  value: ReactNode;
  delta?: { text: string; direction: "up" | "down" } | null;
  icon?: ReactNode;
  dimmed?: boolean;
}) {
  return (
    <div
      className={cn(
        "cc-panel min-w-0 flex-1 px-3.5 py-[11px]",
        dimmed && "opacity-35",
      )}
    >
      <div className="flex items-center gap-1 text-[11px] text-muted-foreground">
        {icon}
        <span className="truncate">{label}</span>
        <span className="min-w-1.5 flex-1" />
        {delta && (
          <span
            className={cn(
              "cc-number font-semibold",
              delta.direction === "up"
                ? "text-red-600 dark:text-red-400"
                : "text-green-700 dark:text-green-400",
            )}
          >
            {delta.text}
          </span>
        )}
      </div>
      <div className="cc-number mt-1 truncate text-[22px] font-semibold tracking-[-0.5px]">
        {value}
      </div>
    </div>
  );
}

export function EmptyState({
  title,
  description,
  icon,
  action,
  className,
}: {
  title: string;
  description?: string;
  icon?: ReactNode;
  action?: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex min-h-32 flex-col items-center justify-center gap-2 px-6 py-8 text-center",
        className,
      )}
    >
      {icon}
      <p className="text-[13px] font-medium">{title}</p>
      {description && (
        <p className="max-w-md text-[11px] leading-relaxed text-muted-foreground">
          {description}
        </p>
      )}
      {action}
    </div>
  );
}

export function LoadingState({
  label,
  rows = 5,
}: {
  label?: string;
  rows?: number;
}) {
  const t = useTranslation();
  return (
    <div className="space-y-3 p-5" role="status" aria-live="polite">
      <div className="flex items-center gap-2 text-muted-foreground">
        <LoaderCircle className="size-3.5 animate-spin" />
        <span className="text-[11.5px]">
          {label ?? t("Loading…", "加载中…")}
        </span>
      </div>
      {Array.from({ length: rows }, (_, index) => (
        <Skeleton key={index} className="h-12 w-full rounded-lg" />
      ))}
    </div>
  );
}

export function ErrorState({
  title,
  message,
  onRetry,
  retryLabel,
}: {
  title: string;
  message: string;
  onRetry?: () => void;
  retryLabel?: string;
}) {
  const t = useTranslation();
  return (
    <div
      role="alert"
      className="flex min-h-52 flex-col items-center justify-center gap-3 p-8 text-center"
    >
      <AlertTriangle className="size-6 text-orange-600 dark:text-orange-400" />
      <h1 className="text-[15px] font-semibold">{title}</h1>
      <p className="max-w-lg whitespace-pre-wrap text-[12px] leading-relaxed text-muted-foreground">
        {message}
      </p>
      {onRetry && (
        <Button onClick={onRetry} variant="outline">
          {retryLabel ?? t("Retry", "重试")}
        </Button>
      )}
    </div>
  );
}

export function InlineNotice({
  children,
  tone = "warning",
}: {
  children: ReactNode;
  tone?: "warning" | "error" | "info";
}) {
  return (
    <div
      className={cn(
        "flex items-start gap-2 px-4 py-2 text-[11.5px]",
        tone === "info"
          ? "bg-blue-500/[0.08] text-blue-700 dark:text-blue-300"
          : "bg-orange-500/[0.08] text-orange-700 dark:text-orange-300",
      )}
      role={tone === "error" ? "alert" : "status"}
    >
      <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
      <div className="min-w-0 flex-1">{children}</div>
    </div>
  );
}

export function PrivacyText({
  kind = "identifier",
}: {
  kind?: "identifier" | "path" | "branch";
}) {
  return (
    <span
      aria-label="Hidden"
      className={cn(
        "cc-private-block",
        kind === "path" && "cc-private-path",
        kind === "branch" && "cc-private-branch",
      )}
    />
  );
}
