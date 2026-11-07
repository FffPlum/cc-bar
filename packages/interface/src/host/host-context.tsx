import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type DependencyList,
  type ReactNode,
} from "react";
import { HostError, type Domain } from "@ccbar/host-api";
import type {
  Route,
  WindowAPI,
  WindowBootstrap,
  WindowSettings,
} from "@ccbar/host-api/window";
import { ErrorState, LoadingState } from "@/components/workspace";
import { useTranslation } from "@/lib/i18n";

interface HostContextValue {
  api: WindowAPI;
  bootstrap: WindowBootstrap;
  settings: WindowSettings;
  navigate: (route: Route) => Promise<void>;
  routePending: boolean;
  hostError: string | null;
  retry: () => void;
  refreshBootstrap: () => Promise<void>;
  refreshSettings: () => Promise<void>;
}

const HostContext = createContext<HostContextValue | null>(null);

export function HostProvider({
  api,
  children,
}: {
  api: WindowAPI;
  children: ReactNode;
}) {
  const [bootstrap, setBootstrap] = useState<WindowBootstrap | null>(null);
  const [settings, setSettings] = useState<WindowSettings | null>(null);
  const [bootstrapError, setBootstrapError] = useState<string | null>(null);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [navigationError, setNavigationError] = useState<string | null>(null);
  const [routePending, setRoutePending] = useState(false);
  const bootstrapGeneration = useRef(0);
  const settingsGeneration = useRef(0);
  const navigationGeneration = useRef(0);
  const mounted = useRef(true);

  const refreshBootstrap = useCallback(async () => {
    const current = ++bootstrapGeneration.current;
    try {
      const value = await api.bootstrap();
      if (mounted.current && bootstrapGeneration.current === current) {
        setBootstrap(value);
        setBootstrapError(null);
      }
    } catch (reason) {
      if (mounted.current && bootstrapGeneration.current === current)
        setBootstrapError(errorMessage(reason));
    }
  }, [api]);

  const refreshSettings = useCallback(async () => {
    const current = ++settingsGeneration.current;
    try {
      const value = await api.settingsGet();
      if (mounted.current && settingsGeneration.current === current) {
        setSettings(value);
        setSettingsError(null);
      }
    } catch (reason) {
      if (mounted.current && settingsGeneration.current === current)
        setSettingsError(errorMessage(reason));
    }
  }, [api]);

  useEffect(() => {
    mounted.current = true;
    void refreshBootstrap();
    void refreshSettings();
    return () => {
      mounted.current = false;
      bootstrapGeneration.current += 1;
      settingsGeneration.current += 1;
      navigationGeneration.current += 1;
    };
  }, [refreshBootstrap, refreshSettings]);

  useEffect(
    () =>
      api.subscribe((event) => {
        if (
          event.domains.some((domain) =>
            ["settings", "notifications", "updates", "pricing"].includes(
              domain,
            ),
          )
        ) {
          void refreshSettings();
          void refreshBootstrap();
        }
        if (
          event.domains.includes("navigation") ||
          event.domains.includes("applications") ||
          event.domains.includes("appearance")
        ) {
          void refreshBootstrap();
        }
      }),
    [api, refreshBootstrap, refreshSettings],
  );

  const navigate = useCallback(
    async (route: Route) => {
      const navigation = ++navigationGeneration.current;
      const request = ++bootstrapGeneration.current;
      setRoutePending(true);
      setNavigationError(null);
      try {
        const value = await api.navigate(route);
        if (
          mounted.current &&
          navigationGeneration.current === navigation &&
          bootstrapGeneration.current === request
        ) {
          setBootstrap(value);
          setNavigationError(null);
        }
      } catch (reason) {
        if (mounted.current && navigationGeneration.current === navigation)
          setNavigationError(errorMessage(reason));
      } finally {
        if (mounted.current && navigationGeneration.current === navigation)
          setRoutePending(false);
      }
    },
    [api],
  );

  const retry = useCallback(() => {
    setBootstrapError(null);
    setSettingsError(null);
    setNavigationError(null);
    void refreshBootstrap();
    void refreshSettings();
  }, [refreshBootstrap, refreshSettings]);
  const hostError = navigationError ?? bootstrapError ?? settingsError;
  const value = useMemo<HostContextValue | null>(
    () =>
      bootstrap && settings
        ? {
            api,
            bootstrap,
            settings,
            navigate,
            routePending,
            hostError,
            retry,
            refreshBootstrap,
            refreshSettings,
          }
        : null,
    [
      api,
      bootstrap,
      settings,
      navigate,
      routePending,
      hostError,
      retry,
      refreshBootstrap,
      refreshSettings,
    ],
  );

  if (!value) return <BootstrapFeedback error={hostError} onRetry={retry} />;
  return <HostContext.Provider value={value}>{children}</HostContext.Provider>;
}

