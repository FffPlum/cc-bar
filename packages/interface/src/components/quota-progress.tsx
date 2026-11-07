import { cn } from "@/lib/utils";

export function quotaStatusClass(remainingPercent: number): string {
  if (remainingPercent <= 0) return "cc-status-empty";
  if (remainingPercent < 20) return "cc-status-low";
  return "cc-status-normal";
}

export function QuotaProgress({
  remainingPercent,
  height = 6,
  className,
}: {
  remainingPercent: number;
  height?: number;
  className?: string;
}) {
  const value = Math.max(0, Math.min(100, remainingPercent));
  return (
    <div
      className={cn(
        "w-full overflow-hidden rounded-full bg-secondary",
        className,
      )}
      style={{ height }}
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={value}
    >
      <div
        className={cn(
          "h-full rounded-full bg-current",
          quotaStatusClass(value),
        )}
        style={{ width: `${value}%` }}
      />
    </div>
  );
}
