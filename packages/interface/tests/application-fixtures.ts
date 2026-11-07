import type {
  ApplicationInstallation,
  ApplicationInventory,
  ApplicationSummary,
  ManagedApplication,
} from "@ccbar/host-api/window";

export const configuredCodex: ApplicationSummary = {
  id: "codex",
  name: "Codex",
  detected: true,
  addedToSidebar: false,
  usageService: "codex",
  usageVisible: false,
  supportsProviderConfiguration: true,
  supportedAPIs: ["responses"],
  defaultSupplier: "openai",
  icon: { brand: "codex", kind: "fallback", dataURI: null, fillsTile: false, lightHex: "#000000", darkHex: "#FFFFFF" },
};

export function installation(patch: Partial<ApplicationInstallation> = {}): ApplicationInstallation {
  return {
    id: "codex-npm",
    path: "/fixture/bin/codex",
    resolvedPath: "/fixture/npm/codex/bin/codex.js",
    version: "1.0.0",
    source: "npm",
    sourceLabel: "npm",
    active: true,
    versionCheck: { status: "unchecked", latestVersion: null, checkedAt: null, error: null },
    canUpgrade: true,
    canUninstall: true,
    unavailableReason: null,
    ...patch,
  };
}

export function managedApplication(patch: Partial<ManagedApplication> = {}): ManagedApplication {
  return {
    id: "codex",
    name: "Codex CLI",
    kind: "cli",
    configurationApplication: "codex",
    website: "https://example.invalid/codex",
    icon: configuredCodex.icon,
    installed: true,
    configurationFound: true,
    installations: [installation()],
    canInstall: true,
    installUnavailableReason: null,
    ...patch,
  };
}

export function applicationInventory(applications: ManagedApplication[], patch: Partial<ApplicationInventory> = {}): ApplicationInventory {
  return { applications, scanning: false, checkingVersions: false, lastScannedAt: "2026-11-06T00:00:00Z", operation: null, error: null, ...patch };
}
