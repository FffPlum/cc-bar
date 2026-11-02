import { useCallback, useEffect, useRef, useState } from "react";
import type {
  CodexImportPreview,
  DeepSeekAuthorizationInput,
  KimiAuthorizationInput,
  QuotaAccount,
  QuotaAccountsResult,
  QuotaResetCreditsResult,
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
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { FormField } from "@/components/form-field";
import { SelectField } from "@/components/select-field";
import { PendingButton } from "@/components/pending-button";
import { PrivacyText } from "@/components/workspace";
import { useHost, errorMessage } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { AuthorizationSession } from "@/features/quota/authorization-session";
import { formatDate } from "@/lib/display";

export function CodexImportDialog({
  onClose,
  onImported,
  privacyMode,
}: {
  onClose: () => void;
  onImported: (result: QuotaAccountsResult) => void;
  privacyMode: boolean;
}) {
  const { api } = useHost();
  const t = useTranslation();
  const [payload, setPayload] = useState("");
  const [preview, setPreview] = useState<CodexImportPreview | null>(null);
  const [visible, setVisible] = useState(true);
  const [pending, setPending] = useState<"preview" | "save" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const runPreview = async () => {
    if (pending || !payload.trim()) return;
    setPending("preview");
    setError(null);
    try {
      setPreview(await api.codexPreview(payload));
    } catch (reason) {
      setPreview(null);
      setError(errorMessage(reason));
    } finally {
      setPending(null);
    }
  };
  const save = async () => {
    if (pending || !preview) return;
    setPending("save");
    setError(null);
    try {
      const result = await api.codexImport({
        payload,
        visibleInPopover: visible,
      });
      if (result.error || result.failed > 0) {
        setError(
          result.error ??
            t(
              "Some accounts weren’t imported. Review the payload and try again.",
              "部分账号未能导入，请检查凭据后重试。",
            ),
        );
        return;
      }
      setPayload("");
      setPreview(null);
      onImported(await api.quotaAccounts());
      onClose();
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setPending(null);
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
    >
      <DialogContent
        className="sm:max-w-[520px]"
        showCloseButton={pending === null}
      >
        <DialogHeader>
          <DialogTitle>{t("Add Codex Account", "添加 Codex 账号")}</DialogTitle>
          <DialogDescription>
            {t(
              "Supports one auth.json, a JSON account array, or a personal access token. Your Codex CLI sign-in is not changed.",
              "支持单个 auth.json、多账号 JSON 数组或 Personal access token，不会切换 Codex CLI 登录。",
            )}
          </DialogDescription>
        </DialogHeader>
        <FormField
          id="codex-payload"
          label={t("Paste auth.json content", "粘贴 auth.json 内容")}
        >
          <Textarea
            id="codex-payload"
            value={payload}
            onChange={(event) => {
              setPayload(event.target.value);
              setPreview(null);
              setError(null);
            }}
            className="h-28 resize-none font-mono text-[11px]"
            disabled={pending !== null}
            data-private={privacyMode || undefined}
            autoComplete="off"
            spellCheck={false}
          />
        </FormField>
        {!preview && (
          <Button
            variant="outline"
            onClick={() => void runPreview()}
            disabled={!payload.trim() || pending !== null}
            aria-busy={pending === "preview"}
          >
            {pending === "preview"
              ? t("Reading…", "正在识别…")
              : t("Preview", "预览")}
          </Button>
        )}
        {preview?.kind === "personalAccessToken" && (
          <div className="rounded-lg bg-green-500/[0.07] p-3">
            <p className="font-medium">Personal access token</p>
            <p className="mt-1 text-[11px] text-muted-foreground">
              {t(
                "Identity is verified online on save.",
                "身份将在保存时联网验证。",
              )}
            </p>
          </div>
        )}
        {preview && preview.accounts.length > 0 && (
          <div className="max-h-40 space-y-2 overflow-auto rounded-lg bg-green-500/[0.07] p-3">
            {preview.accounts.map((account) => (
              <div
                key={account.id}
                className="flex items-center gap-2 text-[11.5px]"
              >
                <span className="font-medium">
                  {privacyMode ? <PrivacyText /> : account.email}
                </span>
                {account.plan && (
                  <Badge variant="secondary">{account.plan}</Badge>
                )}
                <span className="flex-1" />
                {privacyMode ? (
                  <PrivacyText />
                ) : (
                  <span className="max-w-40 truncate font-mono text-[10px] text-muted-foreground">
                    {account.chatgptAccountID}
                  </span>
                )}
              </div>
            ))}
          </div>
        )}
        {preview && (
          <label className="flex items-center justify-between text-[12.5px]">
            <span>{t("Show in popover", "在弹出面板中显示")}</span>
            <Switch
              disabled={pending !== null}
              checked={visible}
              onCheckedChange={setVisible}
            />
          </label>
        )}
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
            variant="outline"
            onClick={onClose}
            disabled={pending !== null}
          >
            {t("Cancel", "取消")}
          </Button>
          <PendingButton
            pending={pending === "save"}
            disabled={!preview || pending !== null}
            onClick={() => void save()}
          >
            {preview && preview.accounts.length > 1
              ? t("Import All", "全部导入")
              : t("Save", "保存")}
          </PendingButton>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function DeviceAuthorizationDialog({
  kind,
  account,
  state,
  onClose,
  onChanged,
}: {
  kind: "kimi" | "deepSeek";
  account: QuotaAccount | null;
  state: QuotaAccountsResult["kimiAuthorization"];
  onClose: () => void;
  onChanged: (result: QuotaAccountsResult) => void;
}) {
  const { api } = useHost();
  const t = useTranslation();
  const [region, setRegion] = useState<"china" | "global">(
    account?.region ?? "china",
  );
  const [name, setName] = useState(account?.name ?? "DeepSeek");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [closing, setClosing] = useState(false);
  const [started, setStarted] = useState(false);
  const [done, setDone] = useState(false);
  const mounted = useRef(true);
  const session = useRef<AuthorizationSession | null>(null);
  if (!session.current)
    session.current = new AuthorizationSession(() =>
      kind === "kimi"
        ? api.kimiCancelAuthorization()
        : api.deepSeekCancelAuthorization(),
    );
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      void session.current?.stop().catch(() => undefined);
    };
  }, []);
  useEffect(() => {
    if (state.inProgress) session.current?.track();
  }, [state.inProgress]);
  useEffect(() => {
    if (
      started &&
      !pending &&
      !state.inProgress &&
      !state.error &&
      !error &&
      !closing
    ) {
      session.current?.complete();
      setDone(true);
      if (kind === "deepSeek") onClose();
    }
  }, [
    started,
    pending,
    state.inProgress,
    state.error,
    error,
    closing,
    kind,
    onClose,
  ]);
  const busy = pending || state.inProgress || closing;
  const start = async () => {
    if (busy || (kind === "deepSeek" && !name.trim())) return;
    setPending(true);
    setError(null);
    setDone(false);
    try {
      await session.current!.start(async () => {
        if (kind === "kimi") {
          const input: KimiAuthorizationInput = {
            region,
            ...(account ? { replacingAccountID: account.id } : {}),
          };
          await api.kimiStartAuthorization(input);
        } else {
          const input: DeepSeekAuthorizationInput = {
            name: name.trim(),
            ...(account ? { accountID: account.id } : {}),
          };
          await api.deepSeekStartAuthorization(input);
        }
      });
      if (!mounted.current) return;
      onChanged(await api.quotaAccounts());
      setStarted(true);
    } catch (reason) {
      if (mounted.current) setError(errorMessage(reason));
    } finally {
      if (mounted.current) setPending(false);
    }
  };
  const cancel = async () => {
    if (closing) return;
    setClosing(true);
    setError(null);
    try {
      await session.current!.stop();
      if (mounted.current) onClose();
    } catch (reason) {
      if (mounted.current) {
        setError(errorMessage(reason));
        setClosing(false);
      }
    }
  };
  const rename = async () => {
    if (!account || !name.trim()) return;
    setPending(true);
    try {
      onChanged(await api.deepSeekRename(account.id, name.trim()));
      onClose();
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
        if (!open) void cancel();
      }}
    >
      <DialogContent className="sm:max-w-[460px]" showCloseButton={!closing}>
        <DialogHeader>
          <DialogTitle>
            {kind === "kimi"
              ? t("Sign in to Kimi Code", "登录 Kimi Code")
              : account
                ? t("Edit DeepSeek account", "编辑 DeepSeek 账号")
                : t("Add DeepSeek account", "添加 DeepSeek 账号")}
          </DialogTitle>
          <DialogDescription>
            {kind === "kimi"
              ? t(
                  "CCBar opens the official Kimi authorization page in your browser. Your CLI sign-in is not changed.",
                  "CCBar 会在浏览器中打开 Kimi 官方授权页，不会更改 CLI 登录。",
                )
              : t(
                  "Continue in your browser to authorize your DeepSeek account. Credentials are saved in a private file on this Mac.",
                  "在系统浏览器中完成 DeepSeek 账号授权，凭据保存在本机私有文件中。",
                )}
          </DialogDescription>
        </DialogHeader>
        {kind === "kimi" ? (
          <FormField id="kimi-region" label={t("Region", "地区")}>
            <SelectField
              value={region}
              options={[
                { value: "china", label: t("China edition", "国内版") },
                { value: "global", label: t("Global edition", "海外版") },
              ]}
              onChange={setRegion}
              ariaLabel={t("Region", "地区")}
              disabled={busy || account !== null}
            />
          </FormField>
        ) : (
          <FormField id="deepseek-name" label={t("Account name", "账号名称")}>
            <Input
              id="deepseek-name"
              value={name}
              onChange={(event) => setName(event.target.value)}
              disabled={busy}
            />
          </FormField>
        )}
        {done && (
          <p role="status">{t("Signed in successfully.", "登录成功。")}</p>
        )}
        {busy && (
          <p className="text-[11.5px] text-muted-foreground" role="status">
            {state.awaitingBrowser
              ? t(
                  "Complete authorization in your browser. Sign-in continues automatically.",
                  "请在浏览器中完成授权，登录会自动继续。",
                )
              : t("Requesting official authorization…", "正在申请官方授权…")}
          </p>
        )}
        {(error || state.error) && (
          <p
            className="text-[11.5px] text-red-600 dark:text-red-400"
            role="alert"
          >
            {error ?? state.error}
          </p>
        )}
        <DialogFooter>
          <Button
            disabled={closing}
            variant="outline"
            onClick={() => void cancel()}
          >
            {done
              ? t("Done", "完成")
              : busy
                ? t("Cancel authorization", "取消授权")
                : t("Cancel", "取消")}
          </Button>
          {kind === "deepSeek" && account && (
            <PendingButton
              disabled={busy}
              pending={pending}
              onClick={() => void rename()}
              variant="outline"
            >
              {t("Save name", "保存名称")}
            </PendingButton>
          )}
          <PendingButton
            pending={pending}
            disabled={done || busy || (kind === "deepSeek" && !name.trim())}
            onClick={() => void start()}
          >
            {state.error
              ? t("Try again", "重试")
              : kind === "kimi"
                ? t("Start official sign-in", "开始官方登录")
                : t("Authorize in browser", "在浏览器中授权")}
          </PendingButton>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function ResetCreditsDialog({
  account,
  onClose,
}: {
  account: QuotaAccount;
  onClose: () => void;
}) {
  const { api, bootstrap } = useHost();
  const t = useTranslation();
  const [result, setResult] = useState<QuotaResetCreditsResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const generation = useRef(0);
  const load = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true);
    try {
      const value = await api.quotaResetCredits(account.id);
      if (generation.current === current) {
        setResult(value);
        setError(null);
      }
    } catch (reason) {
      if (generation.current === current) setError(errorMessage(reason));
    } finally {
      if (generation.current === current) setLoading(false);
    }
  }, [api, account.id]);
  useEffect(() => {
    void load();
    return () => {
      generation.current += 1;
    };
  }, [load]);
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="sm:max-w-[480px]">
        <DialogHeader>
          <DialogTitle>{t("Reset Credits", "额度重置次数")}</DialogTitle>
          <DialogDescription>{account.name}</DialogDescription>
        </DialogHeader>
        {loading && (
          <p className="text-muted-foreground">{t("Loading…", "加载中…")}</p>
        )}
        {error && (
          <p className="text-red-600" role="alert">
            {error}
          </p>
        )}
        {result && (
          <>
            <p className="text-[12px] text-muted-foreground">
              {t(
                `${result.availableCount} available`,
                `可用 ${result.availableCount} 次`,
              )}
            </p>
            <div className="max-h-72 space-y-2 overflow-auto">
              {result.credits.map((credit) => (
                <div key={credit.id} className="rounded-lg border p-3">
                  <div className="flex items-center gap-2">
                    <span className="font-medium">{credit.title}</span>
                    <Badge variant="secondary">{credit.status}</Badge>
                  </div>
                  <p className="cc-number mt-1 text-[11px] text-muted-foreground">
                    {formatDate(
                      credit.grantedAt,
                      bootstrap.resolvedLanguage,
                      bootstrap.timeZone,
                      true,
                    )}{" "}
                    →{" "}
                    {formatDate(
                      credit.expiresAt,
                      bootstrap.resolvedLanguage,
                      bootstrap.timeZone,
                      true,
                    )}
                  </p>
                </div>
              ))}
            </div>
            {result.error && <p className="text-orange-600">{result.error}</p>}
          </>
        )}
        <DialogFooter>
          {(error || result?.error) && (
            <Button
              variant="outline"
              disabled={loading}
              onClick={() => void load()}
            >
              {t("Retry", "重试")}
            </Button>
          )}
          <Button onClick={onClose}>{t("Done", "完成")}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
