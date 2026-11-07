import { useRef, useState, type ReactNode } from "react";
import {
  ArrowUpCircle,
  Check,
  ChevronDown,
  Download,
  ExternalLink,
  LoaderCircle,
  MoreHorizontal,
  RefreshCw,
  Trash2,
} from "lucide-react";
import type {
  ApplicationInstallation,
  ApplicationInventory,
  ApplicationOperationAction,
  ApplicationOperationPlan,
  ManagedApplication,
} from "@ccbar/host-api/window";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { HostIcon } from "@/components/host-icon";
import { PendingButton } from "@/components/pending-button";
import { errorMessage, useHost, useHostResource } from "@/host/host-context";
import { formatDate } from "@/lib/display";
import { useTranslation } from "@/lib/i18n";

const applicationDomains = ["applications"] as const;

export function useApplicationManagement() {
  const { api } = useHost();
  const resource = useHostResource<ApplicationInventory>(
    () => api.applicationsInventory(),
    applicationDomains,
    [api],
  );
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [plan, setPlan] = useState<ApplicationOperationPlan | null>(null);
  const requestPending = useRef(false);

  const acceptInventory = (inventory: ApplicationInventory) => {
    resource.setData(inventory);
    // A completion event can arrive before the mutation response. Reconcile once
    // after accepting a background task; subsequent updates come from events.
    if (
      inventory.scanning ||
      inventory.checkingVersions ||
      inventory.operation?.status === "running"
    ) {
      void resource.reload();
    }
  };

  const request = async (key: string, action: () => Promise<void>) => {
    if (requestPending.current) return;
    requestPending.current = true;
    setPending(key);
    setError(null);
    try {
      await action();
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      requestPending.current = false;
      setPending(null);
    }
  };

  return {
    resource,
    pending,
    error,
    plan,
    busy: pending !== null || resource.data?.operation?.status === "running",
    scan: () =>
      request("scan", async () => {
        acceptInventory(await api.applicationsInventory({ refresh: true }));
      }),
    checkVersions: (catalogID?: string) =>
      request(`check:${catalogID ?? "all"}`, async () => {
        acceptInventory(await api.applicationsCheckVersions({ catalogID }));
      }),
    prepare: (
      catalogID: string,
      action: ApplicationOperationAction,
      installationID?: string,
    ) =>
      request(
        `plan:${catalogID}:${installationID ?? ""}:${action}`,
        async () => {
          setPlan(
            await api.applicationsPlanOperation({
              catalogID,
              action,
              installationID,
            }),
          );
        },
      ),
    execute: () => {
      if (!plan) return Promise.resolve();
      return request("execute", async () => {
        acceptInventory(
          await api.applicationsExecuteOperation({ planID: plan.id }),
        );
        setPlan(null);
      });
    },
    closePlan: () => {
      if (requestPending.current) return;
      setPlan(null);
      setError(null);
    },
    openWebsite: (url: string) =>
      request("website", async () => {
        await api.platformOpenExternal(url);
      }),
  };
}

export type ApplicationManagement = ReturnType<typeof useApplicationManagement>;

export function ApplicationManagementFeedback({
  management,
}: {
  management: ApplicationManagement;
}) {
  const t = useTranslation();
  const { bootstrap } = useHost();
  const inventory = management.resource.data;
  const operation = inventory?.operation;
  const name =
    inventory?.applications.find((item) => item.id === operation?.catalogID)
      ?.name ?? operation?.catalogID;
  const actions = {
    install: t("Installation", "安装"),
    upgrade: t("Upgrade", "升级"),
    uninstall: t("Uninstall", "卸载"),
  };
  return (
    <>
      {(management.error || inventory?.error) && !management.plan && (
        <p
          role="alert"
          className="text-[12px] text-orange-600 dark:text-orange-400"
        >
          {management.error ?? inventory?.error}
        </p>
      )}
      {operation && (
        <section
          className="cc-panel space-y-2 p-3 text-[12px]"
          aria-label={t("Application operation", "应用操作")}
          aria-live="polite"
        >
          <p className="font-medium">
            {name} · {actions[operation.action]} ·{" "}
            {operation.status === "running"
              ? t("In progress", "进行中")
              : operation.status === "succeeded"
                ? t("Completed", "已完成")
                : t("Failed", "失败")}
          </p>
          <p className="text-[11px] tabular-nums text-muted-foreground">
            {formatDate(
              operation.finishedAt ?? operation.startedAt,
              bootstrap.resolvedLanguage,
              bootstrap.timeZone,
              true,
            )}
          </p>
          {operation.error && (
            <p role="alert" className="text-orange-600 dark:text-orange-400">
              {operation.error}
            </p>
          )}
          {operation.output && (
            <details>
              <summary className="cursor-pointer text-muted-foreground">
                {t("Operation details", "操作详情")}
              </summary>
              <pre className="cc-scrollbar mt-2 max-h-40 whitespace-pre-wrap break-all font-mono text-[11px]">
                {operation.output}
              </pre>
            </details>
          )}
        </section>
      )}
    </>
  );
}

