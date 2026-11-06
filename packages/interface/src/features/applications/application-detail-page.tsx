import { useState } from "react";
import { ArrowLeft, Check, KeyRound, Plus } from "lucide-react";
import type {
  ApplicationDetail,
  ApplicationID,
  ProviderCatalog,
} from "@ccbar/host-api/window";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { EmptyState, WorkspaceHeader } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { ServiceIcon } from "@/components/service-icon";
import { HostIcon } from "@/components/host-icon";
import { useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { brandColor, supplierBrand } from "@/lib/display";
import { ProviderCatalogView } from "@/features/applications/provider-catalog-view";
import { cn } from "@/lib/utils";
import {
  ApplicationInventoryActions,
  ApplicationManagementCard,
  ApplicationManagementFeedback,
  ApplicationOperationDialog,
  useApplicationManagement,
} from "./application-management";

const applicationDomains = ["applications", "authorizations"] as const;

export function ApplicationDetailPage({
  application,
}: {
  application: ApplicationID;
}) {
  const { api, settings, bootstrap } = useHost();
  const t = useTranslation();
  const [catalogOpen, setCatalogOpen] = useState(false);
  const management = useApplicationManagement();
  const detail = useHostResource<ApplicationDetail>(
    () => api.applicationDetail(application),
    applicationDomains,
    [api, application],
  );
  const catalog = useHostResource<ProviderCatalog>(
    () => api.providersCatalog(application),
    applicationDomains,
    [api, application, catalogOpen],
  );

  if (catalogOpen) {
    return (
      <ResourceFeedback {...catalog} onRetry={() => void catalog.reload()}>
        {(result) => (
          <ProviderCatalogView
            catalog={result}
            applicationName={detail.data?.name ?? application}
            supportedAPIs={detail.data?.supportedAPIs ?? []}
            supportsConfiguration={
              detail.data?.supportsProviderConfiguration ?? false
            }
            onBack={() => setCatalogOpen(false)}
            onChanged={(value) => catalog.setData(value)}
            onProviderAdded={(value) => {
              detail.setData(value);
            }}
          />
        )}
      </ResourceFeedback>
    );
  }

  return (
    <ResourceFeedback {...detail} onRetry={() => void detail.reload()}>
      {(result) => (
        <div className="flex h-full min-h-0 flex-col">
          <div className="border-b px-6 py-5">
            <WorkspaceHeader
              title={result.name}
              leading={
                <HostIcon
                  icon={result.icon}
                  name={result.name}
                  dark={bootstrap.appearance === "dark"}
                  size={28}
                />
              }
              actions={
                <Button onClick={() => setCatalogOpen(true)}>
                  <Plus />
                  {t("Add provider", "添加供应商")}
                </Button>
              }
            />
          </div>
          <div className="cc-scrollbar flex-1">
            <div className="flex flex-col gap-4 p-6">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <h2 className="text-[13px] font-semibold">{t("Installations", "安装信息")}</h2>
                <div className="flex gap-2"><ApplicationInventoryActions management={management} /></div>
              </div>
              <ApplicationManagementFeedback management={management} />
              <ResourceFeedback {...management.resource} onRetry={() => void management.resource.reload()}>
                {(inventory) => inventory.applications
                  .filter((item) => item.configurationApplication === application)
                  .map((item) => <ApplicationManagementCard key={item.id} application={item} management={management} />)}
              </ResourceFeedback>
              <ApplicationOperationDialog management={management} />
              {result.error && (
                <p
                  className="text-[12px] text-orange-600 dark:text-orange-400"
                  role="alert"
                >
                  {result.error}
                </p>
              )}
              <p className="text-[12.5px] text-muted-foreground">
                {t(
                  `Added · ${result.connections.length || (result.loginSummary ? 1 : 0)}`,
                  `已添加 · ${result.connections.length || (result.loginSummary ? 1 : 0)}`,
                )}
              </p>
              {result.connections.map((connection) => (
                <article
                  key={connection.id}
                  className={cn(
                    "flex min-h-20 items-center gap-4 rounded-[10px] border p-[18px]",
                    connection.active
                      ? "border-blue-500/50 bg-blue-500/[0.08]"
                      : "cc-panel",
                  )}
                >
                  <ServiceIcon
                    name={connection.name}
                    color={brandColor(
                      supplierBrand(connection.supplier),
                      settings,
                      bootstrap.appearance === "dark",
                    )}
                    size={38}
                  />
                  <div className="min-w-0 flex-1 space-y-1.5">
                    <div className="flex items-center gap-2">
                      <h2 className="truncate text-[15px] font-semibold">
                        {connection.name}
                      </h2>
                      {connection.official && (
                        <Badge variant="secondary">
                          {t("Official", "官方")}
                        </Badge>
                      )}
                    </div>
                    <p
                      className="truncate text-[12.5px] text-muted-foreground"
                      title={
                        connection.official
                          ? (result.loginSummary ?? undefined)
                          : connection.endpoint
                      }
                    >
                      {connection.official
                        ? (result.loginSummary ??
                          t(
                            "Sign-in managed by the application",
                            "登录由原应用管理",
                          ))
                        : connection.endpoint}
                    </p>
                    <p className="line-clamp-2 text-[11px] text-muted-foreground">
                      {connection.official
                        ? t("Account sign-in", "账号登录")
                        : `API Key${connection.models.length ? ` · ${connection.models.join(" / ")}` : ""}`}
                    </p>
                  </div>
                  {connection.active && (
                    <span className="flex items-center gap-1.5 text-[11px] text-blue-600 dark:text-blue-400">
                      <Check className="size-3" />
                      {t("In use", "使用中")}
                    </span>
                  )}
                </article>
              ))}
              {result.connections.length === 0 && result.loginSummary && (
                <article className="cc-panel flex items-center gap-4 p-[18px]">
                  <HostIcon
                    icon={result.icon}
                    name={result.name}
                    dark={bootstrap.appearance === "dark"}
                    size={38}
                  />
                  <div>
                    <h2 className="text-[15px] font-semibold">{result.name}</h2>
                    <p className="mt-1.5 text-[12.5px] text-muted-foreground">
                      {result.loginSummary}
                    </p>
                    <p className="mt-1.5 text-[11px] text-muted-foreground">
                      {t("Account sign-in", "账号登录")}
                    </p>
                  </div>
                  <span className="flex-1" />
                  <span className="flex items-center gap-1.5 text-[11px] text-blue-600">
                    <Check className="size-3" />
                    {t("In use", "使用中")}
                  </span>
                </article>
              )}
              {result.connections.length === 0 && !result.loginSummary && (
                <EmptyState
                  title={t("No authorizations detected", "暂未识别到授权")}
                  description={t(
                    "Add a provider or sign in within the application.",
                    "添加供应商，或在原应用中登录账号。",
                  )}
                  icon={<KeyRound className="size-7 text-muted-foreground" />}
                />
              )}
            </div>
          </div>
        </div>
      )}
    </ResourceFeedback>
  );
}

export function CatalogBackButton({ onClick }: { onClick: () => void }) {
  const t = useTranslation();
  return (
    <Button
      variant="ghost"
      size="icon-sm"
      onClick={onClick}
      aria-label={t("Back to application", "返回应用")}
    >
      <ArrowLeft />
    </Button>
  );
}
