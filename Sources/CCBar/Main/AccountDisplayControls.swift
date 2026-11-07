import SwiftUI
import AppKit

/// 服务行的缩进与右侧固定列宽。`ImportedCodexAccountsView` 的子行按同一套列对齐。
enum ServiceRowMetrics {
    static let leadingPadding: CGFloat = 16
    static let trailingPadding: CGFloat = 14
    /// 左侧重排抓手列。
    static let handleWidth: CGFloat = 16
    /// 手柄与服务 tile 的间距。列宽加宽后把间距从 10 收到 6，名称起点仍是 78pt。
    static let handleGap: CGFloat = 6
    static let tileSize: CGFloat = 28
    static let tileGap: CGFloat = 12
    /// 名称文字起点：内边距 + 手柄列 + 手柄间距 + tile + tile 间距。分隔线从这里开始。
    static let textLeading: CGFloat = leadingPadding + handleWidth + handleGap + tileSize + tileGap
    /// 英文列头 Floating HUD 约 70pt，按自然宽度居中会略越出 64pt 列宽，但不会压到相邻列头。
    static let destination: CGFloat = 64
    static let info: CGFloat = 28
    static let toggle: CGFloat = 44
}

// MARK: - DisplayDestinationCheckbox

/// 矩阵单元格里的 13pt 复选框，没有文字标签（列头说明含义），`title` 只作无障碍标签。
/// 整个单元格可点，不只是 13pt 的框。
struct DisplayDestinationCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    var disabledHelp: String? = nil

    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        let button = Button {
            if disabled {
                if disabledHelp != nil {
                    showTooltip = true
                }
            } else {
                isOn.toggle()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(isOn ? Color.primary.opacity(disabled ? 0.04 : 0.08) : Color.clear)

                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.8)

                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.secondary)
                }
            }
            .frame(width: 13, height: 13)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? tr("On", "已开启") : tr("Off", "已关闭"))
        .onHover { hovering in
            guard disabled, let disabledHelp, !disabledHelp.isEmpty else { return }
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    showTooltip = true
                }
            } else {
                showTooltip = false
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            hoverTask = nil
        }
        .popover(isPresented: $showTooltip, arrowEdge: .top) {
            if let disabledHelp, !disabledHelp.isEmpty {
                Text(disabledHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .fixedSize()
            }
        }
        .help(disabled ? (disabledHelp ?? "") : "")

        if disabled {
            button
        } else {
            button.pointingHandCursor()
        }
    }

    private var borderColor: Color {
        if disabled { return Color.primary.opacity(isOn ? 0.12 : 0.06) }
        return Color.primary.opacity(isOn ? 0.28 : 0.12)
    }
}

// MARK: - Reorder chrome
//
// 列表内拖动重排（Safari 标签页、控制中心那种）：整行起拖，抬起的就是这一行本身，
// 从原位置 1:1 跟手上下移动，越过相邻行中线时相邻行滑开让位，松手后落进空位再写入顺序。
// 拖动中不改布局和数据，只改每行的纵向偏移，位置只按指针算，所以不会闪。

/// 交给行的拖动入口：是否抬起，以及挂在行上的拖动手势（固定行为 nil）。
struct ReorderRowState {
    var isLifted: Bool
    var gesture: AnyGesture<DragGesture.Value>?
}

extension View {
    /// 把行设为拖动起点。行内的按钮、开关、菜单优先响应自己的点击，不触发拖动。
    func reorderDragSource(_ state: ReorderRowState) -> some View {
        contentShape(Rectangle())
            .gesture(
                state.gesture ?? AnyGesture(DragGesture().map { $0 }),
                including: state.gesture == nil ? .subviews : .all
            )
    }
}

private struct ReorderFramesKey: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] = [:]
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// offset 不参与测量；每次起拖均按当前顺序重新累加行高，包括厂商下的账户与添加入口。
enum ReorderLayout {
    static func frames<ID: Hashable>(for order: [ID], measurements: [AnyHashable: CGRect]) -> [ID: CGRect]? {
        var result: [ID: CGRect] = [:]
        var y: CGFloat = 0
        for id in order {
            guard let measured = measurements[AnyHashable(id)], measured.height > 0 else { return nil }
            let rect = CGRect(x: 0, y: y, width: measured.width, height: measured.height)
            result[id] = rect
            y = rect.maxY
        }
        return result
    }
}

/// 可拖动重排的纵向列表。前 `movableCount` 行可拖（需连续排在前面），其后是固定行。
/// 行之间的分隔线由列表画在每行顶部，跟着行一起移动。
struct ReorderableStack<ID: Hashable, Row: View>: View {
    let ids: [ID]
    let movableCount: Int
    var dividerLeading: CGFloat
    /// 第一行顶部也画分隔线（子列表要和上面的主行分开）。
    var dividesFirstRow = false
    /// 松手落位后调用，传入可拖行的新顺序；顺序没变时不调用。
    let onMove: (_ moved: ID, _ newOrder: [ID]) -> Void
    @ViewBuilder let row: (ID, ReorderRowState) -> Row

