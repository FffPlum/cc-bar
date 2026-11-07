import { useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { SearchInput } from "@/components/search-input";
import { ResourceFeedback } from "@/components/resource-feedback";
import { EmptyState } from "@/components/workspace";
import { errorMessage, useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { formatDate } from "@/lib/display";
import { Button } from "@/components/ui/button";
import { PendingButton } from "@/components/pending-button";
import { cn } from "@/lib/utils";

export function PricingCatalogDialog({ onClose }: { onClose: () => void }) {
  const { api, bootstrap } = useHost();
  const t = useTranslation();
  const [query, setQuery] = useState("");
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [provider, setProvider] = useState<string | null>(null);
  const resource = useHostResource(
    () => api.pricingCatalog(),
    ["settings", "usage", "pricing"],
    [api],
  );
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="flex h-[min(720px,90vh)] max-w-[min(960px,94vw)] flex-col sm:max-w-[min(960px,94vw)]">
        <DialogHeader>
          <DialogTitle>{t("Price catalog", "价格目录")}</DialogTitle>
          <DialogDescription>
            {t(
              "Prices per million tokens. Converted using the selected display currency.",
              "每百万 Tokens 的价格，按所选显示货币换算。",
            )}
          </DialogDescription>
        </DialogHeader>
        <div className="flex items-center gap-3">
          <Button
            size="sm"
            variant="link"
            onClick={() =>
              void api
                .platformOpenExternal("https://models.dev")
                .catch((reason: unknown) =>
                  setActionError(errorMessage(reason)),
                )
            }
          >
            models.dev ↗
          </Button>
          <span className="flex-1" />
          <PendingButton
            size="sm"
            variant="outline"
            pending={pending || resource.data?.usage.refreshingPricing || false}
            onClick={() => {
              if (pending) return;
              setPending(true);
              setMessage(null);
              setActionError(null);
              void api
                .pricingRefreshAndRecalculate()
                .then(async (result) => {
                  if (result.ok) setMessage(result.message);
                  else setActionError(result.message);
                  await resource.reload();
                })
                .catch((reason: unknown) =>
                  setActionError(errorMessage(reason)),
                )
                .finally(() => setPending(false));
            }}
          >
            {t("Update & Recalculate", "更新并重算")}
          </PendingButton>
        </div>
        {actionError && (
          <p role="alert" className="text-xs text-orange-600">
            {actionError}
          </p>
        )}
        {message && (
          <p role="status" className="text-xs text-muted-foreground">
            {message}
          </p>
        )}
        <ResourceFeedback {...resource} onRetry={() => void resource.reload()}>
          {(catalog) => {
            const normalized = query.trim().toLowerCase();
            const providers = catalog.providers
              .map((item) => ({
                ...item,
                models: item.models.filter((model) =>
                  `${item.name} ${model.name} ${model.id}`
                    .toLowerCase()
                    .includes(normalized),
                ),
              }))
              .filter((item) => item.models.length);
            const selected =
              providers.find((item) => item.id === provider) ?? providers[0];
            return (
              <>
                <div className="flex items-center gap-4">
                  <SearchInput
                    value={query}
                    onChange={setQuery}
                    placeholder={t(
                      "Search models or providers",
                      "搜索模型或提供商",
                    )}
                  />
                  <span className="shrink-0 text-xs text-muted-foreground">
                    {formatDate(
                      catalog.fetchedAt,
                      bootstrap.resolvedLanguage,
                      bootstrap.timeZone,
                    )}
                  </span>
                </div>
                {catalog.refreshFailed && (
                  <p className="text-xs text-orange-600" role="status">
                    {t(
                      "Price refresh failed. Showing saved prices.",
                      "价格刷新失败，保留已保存的价格。",
                    )}
                  </p>
                )}
                <div className="flex min-h-0 flex-1 gap-4">
                  <nav
                    className="cc-scrollbar w-36 shrink-0 space-y-1"
                    aria-label={t("Providers", "提供商")}
                  >
                    {providers.map((item) => (
                      <button
                        type="button"
                        key={item.id}
                        aria-pressed={item.id === selected?.id}
                        className={cn(
                          "flex w-full justify-between gap-2 rounded px-2 py-2 text-left text-xs",
                          item.id === selected?.id && "bg-muted",
                        )}
                        onClick={() => setProvider(item.id)}
                      >
                        <span className="truncate">{item.name}</span>
                        <span>{item.models.length}</span>
                      </button>
                    ))}
                  </nav>
                  <div className="cc-scrollbar min-w-0 flex-1">
                    {selected ? (
                      <Table>
                        <TableHeader>
                          <TableRow>
                            <TableHead>{t("Model", "模型")}</TableHead>
                            {[
                              t("Input", "输入"),
                              t("Output", "输出"),
                              t("Cache read", "缓存读取"),
                              t("Cache write", "缓存写入"),
                            ].map((label) => (
                              <TableHead key={label} className="text-right">
                                {label}
                              </TableHead>
                            ))}
                          </TableRow>
                        </TableHeader>
                        <TableBody>
                          {selected.models.map((model) => (
                            <TableRow key={model.id}>
                              <TableCell>
                                <p>{model.name}</p>
                                <p className="text-[10px] text-muted-foreground">
                                  {model.id}
                                </p>
                              </TableCell>
                              {(
                                [
                                  "input",
                                  "output",
                                  "cacheRead",
                                  "cacheCreation",
                                ] as const
                              ).map((key) => (
                                <TableCell
                                  key={key}
                                  className="cc-number text-right"
                                >
                                  {model.displayPrice[key]}
                                </TableCell>
                              ))}
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    ) : (
                      <EmptyState
                        title={t("No matching models", "没有匹配的模型")}
                      />
                    )}
                  </div>
                </div>
              </>
            );
          }}
        </ResourceFeedback>
      </DialogContent>
    </Dialog>
  );
}
