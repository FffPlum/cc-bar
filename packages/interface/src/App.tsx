import { lazy, Suspense, useEffect, type ReactNode } from "react";
import type { Route } from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import { HostIcon } from "@/components/host-icon";
import { NavigationIcon } from "@/components/navigation-icon";
import { InlineNotice, LoadingState } from "@/components/workspace";
import { useHost } from "@/host/host-context";
import { LanguageProvider, useTranslation } from "@/lib/i18n";
import { cn } from "@/lib/utils";
const ApplicationsPage = lazy(() =>
  import("@/features/applications/applications-page").then((module) => ({
    default: module.ApplicationsPage,
  })),
);
const ApplicationDetailPage = lazy(() =>
  import("@/features/applications/application-detail-page").then((module) => ({
    default: module.ApplicationDetailPage,
  })),
);
const QuotaPage = lazy(() =>
  import("@/features/quota/quota-page").then((module) => ({
    default: module.QuotaPage,
  })),
);
const StatsPage = lazy(() =>
  import("@/features/stats/stats-page").then((module) => ({
    default: module.StatsPage,
  })),
);
const SettingsPage = lazy(() =>
  import("@/features/settings/settings-page").then((module) => ({
    default: module.SettingsPage,
  })),
);

export function App() {
  const { bootstrap } = useHost();
  useEffect(() => {
    document.documentElement.lang = bootstrap.resolvedLanguage;
    document.documentElement.classList.toggle(
      "dark",
      bootstrap.appearance === "dark",
    );
  }, [bootstrap.resolvedLanguage, bootstrap.appearance]);
  return (
    <LanguageProvider language={bootstrap.resolvedLanguage}>
      <Workspace />
    </LanguageProvider>
  );
}

function Workspace() {
  const { bootstrap, navigate, routePending, hostError, retry } = useHost();
  const t = useTranslation();
  const route = bootstrap.route;
  const nav = (target: Route, label: string, icon: ReactNode) => {
    const active =
      target.page === route.page &&
      (target.page !== "application" ||
        (route.page === "application" &&
          target.application === route.application));
    return (
      <button
        key={target.page === "application" ? target.application : target.page}
        type="button"
        aria-current={active ? "page" : undefined}
        onClick={() => void navigate(target)}
        className={cn(
          "flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-left text-[12.5px] outline-none focus-visible:ring-2 focus-visible:ring-ring",
          active
            ? "bg-black/[0.08] font-medium dark:bg-white/[0.10]"
            : "hover:bg-black/[0.04] dark:hover:bg-white/[0.04]",
        )}
      >
        {icon}
        <span className="truncate">{label}</span>
      </button>
    );
  };
  return (
    <div className="flex h-dvh min-h-0 w-full overflow-hidden bg-background text-foreground">
      <aside
        className="flex w-[200px] shrink-0 flex-col border-r bg-sidebar px-2.5 pb-2.5 pt-4"
        aria-label={t("Navigation", "导航")}
      >
        <div className="mb-3 px-2 text-[11px] font-semibold text-muted-foreground">
          CCBar
        </div>
        <nav
          className="cc-scrollbar min-h-0 flex-1 space-y-1"
          aria-label={t("Applications", "应用")}
        >
          {bootstrap.sidebarApplications
            .filter((app) => app.addedToSidebar)
            .map((app) =>
              nav(
                { page: "application", application: app.id },
                app.name,
                <HostIcon
                  icon={app.icon}
                  name={app.name}
                  dark={bootstrap.appearance === "dark"}
                  size={20}
                />,
              ),
            )}
        </nav>
        <nav
          className="mt-3 space-y-1 border-t pt-2"
          aria-label={t("Workspace", "工作区")}
        >
          {nav(
            { page: "quotaManagement" },
            t("Quota Management", "额度管理"),
            <NavigationIcon page="quotaManagement" />,
          )}
          {nav(
            { page: "stats" },
            t("Usage Statistics", "用量统计"),
            <NavigationIcon page="stats" />,
          )}
        </nav>
        <nav
          className="mt-2 space-y-1 border-t pt-2"
          aria-label={t("Manage", "管理")}
        >
          {nav(
            { page: "applications" },
            t("Applications", "应用"),
            <NavigationIcon page="applications" />,
          )}
          {nav(
            { page: "settings" },
            t("Settings", "设置"),
            <NavigationIcon page="settings" />,
          )}
        </nav>
      </aside>
      <main
        className="relative flex min-h-0 min-w-0 flex-1 flex-col"
        aria-busy={routePending}
      >
        {hostError && (
          <InlineNotice tone="error">
            {hostError}
            <Button
              size="xs"
              variant="outline"
              className="ml-3"
              onClick={retry}
            >
              {t("Retry", "重试")}
            </Button>
          </InlineNotice>
        )}
        <div className="min-h-0 flex-1">
          <Suspense fallback={<LoadingState />}>
            {route.page === "applications" && <ApplicationsPage />}
            {route.page === "application" && (
              <ApplicationDetailPage
                key={route.application}
                application={route.application}
              />
            )}
            {route.page === "quotaManagement" && <QuotaPage />}
            {route.page === "stats" && <StatsPage />}
            {route.page === "settings" && <SettingsPage />}
          </Suspense>
        </div>
      </main>
    </div>
  );
}