    private enum Phase { case dragging, settling, cancelling }

    private struct Session {
        var id: ID
        var from: Int
        var order: [ID]
        var frames: [ID: CGRect]
        var phase: Phase
    }

    /// 回到已越过的中线以内 2pt 才换回去，指针停在中线附近不会来回跳。
    private static var hysteresis: CGFloat { 2 }
    /// 松手位置离开列表超过这个距离，视为取消。
    private static var cancelMargin: CGFloat { 40 }

    @State private var space = UUID()
    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var stackSize: CGSize = .zero
    @State private var session: Session?
    @State private var dragOffset: CGFloat = 0
    @State private var target = 0
    @State private var liftedID: ID?
    @State private var ignoresCurrentGesture = false
    @State private var keyMonitor: Any?
    @GestureState private var gestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                let movable = index < movableCount
                row(id, ReorderRowState(
                    isLifted: liftedID == id,
                    gesture: movable ? dragGesture(for: id) : nil
                ))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, dividerLeading)
                        .opacity(showsDivider(id, index: index) ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ReorderFramesKey.self,
                            value: [AnyHashable(id): CGRect(origin: .zero, size: geo.size)]
                        )
                    }
                }
                .background { liftedCard.opacity(liftedID == id ? 1 : 0) }
                .offset(y: offset(for: id, index: index))
                .zIndex(session?.id == id ? 1 : 0)
            }
        }
        .coordinateSpace(name: space)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { stackSize = geo.size }
                    .onChange(of: geo.size) { _, size in stackSize = size }
            }
        }
        .onPreferenceChange(ReorderFramesKey.self) { measured in
            // 只记录尺寸，不记录 offset 后的坐标；落位不改变尺寸时也不会留下旧位置。
            frames = measured
        }
        // 嵌套的子列表把自己的位置留在内部，不往外层列表冒。
        .transformPreference(ReorderFramesKey.self) { $0 = [:] }
        .onChange(of: gestureActive) { _, active in
            guard !active else { return }
            // 手势被系统中途取消时没有 onEnded，下一轮还在拖动就按取消处理。
            DispatchQueue.main.async {
                if session?.phase == .dragging { cancel() }
                ignoresCurrentGesture = false
            }
        }
        .onDisappear {
            removeKeyMonitor()
            if session != nil { ReorderCursor.shared.dragging = false }
        }
    }

    /// 抬起的行：与设置卡片同色的实底、8pt 圆角、很浅的阴影；不缩放、不变色。
    private var liftedCard: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.background)
            .overlay(PanelBackground().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 8, y: 2)
    }

    // MARK: 布局

    private func offset(for id: ID, index: Int) -> CGFloat {
        guard let s = session, index < movableCount, let i = s.order.firstIndex(of: id) else { return 0 }
        if id == s.id { return dragOffset }
        let height = s.frames[s.id]?.height ?? 0
        if s.from < target, i > s.from, i <= target { return -height }
        if s.from > target, i >= target, i < s.from { return height }
        return 0
    }

    /// 分隔线按眼下看到的顺序画：最上面一行不画，抬起的行不画。
    private func showsDivider(_ id: ID, index: Int) -> Bool {
        if liftedID == id { return false }
        if dividesFirstRow { return true }
        guard let s = session, index < movableCount else { return index > 0 }
        var visual = s.order
        visual.remove(at: s.from)
        visual.insert(s.id, at: target)
        return visual.firstIndex(of: id) != 0
    }

    private func clampedOffset(_ raw: CGFloat, _ s: Session) -> CGFloat {
        guard let f = s.frames[s.id],
              let first = s.order.first.flatMap({ s.frames[$0] }),
              let last = s.order.last.flatMap({ s.frames[$0] }) else { return 0 }
        return min(max(raw, first.minY - f.minY), last.maxY - f.maxY)
    }

    /// 被拖行的上沿越过上面某行中线、或下沿越过下面某行中线，就插到那一行的位置。
    private func insertionIndex(for offset: CGFloat, _ s: Session) -> Int {
        guard let f = s.frames[s.id] else { return s.from }
        let top = f.minY + offset
        let bottom = f.maxY + offset
        var result = s.from
        for i in stride(from: s.from - 1, through: 0, by: -1) {
            guard let mid = s.frames[s.order[i]]?.midY else { break }
            let shifted = target <= i
            if top < mid + (shifted ? Self.hysteresis : 0) { result = i } else { break }
        }
        guard result == s.from else { return result }
        for i in (s.from + 1)..<s.order.count {
            guard let mid = s.frames[s.order[i]]?.midY else { break }
            let shifted = target >= i
            if bottom > mid - (shifted ? Self.hysteresis : 0) { result = i } else { break }
        }
        return result
    }

    private func slotOffset(_ s: Session) -> CGFloat {
        guard let f = s.frames[s.id] else { return 0 }
        if target < s.from, let r = s.frames[s.order[target]] { return r.minY - f.minY }
        if target > s.from, let r = s.frames[s.order[target]] { return r.maxY - f.maxY }
        return 0
    }

    // MARK: 手势

    private func dragGesture(for id: ID) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged { value in dragChanged(id, value) }
                .onEnded { value in dragEnded(value) }
        )
    }

    private func dragChanged(_ id: ID, _ value: DragGesture.Value) {
        if ignoresCurrentGesture { return }
        if session == nil, !begin(id) {
            ignoresCurrentGesture = true
            return
        }
        // 上一次还在落位时按下的新拖动，整轮忽略。
        guard let s = session, s.phase == .dragging, s.id == id else {
            ignoresCurrentGesture = true
            return
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { dragOffset = clampedOffset(value.translation.height, s) }
        let next = insertionIndex(for: dragOffset, s)
        if next != target {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { target = next }
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        if ignoresCurrentGesture {
            ignoresCurrentGesture = false
            return
        }
        guard session?.phase == .dragging else { return }
        let bounds = CGRect(origin: .zero, size: stackSize)
            .insetBy(dx: -Self.cancelMargin, dy: -Self.cancelMargin)
        if bounds.contains(value.location) {
            settle()
        } else {
            cancel()
        }
    }

    private func begin(_ id: ID) -> Bool {
        let order = Array(ids.prefix(movableCount))
        guard let from = order.firstIndex(of: id) else { return false }
        guard let snapshot = ReorderLayout.frames(for: order, measurements: frames) else { return false }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            session = Session(id: id, from: from, order: order, frames: snapshot, phase: .dragging)
            target = from
            dragOffset = 0
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { liftedID = id }
        ReorderCursor.shared.dragging = true
        installKeyMonitor()
        return true
    }

    /// 松手：从当前位置落进空位，阴影同时淡出；落定后再写入新顺序。
    private func settle() {
        guard var s = session else { return }
        s.phase = .settling
        session = s
        removeKeyMonitor()
        ReorderCursor.shared.dragging = false
        if reduceMotion {
            commit()
            return
        }
        withAnimation(.smooth(duration: 0.2), completionCriteria: .removed) {
            dragOffset = slotOffset(s)
            liftedID = nil
        } completion: {
            commit()
        }
    }

    /// 取消（Esc、列表外松手、手势被打断）：滑回原位，顺序不变。
    private func cancel() {
        guard var s = session else { return }
        s.phase = .cancelling
        session = s
        removeKeyMonitor()
        ReorderCursor.shared.dragging = false
        if reduceMotion {
            reset()
            return
        }
        withAnimation(.smooth(duration: 0.2), completionCriteria: .removed) {
            dragOffset = 0
            target = s.from
            liftedID = nil
        } completion: {
            if session?.phase == .cancelling { reset() }
        }
    }

    /// 写入顺序和清掉偏移放在同一帧、不加动画：数据重排后的位置正好等于落位的位置，画面不跳。
    private func commit() {
        guard let s = session, s.phase == .settling else { return }
        var order = s.order
        order.remove(at: s.from)
        order.insert(s.id, at: target)
        let moved = target != s.from
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if moved { onMove(s.id, order) }
            clearSession()
        }
    }

    private func reset() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { clearSession() }
    }

    private func clearSession() {
        session = nil
        dragOffset = 0
        target = 0
        liftedID = nil
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 53, session?.phase == .dragging else { return event }
            ignoresCurrentGesture = true
            cancel()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// 重排抓手：拖动的提示，拖动手势挂在整行上。悬停是张开的手，避免被看成可点击按钮。
struct ReorderGrip: View {
    var isLifted: Bool

    @State private var hovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovering || isLifted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                ReorderCursor.shared.hoveringGrip = inside
            }
            .onDisappear {
                if hovering { ReorderCursor.shared.hoveringGrip = false }
            }
            .help(tr("Drag to reorder", "拖动以排序"))
            .accessibilityHidden(true)
    }
}

/// 重排光标：悬停抓手是张开的手，拖动中是抓紧的手。全局只压一层，避免两种手叠在光标栈上。
final class ReorderCursor {
    static let shared = ReorderCursor()

    private enum Kind {
        case open
        case closed
    }

    var hoveringGrip = false {
        didSet { update() }
    }

    var dragging = false {
        didSet {
            // 拖动中收不到抓手的移出事件，松手后先按不在抓手上处理。
            if !dragging { hoveringGrip = false }
            update()
        }
    }

    private var pushed: Kind?

    private func update() {
        let next: Kind? = dragging ? .closed : (hoveringGrip ? .open : nil)
        guard next != pushed else { return }
        if pushed != nil { NSCursor.pop() }
        switch next {
        case .open: NSCursor.openHand.push()
        case .closed: NSCursor.closedHand.push()
        case nil: break
        }
        pushed = next
    }
}