function BootstrapFeedback({
  error,
  onRetry,
}: {
  error: string | null;
  onRetry: () => void;
}) {
  const t = useTranslation();
  if (error)
    return (
      <ErrorState
        title={t("CCBar couldn’t load the main window", "主窗口暂时无法加载")}
        message={
          t(
            "The app’s data service didn’t respond. Close and reopen the window, or restart CCBar and try again.",
            "应用数据服务没有响应。请关闭后重新打开窗口，或重启 CCBar 再试。",
          ) + `\n\n${error}`
        }
        onRetry={onRetry}
      />
    );
  return (
    <LoadingState
      label={t("Connecting to CCBar…", "正在连接 CCBar…")}
      rows={3}
    />
  );
}

export function useHost(): HostContextValue {
  const value = useContext(HostContext);
  if (!value) throw new Error("HostProvider is missing");
  return value;
}

export function useHostResource<T>(
  loader: () => Promise<T>,
  domains: readonly Domain[],
  dependencies: DependencyList,
) {
  const { api, settings, bootstrap } = useHost();
  const [data, setDataState] = useState<T | null>(null);
  const visibilityKey = `${settings.appearance.privacyMode}:${settings.data.currency.selected}:${bootstrap.resolvedLanguage}`;
  const visibilityKeyRef = useRef(visibilityKey);
  visibilityKeyRef.current = visibilityKey;
  const dataVisibilityKey = useRef(visibilityKey);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const generation = useRef(0);
  const loaderRef = useRef(loader);
  loaderRef.current = loader;
  const domainKey = domains.join("\0");

  const reload = useCallback(async () => {
    const current = ++generation.current;
    const requestVisibility = visibilityKeyRef.current;
    setLoading(true);
    try {
      const value = await loaderRef.current();
      if (generation.current !== current) return;
      dataVisibilityKey.current = requestVisibility;
      setDataState(value);
      setError(null);
    } catch (reason) {
      if (generation.current === current) setError(errorMessage(reason));
    } finally {
      if (generation.current === current) setLoading(false);
    }
  }, []);

  const setData = useCallback((value: T) => {
    generation.current += 1;
    dataVisibilityKey.current = visibilityKeyRef.current;
    setDataState(value);
    setError(null);
    setLoading(false);
  }, []);

  useEffect(() => {
    dataVisibilityKey.current = visibilityKeyRef.current;
    setDataState(null);
    setError(null);
    void reload();
    return () => {
      generation.current += 1;
    };
  }, [
    ...dependencies,
    settings.appearance.privacyMode,
    settings.data.currency.selected,
    bootstrap.resolvedLanguage,
  ]);

  useEffect(
    () =>
      api.subscribe((event) => {
        if (
          domainKey.length > 0 &&
          event.domains.some((domain) => domainKey.split("\0").includes(domain))
        )
          void reload();
      }),
    [api, domainKey, reload],
  );

  const visible = dataVisibilityKey.current === visibilityKey;
  return {
    data: visible ? data : null,
    error: visible ? error : null,
    loading: loading || !visible,
    reload,
    setData,
  };
}

export function errorMessage(reason: unknown): string {
  const chinese =
    typeof document !== "undefined" &&
    document.documentElement.lang.toLocaleLowerCase().startsWith("zh");
  const choose = (english: string, zh: string) => (chinese ? zh : english);
  if (reason instanceof HostError) {
    if (reason.code === "timeout")
      return choose(
        "The operation took too long. Check the current state before trying again.",
        "操作等待超时。请先查看当前状态，再决定是否重试。",
      );
    if (reason.code === "unavailable")
      return choose(
        "CCBar’s data service is unavailable. Reopen the window or restart the app.",
        "CCBar 数据服务不可用。请重新打开窗口或重启应用。",
      );
    if (reason.code === "disposed")
      return choose(
        "The window was closed. Reopen it and try again.",
        "窗口已关闭。请重新打开后再试。",
      );
    if (reason.code === "invalid_response")
      return choose(
        "CCBar returned data this window couldn’t read. Restart the app and try again.",
        "CCBar 返回了窗口无法读取的数据。请重启应用后再试。",
      );
    if (reason.code === "not_found")
      return choose(
        "This item no longer exists. Refresh and choose again.",
        "此项已不存在。请刷新后重新选择。",
      );
    if (reason.code === "operation_failed" || reason.code === "invalid_params")
      return reason.message;
    return choose(
      "The operation couldn’t be completed. Check the current state and try again.",
      "操作未完成。请查看当前状态后再试。",
    );
  }
  return choose(
    "The operation couldn’t be completed. Check the current state and try again.",
    "操作未完成。请查看当前状态后再试。",
  );
}
