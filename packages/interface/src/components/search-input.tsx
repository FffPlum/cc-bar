import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

export function SearchInput({
  value,
  onChange,
  placeholder,
  privateValue = false,
  className,
  ariaLabel,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  privateValue?: boolean;
  className?: string;
  ariaLabel?: string;
}) {
  return (
    <div className={cn("relative min-w-0", className)}>
      <Search className="cc-tertiary pointer-events-none absolute left-2 top-1/2 size-3 -translate-y-1/2" />
      <Input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        aria-label={ariaLabel ?? placeholder}
        type={privateValue ? "password" : "search"}
        autoComplete="off"
        className="h-7 border-0 bg-black/[0.06] pl-6 pr-2 text-[11.5px] shadow-none focus-visible:ring-1 dark:bg-white/[0.08]"
      />
    </div>
  );
}
