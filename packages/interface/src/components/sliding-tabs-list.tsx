import { Tabs as TabsPrimitive } from "@base-ui/react/tabs";
import { TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";

export function SlidingTabsList({
  options,
  ariaLabel,
  className,
}: {
  options: readonly { value: string; label: string }[];
  ariaLabel: string;
  className?: string;
}) {
  return (
    <TabsList
      aria-label={ariaLabel}
      className={cn("relative isolate shrink-0", className)}
    >
      {options.map((option) => (
        <TabsTrigger
          key={option.value}
          value={option.value}
          className="z-10 transition-colors data-active:bg-transparent dark:data-active:border-transparent dark:data-active:bg-transparent group-data-[variant=default]/tabs-list:data-active:shadow-none"
        >
          {option.label}
        </TabsTrigger>
      ))}
      <TabsPrimitive.Indicator
        aria-hidden="true"
        data-slot="sliding-tabs-indicator"
        className="pointer-events-none absolute left-0 z-0 rounded-md border border-transparent bg-background shadow-sm dark:border-input dark:bg-input/30 motion-safe:transition-transform motion-safe:duration-150 motion-safe:ease-[cubic-bezier(0.77,0,0.175,1)] motion-reduce:transition-none"
        style={{
          top: "var(--active-tab-top)",
          width: "var(--active-tab-width)",
          height: "var(--active-tab-height)",
          transform: "translateX(var(--active-tab-left))",
        }}
      />
    </TabsList>
  );
}
