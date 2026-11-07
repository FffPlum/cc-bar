import { useEffect, useRef, useState } from "react";
import type {
  SettingsPatch,
  UsageOperationStatus,
} from "@ccbar/host-api/window";
import { Dialog } from "@base-ui/react/dialog";
import { CircleHelp, SlidersHorizontal, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { SelectField } from "@/components/select-field";
import { Switch } from "@/components/ui/switch";
import { PendingButton } from "@/components/pending-button";
import { SettingsGroup, SettingsRow } from "@/components/workspace";
import { errorMessage, useHost } from "@/host/host-context";
import { formatDate } from "@/lib/display";
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
  onSync,
  syncing,
  syncError,
  status,
  className,
}: {
  view: StatsView;
  onView: (view: StatsView) => void;
  onSync: () => void;
  syncing: boolean;
  syncError?: string | null;
  status?: UsageOperationStatus;
  className?: string;
}) {
  const t = useTranslation();
  const { api, settings, bootstrap, refreshSettings, hostError } = useHost();
  const [open, setOpen] = useState(false);
  const [instant, setInstant] = useState(false);
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => setOpen(false), [view]);
  const update = async (patch: SettingsPatch) => {
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    setError(null);
    try {
      await api.settingsUpdate(patch);
      await refreshSettings();
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  };
  const intervalOptions = (["m1", "m2", "m3", "m5", "m10"] as const).map(
    (value) => ({
      value,
      label: t(
        `${Number(value.slice(1))} min`,
        `${Number(value.slice(1))} 分钟`,
      ),
    }),
  );
  const views: { value: StatsView; label: string }[] = [
    { value: "overview", label: t("Overview", "概览") },
    { value: "conversations", label: t("Conversations", "对话") },
    { value: "projects", label: t("Projects", "项目") },
    { value: "quota", label: t("Quota", "额度") },
  ];
  return (
    <Dialog.Root
      open={open}
      onOpenChange={(next, { event }) => {
        setOpen(next);
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
                onChange={(next) => {
                  onView(next);
                  setOpen(false);
                }}
                ariaLabel={t("Switch view", "切换视图")}
                contentAlign="end"
                className="shrink-0 data-[size=sm]:h-8"
              />
            </div>
            <SettingsGroup title={t("Data sources", "数据来源")}>
              <div className="space-y-3 px-4 py-3">
                <div className="flex items-center justify-between gap-3">
                  <span className="text-[13px]">
                    {t("Automatically scan session logs", "自动扫描会话日志")}
                  </span>
                  <Switch
                    checked={settings.data.usageAutoScanEnabled}
                    disabled={saving}
                    aria-label={t(
                      "Automatically scan session logs",
                      "自动扫描会话日志",
                    )}
                    onCheckedChange={(usageAutoScanEnabled) =>
                      void update({ usageAutoScanEnabled })
                    }
                  />
                </div>
                <div className="space-y-1 text-[11px] leading-relaxed text-muted-foreground">
                  <p>
                    {settings.data.usageAutoScanEnabled
                      ? t(
                          "Scan local session logs in the background.",
                          "在后台定期扫描本机会话日志。",
                        )
                      : t(
                          "Automatic scanning is off. Sync manually to update usage.",
                          "自动扫描已关闭，可手动同步更新用量。",
                        )}
                  </p>
                  <p>
                    {status?.lastScanAt
                      ? `${t("Last synced", "上次同步")} · ${formatDate(status.lastScanAt, bootstrap.resolvedLanguage, bootstrap.timeZone, true)}`
                      : t("Not synced yet", "尚未同步")}
                  </p>
                </div>
                <div className="flex items-center justify-between gap-3">
                  <SelectField
                    value={settings.data.usageInterval}
                    options={intervalOptions}
                    onChange={(usageInterval) => void update({ usageInterval })}
                    disabled={saving || !settings.data.usageAutoScanEnabled}
                    ariaLabel={t("Scan interval", "扫描周期")}
                  />
                  <PendingButton
                    variant="outline"
                    size="sm"
                    pending={syncing}
                    onClick={onSync}
                  >
                    {syncing
                      ? t("Syncing…", "同步中…")
                      : t("Sync now", "立刻同步")}
                  </PendingButton>
                </div>
                {(syncError || status?.error) && (
                  <p
                    role="alert"
                    className="text-[11px] text-red-600 dark:text-red-400"
                  >
                    {syncError || status?.error}
                  </p>
                )}
              </div>
            </SettingsGroup>
            <SettingsGroup title={t("Display", "显示")}>
              <SettingsRow label={t("Chart type", "图表类型")}>
                <SelectField
                  value={settings.appearance.statsChartType}
                  options={[
                    { value: "bar", label: t("Bar chart", "柱状图") },
                    { value: "area", label: t("Area chart", "曲线面积图") },
                  ]}
                  onChange={(statsChartType) => void update({ statsChartType })}
                  disabled={saving}
                  ariaLabel={t("Chart type", "图表类型")}
                  contentAlign="end"
                />
              </SettingsRow>
            </SettingsGroup>
            {(error || hostError) && (
              <p
                role="alert"
                className="text-[11.5px] text-red-600 dark:text-red-400"
              >
                {error || hostError}
              </p>
            )}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