// Keep version, action, visibility, and overflow columns aligned across both groups.
export const applicationRowGrid =
  "grid grid-cols-[minmax(0,1fr)_128px_88px_48px_28px] items-center gap-x-3 md:grid-cols-[minmax(0,1fr)_168px_88px_56px_28px] md:gap-x-4";

function installationLabel(
  application: ManagedApplication,
  installation: ApplicationInstallation,
  t: ReturnType<typeof useTranslation>,
) {
  const index =
    application.installations.findIndex((item) => item.id === installation.id) +
    1;
  return `${application.name} ${installation.sourceLabel} ${t(`Installation ${index}`, `安装 ${index}`)}`;
}

export function ApplicationManagementCard({
  application,
  management,
  children,
  sidebar,
  grouped = false,
}: {
  application: ManagedApplication;
  management: ApplicationManagement;
  children?: ReactNode;
  sidebar?: ReactNode;
  grouped?: boolean;
}) {
  const t = useTranslation();
  const { bootstrap } = useHost();
  const [expanded, setExpanded] = useState(false);
  const checking = management.resource.data?.checkingVersions === true;
  const disabled =
    management.busy || management.resource.data?.scanning === true;
  const initialScan =
    management.resource.data?.scanning === true &&
    !management.resource.data.lastScannedAt;
  const primary =
    application.installations.find((item) => item.active) ??
    application.installations[0];
  const others = application.installations.filter(
    (item) => item.id !== primary?.id,
  );
  return (
    <article
      className={grouped ? "px-4 py-3" : "cc-panel px-4 py-3"}
      aria-label={application.name}
    >
      <section
        className={`${applicationRowGrid} min-h-10`}
        aria-label={
          primary ? installationLabel(application, primary, t) : undefined
        }
      >
        <div className="flex min-w-0 items-center gap-3">
          {application.icon ? (
            <HostIcon
              icon={application.icon}
              name={application.name}
              dark={bootstrap.appearance === "dark"}
              size={20}
            />
          ) : (
            <span
              aria-hidden="true"
              className="flex size-5 shrink-0 items-center justify-center rounded bg-muted text-[12px] font-semibold"
            >
              {application.name.slice(0, 1).toUpperCase()}
            </span>
          )}
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-1.5">
              <h3 className="break-words text-[13px] font-semibold">
                {application.name}
              </h3>
              {primary && <SourceBadge>{primary.sourceLabel}</SourceBadge>}
            </div>
            {others.length > 0 && (
              <button
                type="button"
                onClick={() => setExpanded(!expanded)}
                aria-expanded={expanded}
                className="mt-1 inline-flex items-center gap-1 rounded text-[11px] text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              >
                {t(
                  `${others.length} other installations`,
                  `其他 ${others.length} 处安装`,
                )}
                <ChevronDown
                  className={`size-3 ${expanded ? "rotate-180" : ""}`}
                />
              </button>
            )}
          </div>
        </div>
        <InstallationVersion installation={primary} scanning={initialScan} />
        <div className="flex justify-end">
          {!initialScan && (
            <InstallationAction
              application={application}
              installation={primary}
              management={management}
              disabled={disabled || checking}
            />
          )}
        </div>
        <div className="flex justify-end">{sidebar}</div>
        <InstallationMenu
          application={application}
          installation={primary}
          management={management}
          disabled={disabled}
          label={`${application.name} ${t("More actions", "更多操作")}`}
        >
          {children}
        </InstallationMenu>
      </section>
      {!initialScan &&
        !application.installed &&
        (application.configurationFound ||
          application.installUnavailableReason) && (
          <div className="ml-8 mt-1 space-y-1 text-[11px] text-muted-foreground">
            {application.configurationFound && (
              <p>
                {t(
                  "Configuration found; application is not installed.",
                  "发现已有配置，应用尚未安装。",
                )}
              </p>
            )}
            {application.installUnavailableReason && (
              <p>{application.installUnavailableReason}</p>
            )}
          </div>
        )}
      {primary && <InstallationFeedback installation={primary} />}
      {expanded && others.length > 0 && (
        <div className="mt-3 space-y-3 border-t pt-3">
          {others.map((installation) => (
            <section
              key={installation.id}
              aria-label={installationLabel(application, installation, t)}
            >
              <div className={`${applicationRowGrid} min-h-8`}>
                <div className="ml-8 flex flex-wrap items-center gap-2 text-[11px] text-muted-foreground">
                  <SourceBadge>{installation.sourceLabel}</SourceBadge>
                  <span>
                    {t(
                      `Installation ${application.installations.indexOf(installation) + 1}`,
                      `安装 ${application.installations.indexOf(installation) + 1}`,
                    )}
                  </span>
                  {installation.active && (
                    <span className="inline-flex items-center gap-1">
                      <Check className="size-3" />
                      {t("Active", "当前生效")}
                    </span>
                  )}
                </div>
                <InstallationVersion installation={installation} />
                <div className="flex justify-end">
                  <InstallationAction
                    application={application}
                    installation={installation}
                    management={management}
                    disabled={disabled || checking}
                  />
                </div>
                <span />
                <InstallationMenu
                  application={application}
                  installation={installation}
                  management={management}
                  disabled={disabled}
                  label={`${installationLabel(application, installation, t)} ${t("More actions", "更多操作")}`}
                />
              </div>
              <InstallationFeedback installation={installation} />
            </section>
          ))}
        </div>
      )}
    </article>
  );
}

