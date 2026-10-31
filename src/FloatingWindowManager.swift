import UIKit
import SwiftUI
import Combine
import ObjectiveC

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

// MARK: - 私有窗口方法的运行时覆写

/// Swift 编译期看不到 UIKit 的私有方法，`override` 直接编译不过，只能用运行时补。
///
/// 这几个方法是「窗口到底能不能被 SpringBoard 合成」的总开关。
/// 2.1.6 的 QFHudWindow 里明确写了：「自报系统窗口，并声明 CAContext 由自己管 ——
/// 两个条件缺一个，SpringBoard 就不会合成它」。
/// 缺了它们表现就是：窗口 hidden=0、alpha=1、ctx 注册返回成功，
/// 但屏幕上什么都没有，而且全程不报错。
private enum WindowPrivateOverrides {

    private typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool

    static func install() {
        let cls: AnyClass = PassThroughWindow.self
        // 自报「我是系统窗口」，否则 SpringBoard 不接这个 CAContext
        set(cls, "_isSystemWindow", onMetaClass: true) { _, _ in true }
        // 声明 CAContext 由本进程自己管，不让 WindowServer 托管
        set(cls, "_isWindowServerHostingManaged", onMetaClass: false) { _, _ in false }
        // secure 上下文建不出来时窗口会静默消失（见 2.1.6 的 1.8.x 踩坑记录）
        set(cls, "_isSecure", onMetaClass: false) { _, _ in false }
        // 窗口要参与命中，否则 UIKit 事件永远进不来
        set(cls, "_ignoresHitTest", onMetaClass: false) { _, _ in false }
    }

    private static func set(_ cls: AnyClass,
                            _ name: String,
                            onMetaClass: Bool,
                            body: @convention(c) (AnyObject, Selector) -> Bool) {
        guard let target: AnyClass = onMetaClass ? object_getClass(cls) : cls else { return }
        let selector = NSSelectorFromString(name)
        let block: IMP = unsafeBitCast(body, to: IMP.self)
        if class_getInstanceMethod(target, selector) != nil {
            class_replaceMethod(target, selector, block, "B@:")
            NSLog("[QFSpeed] 已替换 \(onMetaClass ? "+" : "-")\(name)")
        } else {
            class_addMethod(target, selector, block, "B@:")
            NSLog("[QFSpeed] 已注入 \(onMetaClass ? "+" : "-")\(name)")
        }
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
        // 两条建窗路径，按运行形态选：
        //   ① 有 UIWindowScene（App 自己在前台）→ 绑 scene 建窗。
        //      这是唯一能保证「显示 + 触摸」都走系统标准路径的方式：
        //      UIKit 的事件派发、布局、旋转、安全区全都由 scene 驱动。
        //      ——之前把这条砍掉、一律走无 scene，结果就是窗口建出来了却收不到触摸，
        //        设置面板点不开。
        //   ② 没有 scene（注入进 SpringBoard）→ 无 scene 建窗 + 直接挂系统层。
        let screen = UIScreen.main.bounds
        guard screen.width > 0 else {
            scheduleRetry()
            return
        }
        if window == nil {
            if SpringBoardWindowHost.shared.wasInjected {
                // 注入进 SpringBoard 时不能绑宿主 scene —— 那会把浮条变成
                // SpringBoard 自己的普通子窗口，跟着系统 UI 一起被前后台切换掉。
                buildWindowWithoutScene()
                NSLog("[QFSpeed] 无 scene 建窗（注入/SpringBoard 路径）")
            } else if let scene = activeScene() {
                buildWindow(scene: scene)
                NSLog("[QFSpeed] 用 scene 建窗（显示与触摸走系统标准路径）")
            } else if retryCount < 25 {
                // App 形态下 scene 一定会来（系统保证），只是启动早期还没就绪。
                // 这时候绝不能退化成无 scene 窗口 —— 窗口一旦建出来就再也不会重建，
                // 结果就是「显示不出来、面板也点不开」，而且后面 scene 就绪了也救不回来。
                scheduleRetry()
                return
            } else {
                buildWindowWithoutScene()
                NSLog("[QFSpeed] 等 scene 超时，退化到无 scene 建窗")
            }
        }
        window?.isHidden = false
        store.isVisible = true
        layout.peekSide = .none
        provider.start()
        relayout()
        syncHitRegion()

        // 跨 App 常驻：本 App 的 UIWindow 一进后台就失去合成权，这是物理限制，
        // 不是 bug。照 2.1.6 的 QFPiPBar 走画中画这条路 —— 系统自己合成 PiP 窗口，
        // 浮在任何 App 之上，而且用户能随手把它拖到屏幕任意位置（真正的全局拖动）。
        // 这里只做「准备」：把渲染层挂进视图层级并开始喂帧，
        // 真正浮起来由系统在 App 进后台时自动完成（canStartPictureInPictureAutomaticallyFromInline）。
        PiPBarHost.shared.prepare()
    }

