import type { QuotaAccount } from "@ccbar/host-api/window";
import colors from "tailwindcss/colors";
import { cn } from "@/lib/utils";

// Keep the native CodexAccount.planName mapping: service plan_type is a wire
// value, while account.plan is already a display name and must not be remapped.
const codexPlanNames: Record<string, string> = {
  free: "Free",
  go: "Go",
  plus: "Plus",
  pro: "Pro",
  prolite: "Pro",
  promax: "Pro",
  team: "Business",
  self_serve_business_usage_based: "Business",
  self_serve_business_prolite: "Business",
  business: "Enterprise",
  enterprise: "Enterprise",
  hc: "Enterprise",
  ent26: "Enterprise",
  enterprise_cbp_usage_based: "Enterprise",
  enterprise_cbp_automation: "Enterprise",
  edu: "Edu",
  education: "Edu",
  edu_plus: "Edu",
  edu_pro: "Edu",
  sci: "Academic",
  sci_plus: "Academic",
};

export function quotaAccountPlan(account: QuotaAccount): string | null {
  // Successful quota responses are newer than imported/local credential claims.
  const reported = account.snapshot?.planType?.trim();
  if (reported) {
    const key = reported.toLowerCase();
    return account.service === "codex" && Object.hasOwn(codexPlanNames, key)
      ? codexPlanNames[key]!
      : reported;
  }
  return account.plan?.trim() || null;
}

function normalizedPlan(plan: string) {
  return plan
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[_-]+/g, " ")
    .replace(/[()]/g, " ")
    .replace(/^(?:(?:openai|chatgpt|claude)\s+)+/, "")
    .replace(/\s+/g, " ")
    .trim();
}

function isPersonalPro(plan: string) {
  // An anchored match accepts Pro 5x / Pro x20, but never Business Pro or
  // self_serve_business_prolite. Those server values map to Business above.
  return /^pro(?:\s*(?:lite|max|(?:\d+(?:\.\d+)?\s*[x×]|[x×]\s*\d+(?:\.\d+)?)))?$/.test(
    normalizedPlan(plan),
  );
}

export function quotaSupportsKind(
  account: QuotaAccount,
  kind: "fiveHour" | "weekly",
) {
  const plan = quotaAccountPlan(account);
  if (
    kind === "fiveHour" &&
    account.service === "codex" &&
    plan !== null &&
    isPersonalPro(plan)
  )
    return false;
  // A successful snapshot is authoritative about the available windows.
  // Before one exists, let the analytics query establish whether 5H is present.
  return (
    kind !== "fiveHour" ||
    account.snapshot === null ||
    account.snapshot.limits.some((limit) => limit.kind === "fiveHour")
  );
}

// Alternate outwards from blue / sky within Tailwind's red-to-rose palette.
const accountColorFamilies = [
  colors.blue,
  colors.sky,
  colors.indigo,
  colors.cyan,
  colors.violet,
  colors.teal,
  colors.purple,
  colors.emerald,
  colors.fuchsia,
  colors.green,
  colors.pink,
  colors.lime,
  colors.rose,
  colors.yellow,
  colors.amber,
  colors.orange,
  colors.red,
];
const accountColorShades = [500, 400, 300, 200, 100, 50] as const;

/** Build from the full account list before filtering, so selection keeps colors. */
export function quotaAccountColors(
  accounts: readonly Pick<QuotaAccount, "id">[],
): Map<string, string> {
  const result = new Map<string, string>();
  for (const { id } of accounts) {
    if (result.has(id)) continue;
    const index = result.size;
    const family = accountColorFamilies[index % accountColorFamilies.length]!;
    // Exhaust each shade before descending; the lightest shade is the floor.
    const shade =
      accountColorShades[
        Math.min(
          Math.floor(index / accountColorFamilies.length),
          accountColorShades.length - 1,
        )
      ]!;
    result.set(id, family[shade]);
  }
  return result;
}

/** Only remove exact plan fields, preserving the host's identity/region text. */
export function quotaAccountSubtitle(account: QuotaAccount): string {
  const plans = [
    quotaAccountPlan(account),
    account.plan,
    account.snapshot?.planType,
  ]
    .filter((value): value is string => Boolean(value?.trim()))
    .map((value) => value.trim().toLocaleLowerCase());
  return account.subtitle
    .split(" · ")
    .filter((part) => !plans.includes(part.trim().toLocaleLowerCase()))
    .join(" · ");
}

export function QuotaPlanBadge({ account }: { account: QuotaAccount }) {
  const plan = quotaAccountPlan(account);
  if (!plan) return null;
  const normalized = normalizedPlan(plan);
  const tier = /^free\b/.test(normalized)
    ? "free"
    : /^(team|business|enterprise|edu|academic)\b/.test(normalized)
      ? "organization"
      : isPersonalPro(plan) || /^max(?:\b|\d)/.test(normalized)
        ? "high"
        : /^(plus|go|standard|paid|starter|basic|premium)\b/.test(normalized)
          ? "paid"
          : "unknown";
  return (
    <span
      data-plan-tier={tier}
      className={cn(
        "inline-flex h-5 shrink-0 items-center rounded border px-1.5 text-[11px] leading-none",
        tier === "free" && "border-border text-muted-foreground",
        tier === "paid" &&
          "border-transparent bg-secondary text-secondary-foreground",
        tier === "high" &&
          "border-foreground/40 bg-foreground/[0.04] font-semibold text-foreground",
        tier === "organization" &&
          "border-slate-400 text-slate-700 dark:border-slate-500 dark:text-slate-200",
        tier === "unknown" && "border-border text-muted-foreground",
      )}
    >
      {plan}
    </span>
  );
}
