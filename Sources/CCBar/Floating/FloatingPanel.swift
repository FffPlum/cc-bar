import AppKit

/// 桌面悬浮窗使用的 NSPanel 子类。
/// - 无标题、无边框
/// - 不抢焦点（`.nonactivatingPanel` + `canBecomeKey/Main = false`）
/// - 置顶；在所有 Space 与全屏应用上可见
/// - 可拖动（`isMovableByWindowBackground`）
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        worksWhenModal = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
