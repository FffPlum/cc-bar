import { describe, expect, it, vi } from "vitest";
import { moveBefore, moveAdjacent } from "@/features/quota/reorder";
import { AuthorizationSession } from "@/features/quota/authorization-session";
import { deferred } from "./fixtures";
describe("quota order", () => {
  it("moves source before the actual drop target and preserves all other IDs", () => {
    expect(moveBefore(["codex", "claude", "kimi"], "kimi", "codex")).toEqual([
      "kimi",
      "codex",
      "claude",
    ]);
  });
  it("supports both keyboard directions and refuses boundary/foreign IDs", () => {
    expect(moveAdjacent(["a", "b", "c"], "b", 1)).toEqual(["a", "c", "b"]);
    expect(moveAdjacent(["a", "b", "c"], "b", -1)).toEqual(["b", "a", "c"]);
    expect(moveAdjacent(["a"], "a", -1)).toBeNull();
    expect(moveBefore(["codex", "kimi"], "imported", "codex")).toBeNull();
  });
});
describe("authorization cancellation", () => {
  it("cancels a start both before and after its delayed response", async () => {
    const delayed = deferred<void>();
    const cancel = vi.fn(async () => {});
    const session = new AuthorizationSession(cancel);
    const starting = session.start(() => delayed.promise);
    const stopping = session.stop();
    expect(cancel).toHaveBeenCalledTimes(1);
    delayed.resolve();
    await Promise.all([starting, stopping]);
    expect(cancel).toHaveBeenCalledTimes(2);
  });
  it("deduplicates dismissal and retries a failed cancel", async () => {
    const cancel = vi
      .fn()
      .mockRejectedValueOnce(new Error("unavailable"))
      .mockResolvedValue(undefined);
    const session = new AuthorizationSession(cancel);
    session.track();
    const first = session.stop();
    expect(session.stop()).toBe(first);
    await expect(first).rejects.toThrow();
    await session.stop();
    expect(cancel).toHaveBeenCalledTimes(2);
  });
  it("does not cancel an authorization after it completed", async () => {
    const cancel = vi.fn(async () => {});
    const session = new AuthorizationSession(cancel);
    await session.start(async () => {});
    session.complete();
    await session.stop();
    expect(cancel).not.toHaveBeenCalled();
  });
});

it("supports dropping after the last item and reorders only a detected service group", async () => {
  const { moveAfter, replaceGroup } = await import("@/features/quota/reorder");
  expect(moveAfter(["a", "b", "c"], "a", "c")).toEqual(["b", "c", "a"]);
  expect(replaceGroup(["codex", "claude", "kimi"], ["kimi", "codex"])).toEqual([
    "kimi",
    "claude",
    "codex",
  ]);
});
