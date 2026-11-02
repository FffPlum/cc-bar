import type { ReactNode } from "react";
import { Button } from "@/components/ui/button";
import { EmptyState, InlineNotice, LoadingState } from "@/components/workspace";
import { useTranslation } from "@/lib/i18n";

export function ResourceFeedback<T>({
  data,
  error,
  loading,
  onRetry,
  children,
  empty,
}: {
  data: T | null;
  error: string | null;
  loading: boolean;
  onRetry: () => void;
  children: (data: T) => ReactNode;
  empty?: ReactNode;
}) {
  const t = useTranslation();
  if (!data && loading) return <LoadingState />;
  if (!data && error)
    return (
      <EmptyState
        title={t("Couldn’t load this page", "此页暂时无法加载")}
        description={error}
        action={
          <Button variant="outline" onClick={onRetry}>
            {t("Retry", "重试")}
          </Button>
        }
      />
    );
  if (!data) return <>{empty ?? null}</>;
  return (
    <>
      {error && (
        <InlineNotice>
          <span>
            {t(
              "Refresh failed. Showing the last available data.",
              "刷新失败，显示的是上次成功取到的数据。",
            )}{" "}
            {error}
          </span>
          <Button size="sm" variant="ghost" onClick={onRetry}>
            {t("Retry", "重试")}
          </Button>
        </InlineNotice>
      )}
      {children(data)}
    </>
  );
}
