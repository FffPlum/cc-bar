import { useState } from "react";
import { Dialog } from "@base-ui/react/dialog";
import { CircleHelp, SlidersHorizontal, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { SelectField } from "@/components/select-field";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { useTranslation } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import type { StatsView } from "@/features/stats/stats-page";
import "./stats-view-drawer.css";

export function StatsViewDrawer({
  view,
  onView,
  className,
}: {
  view: StatsView;
  onView: (view: StatsView) => void;
  className?: string;
}) {
  const t = useTranslation();
  const [instant, setInstant] = useState(false);
  const views: { value: StatsView; label: string }[] = [
    { value: "overview", label: t("Overview", "概览") },
    { value: "conversations", label: t("Conversations", "对话") },
    { value: "projects", label: t("Projects", "项目") },
    { value: "quota", label: t("Quota", "额度") },
  ];
  return (
    <Dialog.Root
      onOpenChange={(_, { event }) => {
        setInstant(
          event instanceof KeyboardEvent ||
            (event instanceof MouseEvent && event.detail === 0),
        );
      }}
    >
      <Dialog.Trigger
        render={
          <Button
            variant="outline"
            size="icon"
            className={cn("focus-visible:z-10", className)}
            aria-label={t("Usage settings", "用量设置")}
            title={t("Usage settings", "用量设置")}
          />
        }
      >
        <SlidersHorizontal aria-hidden="true" />
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Backdrop
          data-instant={instant || undefined}
          className="cc-stats-drawer-backdrop fixed inset-0 z-50 bg-black/10"
        />
        <Dialog.Popup
          data-instant={instant || undefined}
          className="cc-stats-drawer fixed inset-y-0 right-0 z-50 flex w-[360px] max-w-full flex-col overflow-hidden border-l bg-popover text-popover-foreground outline-none"
        >
          <div className="flex min-w-0 shrink-0 items-center gap-3 border-b p-4">
            <Dialog.Title className="min-w-0 flex-1 truncate text-[17px] font-bold tracking-[-0.4px]">
              {t("Usage settings", "用量设置")}
            </Dialog.Title>
            <Dialog.Close
              render={
                <Button
                  variant="ghost"
                  size="icon"
                  aria-label={t("Close usage settings", "关闭用量设置")}
                />
              }
            >
              <X aria-hidden="true" />
            </Dialog.Close>
          </div>
          <div className="flex min-h-0 flex-1 flex-col items-stretch justify-start gap-4 overflow-y-auto p-4">
            <div className="flex items-center justify-between gap-3">
              <div className="flex min-w-0 items-center gap-1">
                <span className="text-[13px] font-medium">
                  {t("Switch view", "切换视图")}
                </span>
                <Popover>
                  <PopoverTrigger
                    render={
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label={t("About statistics views", "统计视图说明")}
                      />
                    }
                  >
                    <CircleHelp className="size-3.5" aria-hidden="true" />
                  </PopoverTrigger>
                  <PopoverContent
                    align="start"
                    className="w-72 p-3 text-[12px]"
                  >
                    <p>
                      {t(
                        "Overview: totals, trends and request details.",
                        "概览：查看用量汇总、趋势和请求明细。",
                      )}
                    </p>
                    <p>
                      {t(
                        "Conversations: compare usage and details for individual conversations.",
                        "对话：比较单个对话的用量并查看详情。",
                      )}
                    </p>
                    <p>
                      {t(
                        "Projects: compare usage by project and inspect related conversations.",
                        "项目：按项目比较用量并查看相关对话。",
                      )}
                    </p>
                    <p>
                      {t(
                        "Quota: view account allowances and estimated daily usage.",
                        "额度：查看账号额度与每日用量估算。",
                      )}
                    </p>
                  </PopoverContent>
                </Popover>
              </div>
              <SelectField
                value={view}
                options={views}
                onChange={onView}
                ariaLabel={t("Switch view", "切换视图")}
                contentAlign="end"
                className="shrink-0 data-[size=sm]:h-8"
              />
            </div>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
