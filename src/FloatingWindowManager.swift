import UIKit
import SwiftUI
import Combine

// MARK: - 布局状态

/// 唯一的「悬浮条在哪」真相来源。
/// 之前 manager 和 SwiftUI 各自算一遍坐标，一贴边就打架；现在只在这里算。
final class OverlayLayout: ObservableObject {
    /// 悬浮条中心点（window 坐标）
    @Published var barCenter: CGPoint = .zero
    /// 贴边隐藏时露出的那一侧，用于渲染把手
    @Published var peekSide: PeekSide = .none
    /// 窗口尺寸。currentBounds 是计算属性，SwiftUI 观察不到，
    /// 所以另存一份 @Published 的，供 onChange 使用。
    @Published var bounds: CGSize = .zero

    enum PeekSide { case none, left, right }
}

// MARK: - 穿透式窗口

/// 关键：只有真正画了内容的区域吃触摸，空白区必须放行给底下的宿主 App。
/// 少了这个，一个铺满全屏的 window 会吞掉宿主所有点击 —— 注入类浮窗最常见的翻车点。
///
/// 为什么不用「hit.test 结果是不是 hosting view」来判断：
/// SwiftUI 的 `_UIHostingView` 对命中处理是内部实现，不同系统版本行为不一致，
/// 用它会出现在某些版本上整条悬浮条点不动、或者反过来全屏吞触摸。
/// 所以这里改成**显式的交互区域**：bar 的 frame，或者面板展开时的整屏。
final class PassThroughWindow: UIWindow {

    /// 当前允许吃触摸的区域（window 坐标）
    var interactiveRegions: [CGRect] = []
    /// 面板展开时整屏都可交互（点空白处关闭）
    var fullScreenInteractive: Bool = false

    /// 拖拽中：手指会离开起始矩形，若此时仍按 interactiveRegions 判定，
    /// hitTest 会返回 nil 导致手势中断（表现为"拖一下就断"）。
    /// 拖拽期间临时放行整屏，松手后立即收回。
    var draggingPassthrough: Bool = false

    /// bounds 变化（首次布局 / 旋转 / 分屏）时回调
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if fullScreenInteractive || draggingPassthrough {
            // 拖拽 / 面板展开时，把触摸稳定交给根视图，保证 SwiftUI 手势不被中断：
            // 手指移出浮条矩形后若仍走 super.hitTest，空白区可能返回 nil 使手势掉链子（"拖一下就断"）。
            if let root = self.rootViewController?.view { return root }
            return super.hitTest(point, with: event)
        }
        // 留 6pt 余量，手指按在边缘也能抓住
        let margin: CGFloat = 6
        let inside = interactiveRegions.contains { $0.insetBy(dx: -margin, dy: -margin).contains(point) }
        guard inside else { return nil }
        return super.hitTest(point, with: event)
    }
}

// MARK: - 托管控制器

final class OverlayHostController: UIHostingController<OverlayRootView> {

    convenience init(store: SettingsStore,
                     provider: MetricsProvider,
                     layout: OverlayLayout) {
        self.init(rootView: OverlayRootView(store: store, layout: layout, provider: provider))
        view.backgroundColor = .clear
        view.isOpaque = false
    }
}

// MARK: - Window 管理器

/// 负责 window 的创建 / 显隐 / 定位 / 吸附 / 贴边。
/// **不含手势** —— 拖动和点击都在 SwiftUI 层用 DragGesture / onTapGesture 处理，
/// 避免 UIKit 手势与 SwiftUI hitTest 互相抢事件。
final class FloatingWindowManager {

    static let shared = FloatingWindowManager()

    let layout = OverlayLayout()

    private var window: PassThroughWindow?
    private var host: OverlayHostController?
    private let store = SettingsStore.shared
    private let provider = MetricsProvider()