function SourceBadge({ children }: { children: ReactNode }) {
  return (
    <Badge
      variant="outline"
      className="h-[18px] px-1.5 text-[10px] font-normal text-muted-foreground"
    >
      {children}
    </Badge>
  );
}

function InstallationVersion({
  installation,
  scanning = false,
}: {
  installation?: ApplicationInstallation;
  scanning?: boolean;
}) {
  const t = useTranslation();
  const check = installation?.versionCheck;
  if (scanning || check?.status === "checking") {
    return (
      <div
        role="status"
        aria-label={t("Checking version…", "正在检查版本…")}
        className="flex justify-end"
      >
        <LoaderCircle className="size-4 animate-spin text-muted-foreground" />
      </div>
    );
  }
  return (
    <div className="text-right">
      <p
        className={
          installation?.version
            ? "font-mono text-[12px] font-medium tabular-nums"
            : "text-[11px] text-muted-foreground"
        }
      >
        {installation
          ? (installation.version ?? t("Version unknown", "版本未知"))
          : t("Not installed", "未安装")}
      </p>
      {check?.status === "updateAvailable" && check.latestVersion && (
        <p className="mt-0.5 text-[11px] tabular-nums text-muted-foreground">
          {t(
            `New version ${check.latestVersion}`,
            `新版本 ${check.latestVersion}`,
          )}
        </p>
      )}
      {check?.status === "failed" && (
        <p className="mt-0.5 text-[11px] text-orange-600 dark:text-orange-400">
          {t("Version check failed", "版本检查失败")}
        </p>
      )}
      {check?.status === "unknown" && (
        <p className="mt-0.5 text-[11px] text-muted-foreground">
          {t("Latest version unavailable", "暂无法确定最新版本")}
        </p>
      )}
    </div>
  );
}

