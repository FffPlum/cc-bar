import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { cn } from "@/lib/utils";

export function SelectField<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
  className,
  contentAlign = "start",
  disabled = false,
}: {
  value: T;
  options: readonly { value: T; label: string }[];
  onChange: (value: T) => void;
  ariaLabel: string;
  className?: string;
  contentAlign?: "start" | "end";
  disabled?: boolean;
}) {
  return (
    <Select
      value={value}
      items={options}
      onValueChange={(next) => {
        if (next) onChange(next as T);
      }}
      disabled={disabled}
    >
      <SelectTrigger
        size="sm"
        aria-label={ariaLabel}
        className={cn("max-w-56 text-[13px]", className)}
      >
        <SelectValue />
      </SelectTrigger>
      <SelectContent align={contentAlign}>
        {options.map((option) => (
          <SelectItem
            key={option.value}
            value={option.value}
            className="text-[13px]"
          >
            {option.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}
