import { useState } from "react";
import { Plus } from "lucide-react";
import type {
  AddProviderInput,
  APIKeyChoice,
  ApplicationDetail,
  ApplicationID,
  ProviderCatalog,
  ProviderProtocol,
  Supplier,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { WorkspaceHeader } from "@/components/workspace";
import { SearchInput } from "@/components/search-input";
import { ServiceIcon } from "@/components/service-icon";
import { FormField } from "@/components/form-field";
import { SelectField } from "@/components/select-field";
import { PendingButton } from "@/components/pending-button";
import { useHost, errorMessage } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import {
  applicationDisplayName,
  brandColor,
  supplierBrand,
} from "@/lib/display";
import { CatalogBackButton } from "@/features/applications/application-detail-page";
import { cn } from "@/lib/utils";

type Category = "all" | "keys" | "suppliers" | "custom";

export function ProviderCatalogView({
  catalog,
  applicationName,
  supportedAPIs,
  supportsConfiguration,
  onBack,
  onChanged,
  onProviderAdded,
}: {
  catalog: ProviderCatalog;
  applicationName: string;
  supportedAPIs: ProviderProtocol[];
  supportsConfiguration: boolean;
  onBack: () => void;
  onChanged: (catalog: ProviderCatalog) => void;
  onProviderAdded: (detail: ApplicationDetail) => void;
}) {
  const t = useTranslation();
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<Category>("all");
  const [keyEditor, setKeyEditor] = useState<Supplier | "custom" | null>(null);
  const [providerEditor, setProviderEditor] = useState<APIKeyChoice | null>(
    null,
  );
  const normalized = query.trim().toLocaleLowerCase();
  const matches = (value: string) =>
    !normalized || value.toLocaleLowerCase().includes(normalized);
  const keys = catalog.apiKeys.filter((item) =>
    matches(
      `${item.name} ${catalog.suppliers.find((supplier) => supplier.id === item.supplier)?.name ?? item.supplier} ${item.endpoint}`,
    ),
  );
  const suppliers = catalog.suppliers.filter(
    (item) => item.id !== "custom" && matches(`${item.name} ${item.endpoint}`),
  );
  const showCustom = matches("Custom 自定义 API Key");
  const counts: Record<Category, number> = {
    all: keys.length + suppliers.length + (showCustom ? 1 : 0),
    keys: keys.length,
    suppliers: suppliers.length,
    custom: showCustom ? 1 : 0,
  };
  const categories: { id: Category; label: string }[] = [
    { id: "all", label: t("All", "全部") },
    { id: "keys", label: t("Available API Keys", "可用 API Key") },
    { id: "suppliers", label: t("Model providers", "模型厂商") },
    { id: "custom", label: t("Custom", "自定义") },
  ];

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="border-b px-6 py-5">
        <WorkspaceHeader
          title={t("Add provider", "添加供应商")}
          leading={
            <>
              <CatalogBackButton onClick={onBack} />
              <span className="text-muted-foreground">{applicationName}</span>
            </>
          }
          actions={
            <Button variant="outline" onClick={() => setKeyEditor("custom")}>
              <Plus />
              {t("Add API Key", "添加 API Key")}
            </Button>
          }
        />
      </div>
      <div className="flex min-h-0 flex-1 flex-col gap-[18px] p-6">
        <SearchInput
          value={query}
          onChange={setQuery}
          placeholder={t("Search name or endpoint", "搜索名称或 API 地址")}
        />
        <div className="flex min-h-0 flex-1 gap-6">
          <nav
            className="flex w-[165px] shrink-0 flex-col gap-1"
            aria-label={t("Provider categories", "供应商分类")}
          >
            {categories.map((item) => (
              <button
                key={item.id}
                type="button"
                onClick={() => setCategory(item.id)}
                aria-pressed={category === item.id}
                className={cn(
                  "flex items-center rounded-[7px] p-2.5 text-left",
                  category === item.id &&
                    "bg-black/[0.08] dark:bg-white/[0.08]",
                )}
              >
                <span>{item.label}</span>
                <span className="flex-1" />
                <span className="cc-number text-muted-foreground">
                  {counts[item.id]}
                </span>
              </button>
            ))}
          </nav>
          <div className="cc-scrollbar flex-1">
            {catalog.error && (
              <p className="mb-4 text-[12px] text-orange-600 dark:text-orange-400">
                {catalog.error}
              </p>
            )}
            {(category === "all" || category === "keys") && (
              <CatalogSection title={t("Available API Keys", "可用 API Key")}>
                {keys.map((key) => (
                  <CatalogCard
                    key={key.id}
                    name={key.name}
                    supplier={key.supplier}
                    endpoint={key.endpoint}
                    detail={
                      key.sourceApplications.length
                        ? `${t("Detected in", "识别自")} ${key.sourceApplications.map(applicationDisplayName).join("、")}`
                        : t("Saved API Key", "已保存的 API Key")
                    }
                    onClick={() => setProviderEditor(key)}
                    disabled={!supportsConfiguration}
                  />
                ))}
                {keys.length === 0 && (
                  <p className="text-[12.5px] text-muted-foreground">
                    {t("No matching API Keys", "暂无匹配的 API Key")}
                  </p>
                )}
              </CatalogSection>
            )}
            {(category === "all" || category === "suppliers") && (
              <CatalogSection title={t("Model providers", "模型厂商")}>
                {suppliers.map((supplier) => (
                  <CatalogCard
                    key={supplier.id}
                    name={supplier.name}
                    supplier={supplier.id}
                    endpoint={supplier.endpoint}
                    detail={t("Add API Key", "添加 API Key")}
                    onClick={() => setKeyEditor(supplier.id)}
                  />
                ))}
              </CatalogSection>
            )}
            {(category === "all" || category === "custom") && showCustom && (
              <CatalogSection title={t("Custom", "自定义")}>
                <CatalogCard
                  name={t("Custom provider", "自定义供应商")}
                  supplier="custom"
                  endpoint={t(
                    "Enter an endpoint and API Key",
                    "填写 API 地址和 API Key",
                  )}
                  onClick={() => setKeyEditor("custom")}
                />
              </CatalogSection>
            )}
          </div>
        </div>
      </div>
      {keyEditor !== null && (
        <APIKeyDialog
          key={keyEditor}
          supplierID={keyEditor}
          catalog={catalog}
          onOpenChange={(open) => {
            if (!open) setKeyEditor(null);
          }}
          onSaved={(result) => {
            onChanged(result);
            setKeyEditor(null);
          }}
        />
      )}
      {providerEditor && (
        <ProviderDialog
          key={providerEditor.id}
          authorization={providerEditor}
          application={catalog.application}
          supportedAPIs={supportedAPIs}
          onOpenChange={(open) => {
            if (!open) setProviderEditor(null);
          }}
          onAdded={(detail) => {
            setProviderEditor(null);
            onProviderAdded(detail);
          }}
        />
      )}
    </div>
  );
}