function InstallationAction({
  application,
  installation,
  management,
  disabled,
}: {
  application: ManagedApplication;
  installation?: ApplicationInstallation;
  management: ApplicationManagement;
  disabled: boolean;
}) {
  const t = useTranslation();
  const operation = management.resource.data?.operation;
  const running =
    operation?.status === "running" &&
    operation.catalogID === application.id &&
    operation.installationID === (installation?.id ?? null);
  const action = installation ? "upgrade" : "install";
  const pending =
    management.pending ===
      `plan:${application.id}:${installation?.id ?? ""}:${action}` ||
    (running && operation.action === action);
  if (
    installation &&
    installation.versionCheck.status !== "updateAvailable" &&
    !pending
  )
    return null;
  return (
    <PendingButton
      pending={pending}
      disabled={
        disabled ||
        (installation ? !installation.canUpgrade : !application.canInstall)
      }
      variant="outline"
      size="sm"
      onClick={() =>
        void management.prepare(application.id, action, installation?.id)
      }
    >
      {!pending && (installation ? <ArrowUpCircle /> : <Download />)}
      {installation ? t("Upgrade", "升级") : t("Install", "安装")}
    </PendingButton>
  );
}

function InstallationFeedback({
  installation,
}: {
  installation: ApplicationInstallation;
}) {
  if (!installation.versionCheck.error && !installation.unavailableReason)
    return null;
  return (
    <div className="ml-8 mt-1 space-y-1 text-[11px]">
      {installation.versionCheck.error && (
        <p className="text-orange-600 dark:text-orange-400">
          {installation.versionCheck.error}
        </p>
      )}
      {installation.unavailableReason && (
        <p className="text-muted-foreground">
          {installation.unavailableReason}
        </p>
      )}
    </div>
  );
}

