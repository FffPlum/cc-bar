import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import type { SettingsPatch, WindowSettings } from "@ccbar/host-api/window";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { PageHeader } from "@/components/page-header";
import { SettingsGroup, SettingsRow } from "@/components/workspace";
import { SelectField } from "@/components/select-field";
import { PendingButton } from "@/components/pending-button";
import { BrandColorEditor } from "@/features/settings/brand-color-editor";
import { PricingCatalogDialog } from "@/features/settings/pricing-catalog-dialog";
import { useHost, errorMessage } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { applicationDisplayName, formatDate, formatTime } from "@/lib/display";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";

export type SettingsSection = "appearance" | "data" | "general";

export function SettingsPage({ section }: { section: SettingsSection }) {
  const { api, settings, refreshSettings, refreshBootstrap } = useHost();
  const t = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<
    "brands" | "diagnostics" | "alerts" | null
  >(null);
  const [message, setMessage] = useState<string | null>(null);

  const update = async (key: string, patch: SettingsPatch) => {
    if (pending) return;
    setPending(key);
    setError(null);
    try {
      await api.settingsUpdate(patch);
      if (
        patch.quotaAlertsEnabled === true ||
        patch.quotaAlertSoundEnabled === true
      )
        await api.notificationsRequestPermission();
      await refreshSettings();
      await refreshBootstrap();
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setPending(null);
    }
  };
  const action = async (key: string, run: () => Promise<unknown>) => {
    if (pending) return;
    setPending(key);
    setError(null);
    setMessage(null);
    try {
      await run();
      await refreshSettings();
      await refreshBootstrap();
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setPending(null);
    }
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader
        page="settings"
        title={
          section === "appearance"
            ? t("Appearance & Display", "外观与显示")
            : section === "data"
              ? t("Data & Refresh", "数据与刷新")
              : t("General", "通用")
        }
      />
      {error && (
        <p
          className="mx-9 mt-3 text-[11.5px] text-red-600 dark:text-red-400"
          role="alert"
        >
          {error}
        </p>
      )}
      {message && (
        <p
          className="mx-9 mt-3 text-[11.5px] text-muted-foreground"
          role="status"
        >
          {message}
        </p>
      )}
      <div key={section} className="cc-scrollbar min-h-0 flex-1">
        <div className="mx-auto flex max-w-[680px] flex-col gap-[22px] px-9 py-6">
          <fieldset disabled={pending !== null} className="contents">
            {section === "appearance" && (
              <AppearanceSettings
                settings={settings}
                pending={pending}
                update={update}
                onReset={() => setConfirm("brands")}
              />
            )}
            {section === "data" && (
              <DataSettings
                settings={settings}
                pending={pending}
                update={update}
                action={action}
                setMessage={setMessage}
              />
            )}
            {section === "general" && (
              <GeneralSettings
                settings={settings}
                pending={pending}
                update={update}
                action={action}
                setMessage={setMessage}
                onConfirm={setConfirm}
              />
            )}
          </fieldset>
        </div>
      </div>
      {confirm === "brands" && (
        <ConfirmDialog
          title={t("Reset to Brand Colors?", "恢复品牌主题色？")}
          description={t(
            "Restore every service to its default brand color. Custom colors are discarded.",
            "将所有服务恢复为默认品牌主题色，自定义颜色会被清除。",
          )}
          actionLabel={t("Reset", "恢复")}
          onClose={() => setConfirm(null)}
          onAction={() =>
            action("brands", () => api.settingsResetBrandColors())
          }
        />
      )}
      {confirm === "diagnostics" && (
        <ConfirmDialog
          title={t("Export diagnostics?", "导出诊断日志？")}
          description={t(
            "The zip contains app and macOS versions, settings, service status and scan statistics. It contains no tokens, plain-text email, conversation content, file contents or project names. Nothing is uploaded.",
            "压缩包包含 App 与 macOS 版本、设置、服务状态和扫描统计；不含登录令牌、明文邮箱、对话内容、文件内容或项目名，不会上传任何内容。",
          )}
          actionLabel={t("Export", "导出")}
          onClose={() => setConfirm(null)}
          onAction={() =>
            action("diagnostics", async () => {
              await api.diagnosticsExport();
              setMessage(t("Revealed in Finder", "已在 Finder 中显示"));
            })
          }
        />
      )}
      {confirm === "alerts" && (
        <ConfirmDialog
          title={t("Rebuild alert history?", "重建提醒记录？")}
          description={t(
            "Current low quotas will be recorded as already alerted. Alerts resume after recovery or reset. The original file is kept as a backup.",
            "当前低额度先记录为已提醒，恢复或重置后再提醒。原记录文件保留为备份。",
          )}
          actionLabel={t("Rebuild", "重建")}
          onClose={() => setConfirm(null)}
          onAction={() => action("alerts", () => api.notificationsRebuild())}
        />
      )}
    </div>
  );
}

