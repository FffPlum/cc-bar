import { HostError, type Request, type Transport } from "./transport.js";
type BridgeWindow = Window & {
  webkit?: {
    messageHandlers?: {
      ccbarHost?: { postMessage(message: Request): Promise<unknown> };
    };
  };
  __ccbarHostReceiveEvent?: (event: unknown) => void;
};
/** One adapter owns the event callback at a time. Dispose it before creating another. */
export function createMacOSTransport(): Transport {
  if (typeof window === "undefined")
    throw new HostError("unavailable", "macOS host is unavailable");
  const target = window as BridgeWindow;
  if (target.__ccbarHostReceiveEvent)
    throw new HostError(
      "unavailable",
      "Host event receiver is already installed",
    );
  const listeners = new Set<(event: unknown) => void>();
  let disposed = false;
  const receive = (event: unknown) => {
    for (const listener of [...listeners]) listener(event);
  };
  target.__ccbarHostReceiveEvent = receive;
  return {
    async send(request) {
      if (disposed) throw new HostError("disposed", "Transport is disposed");
      const handler = target.webkit?.messageHandlers?.ccbarHost;
      if (!handler)
        throw new HostError("unavailable", "macOS host is unavailable");
      return handler.postMessage(request);
    },
    subscribe(listener) {
      if (disposed) throw new HostError("disposed", "Transport is disposed");
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      listeners.clear();
      if (target.__ccbarHostReceiveEvent === receive)
        delete target.__ccbarHostReceiveEvent;
    },
  };
}
