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
import { PageHeader } from "@/components/page-header";
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
import {
  accountsForProvider,
  quotaProviderGroups,
} from "@/features/quota/provider-groups";

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
    if (target.kind === "importedCodex") {
      const allIDs = data.accounts
        .filter((item) => item.kind === "importedCodex")
        .map((item) => item.id);
      const ids = data.accounts
        .filter(
          (item) =>
            item.kind === "importedCodex" &&
            item.quotaManagement?.provider === "chatgpt",
        )
        .map((item) => item.id);
      const order = direction
        ? moveAdjacent(ids, sourceID, direction)
        : (edge === "after" ? moveAfter : moveBefore)(ids, sourceID, target.id);
      if (order)
        void mutate(`order:${sourceID}`, () =>
          api.quotaReorder(data.serviceOrder, replaceGroup(allIDs, order)),
        );
    }
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader
        page="quotaManagement"
        title={t("Quota Management", "额度管理")}
        actions={
          <PendingButton
            pending={pending === "refresh"}
            disabled={pending !== null}
            variant="outline"
            onClick={() => void mutate("refresh", () => api.quotaRefresh())}
          >
            <RefreshCw />
            {t("Refresh", "刷新")}
          </PendingButton>
        }
      />
      <div className="cc-scrollbar min-h-0 flex-1">
        <div className="mx-auto flex w-full max-w-[1100px] flex-col gap-6 p-7">
          {!settings.appearance.floatingEnabled && (
            <div className="flex items-center gap-2 text-[11.5px] text-muted-foreground">
              <p>
                {t(
                  "The desktop window is off. Selected accounts still appear in the menu bar panel.",
                  "桌面悬浮窗已关闭，菜单栏展开面板仍会显示选中的账号。",
                )}
              </p>
              <Button
                variant="link"
                size="xs"
                onClick={() => void navigate({ page: "settings" })}
              >
                {t("Open settings", "前往设置")}
              </Button>
            </div>
          )}
          {(operationError || resource.data?.operationError) && (
            <p
              className="text-[11.5px] text-orange-600 dark:text-orange-400"
              role="alert"
            >
              {operationError ?? resource.data?.operationError}
            </p>
          )}
          <ResourceFeedback
            {...resource}
            onRetry={() => void resource.reload()}
          >
            {(result) => {
              const row = (account: QuotaAccount) => (
                <AccountRow
                  key={account.id}
                  account={account}
                  pending={pending !== null}
                  onUpdate={(patch) => void update(account, patch)}
                  onDrag={
                    account.kind === "importedCodex"
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
              );
              return (
                <>
                  {quotaProviderGroups.map((provider) => {
                    const accounts = accountsForProvider(
                      result.accounts,
                      provider.id,
                    );
                    const icon = applications.data?.applications.find(
                      (app) => app.id === provider.application,
                    )?.icon;
                    return (
                      <AccountGroup
                        key={provider.id}
                        id={provider.id}
                        title={provider.name}
                        icon={icon ?? null}
                        color={brandColor(provider.brand, settings, dark)}
                        dark={dark}
                        hasAccounts={accounts.length > 0}
                        action={
                          provider.add && (
                            <Button
                              variant="ghost"
                              size="sm"
                              disabled={pending !== null}
                              onClick={() => {
                                setSelectedAccount(null);
                                setDialog(provider.add!);
                              }}
                            >
                              <Plus />
                              {t("Add account", "添加账号")}
                            </Button>
                          )
                        }
                      >
                        {accounts.length > 0 ? (
                          accounts.map(row)
                        ) : (
                          <div className="px-4 py-5 text-[12px] text-muted-foreground">
                            <p>{t("No accounts yet", "暂无账号")}</p>
                            <p className="mt-1 text-[11px]">
                              {t(...provider.hint)}
                            </p>
                          </div>
                        )}
                      </AccountGroup>
                    );
                  })}
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
                            {deleteAccount.kind === "deepSeek"
                              ? deleteAccount.sourceApplication
                                ? t(
                                    "This account will be hidden from CCBar. The original application stays signed in.",
                                    "此账号将从 CCBar 中隐藏，原应用保持登录。",
                                  )
                                : t(
                                    "Removes the credentials saved by CCBar and requests sign-out from DeepSeek.",
                                    "将删除 CCBar 保存的凭据，并请求退出 DeepSeek 登录。",
                                  )
                              : t(
                                  "This account will be removed from CCBar. The original application sign-in is not affected.",
                                  "此账号将从 CCBar 中移除，原应用登录不受影响。",
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
    </div>
  );
}

function AccountGroup({
  id,
  title,
  icon,
  color,
  dark,
  hasAccounts,
  action,
  children,
}: {
  id: string;
  title: string;
  icon: BrandIcon | null;
  color: string;
  dark: boolean;
  hasAccounts: boolean;
  action: React.ReactNode;
  children: React.ReactNode;
}) {
  const t = useTranslation();
  return (
    <section
      aria-labelledby={`quota-provider-${id}`}
      className="cc-panel overflow-hidden"
    >
      <div className="flex items-center gap-2.5 border-b px-4 py-3">
        {icon ? (
          <HostIcon icon={icon} name={title} dark={dark} size={26} />
        ) : (
          <ServiceIcon name={title} color={color} size={26} />
        )}
        <h2
          id={`quota-provider-${id}`}
          className="flex-1 text-[13px] font-semibold"
        >
          {title}
        </h2>
        {action}
      </div>
      {hasAccounts && (
        <div
          className="flex items-center gap-2 px-3 pt-3 pb-1 text-[10.5px] text-muted-foreground"
          aria-hidden="true"
        >
          <span className="flex-1 pl-6">{t("Account", "账号")}</span>
          <span className="w-20 shrink-0 text-center">
            {t("Menu Bar", "菜单栏")}
          </span>
          <span className="w-20 shrink-0 text-center">
            {t("Floating panels", "悬浮窗")}
          </span>
          <span className="w-7 shrink-0" />
          <span className="w-7 shrink-0" />
        </div>
      )}
      <div className="divide-y divide-black/[0.06] dark:divide-white/[0.06]">
        {children}
      </div>
    </section>
  );
}

function AccountRow({
  account,
  pending,
  onUpdate,
  onDrag,
  onMenu,
}: {
  account: QuotaAccount;
  pending: boolean;
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
  const t = useTranslation();
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
      className="flex min-h-[62px] items-center gap-2 px-3 py-3"
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
        <span className="w-3.5 shrink-0" />
      )}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <h3 className="truncate text-[13px] font-medium">{account.name}</h3>
          {account.quotaManagement?.isDefault && (
            <span className="shrink-0 rounded border px-1.5 text-[10px] text-muted-foreground">
              {t("Default", "默认")}
            </span>
          )}
        </div>
        <p className="truncate text-[11px] text-muted-foreground">
          {account.subtitle}
          {account.kind === "primary" &&
          account.service === "kimi" &&
          account.region
            ? ` · ${account.region === "china" ? t("China edition", "国内版") : t("Global edition", "海外版")}`
            : ""}
        </p>
        {account.kind === "localLogin" && (
          <p className="mt-1 text-[11px] text-muted-foreground">
            {account.needsRefresh
              ? t(
                  "Open the application to refresh its login.",
                  "请打开原应用刷新登录。",
                )
              : t("Quota unavailable", "暂未接入额度查询")}
          </p>
        )}
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
            disabled={pending}
            onClick={() => onMenu("grant")}
          >
            {t("Authorize…", "授权…")}
          </Button>
        )}
      </div>
      <Destination
        checked={account.showInMenuBar}
        disabled={!account.supportsMenuBar || pending}
        label={`${account.name} ${t("Menu Bar", "菜单栏")}`}
        onChange={(checked) => onUpdate({ showInMenuBar: checked })}
      />
      <Destination
        checked={account.showInFloatingHUD}
        disabled={!account.supportsFloatingHUD || pending}
        label={`${account.name} ${t("Floating panels", "悬浮窗")}`}
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
              disabled={pending}
            />
          }
        >
          <MoreHorizontal />
        </DropdownMenuTrigger>
        <DropdownMenuContent>
          {account.kind === "localLogin" ? (
            <DropdownMenuItem onClick={() => onMenu("application")}>
              {t("Application settings", "应用配置")}
            </DropdownMenuItem>
          ) : (
            <DropdownMenuItem onClick={() => onMenu("refresh")}>
              {t("Refresh", "刷新")}
            </DropdownMenuItem>
          )}
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
    <div className="flex w-20 shrink-0 justify-center">
      <Checkbox
        checked={checked}
        disabled={disabled}
        onCheckedChange={(value) => onChange(value === true)}
        aria-label={label}
      />
    </div>
  );
}
