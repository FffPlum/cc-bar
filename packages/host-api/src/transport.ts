export type Domain = "usage" | "quota" | "settings" | "navigation" | "applications" | "authorizations" | "pricing" | "notifications" | "updates" | "appearance";
const domains: readonly Domain[] = ["usage", "quota", "settings", "navigation", "applications", "authorizations", "pricing", "notifications", "updates", "appearance"];
export interface StateChanged {
  version: 1;
  event: "state.changed";
  revision: string;
  domains: Domain[];
}
export interface Request {
  version: 1;
  id: string;
  method: string;
  params: object;
}
export interface Transport {
  send(request: Request): Promise<unknown>;
  subscribe(listener: (event: unknown) => void): () => void;
  dispose(): void;
}
export class HostError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "HostError";
  }
}
const object = (x: unknown): x is Record<string, unknown> =>
  typeof x === "object" && x !== null && !Array.isArray(x);
export function parseResponse(value: unknown, id: string): unknown {
  if (!object(value) || value.version !== 1 || value.id !== id)
    throw new HostError("invalid_response", "Invalid response version or id");
  const result = Object.hasOwn(value, "result"),
    error = Object.hasOwn(value, "error");
  if (result === error)
    throw new HostError(
      "invalid_response",
      "Expected exactly one result or error",
    );
  if (error) {
    if (
      !object(value.error) ||
      typeof value.error.code !== "string" ||
      typeof value.error.message !== "string"
    )
      throw new HostError("invalid_response", "Invalid error");
    throw new HostError(value.error.code, value.error.message);
  }
  if (value.result === undefined)
    throw new HostError("invalid_response", "Missing result");
  return value.result;
}
export function parseEvent(x: unknown): StateChanged | undefined {
  if (
    !object(x) ||
    x.version !== 1 ||
    x.event !== "state.changed" ||
    typeof x.revision !== "string" ||
    !Array.isArray(x.domains) ||
    !x.domains.every((d): d is Domain => typeof d === "string" && domains.includes(d as Domain))
  )
    return undefined;
  return x as unknown as StateChanged;
}
