import { useRef, useState } from "react";
import { Grid2X2 } from "lucide-react";
import type {
  ApplicationSummary,
  ApplicationsResult,
} from "@ccbar/host-api/window";
import { Switch } from "@/components/ui/switch";
import {
  DropdownMenuCheckboxItem,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";
import { EmptyState, WorkspaceHeader } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { SearchInput } from "@/components/search-input";
import { useHost, useHostResource, errorMessage } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import {
  applicationRowGrid,
  ApplicationInventoryActions,
  ApplicationManagementCard,
  ApplicationManagementFeedback,
  ApplicationOperationDialog,
  useApplicationManagement,
} from "./application-management";

const applicationDomains = ["applications"] as const;

export function ApplicationsPage() {
  const { api, refreshBootstrap, navigate } = useHost();
  const t = useTranslation();
  const management = useApplicationManagement();
  const visibility = useHostResource<ApplicationsResult>(
    () => api.applicationsList(),
    applicationDomains,
    [api],
  );
  const [search, setSearch] = useState("");
  const [pending, setPending] = useState<string | null>(null);
  const [operationError, setOperationError] = useState<string | null>(null);
  const visibilityPending = useRef(false);

  const update = async (
    application: ApplicationSummary,
    patch: { addedToSidebar?: boolean; usageVisible?: boolean },
  ) => {
    if (visibilityPending.current) return;
    visibilityPending.current = true;
    setPending(application.id);
    setOperationError(null);
    try {
      visibility.setData(
        await api.applicationsSetVisibility(application.id, patch),
      );
      await refreshBootstrap();
    } catch (reason) {
      setOperationError(errorMessage(reason));
    } finally {
      visibilityPending.current = false;
      setPending(null);
    }
  };

  const query = search.trim().toLocaleLowerCase();
  const filtered =
    management.resource.data?.applications.filter(
      (application) =>
        !query ||
        `${application.name} ${application.id}`
          .toLocaleLowerCase()
          .includes(query),
    ) ?? [];
  const initialScan =
    management.resource.data?.scanning &&
    !management.resource.data.lastScannedAt;
  const sections = initialScan
    ? [{ key: "all", title: t("Applications", "应用"), applications: filtered }]
    : [
        {
          key: "installed",
          title: t("Installed", "已安装"),
          applications: filtered.filter((app) => app.installed),
        },
        {
          key: "notInstalled",
          title: t("Not installed", "未安装"),
          applications: filtered.filter((app) => !app.installed),
        },
      ].filter((section) => section.applications.length > 0);

  return (
    <div className="flex h-full min-w-0 flex-col">
      <div className="shrink-0 border-b px-6 py-4">
        <WorkspaceHeader
          title={t("Applications", "应用")}
          leading={<Grid2X2 className="size-5 text-muted-foreground" />}
          actions={<ApplicationInventoryActions management={management} />}
        />
      </div>
      <div className="cc-scrollbar flex min-h-0 flex-1 flex-col gap-4 px-6 pb-10 pt-4">
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder={t("Search applications", "搜索应用")}
        />
        <ApplicationManagementFeedback management={management} />
        {(operationError || visibility.error || visibility.data?.error) && (
          <p
            role="alert"
            className="text-[12px] text-orange-600 dark:text-orange-400"
          >
            {operationError ?? visibility.error ?? visibility.data?.error}
          </p>
        )}
        <ResourceFeedback
          {...management.resource}
          onRetry={() => void management.resource.reload()}
        >
          {(inventory) => (
            <>
              <div className="space-y-4">
                {sections.map((section) => (
                  <section
                    key={section.key}
                    aria-label={`${section.title} (${section.applications.length})`}
                  >
                    <div
                      className={`${applicationRowGrid} min-h-8 px-4 text-[11px] text-muted-foreground`}
                    >
                      <h2 className="font-semibold">
                        {section.title}{" "}
                        <span className="tabular-nums">
                          ({section.applications.length})
                        </span>
                      </h2>
                      <span className="text-right">{t("Version", "版本")}</span>
                      <span />
                      <span className="text-right">{t("Sidebar", "侧栏")}</span>
                      <span />
                    </div>
                    <div className="cc-panel divide-y overflow-hidden">
                      {section.applications.map((application) => {
                        const configuration =
                          application.configurationApplication
                            ? visibility.data?.applications.find(
                                (item) =>
                                  item.id ===
                                  application.configurationApplication,
                              )
                            : undefined;
                        return (
                          <ApplicationManagementCard
                            key={application.id}
                            application={application}
                            management={management}
                            grouped
                            sidebar={
                              configuration && (
                                <Switch
                                  size="sm"
                                  checked={configuration.addedToSidebar}
                                  onCheckedChange={(checked) =>
                                    void update(configuration, {
                                      addedToSidebar: checked,
                                    })
                                  }
                                  disabled={
                                    pending !== null || !configuration.detected
                                  }
                                  aria-label={`${application.name} ${t("In sidebar", "添加到侧栏")}`}
                                />
                              )
                            }
                          >
                            {configuration && (
                              <>
                                <DropdownMenuItem
                                  onClick={() =>
                                    void navigate({
                                      page: "application",
                                      application: configuration.id,
                                    })
                                  }
                                >
                                  {t("Configuration", "配置")}
                                </DropdownMenuItem>
                                {configuration.usageService && (
                                  <DropdownMenuCheckboxItem
                                    checked={configuration.usageVisible}
                                    onCheckedChange={(checked) =>
                                      void update(configuration, {
                                        usageVisible: checked,
                                      })
                                    }
                                    disabled={pending !== null}
                                  >
                                    {t("Usage statistics", "用量统计")}
                                  </DropdownMenuCheckboxItem>
                                )}
                              </>
                            )}
                          </ApplicationManagementCard>
                        );
                      })}
                    </div>
                  </section>
                ))}
              </div>
              {filtered.length === 0 && (
                <EmptyState
                  title={
                    inventory.applications.length === 0
                      ? t("No applications available", "暂无可管理的应用")
                      : t("No matching applications", "没有匹配的应用")
                  }
                  icon={<Grid2X2 className="size-7 text-muted-foreground" />}
                />
              )}
            </>
          )}
        </ResourceFeedback>
        <ApplicationOperationDialog management={management} />
      </div>
    </div>
  );
}
