import { useEffect, useState, type DragEvent, type KeyboardEvent } from "react";
import {
  CircleAlert,
  GripVertical,
  Info,
  MoreHorizontal,
  Plus,
  RefreshCw,
} from "lucide-react";
import type {
  AccountDisplayPatch,
  ApplicationID,
  BrandIcon,
  QuotaAccount,
  QuotaAccountsResult,
  QuotaService,
} from "@ccbar/host-api/window";
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
import { Checkbox } from "@/components/ui/checkbox";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { Switch } from "@/components/ui/switch";
import { EmptyState, WorkspaceHeader } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { HostIcon } from "@/components/host-icon";
import { ServiceIcon } from "@/components/service-icon";
import { PendingButton } from "@/components/pending-button";
import { useHost, useHostResource, errorMessage } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { brandColor } from "@/lib/display";
import {
  CodexImportDialog,
  DeviceAuthorizationDialog,
  ResetCreditsDialog,
} from "@/features/quota/account-dialogs";
import {
  moveAdjacent,
  moveBefore,
  moveAfter,
  replaceGroup,
} from "@/features/quota/reorder";
import { cn } from "@/lib/utils";

const quotaDomains = ["quota", "authorizations"] as const;
const applicationDomains = ["applications"] as const;

export function QuotaPage() {
  const { api, settings, bootstrap, navigate } = useHost();
  const t = useTranslation();
  const resource = useHostResource<QuotaAccountsResult>(
    () => api.quotaAccounts(),
    quotaDomains,
    [api],
  );
  const applications = useHostResource(
    () => api.applicationsList(),
    applicationDomains,
    [api],
  );
  const [pending, setPending] = useState<string | null>(null);
  const [operationError, setOperationError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<
    "codexImport" | "kimi" | "deepSeek" | null
  >(null);
  const [selectedAccount, setSelectedAccount] = useState<QuotaAccount | null>(
    null,
  );
  const [resetAccount, setResetAccount] = useState<QuotaAccount | null>(null);
  const [deleteAccount, setDeleteAccount] = useState<QuotaAccount | null>(null);
  const dark = bootstrap.appearance === "dark";

  useEffect(() => {
    if (
      !resource.data?.kimiAuthorization.inProgress &&
      !resource.data?.deepSeekAuthorization.inProgress
    )
      return;
    const timer = window.setInterval(() => void resource.reload(), 1000);
    return () => window.clearInterval(timer);
  }, [
    resource.data?.kimiAuthorization.inProgress,
    resource.data?.deepSeekAuthorization.inProgress,
    resource.reload,
  ]);

  const mutate = async (
    key: string,
    action: () => Promise<QuotaAccountsResult>,
  ) => {
    if (pending) return;
    setPending(key);
    setOperationError(null);
    try {
      resource.setData(await action());
    } catch (reason) {
      setOperationError(errorMessage(reason));
    } finally {
      setPending(null);
    }
  };
  const update = (account: QuotaAccount, patch: AccountDisplayPatch) =>
    mutate(account.id, () => api.quotaUpdateAccount(account.id, patch));
  const remove = async () => {
    if (!deleteAccount) return;
    const account = deleteAccount;
    const action =
      account.kind === "importedCodex"
        ? () => api.codexDelete(account.id)
        : account.kind === "managedKimi"
          ? () => api.kimiDelete(account.id)
          : () => api.deepSeekDelete(account.id);
    await mutate(account.id, action);
    setDeleteAccount(null);
  };
  const reorderAccount = (
    target: QuotaAccount,
    sourceID: string,
    direction?: -1 | 1,
    edge: "before" | "after" = "before",
  ) => {
    const data = resource.data;
    if (!data || pending) return;
    const source = data.accounts.find((item) => item.id === sourceID);
    if (!source || target.kind !== source.kind) return;
    if (target.kind === "primary" && source.kind === "primary") {
      if (target.detected !== source.detected) return;
      const group = data.serviceOrder.filter((service) =>
        data.accounts.some(
          (item) =>
            item.kind === "primary" &&
            item.service === service &&
            item.detected === source.detected,
        ),
      );
      const moved = direction
        ? moveAdjacent(group, source.service as QuotaService, direction)
        : (edge === "after" ? moveAfter : moveBefore)(
            group,
            source.service as QuotaService,
            target.service as QuotaService,
          );
      if (moved)
        void mutate(`order:${sourceID}`, () =>
          api.quotaReorder(replaceGroup(data.serviceOrder, moved)),
        );
    } else if (target.kind === "importedCodex") {
      const ids = data.accounts
        .filter((item) => item.kind === "importedCodex")
        .map((item) => item.id);
      const order = direction
        ? moveAdjacent(ids, sourceID, direction)
        : (edge === "after" ? moveAfter : moveBefore)(ids, sourceID, target.id);
      if (order)
        void mutate(`order:${sourceID}`, () =>
          api.quotaReorder(data.serviceOrder, order),
        );
    }
  };
  const iconFor = (account: QuotaAccount): BrandIcon | null => {
    const application =
      account.service === "opencodeGo" ? "opencode" : account.service;
    return (
      applications.data?.applications.find((item) => item.id === application)
        ?.icon ?? null
    );
  };

  return (
    <div className="cc-scrollbar h-full">
      <div className="mx-auto flex w-full max-w-[1100px] flex-col gap-6 p-7">
        <WorkspaceHeader
          title={t("Quota Management", "额度管理")}
          actions={
            <PendingButton
              pending={pending === "refresh"}
              variant="outline"
              onClick={() => void mutate("refresh", () => api.quotaRefresh())}
            >
              <RefreshCw />
              {t("Refresh", "刷新")}
            </PendingButton>
          }
        />
        {(operationError || resource.data?.operationError) && (
          <p
            className="text-[11.5px] text-orange-600 dark:text-orange-400"
            role="alert"
          >
            {operationError ?? resource.data?.operationError}
          </p>
        )}
        <ResourceFeedback {...resource} onRetry={() => void resource.reload()}>
          {(result) => {
            const primary = result.accounts
              .filter((account) => account.kind === "primary")
              .sort(
                (a, b) =>
                  result.serviceOrder.indexOf(a.service as QuotaService) -
                  result.serviceOrder.indexOf(b.service as QuotaService),
              );
            const connected = primary.filter((account) => account.detected);
            const others = primary.filter((account) => !account.detected);
            const imported = result.accounts.filter(
              (account) => account.kind === "importedCodex",
            );
            const managed = result.accounts.filter(
              (account) => account.kind === "managedKimi",
            );
            const deepSeek = result.accounts.filter(
              (account) => account.kind === "deepSeek",
            );
            const local = result.accounts.filter(
              (account) => account.kind === "localLogin",
            );
            const row = (account: QuotaAccount) => (
              <div key={account.id}>
                <AccountRow
                  account={account}
                  icon={iconFor(account)}
                  dark={dark}
                  floatingEnabled={result.floatingEnabled}
                  pending={pending !== null}
                  onUpdate={(patch) => void update(account, patch)}
                  onDrag={
                    account.kind === "primary"
                      ? (source, direction, edge) =>
                          reorderAccount(account, source, direction, edge)
                      : undefined
                  }
                  onMenu={(action) => {
                    if (action === "reset") setResetAccount(account);
                    if (action === "delete") setDeleteAccount(account);
                    if (action === "refresh")
                      void mutate(account.id, () =>
                        account.kind === "deepSeek"
                          ? api.deepSeekRefresh(account.id)
                          : api.quotaRefresh(account.id),
                      );
                    if (action === "retry")
                      void mutate(account.id, () =>
                        account.kind === "importedCodex"
                          ? api.codexRetryAccess(account.id)
                          : api.kimiRetryAccess(account.id),
                      );
                    if (action === "grant" && account.authorizationRequired)
                      void mutate(account.id, () =>
                        api.authorizationsGrantAccess(
                          account.authorizationRequired!,
                        ),
                      );
                    if (action === "login") {
                      setSelectedAccount(account);
                      setDialog(
                        account.kind === "managedKimi" ? "kimi" : "deepSeek",
                      );
                    }
                    if (action === "application")
                      void navigate({
                        page: "application",
                        application: account.service as ApplicationID,
                      });
                  }}
                />
                {account.kind === "primary" && account.service === "codex" && (
                  <>
                    {imported.map((item) => (
                      <AccountRow
                        key={item.id}
                        account={item}
                        icon={iconFor(item)}
                        dark={dark}
                        floatingEnabled={result.floatingEnabled}
                        pending={pending !== null}
                        nested
                        onUpdate={(patch) => void update(item, patch)}
                        onDrag={(source, direction, edge) =>
                          reorderAccount(item, source, direction, edge)
                        }
                        onMenu={(action) => {
                          if (action === "reset") setResetAccount(item);
                          if (action === "delete") setDeleteAccount(item);
                          if (action === "retry")
                            void mutate(item.id, () =>
                              api.codexRetryAccess(item.id),
                            );
                        }}
                      />
                    ))}
                    <AddAccountRow
                      label={t("Add Codex Account…", "添加 Codex 账号…")}
                      onClick={() => setDialog("codexImport")}
                    />
                  </>
                )}
                {account.kind === "primary" && account.service === "kimi" && (
                  <>
                    {managed.map((item) => (
                      <AccountRow
                        key={item.id}
                        account={item}
                        icon={iconFor(item)}
                        dark={dark}
                        floatingEnabled={result.floatingEnabled}
                        pending={pending !== null}
                        nested
                        onUpdate={(patch) => void update(item, patch)}
                        onMenu={(action) => {
                          if (action === "delete") setDeleteAccount(item);
                          if (action === "retry")
                            void mutate(item.id, () =>
                              api.kimiRetryAccess(item.id),
                            );
                          if (action === "login") {
                            setSelectedAccount(item);
                            setDialog("kimi");
                          }
                        }}
                      />
                    ))}
                    <AddAccountRow
                      label={t("Add Kimi Account…", "添加 Kimi 账号…")}
                      onClick={() => {
                        setSelectedAccount(null);
                        setDialog("kimi");
                      }}
                    />
                  </>
                )}
              </div>
            );
            return (
              <>
                <AccountGroup title={t("Connected accounts", "已连接账号")}>
                  {connected.length ? (
                    connected.map(row)
                  ) : (
                    <EmptyState
                      title={t(
                        "No services found on this Mac yet",
                        "暂未在这台 Mac 上检测到服务",
                      )}
                    />
                  )}
                </AccountGroup>
                <AccountGroup title="DeepSeek">
                  {deepSeek.map(row)}
                  <AddAccountRow
                    label={t("Add DeepSeek account…", "添加 DeepSeek 账号…")}
                    onClick={() => {
                      setSelectedAccount(null);
                      setDialog("deepSeek");
                    }}
                  />
                </AccountGroup>
                {others.length > 0 && (
                  <AccountGroup
                    title={t("Connect subscriptions", "连接订阅账号")}
                  >
                    {others.map(row)}
                  </AccountGroup>
                )}
                {local.length > 0 && (
                  <section className="space-y-3">
                    {local.map((account) => (
                      <div
                        key={account.id}
                        className="cc-panel flex items-center gap-3 p-4"
                      >
                        <ServiceIcon
                          name={account.name}
                          color={brandColor(
                            account.service as "gemini" | "grok",
                            settings,
                            dark,
                          )}
                          size={30}
                        />
                        <div className="min-w-0 flex-1">
                          <h3 className="font-semibold">{account.name}</h3>
                          <p className="text-[12px]">{account.subtitle}</p>
                          <p className="mt-1 text-[11px] text-muted-foreground">
                            {account.needsRefresh
                              ? t(
                                  "Open the application to refresh its login.",
                                  "请打开原应用刷新登录。",
                                )
                              : t(
                                  "Login managed by the application · Quota unavailable",
                                  "登录由原应用管理 · 暂未接入额度查询",
                                )}
                          </p>
                        </div>
                        <Button
                          variant="outline"
                          onClick={() =>
                            void navigate({
                              page: "application",
                              application: account.service as ApplicationID,
                            })
                          }
                        >
                          {t("Open application settings", "应用配置")}
                        </Button>
                      </div>
                    ))}
                  </section>
                )}
                {dialog === "codexImport" && (
                  <CodexImportDialog
                    privacyMode={settings.appearance.privacyMode}
                    onClose={() => setDialog(null)}
                    onImported={resource.setData}
                  />
                )}
                {dialog === "kimi" && (
                  <DeviceAuthorizationDialog
                    kind="kimi"
                    account={selectedAccount}
                    state={result.kimiAuthorization}
                    onClose={() => {
                      setDialog(null);
                      setSelectedAccount(null);
                    }}
                    onChanged={resource.setData}
                  />
                )}
                {dialog === "deepSeek" && (
                  <DeviceAuthorizationDialog
                    kind="deepSeek"
                    account={selectedAccount}
                    state={result.deepSeekAuthorization}
                    onClose={() => {
                      setDialog(null);
                      setSelectedAccount(null);
                    }}
                    onChanged={resource.setData}
                  />
                )}
                {resetAccount && (
                  <ResetCreditsDialog
                    account={resetAccount}
                    onClose={() => setResetAccount(null)}
                  />
                )}
                {deleteAccount && (
                  <AlertDialog
                    open
                    onOpenChange={(open) => {
                      if (!open) setDeleteAccount(null);
                    }}
                  >
                    <AlertDialogContent>
                      <AlertDialogHeader>
                        <AlertDialogTitle>
                          {t("Remove account?", "删除此账号？")}
                        </AlertDialogTitle>
                        <AlertDialogDescription>
                          {deleteAccount.kind === "deepSeek" &&
                          deleteAccount.sourceOwned
                            ? t(
                                "Removes the CCBar credentials. Browser authorizations also request sign-out from DeepSeek; the original application is not changed.",
                                "将删除 CCBar 保存的凭据；浏览器授权还会请求退出 DeepSeek，原应用登录不受影响。",
                              )
                            : deleteAccount.kind === "deepSeek" &&
                                deleteAccount.sourceApplication
                              ? t(
                                  "This account is detected from an application. It will be hidden from CCBar; the original application credentials remain unchanged.",
                                  "此账号来自原应用，将从 CCBar 中隐藏；不会删除原应用凭据或退出原应用登录。",
                                )
                              : t(
                                  "This account will be removed from CCBar. The account itself and the original application sign-in are not affected.",
                                  "此账号将从 CCBar 中移除，账号本身及原应用登录不受影响。",
                                )}
                        </AlertDialogDescription>
                      </AlertDialogHeader>
                      <AlertDialogFooter>
                        <AlertDialogCancel>
                          {t("Cancel", "取消")}
                        </AlertDialogCancel>
                        <AlertDialogAction
                          variant="destructive"
                          onClick={() => void remove()}
                        >
                          {t("Remove", "删除")}
                        </AlertDialogAction>
                      </AlertDialogFooter>
                    </AlertDialogContent>
                  </AlertDialog>
                )}
              </>
            );
          }}
        </ResourceFeedback>
      </div>
    </div>
  );
}

function AccountGroup({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  const t = useTranslation();
  return (
    <section>
      <div className="flex items-center px-1 pb-2 text-[10.5px] font-semibold text-muted-foreground">
        <h2 className="text-[13px] font-semibold text-foreground">{title}</h2>
        <span className="flex-1" />
        <span className="w-20 text-center">{t("Menu Bar", "菜单栏")}</span>
        <span className="w-20 text-center">{t("Floating HUD", "悬浮窗")}</span>
        <span className="w-7" />
        <span className="w-12 text-center">{t("Show quota", "额度显示")}</span>
      </div>
      <div className="cc-panel divide-y divide-black/[0.06] overflow-hidden dark:divide-white/[0.06]">
        {children}
      </div>
    </section>
  );
}

function AccountRow({
  account,
  icon,
  dark,
  floatingEnabled,
  pending,
  nested = false,
  onUpdate,
  onDrag,
  onMenu,
}: {
  account: QuotaAccount;
  icon: BrandIcon | null;
  dark: boolean;
  floatingEnabled: boolean;
  pending: boolean;
  nested?: boolean;
  onUpdate: (patch: AccountDisplayPatch) => void;
  onDrag?: (
    sourceID: string,
    direction?: -1 | 1,
    edge?: "before" | "after",
  ) => void;
  onMenu: (
    action:
      | "reset"
      | "delete"
      | "refresh"
      | "retry"
      | "grant"
      | "login"
      | "application",
  ) => void;
}) {
  const { settings } = useHost();
  const t = useTranslation();
  const brand =
    account.service === "opencodeGo"
      ? "opencode"
      : account.service === "moonshot"
        ? "kimi"
        : account.service === "deepSeek"
          ? "deepseek"
          : account.service;
  const drag = (event: DragEvent) => {
    event.dataTransfer.setData("text/ccbar-account", account.id);
    event.dataTransfer.effectAllowed = "move";
  };
  const drop = (event: DragEvent) => {
    event.preventDefault();
    const source = event.dataTransfer.getData("text/ccbar-account");
    if (!source || !onDrag || pending) return;
    const bounds = event.currentTarget.getBoundingClientRect();
    onDrag(
      source,
      undefined,
      event.clientY > bounds.top + bounds.height / 2 ? "after" : "before",
    );
  };
  const keyDown = (event: KeyboardEvent) => {
    if (
      !onDrag ||
      pending ||
      !event.altKey ||
      (event.key !== "ArrowUp" && event.key !== "ArrowDown")
    )
      return;
    event.preventDefault();
    onDrag(account.id, event.key === "ArrowUp" ? -1 : 1);
  };
  return (
    <div
      className={cn(
        "flex min-h-[50px] items-center gap-2 px-3 py-2",
        nested && "bg-black/[0.02] pl-10 dark:bg-white/[0.02]",
      )}
      draggable={Boolean(onDrag) && !pending}
      onDragStart={drag}
      onDragOver={(event) => {
        if (onDrag) event.preventDefault();
      }}
      onDrop={drop}
    >
      {onDrag ? (
        <button
          type="button"
          className="cursor-grab text-muted-foreground"
          aria-label={t("Drag to reorder", "拖动以排序")}
          onKeyDown={keyDown}
        >
          <GripVertical className="size-3.5" />
        </button>
      ) : (
        <span className="w-3.5" />
      )}
      {icon ? (
        <HostIcon icon={icon} name={account.name} dark={dark} size={26} />
      ) : (
        <ServiceIcon
          name={account.name}
          color={brandColor(brand, settings, dark)}
          size={26}
        />
      )}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <h3 className="truncate text-[13px] font-medium">{account.name}</h3>
          {account.service === "kimi" && account.current && (
            <span className="rounded-full border px-1.5 text-[10px] text-muted-foreground">
              {t("In use by Kimi", "Kimi 在用")}
            </span>
          )}
        </div>
        <p
          className="truncate text-[11px] text-muted-foreground"
          title={account.subtitle}
        >
          {account.subtitle}
          {account.kind === "primary" &&
          account.service === "kimi" &&
          account.region
            ? ` · ${account.region === "china" ? t("China edition", "国内版") : t("Global edition", "海外版")}`
            : ""}
        </p>
        {account.balance?.wallets.map((wallet) => (
          <p key={wallet.currency} className="cc-number text-[12px]">
            {wallet.displayTotal}
          </p>
        ))}
        {account.refresh.failed && (
          <p className="text-[11px] text-orange-600 dark:text-orange-400">
            {t("Refresh failed", "刷新失败")}
          </p>
        )}
        {account.authorizationRequired && (
          <Button
            size="xs"
            variant="outline"
            className="mt-1"
            onClick={() => onMenu("grant")}
          >
            {t("Authorize…", "授权…")}
          </Button>
        )}
      </div>
      <Destination
        checked={account.showInMenuBar}
        disabled={!account.enabled || !account.supportsMenuBar || pending}
        label={`${account.name} ${t("Menu Bar", "菜单栏")}`}
        onChange={(checked) => onUpdate({ showInMenuBar: checked })}
      />
      <Destination
        checked={account.showInFloatingHUD}
        disabled={
          !account.enabled ||
          !account.supportsFloatingHUD ||
          !floatingEnabled ||
          pending
        }
        label={`${account.name} ${t("Floating HUD", "悬浮窗")}`}
        onChange={(checked) => onUpdate({ showInFloatingHUD: checked })}
      />
      <Popover>
        <PopoverTrigger
          render={
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label={t("Data sources", "数据来源")}
            />
          }
        >
          {account.refresh.failed ? (
            <CircleAlert className="text-orange-500" />
          ) : (
            <Info />
          )}
        </PopoverTrigger>
        <PopoverContent className="w-[300px] space-y-2 text-[11.5px]">
          <h4 className="font-semibold">{account.name}</h4>
          {account.sourceLines.map((line) => (
            <p key={line} className="text-muted-foreground">
              {line}
            </p>
          ))}
          {account.refresh.error && (
            <p className="text-orange-600">{account.refresh.error}</p>
          )}
        </PopoverContent>
      </Popover>
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label={t("More", "更多操作")}
            />
          }
        >
          <MoreHorizontal />
        </DropdownMenuTrigger>
        <DropdownMenuContent>
          {(account.service === "codex" ||
            account.kind === "importedCodex") && (
            <DropdownMenuItem onClick={() => onMenu("reset")}>
              {t("Reset Credits…", "额度重置次数…")}
            </DropdownMenuItem>
          )}
          {account.keychainAccessBlocked && (
            <DropdownMenuItem onClick={() => onMenu("retry")}>
              {t("Retry Keychain Access…", "重试钥匙串访问…")}
            </DropdownMenuItem>
          )}
          {account.kind === "managedKimi" && (
            <DropdownMenuItem onClick={() => onMenu("login")}>
              {t("Sign in again…", "重新登录…")}
            </DropdownMenuItem>
          )}
          {account.kind === "deepSeek" && (
            <>
              <DropdownMenuItem onClick={() => onMenu("refresh")}>
                {t("Refresh", "刷新")}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => onMenu("login")}>
                {t("Edit / Reconnect…", "编辑／重新连接…")}
              </DropdownMenuItem>
            </>
          )}
          {(account.kind === "importedCodex" ||
            account.kind === "managedKimi" ||
            account.kind === "deepSeek") && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuItem
                variant="destructive"
                onClick={() => onMenu("delete")}
              >
                {t("Remove…", "删除…")}
              </DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
      <div className="flex w-12 justify-center">
        <Switch
          checked={account.enabled}
          onCheckedChange={(checked) => onUpdate({ enabled: checked })}
          disabled={pending}
          aria-label={`${account.name} ${t("Show quota", "额度显示")}`}
        />
      </div>
    </div>
  );
}

function Destination({
  checked,
  disabled,
  label,
  onChange,
}: {
  checked: boolean;
  disabled: boolean;
  label: string;
  onChange: (checked: boolean) => void;
}) {
  return (
    <div className="flex w-20 justify-center">
      <Checkbox
        checked={checked}
        disabled={disabled}
        onCheckedChange={(value) => onChange(value === true)}
        aria-label={label}
      />
    </div>
  );
}

function AddAccountRow({
  label,
  onClick,
}: {
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-1.5 px-10 py-2.5 text-left text-[12.5px] text-blue-600 dark:text-blue-400"
    >
      <Plus className="size-3" />
      {label}
    </button>
  );
}