function InstallationMenu({
  application,
  installation,
  management,
  disabled,
  label,
  children,
}: {
  application: ManagedApplication;
  installation?: ApplicationInstallation;
  management: ApplicationManagement;
  disabled: boolean;
  label: string;
  children?: ReactNode;
}) {
  const t = useTranslation();
  const operation = management.resource.data?.operation;
  const uninstalling =
    installation !== undefined &&
    (management.pending ===
      `plan:${application.id}:${installation.id}:uninstall` ||
      (operation?.status === "running" &&
        operation.action === "uninstall" &&
        operation.catalogID === application.id &&
        operation.installationID === installation.id));
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={label}
            disabled={disabled}
            aria-busy={uninstalling}
          />
        }
      >
        {uninstalling ? (
          <LoaderCircle className="animate-spin" />
        ) : (
          <MoreHorizontal />
        )}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-44">
        {installation && (
          <DropdownMenuItem
            disabled={management.resource.data?.checkingVersions === true}
            onClick={() => void management.checkVersions(application.id)}
          >
            <RefreshCw />
            {t("Check updates", "检查更新")}
          </DropdownMenuItem>
        )}
        {application.website && (
          <DropdownMenuItem
            onClick={() => void management.openWebsite(application.website)}
          >
            <ExternalLink />
            {t("Website", "官网")}
          </DropdownMenuItem>
        )}
        {children}
        {installation && (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              variant="destructive"
              disabled={
                !installation.canUninstall ||
                management.resource.data?.checkingVersions === true
              }
              onClick={() =>
                void management.prepare(
                  application.id,
                  "uninstall",
                  installation.id,
                )
              }
            >
              <Trash2 />
              {t("Uninstall", "卸载")}
            </DropdownMenuItem>
          </>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export function ApplicationOperationDialog({
  management,
}: {
  management: ApplicationManagement;
}) {
  const t = useTranslation();
  const plan = management.plan;
  const labels = {
    install: t("Install", "安装"),
    upgrade: t("Upgrade", "升级"),
    uninstall: t("Uninstall", "卸载"),
  };
  const application = management.resource.data?.applications.find(
    (item) => item.id === plan?.catalogID,
  );
  const installation = application?.installations.find(
    (item) => item.id === plan?.installationID,
  );
  const installationIndex =
    application?.installations.findIndex(
      (item) => item.id === plan?.installationID,
    ) ?? -1;
  return (
    <AlertDialog
      open={plan !== null}
      onOpenChange={(open) => {
        if (!open) management.closePlan();
      }}
    >
      {plan && (
        <AlertDialogContent className="sm:max-w-lg">
          <AlertDialogHeader>
            <AlertDialogTitle>
              {labels[plan.action]} {plan.name}
            </AlertDialogTitle>
            <AlertDialogDescription>{plan.sourceLabel}</AlertDialogDescription>
          </AlertDialogHeader>
          {installation && (
            <p className="flex items-center gap-2 text-[12px] tabular-nums text-muted-foreground">
              <span>
                {installation.version ?? t("Version unknown", "版本未知")}
              </span>
              {application && application.installations.length > 1 && (
                <>
                  <span>·</span>
                  <span>
                    {t(
                      `Installation ${installationIndex + 1}`,
                      `安装 ${installationIndex + 1}`,
                    )}
                  </span>
                </>
              )}
              {installation.active && (
                <>
                  <span>·</span>
                  <span>{t("Active", "当前生效")}</span>
                </>
              )}
            </p>
          )}
          {plan.preservesData && (
            <p className="text-[12px] text-muted-foreground">
              {t(
                "Your configuration and history will be kept.",
                "将保留配置和历史记录。",
              )}
            </p>
          )}
          <details className="text-[12px] text-muted-foreground">
            <summary className="cursor-pointer">
              {t("Operation details", "操作详情")}
            </summary>
            {installation && (
              <p className="mt-2 break-all font-mono text-[11px]">
                {installation.path}
              </p>
            )}
            <ol className="cc-scrollbar mt-2 max-h-56 list-decimal space-y-2 overflow-y-auto pl-5">
              {plan.steps.map((step, index) => (
                <li key={index} className="whitespace-pre-wrap break-words">
                  {step}
                </li>
              ))}
            </ol>
          </details>
          {management.error && (
            <p
              role="alert"
              className="text-[12px] text-orange-600 dark:text-orange-400"
            >
              {management.error}
            </p>
          )}
          <AlertDialogFooter>
            <Button
              variant="outline"
              disabled={management.pending === "execute"}
              onClick={management.closePlan}
            >
              {t("Cancel", "取消")}
            </Button>
            <PendingButton
              pending={management.pending === "execute"}
              disabled={
                management.resource.data?.operation?.status === "running"
              }
              variant={plan.action === "uninstall" ? "destructive" : "default"}
              onClick={() => void management.execute()}
            >
              {labels[plan.action]}
            </PendingButton>
          </AlertDialogFooter>
        </AlertDialogContent>
      )}
    </AlertDialog>
  );
}

export function ApplicationInventoryActions({
  management,
}: {
  management: ApplicationManagement;
}) {
  const t = useTranslation();
  const { bootstrap } = useHost();
  const inventory = management.resource.data;
  const checkedAt = inventory?.applications
    .flatMap((app) => app.installations)
    .map((item) => item.versionCheck.checkedAt)
    .filter((value): value is string => value !== null)
    .sort()
    .at(-1);
  const checking =
    management.pending === "check:all" || inventory?.checkingVersions === true;
  return (
    <>
      {checkedAt && (
        <span className="hidden text-[11px] tabular-nums text-muted-foreground lg:inline">
          {t("Last checked", "检查于")}{" "}
          {formatDate(
            checkedAt,
            bootstrap.resolvedLanguage,
            bootstrap.timeZone,
            true,
          )}
        </span>
      )}
      <Button
        disabled={
          management.busy ||
          inventory?.scanning === true ||
          checking ||
          !inventory?.applications.some((item) => item.installed)
        }
        variant="outline"
        aria-busy={checking}
        onClick={() => void management.checkVersions()}
      >
        <RefreshCw className={checking ? "animate-spin" : undefined} />
        <span className="grid justify-items-center [&>*]:col-start-1 [&>*]:row-start-1">
          <span
            aria-hidden={checking}
            className={checking ? "invisible" : undefined}
          >
            {t("Check updates", "检查更新")}
          </span>
          <span
            aria-hidden={!checking}
            className={!checking ? "invisible" : undefined}
          >
            {t("Checking…", "检查中…")}
          </span>
        </span>
      </Button>
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              variant="ghost"
              size="icon"
              aria-label={t("Application actions", "应用管理操作")}
              disabled={management.busy}
            />
          }
        >
          <MoreHorizontal />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-40">
          <DropdownMenuItem
            disabled={
              inventory?.scanning === true ||
              inventory?.checkingVersions === true
            }
            onClick={() => void management.scan()}
          >
            <RefreshCw />
            {t("Rescan", "重新扫描")}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </>
  );
}
