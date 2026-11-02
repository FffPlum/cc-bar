import { useEffect, useMemo, type ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useHost } from "@/host/host-context";
import type { WindowAPI } from "@ccbar/host-api/window";

let nextScopeId = 0;
type Scope = { id: number; context: string; client: QueryClient };
const sessionScopes = new WeakMap<WindowAPI, Scope>();
function scopeFor(api: WindowAPI, context: string): Scope {
  const existing = sessionScopes.get(api);
  if (existing?.context === context) return existing;
  existing?.client.clear();
  const scope = {
    id: ++nextScopeId,
    context,
    client: new QueryClient({
      defaultOptions: {
        queries: {
          staleTime: 60000,
          gcTime: 600000,
          retry: false,
          refetchOnWindowFocus: true,
        },
      },
    }),
  };
  sessionScopes.set(api, scope);
  return scope;
}
export function DashboardQueryScope({ children }: { children: ReactNode }) {
  const { api, bootstrap, settings } = useHost();
  // A semantic key prevents routine bootstrap refreshes from discarding the cache.
  const securityContext = JSON.stringify({
    privacy: settings.appearance.privacyMode,
    language: bootstrap.resolvedLanguage,
    timeZone: bootstrap.timeZone,
    visibleUsageServices: [...bootstrap.visibleUsageServices].sort(),
    currency: {
      selected: settings.data.currency.selected,
      rates: Object.entries(settings.data.currency.rates).sort(([a], [b]) =>
        a.localeCompare(b),
      ),
    },
    services: bootstrap.sidebarApplications
      .map((x) => [x.id, x.usageService, x.usageVisible, x.addedToSidebar])
      .sort((a, b) => String(a[0]).localeCompare(String(b[0]))),
  });
  const scope = useMemo(
    () => scopeFor(api, securityContext),
    [api, securityContext],
  );
  const { client } = scope;
  useEffect(() => {
    let alive = true;
    let eventGeneration = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const unsubscribeCache = client.getQueryCache().subscribe((event) => {
      if (event.type !== "added") return;
      const all = client.getQueryCache().getAll();
      const removable = all
        .filter(
          (query) =>
            query !== event.query &&
            query.getObserversCount() === 0 &&
            query.state.fetchStatus === "idle",
        )
        .sort((a, b) => a.state.dataUpdatedAt - b.state.dataUpdatedAt);
      for (
        let remaining = all.length;
        remaining > 128 && removable.length;
        remaining--
      )
        client.removeQueries({
          queryKey: removable.shift()!.queryKey,
          exact: true,
        });
    });
    const unsubscribe = api.subscribe((event) => {
      if (
        event.domains.some((x) =>
          ["usage", "pricing", "settings", "applications"].includes(x),
        )
      ) {
        const generation = ++eventGeneration;
        if (timer) clearTimeout(timer);
        void client.cancelQueries().then(() => {
          if (!alive || generation !== eventGeneration) return;
          timer = setTimeout(() => {
            if (alive && generation === eventGeneration)
              void client.invalidateQueries();
          }, 100);
        });
      }
    });
    return () => {
      alive = false;
      if (timer) clearTimeout(timer);
      unsubscribe();
      unsubscribeCache();
      void client.cancelQueries();
      void client.invalidateQueries({ refetchType: "none" });
    };
  }, [api, client]);
  return (
    <QueryClientProvider client={client} key={scope.id}>
      {children}
    </QueryClientProvider>
  );
}