    func hide() {
        store.isVisible = false
        window?.isHidden = true
        provider.stop()
        syncHitRegion()
        // 用户主动隐藏时把常驻那张也收掉，否则「隐藏」等于没隐藏。
        PiPBarHost.shared.stop()
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
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return active
        }
        if let any = scenes.first { return any }
        // 兜底：本包 Info.plist 里没有 UIApplicationSceneManifest，
        // 某些系统版本上 connectedScenes 会滞后一拍（启动早期为空）。
        // 这时从已经挂在屏幕上的窗口反查，比干等更可靠。
        return UIApplication.shared.windows.compactMap { $0.windowScene }.first
    }

    /// 不依赖 UIWindowScene 的建窗路径，专供 SpringBoard 注入使用。
    /// 注入到 SpringBoard 时 connectedScenes 可能为空，但 UIWindow 本身
    /// 完全可以脱离 scene 工作（只是不会被 scene 生命周期管理）。
    private func buildWindowWithoutScene() {
        // 必须在建窗前补上私有方法，否则窗口拿到的是「普通 App 窗口」身份，
        // SpringBoard 直接不合成 —— 就是「注册成功但屏幕上没有」的根源。
        WindowPrivateOverrides.install()

        let screen = UIScreen.main.bounds
        let w = PassThroughWindow(frame: screen)
        // 层级对齐 2.1.6：能盖住状态栏/通知中心，又不会高到连系统弹窗都压下去。
        w.windowLevel = UIWindow.Level(rawValue: 10_000_000)
        w.backgroundColor = .clear
        w.isOpaque = false

        // 注意：这里刻意不强制 secure 上下文。
        // 2.1.6 的 1.8.x 就栽在「先开 secure」上：一旦 secure-mode 权限没被系统认下，
        // CAContext 根本建不出来，而窗口对象、hidden、alpha 全是正常的，屏幕上什么都没有。
        // 先非 secure，能截屏也能自己确认；真要 ctx=0 再升 secure 重试。

        let controller = OverlayHostController(store: store, provider: provider, layout: layout)
        w.rootViewController = controller
        w.isHidden = false
        // 同样要显式逼一次布局，理由同 buildWindow(scene:)：
        // 不这么干 bounds 可能一直是 0，浮条位置会被定死在原点。
        w.layoutIfNeeded()

        w.onLayout = { [weak self] in
            guard let self else { return }
            self.layout.bounds = w.bounds.size
            self.relayout()
            self.syncHitRegion()
        }

        // 一律不做 SpringBoard 托管 —— 这是被真机日志证死过的一条死路。
        //
        // 2.1.6 的原话（QFOverlay.log）：
        //   「窗口已交给 SpringBoard 合成 ctx=3565695019 level=10000000 secure=0 注册=成功」
        //   「窗口自检 hidden=0 alpha=1.00 子层=1 条=239x22 barAlpha=1.00」
        // 注册成功、层级够高、透明度正常，屏幕上什么都没有。
        // 因为 CAContext 注册只是通知 SpringBoard「存在这个窗口」，
        // 它并不会去合成一个属于 App 沙箱的 surface。
        // 更糟的是：一旦托管，本来还能正常显示的窗口会被接走，再也回不来。
        //
        // 真正跨 App 常驻只有一条路 —— 窗口生在 SpringBoard 进程内（2.1.6 的 QFSpringBoard）。
        // App 形态老老实实做本 App 内的显示 + 拖动 + 面板，不在这里硬凑。
        NSLog("[QFSpeed] 无 scene 建窗：不做托管，直接按普通窗口显示")

        host = controller
        window = w
        layout.bounds = w.bounds.size
        relayout()
        syncHitRegion()
    }

    private func buildWindow(scene: UIWindowScene) {
        // 这里刻意不装 `_isSystemWindow`。
        // 在 App 进程里把自家窗口自称「系统窗口」，SpringBoard 会来接管这个 CAContext，
        // 但它并不会真的合成一个属于 App 沙箱的 surface —— 结果就是
        // hidden=0、alpha=1、注册返回成功，屏幕上什么都没有。
        // App 形态就老老实实当普通窗口用：显示、拖动、面板全都走系统标准路径。
        // 真正的系统级常驻走另一个入口（注入 SpringBoard 的 dylib）。

        let w = PassThroughWindow(windowScene: scene)

        // 绑了 scene 的窗口活在本 App 进程内，层级用 alert+1 就够（盖住自家 UI），
        // 再高会把系统权限弹窗压到下面 —— 用户点不到「允许」就把自己锁死了。
        // 真正跨 App 的层级由托管时的 atLevel 参数决定，不靠这个值。
        w.windowLevel = UIWindow.Level.alert + 1
        w.backgroundColor = .clear
        w.isOpaque = false

        let controller = OverlayHostController(store: store, provider: provider, layout: layout)
        w.rootViewController = controller
        w.isHidden = false
        // 关键：显式逼一次布局。只把 isHidden 设成 false 不会立刻算 bounds，
        // 此时 relayout() 读到 0x0 会把浮条位置定死在原点。
        // 2.1.6 的 Tweak.xm 在 window.hidden = NO 之后同样紧跟一句 [window layoutIfNeeded]。
        w.layoutIfNeeded()

        w.onLayout = { [weak self] in
            guard let self else { return }
            self.layout.bounds = w.bounds.size
            self.relayout()
            self.syncHitRegion()
        }

        // 不托管：App 形态托管只会把窗口交给 SpringBoard 接管，
        // 而 SpringBoard 不会合成 App 沙箱里的 surface —— 等于把还能正常显示的窗口弄没。
        // 跨 App 常驻由注入 SpringBoard 的 dylib 承担，那条路才真的在系统层。
        host = controller
        window = w
        retryCount = 0
        relayout()
        syncHitRegion()

        // 自证日志：一行说清窗口到底有没有真的上屏。
        // 注意 App 沙箱写不了 /var/mobile/Library/Logs，只能在控制台看到，
        // 所以真正的现场自证放在主界面的「浮窗诊断」卡片里。
        NSLog("[QFSpeed] scene 窗口就位 bounds=\(w.bounds.size) hidden=\(w.isHidden) "
              + "level=\(w.windowLevel.rawValue) barCenter=\(layout.barCenter) visible=\(store.isVisible)")
    }

    // MARK: 定位

    /// 当前 window 尺寸。SwiftUI 侧不要用自己的 geo.size ——
    /// 一旦它与 window.bounds 有偏差（安全区 / 分屏），归一化锚点就会漂。
    var currentBounds: CGSize {
        let b = window?.bounds.size ?? .zero
        // 窗口刚建、还没布局时 bounds 是 0；这里同样用屏幕尺寸兜底，
        // 否则命中区域会算成 0 宽，浮条「看得见点不到」。
        if b.width < 1 || b.height < 1 { return UIScreen.main.bounds.size }
        return b
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
        guard let window else {
            // 窗口还没建出来（OverlayRootView 的 onAppear 早于 show()）。
            // 这里先落一个屏幕内的初始位置，别让 SwiftUI 卡在 .zero 上等 ——
            // 它和下面的命中区域必须用同一个坐标来源，否则会出现「看得见点不到」。
            if layout.barCenter == .zero {
                let s = UIScreen.main.bounds.size
                if s.width > 1 {
                    layout.barCenter = CGPoint(x: s.width / 2, y: s.height * 0.12)
                }
            }
            return
        }
        // ⚠️ 这里是「浮窗完全不显示」的真正死结，别再改回去：
        // 窗口刚建出来、还没 layoutIfNeeded 时 window.bounds 可能是 (0,0,0,0)。
        // 一旦在这里 return，layout.barCenter 就永远停在 .zero，
        // 而 SwiftUI 侧以「barCenter 有效」为渲染前提 —— 于是浮条一辈子不渲染，
        // 整个窗口看着就是「空的 / 没显示」，面板也没有宿主可挂。
        // 2.1.6 的 Tweak.xm 用的是同一套兜底：window.bounds 不可用时取 UIScreen.main.bounds。
        var b = window.bounds
        if b.width < 1 || b.height < 1 {
            b = UIScreen.main.bounds
            NSLog("[QFSpeed] window.bounds 不可用，改用 UIScreen 兜底 \(b.size)")
        }
        guard b.width > 1, b.height > 1 else { return }

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
                let width = currentBounds.width
                let x = min(f.minX, width - edgePeek - 8)
                regions.append(CGRect(x: x, y: f.minY, width: width - x, height: f.height))
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

    // MARK: 现场自证

    /// 把「窗口到底有没有真的上屏」摊到主界面上。
    ///
    /// 为什么必须做成界面元素：App 沙箱写不了 /var/mobile/Library/Logs，
    /// NSLog 只进控制台，而控制台在没有 Mac 的情况下根本看不到。
    /// 之前几轮全靠猜日志，浪费了太多时间 —— 现在一眼看齐所有关键状态。
    var diagnostics: [(String, String)] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
        var rows: [(String, String)] = []

        if let w = window {
            rows.append(("窗口", "已创建"))
            rows.append(("bounds", "\(Int(w.bounds.width))×\(Int(w.bounds.height))"))
            rows.append(("hidden / level", "\(w.isHidden ? 1 : 0) / \(Int(w.windowLevel.rawValue))"))
            rows.append(("命中区域", "\(w.interactiveRegions.count) 块"))
        } else {
            rows.append(("窗口", "未创建"))
        }
        rows.append(("浮条中心", "\(Int(layout.barCenter.x)), \(Int(layout.barCenter.y))"))
        rows.append(("浮条尺寸", "\(Int(barSize.width))×\(Int(barSize.height))"))
        rows.append(("scene", "\(scenes.count) 个 / \(active != nil ? "active" : "无 active")"))
        rows.append(("开关", store.isVisible ? "开" : "关"))
        rows.append(("运行形态", SpringBoardWindowHost.shared.wasInjected ? "SpringBoard 注入" : "独立 App"))
        // 常驻那一层是否真的准备好了（画中画）。这一行是排查「切出去条子就没了」的关键。
        rows.append(("常驻", PiPBarHost.shared.statusText))
        // 把画中画每一步的判定都摊开：真机上不用连 Mac 看日志，一眼就知道卡在哪。
        rows.append(contentsOf: PiPBarHost.shared.detailRows)
        return rows
    }
}

// MARK: - 工具

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