    /// 悬浮条实际尺寸（SwiftUI 回报）
    private(set) var barSize: CGSize = CGSize(width: 320, height: 26)
    /// 贴边后露出的宽度
    let edgePeek: CGFloat = 7
    /// 吸附阈值
    let snapDistance: CGFloat = 14

    private init() {}

    // MARK: 生命周期

    func show() {
        // 常驻显示的核心：始终用「无 scene 窗口 + SpringBoard 托管」。
        //  - 交给 SpringBoard 合成后，退后台 / 切 App / 锁屏都仍可见（系统级窗口）。
        //  - 触摸走 App 自身的 UIApplication 事件循环，全屏可拖可点（全局拖动）。
        // 思路对齐 2.1.6 的 -hud 子进程：不依赖 UIWindowScene，自建系统窗口交给 SpringBoard。
        let screen = UIScreen.main.bounds
        guard screen.width > 0 else {
            scheduleRetry()
            return
        }
        if window == nil { buildWindowWithoutScene() }
        window?.isHidden = false
        store.isVisible = true
        layout.peekSide = .none
        provider.start()
        relayout()
        syncHitRegion()
    }

    func hide() {
        store.isVisible = false
        window?.isHidden = true
        provider.stop()
        syncHitRegion()
    }

    func toggle() {
        store.isVisible ? hide() : show()
    }