type Update = (key: string, patch: SettingsPatch) => Promise<void>;
type Action = (key: string, run: () => Promise<unknown>) => Promise<void>;

function AppearanceSettings({
  settings,
  pending,
  update,
  onReset,
}: {
  settings: WindowSettings;
  pending: string | null;
  update: Update;
  onReset: () => void;
}) {
  const t = useTranslation();
  const value = settings.appearance;
  const { api } = useHost();
  const [guideOpen, setGuideOpen] = useState(false);
  const [guideError, setGuideError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  return (
    <>
      <SettingsGroup title={t("Menu Bar", "菜单栏")}>
        <SettingsRow label={t("Quota period", "额度周期")}>
          <SelectField
            value={value.menuBarWindow}
            options={[
              { value: "primary", label: t("Main", "主额度") },
              { value: "weekly", label: t("Weekly", "周额度") },
              { value: "both", label: t("Both", "都显示") },
            ]}
            onChange={(menuBarWindow) =>
              void update("menuBarWindow", { menuBarWindow })
            }
            ariaLabel={t("Quota period", "额度周期")}
            disabled={pending !== null}
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("Floating HUD", "桌面悬浮窗")}>
        <SettingsRow
          label={t("Show floating window", "显示悬浮窗")}
          description={t(
            "Choose accounts in Quota Management.",
            "显示哪些账号在「额度管理」中设置",
          )}
        >
          <Switch
            checked={value.floatingEnabled}
            onCheckedChange={(floatingEnabled) =>
              void update("floating", { floatingEnabled })
            }
            disabled={pending !== null}
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("Display Details", "显示细节")}>
        <SettingsRow label={t("Reset time", "重置时间")}>
          <SelectField
            value={value.resetTimeDisplay}
            options={[
              { value: "relative", label: t("Remaining", "剩余时长") },
              { value: "absolute", label: t("Exact time", "具体时间") },
            ]}
            onChange={(resetTimeDisplay) =>
              void update("resetTime", { resetTimeDisplay })
            }
            ariaLabel={t("Reset time", "重置时间")}
          />
        </SettingsRow>
        <SettingsRow label={t("Official status dot", "官方状态圆点")}>
          <Switch
            checked={value.showServiceStatus}
            onCheckedChange={(showServiceStatus) =>
              void update("status", { showServiceStatus })
            }
          />
        </SettingsRow>
        <SettingsRow
          label={t("Follow installed app icons", "跟随已安装 App 图标")}
          description={t(
            "When enabled, use the app icon for this service.",
            "启用后使用此服务对应 App 的图标",
          )}
        >
          <Switch
            checked={value.useInstalledAppIcons}
            onCheckedChange={(useInstalledAppIcons) =>
              void update("icons", { useInstalledAppIcons })
            }
          />
        </SettingsRow>
        <SettingsRow
          label={t("Privacy mode", "隐私模式")}
          description={t(
            "Hide account, project, and conversation names for screenshots. Usage numbers stay visible.",
            "隐藏账号、项目和对话名称，用量数据照常显示，便于截图分享",
          )}
        >
          <Switch
            checked={value.privacyMode}
            onCheckedChange={(privacyMode) =>
              void update("privacy", { privacyMode })
            }
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup
        title={t("Brand Colors", "品牌颜色")}
        description={t(
          "Customize the color used to identify each service in charts and legends.",
          "自定义各服务在图表和图例中的识别色",
        )}
      >
        {value.brandColors.map((brand) => (
          <SettingsRow
            key={brand.brand}
            label={applicationDisplayName(brand.brand)}
            leading={
              <span
                className="size-[22px] rounded-md"
                style={{
                  backgroundColor:
                    brand.mode === "custom"
                      ? (brand.customHex ?? brand.defaultLightHex)
                      : brand.defaultLightHex,
                }}
              />
            }
          >
            <BrandColorEditor
              brand={brand}
              recent={value.recentBrandColors}
              presets={value.brandColors}
              disabled={pending !== null}
              onApply={(patch) =>
                void update(`brand:${brand.brand}`, { brandColor: patch })
              }
            />
          </SettingsRow>
        ))}
        <SettingsRow label={t("Reset to Brand Colors", "恢复品牌主题色")}>
          <Button size="sm" variant="outline" onClick={onReset}>
            {t("Reset", "恢复")}
          </Button>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("Statistics", "统计")}>
        <SettingsRow
          label={t("Ranking metric", "排行口径")}
          description={t(
            "Used for sorting and shares in Overview and Projects.",
            "用于概览和项目页的排序与占比",
          )}
        >
          <SelectField
            value={value.statsRankMetric}
            options={[
              { value: "tokens", label: "Tokens" },
              { value: "cost", label: t("Cost", "费用") },
            ]}
            onChange={(statsRankMetric) =>
              void update("rank", { statsRankMetric })
            }
            ariaLabel={t("Ranking metric", "排行口径")}
          />
        </SettingsRow>
        <SettingsRow
          label={t(
            "Include Codex subscription usage in Pi, OpenCode and DSH",
            "包含 Pi、OpenCode、DSH 中的 Codex 订阅用量",
          )}
        >
          <Switch
            checked={value.cycleIncludesOtherAgents}
            onCheckedChange={(cycleIncludesOtherAgents) =>
              void update("cycles", { cycleIncludesOtherAgents })
            }
          />
        </SettingsRow>
        <SettingsRow
          label={t("Estimate Pi output speed", "估算 Pi 输出速度")}
          description={t(
            "Pi logs only record total request time, so the estimate reads low. Plugin-timed requests always use actual generation time.",
            "Pi 日志只记录请求总耗时，估算值偏低；插件计时的请求始终按实际生成时间计算",
          )}
          detail={
            <Button
              variant="link"
              size="sm"
              className="h-auto px-0"
              onClick={() => setGuideOpen(true)}
            >
              {t("Timing plugin instructions", "计时插件说明")}
            </Button>
          }
        >
          <Switch
            checked={value.piEstimatedOutputSpeed}
            onCheckedChange={(piEstimatedOutputSpeed) =>
              void update("piSpeed", { piEstimatedOutputSpeed })
            }
          />
        </SettingsRow>
      </SettingsGroup>
      {guideOpen && (
        <Dialog open onOpenChange={setGuideOpen}>
          <DialogContent className="sm:max-w-[560px]">
            <DialogHeader>
              <DialogTitle>{settings.data.piTimingGuide.title}</DialogTitle>
              <DialogDescription>
                {t(
                  "Use the plugin to record actual generation timing.",
                  "使用插件记录实际生成耗时。",
                )}
              </DialogDescription>
            </DialogHeader>
            <div className="cc-scrollbar max-h-[55vh] whitespace-pre-wrap text-xs leading-relaxed">
              {settings.data.piTimingGuide.instructions}
            </div>
            {guideError && (
              <p role="alert" className="text-xs text-red-600">
                {guideError}
              </p>
            )}
            <DialogFooter>
              <Button variant="outline" onClick={() => setGuideOpen(false)}>
                {t("Done", "完成")}
              </Button>
              <Button
                onClick={() =>
                  void api
                    .settingsCopyPiTimingGuide()
                    .then(() => {
                      setCopied(true);
                      setGuideError(null);
                    })
                    .catch((reason: unknown) =>
                      setGuideError(errorMessage(reason)),
                    )
                }
              >
                {copied
                  ? t("Copied", "已复制")
                  : t("Copy setup instructions", "复制安装步骤")}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
    </>
  );
}

