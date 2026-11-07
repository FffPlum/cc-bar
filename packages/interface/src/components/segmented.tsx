import { cn } from "@/lib/utils";

export interface SegmentOption<T extends string> {
  value: T;
  label: string;
  ariaLabel?: string;
}

export function Segmented<T extends string>({
  value,
  options,
  onChange,
  className,
  stretch = false,
  ariaLabel,
}: {
  value: T;
  options: readonly SegmentOption<T>[];
  onChange: (value: T) => void;
  className?: string;
  stretch?: boolean;
  ariaLabel: string;
}) {
  return (
    <div
      className={cn("cc-segmented", stretch && "flex w-full", className)}
      role="group"
      aria-label={ariaLabel}
    >
      {options.map((option) => (
        <button
          type="button"
          key={option.value}
          className={cn("cc-segment", stretch && "min-w-0 flex-1 px-1")}
          aria-pressed={value === option.value}
          aria-label={option.ariaLabel}
          onClick={() => onChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
