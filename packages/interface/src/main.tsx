import { Component, StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "@/App";
import { BridgeGate } from "@/host/bridge-gate";
import { TooltipProvider } from "@/components/ui/tooltip";
import "@/index.css";

class WindowBoundary extends Component<
  { children: ReactNode },
  { failed: boolean }
> {
  override state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  override render() {
    if (this.state.failed) {
      const zh = document.documentElement.lang.startsWith("zh");
      return (
        <div className="p-8 text-center" role="alert">
          <p>
            {zh
              ? "窗口暂时无法显示，请重新加载。"
              : "This window couldn’t be displayed. Please reload."}
          </p>
          <button
            className="mt-4 rounded border px-4 py-2"
            onClick={() => window.location.reload()}
          >
            {zh ? "重新加载" : "Reload"}
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <WindowBoundary>
      <TooltipProvider>
        <BridgeGate>
          <App />
        </BridgeGate>
      </TooltipProvider>
    </WindowBoundary>
  </StrictMode>,
);
