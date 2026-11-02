import { useState } from "react";
import { Grid2X2, RefreshCw } from "lucide-react";
import type {
  ApplicationSummary,
  ApplicationsResult,
} from "@ccbar/host-api/window";
import { Switch } from "@/components/ui/switch";
import { EmptyState, WorkspaceHeader } from "@/components/workspace";
import { ResourceFeedback } from "@/components/resource-feedback";
import { HostIcon } from "@/components/host-icon";
import { PendingButton } from "@/components/pending-button";
import { useHost, useHostResource, errorMessage } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";

const applicationDomains = ["applications"] as const;

export function ApplicationsPage() {
  const { api, bootstrap, refreshBootstrap } = useHost();
  const t = useTranslation();
  const resource = useHostResource<ApplicationsResult>(
    () => api.applicationsList(),
    applicationDomains,
    [api],
  );
  const [pending, setPending] = useState<string | null>(null);
  const [operationError, setOperationError] = useState<string | null>(null);

  const update = async (
    application: ApplicationSummary,
    patch: { addedToSidebar?: boolean; usageVisible?: boolean },
  ) => {
    const key = `${application.id}:${Object.keys(patch).join(",")}`;
    if (pending) return;
    setPending(key);
    setOperationError(null);
    try {
      const result = await api.applicationsSetVisibility(application.id, patch);
      resource.setData(result);
      await refreshBootstrap();
    } catch (reason) {
      setOperationError(errorMessage(reason));
    } finally {
      setPending(null);
    }
  };

  const detect = async () => {
    if (pending) return;
    setPending("detect");
    setOperationError(null);
    try {
      resource.setData(await api.applicationsDetect());
      await refreshBootstrap();
    } catch (reason) {
      setOperationError(errorMessage(reason));
    } finally {
      setPending(null);
    }
  };

  return (
    <div className="cc-scrollbar h-full">
      <div className="mx-auto flex w-full max-w-[1000px] flex-col gap-5 p-7">
        <WorkspaceHeader
          title={t("Applications", "应用")}
          actions={
            <PendingButton
              pending={pending === "detect"}
              onClick={() => void detect()}
              variant="outline"
            >
              <RefreshCw />
              {t("Detect applications", "重新识别")}
            </PendingButton>
          }
        />
        {operationError && (
          <p
            className="text-[11.5px] text-orange-600 dark:text-orange-400"
            role="alert"
          >
            {operationError}
          </p>
        )}
        <ResourceFeedback {...resource} onRetry={() => void resource.reload()}>
          {(result) => (
            <>
              {result.error && (
                <p className="text-[11.5px] text-orange-600 dark:text-orange-400">
                  {result.error}
                </p>
              )}
              <h2 className="text-[13px] font-semibold">
                {t("Installed applications", "已安装的应用")}
              </h2>
              <div className="space-y-3">
                {result.applications
                  .filter((application) => application.detected)
                  .map((application) => (
                    <div
                      key={application.id}
                      className="cc-panel flex items-center gap-3.5 p-[18px]"
                    >
                      <HostIcon
                        icon={application.icon}
                        name={application.name}
                        dark={bootstrap.appearance === "dark"}
                        size={32}
                      />
                      <div className="min-w-0 flex-1">
                        <h3 className="text-[13px] font-semibold">
                          {application.name}
                        </h3>
                        {!application.usageService && (
                          <p className="mt-1 text-[11px] text-muted-foreground">
                            {t(
                              "Usage statistics unavailable",
                              "暂未接入用量统计",
                            )}
                          </p>
                        )}
                      </div>
                      {application.usageService && (
                        <label className="flex items-center gap-2 text-[12px]">
                          <span>{t("Usage statistics", "用量统计")}</span>
                          <Switch
                            checked={application.usageVisible}
                            onCheckedChange={(checked) =>
                              void update(application, {
                                usageVisible: checked,
                              })
                            }
                            disabled={pending !== null}
                            aria-label={`${application.name} ${t("Usage statistics", "用量统计")}`}
                          />
                        </label>
                      )}
                      <label className="flex items-center gap-2 text-[12px]">
                        <span>{t("In sidebar", "添加到侧栏")}</span>
                        <Switch
                          checked={application.addedToSidebar}
                          onCheckedChange={(checked) =>
                            void update(application, {
                              addedToSidebar: checked,
                            })
                          }
                          disabled={pending !== null}
                          aria-label={`${application.name} ${t("In sidebar", "添加到侧栏")}`}
                        />
                      </label>
                    </div>
                  ))}
              </div>
              {result.applications.filter((application) => application.detected)
                .length === 0 && (
                <EmptyState
                  title={t("No applications detected", "暂未识别到应用")}
                  icon={<Grid2X2 className="size-7 text-muted-foreground" />}
                  description={t(
                    "Detect applications again after installing or signing in.",
                    "安装或登录应用后，可重新识别。",
                  )}
                />
              )}
            </>
          )}
        </ResourceFeedback>
      </div>
    </div>
  );
}
