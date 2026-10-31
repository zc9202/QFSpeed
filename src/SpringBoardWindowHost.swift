import UIKit
import QuartzCore
import ObjectiveC

/// 把浮窗托管给 SpringBoard —— 照 TrollSpeed 的实测可行路径实现。
///
/// 关键点（都是从 TrollSpeed 2.0-13 的可执行文件里挖出来的）：
///
///   1. 方法签名是 `registerWindowWithContextID:atLevel:`，**不是** 只有 contextID。
///      少了 atLevel: 参数等于调了一个不存在的方法，托管静默失败。
///   2. 窗口必须先设 `_shouldCreateContextAsSecure = YES`，
///      否则拿到的 CAContext 不是 displayable 的，SpringBoard 不认。
///      这一步依赖 entitlements 里的 `com.apple.QuartzCore.displayable-context`
///      和 `com.apple.QuartzCore.secure-mode`。
///   3. contextID 必须取窗口真实的 `_contextId`，不能自己造。
///
/// 全部走 NSClassFromString + IMP 动态调用：SpringBoardServices 没有 Swift
/// modulemap，私有类也可能在某个系统版本上消失，硬链接会启动即崩。
final class SpringBoardWindowHost {

    static let shared = SpringBoardWindowHost()
    private init() {}

    private var hosting: AnyObject?
    private(set) var contextID: UInt32 = 0
    private(set) var isHosted = false
    private(set) var wasInjected = false

    /// 失败原因，面板里直接显示
    private(set) var failureReason: String?

    /// 托管层级。TrollSpeed 用的是一个很高的 level，
    /// 保证盖在状态栏、通知中心之上
    var hostLevel: Int = 10_000_000

    func markInjected() { wasInjected = true }

    /// 托管是否真的进入「远程渲染」状态。
    ///
    /// 这是「本 App 退出后条子还在不在」的分水岭：
    /// `_isRemoteHUDActive` 为 true 表示界面已经交给 SpringBoard 侧渲染，
    /// 我们这边的窗口只是个壳，进程没了也不影响显示。
    var isRemoteActive: Bool {
        let sel = NSSelectorFromString("_isRemoteHUDActive")
        guard let w = hostedWindow, w.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(w.method(for: sel), to: Fn.self)
        return fn(w, sel)
    }

    private weak var hostedWindow: UIWindow?

    // MARK: - 取窗口真实 contextId

    private func contextID(of window: UIWindow) -> UInt32? {
        let sel = NSSelectorFromString("_contextId")
        guard window.responds(to: sel) else { return nil }
        // 不同版本返回 unsigned int / unsigned long，按 UInt 取再截断
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt
        let fn = unsafeBitCast(window.method(for: sel), to: Fn.self)
        let cid = UInt32(truncatingIfNeeded: fn(window, sel))
        return cid == 0 ? nil : cid
    }

    /// 设置 `_shouldCreateContextAsSecure = YES`。
    /// TrollSpeed 的可执行文件里明确引用了这个 setter。
    /// ⚠️ 必须在窗口真正拿到 contextId 之前设置。
    @discardableResult
    func markSecure(_ window: UIWindow) -> Bool {
        let sel = NSSelectorFromString("_setShouldCreateContextAsSecure:")
        if window.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
            let fn = unsafeBitCast(window.method(for: sel), to: Fn.self)
            fn(window, sel, true)
            NSLog("[QFSpeed] _shouldCreateContextAsSecure = YES")
            return true
        }
        // 某些版本只暴露属性而非 setter
        let prop = NSSelectorFromString("set_shouldCreateContextAsSecure:")
        if window.responds(to: prop) {
            typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
            let fn = unsafeBitCast(window.method(for: prop), to: Fn.self)
            fn(window, prop, true)
            NSLog("[QFSpeed] set_shouldCreateContextAsSecure: YES")
            return true
        }
        NSLog("[QFSpeed] 找不到 secure context setter（继续尝试托管）")
        return false
    }

    // MARK: - 托管

    @discardableResult
    func host(_ window: UIWindow) -> Bool {
        guard !isHosted else { return true }

        // ① 先标记 secure context —— 顺序很重要
        markSecure(window)

        // ② 拿到真实 contextId
        guard let cid = contextID(of: window) else {
            failureReason = "取不到 _contextId"
            NSLog("[QFSpeed] 取不到 _contextId，降级为普通窗口")
            return false
        }

        // ③ 取托管控制器
        guard let cls = NSClassFromString("SBSAccessibilityWindowHostingController") as? NSObject.Type else {
            failureReason = "无 HostingController 类"
            NSLog("[QFSpeed] SBSAccessibilityWindowHostingController 不存在")
            return false
        }

        let controller = cls.init()

        // ④ 优先用 TrollSpeed 的签名：registerWindowWithContextID:atLevel:
        let selWithLevel = NSSelectorFromString("registerWindowWithContextID:atLevel:")
        if controller.responds(to: selWithLevel) {
            typealias Fn = @convention(c) (AnyObject, Selector, UInt32, Int) -> Void
            let fn = unsafeBitCast(controller.method(for: selWithLevel), to: Fn.self)
            fn(controller, selWithLevel, cid, hostLevel)

            hosting = controller
            hostedWindow = window
            contextID = cid
            isHosted = true
            failureReason = nil
            NSLog("[QFSpeed] 托管成功（atLevel=%d）contextID=%u", hostLevel, cid)
            return true
        }

        // ⑤ 退一步：老签名的 registerWindowWithContextID:
        let selPlain = NSSelectorFromString("registerWindowWithContextID:")
        if controller.responds(to: selPlain) {
            typealias Fn = @convention(c) (AnyObject, Selector, UInt32) -> Void
            let fn = unsafeBitCast(controller.method(for: selPlain), to: Fn.self)
            fn(controller, selPlain, cid)

            hosting = controller
            hostedWindow = window
            contextID = cid
            isHosted = true
            failureReason = nil
            NSLog("[QFSpeed] 托管成功（旧签名无 level）contextID=%u", cid)
            return true
        }

        failureReason = "无 register 方法"
        NSLog("[QFSpeed] 两种 register 签名都不可用")
        return false
    }

    func unhost() {
        guard isHosted, let controller = hosting else { return }
        let sel = NSSelectorFromString("unregisterWindowWithContextID:")
        if controller.responds(to: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, UInt32) -> Void
            let fn = unsafeBitCast(controller.method(for: sel), to: Fn.self)
            fn(controller, sel, contextID)
        }
        hosting = nil
        isHosted = false
        NSLog("[QFSpeed] 已取消托管")
    }
}