function DataSettings({
  settings,
  pending,
  update,
  action,
  setMessage,
}: {
  settings: WindowSettings;
  pending: string | null;
  update: Update;
  action: Action;
  setMessage: (message: string) => void;
}) {
  const { api, bootstrap } = useHost();
  const t = useTranslation();
  const value = settings.data;
  const [proxyHost, setProxyHost] = useState(value.proxyHost);
  const [proxyPort, setProxyPort] = useState(
    value.proxyPort ? String(value.proxyPort) : "",
  );
  const [proxyResult, setProxyResult] = useState<string | null>(null);
  const [catalogOpen, setCatalogOpen] = useState(false);
  useEffect(() => {
    setProxyHost(value.proxyHost);
    setProxyPort(value.proxyPort ? String(value.proxyPort) : "");
  }, [value.proxyHost, value.proxyPort]);
  const intervalOptions = (["m1", "m2", "m3", "m5", "m10"] as const).map(
    (interval) => ({
      value: interval,
      label: t(
        `${Number(interval.slice(1))} minute`,
        `${Number(interval.slice(1))} 分钟`,
      ),
    }),
  );
  const currency = value.currency;
  const rate = currency.rates[currency.selected];
  return (
    <>
      <SettingsGroup title={t("Polling Intervals", "后台刷新")}>
        <SettingsRow label={t("Quota refresh", "额度刷新")}>
          <SelectField
            value={value.quotaInterval}
            options={intervalOptions}
            onChange={(quotaInterval) =>
              void update("quotaInterval", { quotaInterval })
            }
            ariaLabel={t("Quota refresh", "额度刷新")}
          />
        </SettingsRow>
        <SettingsRow
          label={t("Automatically scan session logs", "自动扫描会话日志")}
        >
          <Switch
            checked={value.usageAutoScanEnabled}
            onCheckedChange={(usageAutoScanEnabled) =>
              void update("usageAutoScanEnabled", { usageAutoScanEnabled })
            }
          />
        </SettingsRow>
        <SettingsRow label={t("Scan interval", "扫描周期")}>
          <SelectField
            value={value.usageInterval}
            options={intervalOptions}
            disabled={!value.usageAutoScanEnabled}
            onChange={(usageInterval) =>
              void update("usageInterval", { usageInterval })
            }
            ariaLabel={t("Scan interval", "扫描周期")}
          />
        </SettingsRow>
        <SettingsRow label={t("Last refresh", "上次刷新")}>
          <span className="cc-number text-[11.5px] text-muted-foreground">
            {formatTime(value.usage.lastScanAt, bootstrap.timeZone)}
          </span>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("Network Proxy", "网络代理")}>
        <SettingsRow
          label={t("Proxy", "代理")}
          description={
            value.proxyMode === "manual"
              ? t(
                  "If the proxy is unavailable, requests stop instead of connecting directly.",
                  "代理不可用时停止取数，不改为直连",
                )
              : undefined
          }
        >
          <SelectField
            value={value.proxyMode}
            options={[
              { value: "system", label: t("Follow System", "跟随系统") },
              { value: "manual", label: t("Manual", "手动") },
            ]}
            onChange={(proxyMode) => {
              setProxyResult(null);
              void update("proxyMode", { proxyMode });
            }}
            ariaLabel={t("Proxy", "代理")}
          />
        </SettingsRow>
        {value.proxyMode === "manual" && (
          <>
            <SettingsRow
              label={t("Type", "类型")}
              description={
                value.proxyType === "socks5"
                  ? t(
                      "The claude and agy command-line quota queries are skipped.",
                      "SOCKS5 下不调用 claude、agy 命令行查询额度",
                    )
                  : undefined
              }
            >
              <SelectField
                value={value.proxyType}
                options={[
                  { value: "http", label: "HTTP" },
                  { value: "socks5", label: "SOCKS5" },
                ]}
                onChange={(proxyType) => {
                  setProxyResult(null);
                  void update("proxyType", { proxyType });
                }}
                ariaLabel={t("Type", "类型")}
              />
            </SettingsRow>
            <SettingsRow label={t("Address", "地址")}>
              <div className="flex items-center gap-1">
                <Input
                  value={proxyHost}
                  onChange={(event) => {
                    setProxyHost(event.target.value);
                    setProxyResult(null);
                  }}
                  placeholder={t("Host", "主机")}
                  className="h-7 w-[140px]"
                />
                <span>:</span>
                <Input
                  value={proxyPort}
                  onChange={(event) => {
                    setProxyPort(
                      event.target.value.replace(/\D/g, "").slice(0, 5),
                    );
                    setProxyResult(null);
                  }}
                  placeholder={t("Port", "端口")}
                  className="cc-number h-7 w-16"
                  inputMode="numeric"
                />
                <Button
                  size="sm"
                  variant="outline"
                  disabled={
                    !proxyHost.trim() ||
                    Number(proxyPort) < 1 ||
                    Number(proxyPort) > 65535
                  }
                  onClick={() =>
                    void update("proxyAddress", {
                      proxyHost: proxyHost.trim(),
                      proxyPort: Number(proxyPort),
                    })
                  }
                >
                  {t("Save", "保存")}
                </Button>
              </div>
            </SettingsRow>
            <SettingsRow label={t("Connection test", "连接测试")}>
              <span className="max-w-60 text-right text-[11px] text-muted-foreground">
                {proxyResult}
              </span>
              <PendingButton
                disabled={
                  !proxyHost.trim() ||
                  Number(proxyPort) < 1 ||
                  Number(proxyPort) > 65535
                }
                pending={pending === "proxy"}
                size="sm"
                variant="outline"
                onClick={() =>
                  void action("proxy", async () => {
                    await api.settingsUpdate({
                      proxyHost: proxyHost.trim(),
                      proxyPort: Number(proxyPort),
                    });
                    const result = await api.settingsTestProxy();
                    setProxyResult(result.message);
                  })
                }
              >
                {t("Test", "测试")}
              </PendingButton>
            </SettingsRow>
          </>
        )}
      </SettingsGroup>
      <SettingsGroup title={t("Currency", "货币")}>
        <SettingsRow
          label={t("Display currency", "货币单位")}
          description={
            currency.selected === "USD"
              ? t(
                  "Amounts are stored in USD. Currency selection changes display only.",
                  "金额以美元存储，切换币种只改变显示",
                )
              : currency.lastRefreshFailedAt
                ? t(
                    "Refresh failed. Existing rates and amounts are kept.",
                    "刷新失败，保留已有汇率和金额",
                  )
                : rate
                  ? `1 USD = ${rate} ${currency.selected} · ${formatDate(currency.fetchedAt, bootstrap.resolvedLanguage, bootstrap.timeZone)}`
                  : t(
                      "Refresh to fetch the current exchange rate. Amounts remain in USD until then.",
                      "刷新获取当前汇率，在此之前金额仍显示美元",
                    )
          }
        >
          <SelectField
            value={currency.selected}
            options={(
              ["USD", "CNY", "JPY", "KRW", "HKD", "AUD", "SGD", "GBP"] as const
            ).map((code) => ({ value: code, label: code }))}
            onChange={(currency) => void update("currency", { currency })}
            ariaLabel={t("Display currency", "货币单位")}
          />
          <PendingButton
            pending={pending === "currency" || currency.refreshing}
            size="icon-sm"
            variant="outline"
            aria-label={t("Refresh exchange rates", "刷新汇率")}
            onClick={() =>
              void action("currency", () => api.settingsRefreshCurrency())
            }
          >
            <RefreshCw />
          </PendingButton>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("Data Maintenance", "数据维护")}>
        <SettingsRow
          label={t("Price catalog", "价格目录")}
          description={t(
            "Official provider prices from models.dev.",
            "models.dev 官方提供商价格",
          )}
        >
          <Button
            size="sm"
            variant="outline"
            onClick={() => setCatalogOpen(true)}
          >
            {t("View", "查看")}
          </Button>
        </SettingsRow>
        <SettingsRow
          label={t("Update prices & recalculate usage", "更新价格并重算用量")}
          description={t(
            "Fetch models.dev, then recompute history with the latest prices and rules. Usage from deleted logs is kept.",
            "先更新 models.dev 价格，再按最新价格和规则重算历史；已删除日志的对话保留用量",
          )}
          detail={
            <div>
              {value.usage.progress && (
                <p role="status">
                  {applicationDisplayName(value.usage.progress.service)} ·{" "}
                  {value.usage.progress.filesCompleted} /{" "}
                  {value.usage.progress.filesTotal} {t("files", "个文件")} ·{" "}
                  {value.usage.progress.linesParsed} {t("lines", "行")}
                </p>
              )}
              {value.usage.lastRebuildMessage && (
                <span className="text-muted-foreground">
                  {value.usage.lastRebuildMessage}
                </span>
              )}
            </div>
          }
        >
          <PendingButton
            pending={
              pending === "recalculate" ||
              value.usage.refreshingPricing ||
              value.usage.rebuildingHistory
            }
            size="sm"
            variant="outline"
            onClick={() =>
              void action("recalculate", async () => {
                const result = await api.pricingRefreshAndRecalculate();
                setMessage(result.message);
              })
            }
          >
            {t("Update & Recalculate", "更新并重算")}
          </PendingButton>
        </SettingsRow>
      </SettingsGroup>
      {catalogOpen && (
        <PricingCatalogDialog onClose={() => setCatalogOpen(false)} />
      )}
    </>
  );
}