function CatalogSection({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="mb-[18px] space-y-3">
      <h2 className="text-[12.5px] text-muted-foreground">{title}</h2>
      <div className="grid grid-cols-[repeat(auto-fill,minmax(260px,1fr))] gap-3.5">
        {children}
      </div>
    </section>
  );
}

function CatalogCard({
  name,
  supplier,
  endpoint,
  detail,
  onClick,
  disabled = false,
}: {
  name: string;
  supplier: Supplier;
  endpoint: string;
  detail?: string;
  onClick: () => void;
  disabled?: boolean;
}) {
  const { settings, bootstrap } = useHost();
  return (
    <button
      type="button"
      className="cc-panel flex min-h-24 items-center gap-3 p-4 text-left disabled:opacity-45"
      onClick={onClick}
      disabled={disabled}
    >
      <ServiceIcon
        name={name}
        color={brandColor(
          supplierBrand(supplier),
          settings,
          bootstrap.appearance === "dark",
        )}
        size={30}
      />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[13px] font-semibold">{name}</span>
        <span
          className="mt-1 block truncate text-[11px] text-muted-foreground"
          title={endpoint}
        >
          {endpoint}
        </span>
        {detail && (
          <span className="mt-1 block truncate text-[10.5px] text-muted-foreground">
            {detail}
          </span>
        )}
      </span>
    </button>
  );
}

