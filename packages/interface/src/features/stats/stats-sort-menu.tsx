import { ArrowDownWideNarrow, ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useTranslation } from "@/lib/i18n";

export function StatsSortMenu<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: T;
  options: readonly { value: T; label: string }[];
  onChange: (value: T) => void;
  ariaLabel: string;
}) {
  const t = useTranslation();
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            variant="ghost"
            size="sm"
            className="max-w-[150px]"
            aria-label={ariaLabel}
          />
        }
      >
        <ArrowDownWideNarrow aria-hidden="true" />
        <span className="truncate">
          {options.find((option) => option.value === value)?.label}
        </span>
        <ChevronDown aria-hidden="true" />
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        className="w-max min-w-(--anchor-width) max-w-(--available-width)"
      >
        <DropdownMenuRadioGroup
          value={value}
          onValueChange={(next) => {
            const option = options.find((option) => option.value === next);
            if (option) onChange(option.value);
          }}
          aria-label={t("Sort", "排序")}
        >
          {options.map((option) => (
            <DropdownMenuRadioItem
              key={option.value}
              value={option.value}
              closeOnClick
            >
              {option.label}
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