function GeneralSettings({
  settings,
  pending,
  update,
  action,
  setMessage,
  onConfirm,
}: {
  settings: WindowSettings;
  pending: string | null;
  update: Update;
  action: Action;
  setMessage: (message: string) => void;
  onConfirm: (value: "diagnostics" | "alerts") => void;
}) {
  const { api, bootstrap } = useHost();
  const t = useTranslation();
  const value = settings.general;
  const alerts = value.quotaAlertsEnabled;
  return (
    <>
      <SettingsGroup title={t("System", "系统")}>
        <SettingsRow label={t("Language", "语言")}>
          <SelectField
            value={value.language}
            options={[
              { value: "system", label: t("Follow System", "跟随系统") },
              { value: "zh", label: "中文" },
              { value: "en", label: "English" },
            ]}
            onChange={(language) => void update("language", { language })}
            ariaLabel={t("Language", "语言")}
          />
        </SettingsRow>
        <SettingsRow
          label={t("Launch at login", "开机自动启动")}
          detail={
            value.launchAtLoginRequiresApproval ? (
              <span className="text-orange-600">
                {t(
                  "Approve CCBar in System Settings > General > Login Items & Extensions.",
                  "请在「系统设置 > 通用 > 登录项与扩展」中允许 CCBar。",
                )}
              </span>
            ) : undefined
          }
        >
          <Switch
            checked={value.launchAtLogin}
            onCheckedChange={(launchAtLogin) =>
              void action("launch", () =>
                api.settingsSetLaunchAtLogin(launchAtLogin),
              )
            }
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup
        title={t("Quota alerts", "额度提醒")}
        description={t(
          "Checks enabled quota services and imported Codex accounts after successful refreshes.",
          "包含已启用的额度服务和导入 Codex 账号，成功刷新后检查",
        )}
      >
        <SettingsRow
          label={t("Enable quota alerts", "开启额度提醒")}
          detail={
            <NotificationDetail
              settings={settings}
              pending={pending}
              action={action}
              onRebuild={() => onConfirm("alerts")}
            />
          }
        >
          <Switch
            checked={alerts}
            onCheckedChange={(quotaAlertsEnabled) =>
              void update("alerts", { quotaAlertsEnabled })
            }
          />
        </SettingsRow>
        <SettingsRow label={t("Remaining below", "剩余低于")}>
          <SelectField
            value={String(value.quotaAlertThresholdPercent)}
            options={Array.from(
              { length: 10 },
              (_, index) => (index + 1) * 5,
            ).map((number) => ({ value: String(number), label: `${number}%` }))}
            onChange={(threshold) =>
              void update("threshold", {
                quotaAlertThresholdPercent: Number(threshold),
              })
            }
            ariaLabel={t("Remaining below", "剩余低于")}
            disabled={!alerts}
          />
        </SettingsRow>
        <SettingsRow label={t("5-hour / session quota", "5 小时／会话额度")}>
          <Switch
            checked={value.quotaAlertFiveHourEnabled}
            onCheckedChange={(quotaAlertFiveHourEnabled) =>
              void update("alert5h", { quotaAlertFiveHourEnabled })
            }
            disabled={
              !alerts ||
              (!value.quotaAlertWeeklyEnabled &&
                !value.quotaAlertBillingCycleEnabled)
            }
          />
        </SettingsRow>
        <SettingsRow
          label={t("Weekly quota", "周额度")}
          description={t(
            "Includes model-specific weekly quotas.",
            "包含模型专属周额度",
          )}
        >
          <Switch
            checked={value.quotaAlertWeeklyEnabled}
            onCheckedChange={(quotaAlertWeeklyEnabled) =>
              void update("alertWeek", { quotaAlertWeeklyEnabled })
            }
            disabled={
              !alerts ||
              (!value.quotaAlertFiveHourEnabled &&
                !value.quotaAlertBillingCycleEnabled)
            }
          />
        </SettingsRow>
        <SettingsRow
          label={t("Billing cycle quota", "计费周期额度")}
          description={t(
            "Cursor Total / Auto / API, and Command Code, OpenCode Go and Kimi Code monthly quotas.",
            "Cursor Total／Auto／API，以及 Command Code、OpenCode Go、Kimi Code 月额度",
          )}
        >
          <Switch
            checked={value.quotaAlertBillingCycleEnabled}
            onCheckedChange={(quotaAlertBillingCycleEnabled) =>
              void update("alertBilling", { quotaAlertBillingCycleEnabled })
            }
            disabled={
              !alerts ||
              (!value.quotaAlertFiveHourEnabled &&
                !value.quotaAlertWeeklyEnabled)
            }
          />
        </SettingsRow>
        <SettingsRow label={t("Play sound", "播放声音")}>
          <Switch
            checked={value.quotaAlertSoundEnabled}
            onCheckedChange={(quotaAlertSoundEnabled) =>
              void update("alertSound", { quotaAlertSoundEnabled })
            }
            disabled={!alerts}
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("Diagnostics", "诊断")}>
        <SettingsRow
          label={t("Export diagnostics", "导出诊断日志")}
          description={t(
            "A redacted zip for reporting issues.",
            "生成脱敏的 zip，用于反馈问题",
          )}
        >
          <Button
            size="sm"
            variant="outline"
            onClick={() => onConfirm("diagnostics")}
          >
            {t("Export", "导出")}
          </Button>
        </SettingsRow>
        <SettingsRow
          label={t("Reveal log folder", "打开日志目录")}
          description="~/Library/Logs/CCBar"
        >
          <Button
            size="sm"
            variant="outline"
            onClick={() =>
              void action("logs", () => api.diagnosticsRevealLogs())
            }
          >
            {t("Open", "打开")}
          </Button>
        </SettingsRow>
        <SettingsRow
          label={t("Verbose logging", "详细日志")}
          description={t(
            "Turn on while troubleshooting, then turn it off.",
            "排查问题时开启，用完建议关闭",
          )}
        >
          <Switch
            checked={value.verboseLogging}
            onCheckedChange={(verboseLogging) =>
              void update("verbose", { verboseLogging })
            }
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("Updates & About", "更新与关于")}>
        <SettingsRow label={t("Version", "版本")}>
          <span className="cc-number text-[11.5px] text-muted-foreground">
            {value.updates.version}
          </span>
        </SettingsRow>
        <SettingsRow label={t("Check for updates", "检查更新")}>
          <PendingButton
            pending={pending === "updates"}
            disabled={!value.updates.canCheck}
            size="sm"
            variant="outline"
            onClick={() =>
              void action("updates", async () => {
                await api.updatesCheck();
                setMessage(t("The update window is open.", "更新窗口已打开。"));
              })
            }
          >
            {value.updates.hasUpdate || value.updates.isWorking
              ? t("View Update", "查看更新")
              : t("Check", "检查")}
          </PendingButton>
        </SettingsRow>
        <SettingsRow label={t("Last checked", "上次检查")}>
          <span className="cc-number text-[11.5px] text-muted-foreground">
            {formatDate(
              value.updates.lastCheckedAt,
              bootstrap.resolvedLanguage,
              bootstrap.timeZone,
              true,
            )}
          </span>
        </SettingsRow>
        <SettingsRow
          label={t("Automatically check for updates", "自动检查更新")}
        >
          <Switch
            checked={value.updates.automaticChecks}
            onCheckedChange={(automaticChecks) =>
              void action("automaticUpdates", () =>
                api.updatesSetAutomatic(automaticChecks),
              )
            }
          />
        </SettingsRow>
      </SettingsGroup>
    </>
  );
}

