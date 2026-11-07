import { useEffect, useState } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { SelectField } from "@/components/select-field";
import { useTranslation } from "@/lib/i18n";

export function RequestPagination({
  totalCount,
  page,
  pageSize,
  disabled,
  onPageChange,
  onPageSizeChange,
}: {
  totalCount: number | null;
  page: number;
  pageSize: number;
  disabled: boolean;
  onPageChange: (page: number) => void;
  onPageSizeChange: (pageSize: number) => void;
}) {
  const t = useTranslation();
  const totalPages = Math.max(1, Math.ceil((totalCount ?? 0) / pageSize));
  const [input, setInput] = useState(String(page));
  useEffect(() => setInput(String(page)), [page, pageSize]);
  const unavailable = disabled || totalCount === null;
  const commit = () => {
    const value = Number(input);
    if (unavailable || !/^\d+$/.test(input) || !Number.isSafeInteger(value)) {
      setInput(String(page));
      return;
    }
    const next = Math.min(totalPages, Math.max(1, value));
    setInput(String(next));
    if (next !== page) onPageChange(next);
  };
  return (
    <div className="flex min-h-14 flex-wrap items-center justify-between gap-3 border-t px-3 py-2 tabular-nums">
      <div className="flex items-center gap-3">
        <span className="text-muted-foreground">
          {t(
            `${totalCount?.toLocaleString() ?? "—"} records`,
            `共 ${totalCount?.toLocaleString() ?? "—"} 条`,
          )}
        </span>
        <SelectField
          value={String(pageSize)}
          options={[12, 24, 48, 96].map((size) => ({
            value: String(size),
            label: t(`${size} / page`, `${size} 条 / 页`),
          }))}
          ariaLabel={t("Rows per page", "每页条数")}
          disabled={unavailable}
          onChange={(value) => onPageSizeChange(Number(value))}
        />
      </div>
      <nav
        aria-label={t("Request log pagination", "请求日志分页")}
        className="flex items-center gap-2"
      >
        <Button
          size="icon-sm"
          variant="outline"
          aria-label={t("Previous", "上一页")}
          disabled={unavailable || page <= 1}
          onClick={() => onPageChange(page - 1)}
        >
          <ChevronLeft aria-hidden="true" />
        </Button>
        <div className="flex items-center gap-1.5">
          <Input
            aria-label={t("Current page", "当前页码")}
            type="text"
            inputMode="numeric"
            className="h-7 w-14 px-1 text-center text-xs tabular-nums"
            value={input}
            disabled={unavailable}
            onChange={(event) => setInput(event.target.value)}
            onBlur={commit}
            onKeyDown={(event) => {
              if (event.key === "Enter") event.currentTarget.blur();
              if (event.key === "Escape") setInput(String(page));
            }}
          />
          <span className="text-muted-foreground">
            / {totalCount === null ? "—" : totalPages.toLocaleString()}
          </span>
        </div>
        <Button
          size="icon-sm"
          variant="outline"
          aria-label={t("Next", "下一页")}
          disabled={unavailable || page >= totalPages}
          onClick={() => onPageChange(page + 1)}
        >
          <ChevronRight aria-hidden="true" />
        </Button>
      </nav>
    </div>
  );
}
