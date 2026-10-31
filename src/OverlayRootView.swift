import SwiftUI

// MARK: - 悬浮层根视图

/// 一层透明底（不吃触摸）+ 悬浮条 + 可选设定面板。
/// 拖动/点击全部用 SwiftUI 手势，不用 UIKit 手势识别器。
struct OverlayRootView: View {

    @ObservedObject var store: SettingsStore
    @ObservedObject var layout: OverlayLayout
    let provider: MetricsProvider

    @State private var snapshot: MetricsSnapshot = .empty
    @State private var showPanel = false
    /// 拖动过程中的临时位移（未提交到 anchor）
    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    /// 拖动开始那一刻的中心点。贴边召回会让 barCenter 突变，
    /// 位移必须相对**起点**算，不能相对当前值，否则手指一按条子就飞。
    @State private var dragOrigin: CGPoint = .zero
    /// 悬浮条的自然尺寸（未缩放），用于回报实际占位
    @State private var naturalSize: CGSize = .zero

    /// 内容比屏幕还宽时的额外收缩系数。
    /// 8 项全开 + 12pt 在小屏（SE / mini）上必然超出，硬塞会被裁掉，
    /// 所以按可用宽度再乘一个系数，而不是让用户手动调 scale。
    @State private var fitScale: CGFloat = 1

    private var manager: FloatingWindowManager { .shared }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)

                if store.isVisible && layout.barCenter != .zero {
                    bar
                        .position(
                            x: layout.barCenter.x + dragTranslation.width,
                            y: layout.barCenter.y + dragTranslation.height
                        )
                        // 不能用 .gesture(drag) + .onTapGesture：
                        // .gesture 的优先级高于 onTapGesture，DragGesture 会把点击吞掉，
                        // 表现为"点了没反应，面板打不开"。必须用 simultaneousGesture。
                        .simultaneousGesture(dragGesture)
                        .simultaneousGesture(
                            TapGesture().onEnded { handleTap() }
                        )
                }

                if showPanel {
                    panel(in: geo.size)
                }
            }
            .onAppear {
                provider.onUpdate = { snap in
                    // 这些值一秒变一次，不需要动画，避免整条闪烁
                    snapshot = snap
                }
                manager.relayout()
            }
            .onChange(of: store.anchor) { _ in manager.relayout() }
            .onChange(of: store.edgeAutoHide) { _ in
                if !store.edgeAutoHide { manager.unpeek() }
            }
            .onChange(of: layout.bounds) { _ in
                updateNaturalSize(naturalSize)
            }
            .onChange(of: store.refreshInterval) { _ in
                provider.restartIfNeeded()
            }
            // 外部（主界面按钮）请求打开面板
            .onChange(of: store.panelRequestTick) { _ in
                withAnimation(.easeOut(duration: 0.20)) { showPanel = true }
            }
            .onChange(of: showPanel) { presented in
                manager.setPanelPresented(presented)
            }
            .onChange(of: store.isVisible) { visible in
                manager.syncHitRegion()
                if !visible { showPanel = false }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 悬浮条

    private var bar: some View {
        FloatingBarView(
            metrics: store.visibleMetrics,
            snapshot: snapshot,
            fontSize: store.fontSize,
            useIcon: store.useIcon,
            backgroundOpacity: Double(store.backgroundOpacity)
        )
        .scaleEffect(store.scale * fitScale)
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { updateNaturalSize(g.size) }
                    .onChange(of: g.size) { new in updateNaturalSize(new) }
            }
        )
        .onChange(of: store.scale) { _ in reportBarSize() }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: layout.barCenter)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: store.scale)
    }

    /// 自然尺寸变化（换字号、开关指标、旋转都会变）
    private func updateNaturalSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        naturalSize = size

        // 可用宽度留 10pt 边距；低于 0.42 就说明内容实在太多，宁可超也别缩成看不清
        let avail = manager.currentBounds.width - 10
        if avail > 0, size.width * store.scale > avail {
            fitScale = max(avail / (size.width * store.scale), 0.42)
        } else {
            fitScale = 1
        }
        reportBarSize()
    }

    /// 回报**缩放后**的实际占位 —— 命中区域和贴边判定都要用真实大小，
    /// 用未缩放尺寸会导致点不到右边缘。
    private func reportBarSize() {
        guard naturalSize.width > 0 else { return }
        let s = store.scale * fitScale
        manager.reportBarSize(CGSize(
            width: naturalSize.width * s,
            height: naturalSize.height * s
        ))
    }

    // MARK: 拖动

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard !store.isLocked else { return }

                // 第一帧：若处于贴边隐藏，先召回（接下来整段拖动都是正常位置拖动）
                if !isDragging {
                    isDragging = true
                    manager.setDragging(true)
                    if layout.peekSide != .none {
                        manager.unpeek()
                    }
                    // 召回之后再取起点，这样起点就是召回后的真实位置
                    dragOrigin = layout.barCenter
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false
                manager.setDragging(false)

                // 把「当前显示位置 + 位移」换算成新的中心点，交给 manager 归一化
                let target = CGPoint(
                    x: dragOrigin.x + value.translation.width,
                    y: dragOrigin.y + value.translation.height
                )
                let b = manager.currentBounds
                // 关键顺序：先把"临时位移归零 + 锚点改成新位置"放进**无动画**事务里一起提交，
                // 这两步互相抵消，视觉上条子不会跳；然后再单独给吸附加动画。
                var tx = Transaction()
                tx.animation = nil
                withTransaction(tx) {
                    dragTranslation = .zero
                    if b.width > 0 { manager.setAnchor(center: target, in: b) }
                }
                if b.width > 0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        manager.snap(in: b)
                    }
                }
            }
    }

    // MARK: 点击

    private func handleTap() {
        // 贴边隐藏状态下，点一下就是把条召回，不弹面板
        if layout.peekSide != .none {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                manager.unpeek()
            }
            return
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            showPanel = true
        }
    }

    // MARK: 面板

    @ViewBuilder
    private func panel(in bounds: CGSize) -> some View {
        Color.black.opacity(0.42)
            .ignoresSafeArea()
            .onTapGesture { closePanel() }

        VStack {
            Spacer(minLength: 44)
            SettingsPanelView(
                store: store,
                bounds: bounds,
                onClose: { closePanel() }
            )
            .frame(maxWidth: min(bounds.width - 24, 400))
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func closePanel() {
        withAnimation(.easeOut(duration: 0.22)) { showPanel = false }
    }
}