function APIKeyDialog({
  supplierID,
  catalog,
  onOpenChange,
  onSaved,
}: {
  supplierID: Supplier | "custom";
  catalog: ProviderCatalog;
  onOpenChange: (open: boolean) => void;
  onSaved: (catalog: ProviderCatalog) => void;
}) {
  const { api } = useHost();
  const t = useTranslation();
  const initial = catalog.suppliers.find((item) => item.id === supplierID);
  const [supplier, setSupplier] = useState<Supplier | "custom">(supplierID);
  const [name, setName] = useState(
    initial?.name ?? t("Custom provider", "自定义供应商"),
  );
  const [endpoint, setEndpoint] = useState(initial?.endpoint ?? "");
  const [key, setKey] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const supplierOptions = [
    ...catalog.suppliers
      .filter((item) => item.id !== "custom")
      .map((item) => ({
        value: item.id as Supplier | "custom",
        label: item.name,
      })),
    { value: "custom" as const, label: t("Custom", "自定义") },
  ];

  const save = async () => {
    if (pending) return;
    setPending(true);
    setError(null);
    try {
      await api.authorizationsSaveAPIKey({ supplier, name, endpoint, key });
      setKey("");
      try {
        onSaved(await api.providersCatalog(catalog.application));
      } catch {
        setError(
          t(
            "The API Key was saved, but the catalog couldn’t be refreshed. Reopen the catalog to see it.",
            "API Key 已保存，但目录刷新失败。重新打开目录即可查看。",
          ),
        );
      }
    } catch (reason) {
      setError(
        errorMessage(reason) ||
          t(
            "API key wasn't saved. Check the name, API URL, and key.",
            "API Key 未保存，请检查名称、API 地址和 Key。",
          ),
      );
    } finally {
      setPending(false);
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!pending) onOpenChange(open);
      }}
    >
      <DialogContent className="sm:max-w-[480px]" showCloseButton={!pending}>
        <DialogHeader>
          <DialogTitle>{t("Add API Key", "添加 API Key")}</DialogTitle>
          <DialogDescription>
            {t(
              "Keys are stored in private files on this Mac and used only when you apply an application profile.",
              "Key 保存在本机私有文件中，应用供应商配置时才会使用。",
            )}
          </DialogDescription>
        </DialogHeader>
        <form
          className="contents"
          onSubmit={(event) => {
            event.preventDefault();
            void save();
          }}
        >
          <fieldset disabled={pending} className="contents">
            <FormField id="key-supplier" label={t("Provider", "供应商")}>
              <SelectField
                value={supplier}
                options={supplierOptions}
                onChange={(value) => {
                  setSupplier(value);
                  const choice = catalog.suppliers.find(
                    (item) => item.id === value,
                  );
                  setName(choice?.name ?? t("Custom provider", "自定义供应商"));
                  setEndpoint(choice?.endpoint ?? "");
                }}
                ariaLabel={t("Provider", "供应商")}
              />
            </FormField>
            <FormField id="key-name" label={t("Name", "名称")}>
              <Input
                id="key-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
                autoComplete="off"
              />
            </FormField>
            <FormField id="key-endpoint" label={t("API endpoint", "API 地址")}>
              <Input
                id="key-endpoint"
                value={endpoint}
                onChange={(event) => setEndpoint(event.target.value)}
                autoComplete="off"
                spellCheck={false}
              />
            </FormField>
            {catalog.suppliers.find((item) => item.id === supplier)
              ?.website && (
              <Button
                type="button"
                variant="link"
                className="justify-start px-0"
                onClick={() =>
                  void api
                    .platformOpenExternal(
                      catalog.suppliers.find((item) => item.id === supplier)!
                        .website,
                    )
                    .catch((reason: unknown) => setError(errorMessage(reason)))
                }
              >
                {t("Get an API Key", "获取 API Key")}
              </Button>
            )}
            <FormField id="api-key" label="API Key">
              <Input
                id="api-key"
                type="password"
                value={key}
                onChange={(event) => setKey(event.target.value)}
                autoComplete="new-password"
              />
            </FormField>
            {error && (
              <p
                className="text-[11.5px] text-red-600 dark:text-red-400"
                role="alert"
              >
                {error}
              </p>
            )}
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => onOpenChange(false)}
                disabled={pending}
              >
                {t("Cancel", "取消")}
              </Button>
              <PendingButton
                type="submit"
                pending={pending}
                disabled={!name.trim() || !endpoint.trim() || !key.trim()}
              >
                {t("Save", "保存")}
              </PendingButton>
            </DialogFooter>
          </fieldset>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function ProviderDialog({
  authorization,
  application,
  supportedAPIs,
  onOpenChange,
  onAdded,
}: {
  authorization: APIKeyChoice;
  application: ApplicationID;
  supportedAPIs: ProviderProtocol[];
  onOpenChange: (open: boolean) => void;
  onAdded: (detail: ApplicationDetail) => void;
}) {
  const { api } = useHost();
  const t = useTranslation();
  const [name, setName] = useState(authorization.name);
  const [endpoint, setEndpoint] = useState(authorization.endpoint);
  const [model, setModel] = useState("");
  const [contextWindow, setContextWindow] = useState("128000");
  const [protocol, setProtocol] = useState<ProviderProtocol>(
    supportedAPIs.includes("chatCompletions")
      ? "chatCompletions"
      : (supportedAPIs[0] ?? "responses"),
  );
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const add = async () => {
    if (pending) return;
    setPending(true);
    setError(null);
    try {
      const input: AddProviderInput = {
        application,
        authorizationID: authorization.id,
        supplier: authorization.supplier,
        name,
        endpoint,
        model,
        protocol,
        contextWindow: Number(contextWindow),
      };
      onAdded(await api.providersAdd(input));
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setPending(false);
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!pending) onOpenChange(open);
      }}
    >
      <DialogContent className="sm:max-w-[480px]" showCloseButton={!pending}>
        <DialogHeader>
          <DialogTitle>{t("Add provider", "添加供应商")}</DialogTitle>
          <DialogDescription>
            {t(
              "Adds this provider to CCBar. The application's current configuration is unchanged.",
              "添加到 CCBar 的应用列表，原应用当前配置保持不变。",
            )}
          </DialogDescription>
        </DialogHeader>
        <form
          className="contents"
          onSubmit={(event) => {
            event.preventDefault();
            void add();
          }}
        >
          <fieldset disabled={pending} className="contents">
            <FormField id="provider-name" label={t("Name", "名称")}>
              <Input
                id="provider-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
              />
            </FormField>
            <FormField
              id="provider-endpoint"
              label={t("API endpoint", "API 地址")}
            >
              <Input
                id="provider-endpoint"
                value={endpoint}
                onChange={(event) => setEndpoint(event.target.value)}
                spellCheck={false}
              />
            </FormField>
            <FormField
              id="provider-protocol"
              label={t("API protocol", "API 协议")}
            >
              <SelectField
                value={protocol}
                options={supportedAPIs.map((item) => ({
                  value: item,
                  label: protocolName(item),
                }))}
                onChange={setProtocol}
                ariaLabel={t("API protocol", "API 协议")}
              />
            </FormField>
            <FormField id="provider-model" label={t("Model ID", "模型名称")}>
              <Input
                id="provider-model"
                value={model}
                onChange={(event) => setModel(event.target.value)}
                spellCheck={false}
              />
            </FormField>
            <FormField
              id="provider-context"
              label={t("Context window", "上下文长度")}
            >
              <Input
                id="provider-context"
                inputMode="numeric"
                className="cc-number"
                value={contextWindow}
                onChange={(event) =>
                  setContextWindow(event.target.value.replace(/\D/g, ""))
                }
              />
            </FormField>
            {error && (
              <p
                className="text-[11.5px] text-red-600 dark:text-red-400"
                role="alert"
              >
                {error}
              </p>
            )}
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => onOpenChange(false)}
                disabled={pending}
              >
                {t("Cancel", "取消")}
              </Button>
              <PendingButton
                type="submit"
                pending={pending}
                disabled={
                  !name.trim() ||
                  !endpoint.trim() ||
                  !model.trim() ||
                  Number(contextWindow) <= 0
                }
              >
                {t("Add", "添加")}
              </PendingButton>
            </DialogFooter>
          </fieldset>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function protocolName(value: ProviderProtocol) {
  return {
    responses: "OpenAI Responses",
    chatCompletions: "OpenAI Chat Completions",
    anthropic: "Anthropic Messages",
    gemini: "Google Gemini",
  }[value];
}