function NotificationDetail({
  settings,
  pending,
  action,
  onRebuild,
}: {
  settings: WindowSettings;
  pending: string | null;
  action: Action;
  onRebuild: () => void;
}) {
  const { api } = useHost();
  const t = useTranslation();
  const state = settings.general.notifications;
  return (
    <div className="flex flex-wrap items-center gap-2">
      {state.statusText && (
        <span className="text-muted-foreground">{state.statusText}</span>
      )}
      {state.soundAllowed === false &&
        settings.general.quotaAlertSoundEnabled && (
          <span className="text-orange-600">
            {t(
              "Notification sound is disabled in System Settings.",
              "系统设置已关闭通知声音。",
            )}
          </span>
        )}
      {(!state.canSubmit ||
        state.authorizationFailed ||
        state.permissionReadFailed) && (
        <span className="text-orange-600">
          {t(
            "Notifications are not allowed. Enable them in System Settings.",
            "系统通知未允许，请在系统设置中开启",
          )}
        </span>
      )}
      {!state.canSubmit && (
        <Button
          size="xs"
          variant="outline"
          onClick={() =>
            void action("notificationSettings", () =>
              api.notificationsOpenSettings(),
            )
          }
        >
          {t("Open notification settings", "打开系统通知设置")}
        </Button>
      )}
      {(state.authorization === "notDetermined" ||
        state.authorizationFailed ||
        state.permissionReadFailed) && (
        <PendingButton
          pending={pending === "permission"}
          size="xs"
          variant="outline"
          onClick={() =>
            void action("permission", () =>
              api.notificationsRequestPermission(),
            )
          }
        >
          {t("Retry permission request", "重试申请权限")}
        </PendingButton>
      )}
      {state.storagePaused && (
        <Button size="xs" variant="outline" onClick={onRebuild}>
          {t("Rebuild alert history", "重建提醒记录")}
        </Button>
      )}
    </div>
  );
}

function ConfirmDialog({
  title,
  description,
  actionLabel,
  onClose,
  onAction,
}: {
  title: string;
  description: string;
  actionLabel: string;
  onClose: () => void;
  onAction: () => void;
}) {
  const t = useTranslation();
  return (
    <AlertDialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>{description}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{t("Cancel", "取消")}</AlertDialogCancel>
          <AlertDialogAction
            onClick={() => {
              onAction();
              onClose();
            }}
          >
            {actionLabel}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