    /// 屏幕尚未就绪时的重试（最多 ~5 秒）。
    /// 无 scene 窗口只依赖 UIScreen，不需要 scene，所以只需等屏幕可用。
    private var retryCount = 0
    private func scheduleRetry() {
        guard retryCount < 25 else {
            NSLog("[QFSpeed] 屏幕始终未就绪，放弃")
            return
        }
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.show()
        }
    }

    /// UIWindowScene 激活后补挂一次（注入模式下宿主可能迟迟不 active）。
    /// 无 scene 窗口不依赖 scene，这里只要窗口还没建就直接建。
    func showIfActive() {
        guard window == nil else { return }
        show()
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// 不依赖 UIWindowScene 的建窗路径，专供 SpringBoard 注入使用。
    /// 注入到 SpringBoard 时 connectedScenes 可能为空，但 UIWindow 本身
    /// 完全可以脱离 scene 工作（只是不会被 scene 生命周期管理）。
    private func buildWindowWithoutScene() {
        let screen = UIScreen.main.bounds
        let w = PassThroughWindow(frame: screen)
        w.windowLevel = UIWindow.Level.alert + 1
        w.backgroundColor = .clear
        w.isOpaque = false

        // ⚠️ 顺序关键：secure context 必须在窗口上屏之前标记，
        // 否则 CAContext 已经按非 secure 建好，再设也没用。
        // TrollSpeed 就是先设这个再托管。
        SpringBoardWindowHost.shared.markSecure(w)

        let controller = OverlayHostController(store: store, provider: provider, layout: layout)
        w.rootViewController = controller
        w.isHidden = false
        // 不要 makeKeyAndVisible：在 SpringBoard 进程里会把系统 key window
        // 抢过来，可能导致状态栏/控制中心等系统 UI 行为异常。
        // 只设 isHidden = false 就足够显示。

        w.onLayout = { [weak self] in
            guard let self else { return }
            self.layout.bounds = w.bounds.size
            self.relayout()
            self.syncHitRegion()
        }

        let hosted = SpringBoardWindowHost.shared.host(w)
        NSLog("[QFSpeed] 无 scene 建窗，SpringBoard 托管: \(hosted)")

        host = controller
        window = w
        layout.bounds = w.bounds.size
        relayout()
        syncHitRegion()
    }

    private func buildWindow(scene: UIWindowScene) {
        let w = PassThroughWindow(windowScene: scene)

        // 层级选择：
        //  - 有了 platform-application + 越权签名时，用 `.statusBar + 1` 能压在
        //    绝大多数系统 UI 之上；但如果盖住 SpringBoard 的权限弹窗，
        //    用户点不到「允许」就会把自己锁死，所以上限卡在 alert。
        //  - 普通签名（自签/TrollStore 未越权）时只能 `.alert + 1`，
        //    超过这个层级系统直接不理你。
        w.windowLevel = UIWindow.Level.alert + 1
        w.backgroundColor = .clear
        w.isOpaque = false

        // ⚠️ secure context 必须在窗口上屏之前标记，否则 CAContext 已按非 secure
        // 建好，再设也没用（参考 2.1.6：先设 secure 再托管）。
        SpringBoardWindowHost.shared.markSecure(w)

        let controller = OverlayHostController(store: store, provider: provider, layout: layout)
        w.rootViewController = controller
        w.isHidden = false
        // 不要 makeKeyAndVisible：在 SpringBoard 进程里会把系统 key window
        // 抢过来，可能导致状态栏/控制中心等系统 UI 行为异常。
        // 只设 isHidden = false 就足够显示。

        w.onLayout = { [weak self] in
            guard let self else { return }
            self.layout.bounds = w.bounds.size
            self.relayout()
            self.syncHitRegion()
        }

        // 关键：尝试把窗口托管给 SpringBoard。
        // 成功 → 本 App 进后台 / 用户切到别的 App，浮窗照样显示（系统级）。
        // 失败 → 保持普通 UIWindow，只在本 App 内可见。
        // 无论成败都不影响功能，只是可见范围不同，所以不阻断流程。
        let hosted = SpringBoardWindowHost.shared.host(w)
        NSLog("[QFSpeed] SpringBoard 托管: \(hosted ? "成功（系统级）" : "失败（仅本 App）")")

        host = controller
        window = w
        relayout()
        syncHitRegion()
    }

    // MARK: 定位

    /// 当前 window 尺寸。SwiftUI 侧不要用自己的 geo.size ——
    /// 一旦它与 window.bounds 有偏差（安全区 / 分屏），归一化锚点就会漂。
    var currentBounds: CGSize {
        window?.bounds.size ?? .zero
    }

    /// 悬浮条 frame（window 坐标）
    var barFrame: CGRect {
        let size = barSize
        return CGRect(
            x: layout.barCenter.x - size.width / 2,
            y: layout.barCenter.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 按 store.anchor + peekSide 重算 layout.barCenter
    func relayout() {
        guard let window else { return }
        let b = window.bounds
        guard b.width > 0, b.height > 0 else { return }

        let size = barSize
        var cx: CGFloat
        var cy = b.height * store.anchor.y

        switch layout.peekSide {
        case .left:
            cx = edgePeek - size.width / 2
        case .right:
            cx = b.width - edgePeek + size.width / 2
        case .none:
            cx = b.width * store.anchor.x
        }

        // 边界钳制：旋转 / 换设备后别把条卡在屏幕外
        let halfW = size.width / 2
        let halfH = size.height / 2
        if layout.peekSide == .none {
            cx = min(max(cx, halfW), b.width - halfW)
        }
        cy = min(max(cy, halfH), b.height - halfH)

        let newCenter = CGPoint(x: cx, y: cy)
        if newCenter != layout.barCenter {
            layout.barCenter = newCenter
        }
        syncHitRegion()
    }

    /// 把 anchor 归一化（0...1），越界自动夹紧
    func setAnchor(center: CGPoint, in bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // bounds 为 0 时（窗口尚未布局完）除法会产生 nan/inf，
        // 再进 clamped 会导致比较结果异常 → 位置算成 NaN → 视图层崩溃。
        guard bounds.width > 1, bounds.height > 1 else { return }
        let nx = (center.x / bounds.width).clamped(to: 0...1)
        let ny = (center.y / bounds.height).clamped(to: 0...1)
        store.anchor = BarAnchor(x: nx, y: ny)
        relayout()
    }

    // MARK: 吸附

    /// 松手时吸附到最近的边缘（14pt 内）
    func snap(in bounds: CGSize) {
        guard bounds.width > 0 else { return }
        let frame = barFrame
        var cx = frame.midX
        var cy = frame.midY

        if frame.minX < snapDistance { cx = frame.width / 2 }
        else if frame.maxX > bounds.width - snapDistance { cx = bounds.width - frame.width / 2 }

        if frame.minY < snapDistance { cy = frame.height / 2 }
        else if frame.maxY > bounds.height - snapDistance { cy = bounds.height - frame.height / 2 }

        setAnchor(center: CGPoint(x: cx, y: cy), in: bounds)
        maybePeek(in: bounds)
    }

    /// 贴边隐藏：只有紧贴左右边缘才半收
    func maybePeek(in bounds: CGSize) {
        guard store.edgeAutoHide else { return }
        let frame = barFrame
        if frame.minX <= 1 {
            layout.peekSide = .left
        } else if frame.maxX >= bounds.width - 1 {
            layout.peekSide = .right
        } else {
            layout.peekSide = .none
        }
        relayout()
    }

    func unpeek() {
        guard layout.peekSide != .none else { return }
        layout.peekSide = .none
        relayout()
    }

    // MARK: 面板按钮

    func nudge(dx: CGFloat, dy: CGFloat, in bounds: CGSize) {
        guard bounds.width > 0 else { return }
        let frame = barFrame
        setAnchor(center: CGPoint(x: frame.midX + dx, y: frame.midY + dy), in: bounds)
    }

    func resetPosition(in bounds: CGSize) {
        layout.peekSide = .none
        store.anchor = BarAnchor(x: 0.5, y: 0.20)
        if bounds.width > 0 {
            setAnchor(center: CGPoint(x: bounds.width / 2, y: bounds.height * 0.20), in: bounds)
        } else {
            relayout()
        }
    }

    // MARK: 命中区域
    //
    // window 只在 bar 的矩形内吃触摸，其余全部放行。贴边隐藏时故意把可见条
    // 也算进去（虽然收在屏幕外，但露出那 7pt 把手必须可点）。

    /// 拖拽期间整屏放行触摸，松手后恢复按条子矩形判定。
    /// 不这么做的话，手指一离开起始矩形 hitTest 就返回 nil，手感是"拖一下就断"。
    func setDragging(_ dragging: Bool) {
        (window as? PassThroughWindow)?.draggingPassthrough = dragging
        if !dragging { syncHitRegion() }
    }

    func syncHitRegion() {
        guard let window else { return }
        var regions: [CGRect] = []
        if store.isVisible {
            let f = barFrame
            // 贴边隐藏时把区域往下延伸到整个屏幕边，避免只有 7pt 宽点不中
            if layout.peekSide == .left {
                regions.append(CGRect(x: 0, y: f.minY, width: max(f.maxX, edgePeek + 8), height: f.height))
            } else if layout.peekSide == .right {
                let x = min(f.minX, window.bounds.width - edgePeek - 8)
                regions.append(CGRect(x: x, y: f.minY, width: window.bounds.width - x, height: f.height))
            } else {
                regions.append(f)
            }
        }
        window.interactiveRegions = regions
    }

    /// 面板展开/收起时切整屏交互
    /// 主界面「设置面板」按钮调用。
    /// 悬浮窗没显示时先显示出来，否则面板没有宿主可以挂。
    func openSettingsPanel() {
        if window == nil || window?.isHidden == true { show() }
        store.isVisible = true
        store.panelRequestTick &+= 1
    }

    func setPanelPresented(_ presented: Bool) {
        window?.fullScreenInteractive = presented
    }

    /// SwiftUI 侧测到真实尺寸后回报
    func reportBarSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard abs(size.width - barSize.width) > 0.5 || abs(size.height - barSize.height) > 0.5 else { return }
        barSize = size
        relayout()
        syncHitRegion()
    }
}

// MARK: - 工具

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
