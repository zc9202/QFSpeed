import UIKit

/// 进程注入入口。
///
/// 这个 dylib 会被 TrollFools（或越狱环境的 Tweak 注入）加载进 SpringBoard 进程。
/// 一旦在 SpringBoard 里跑起来，我们建的 UIWindow 就天然处在系统 UI 层，
/// 覆盖所有 App —— 这才是真正的「系统级浮窗」。
///
/// 关键：**不要依赖 connectedScenes**。
/// SpringBoard 不是普通 App，它自己管理窗口，UIApplication.connectedScenes
/// 经常是空的，或者里面的 scene 永远不是 foregroundActive。原实现卡在这里，
/// 一轮轮重试直到 5 秒超时放弃 —— 表现就是「注入了但什么都没出现」。
/// 现在改为直接建 UIWindow(frame:)，它不需要 scene 也能显示。
@_cdecl("qfspeed_inject_entry")
public func qfspeedInjectEntry() {
    NSLog("[QFSpeed] dylib 已加载，准备挂载")
    DispatchQueue.main.async {
        startWhenReady(attempt: 0)
    }
}

private func startWhenReady(attempt: Int) {
    // SpringBoard 启动期比较忙，给足 10 秒（50 × 0.2s）
    guard attempt < 50 else {
        NSLog("[QFSpeed] 等待超时，放弃挂载")
        return
    }

    // UIWindow 必须在有 UIScreen 之后才能建；这里只等这个条件，
    // 不再等 scene。
    guard UIScreen.main.bounds.width > 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            startWhenReady(attempt: attempt + 1)
        }
        return
    }

    // 先标记，再 show()。show() 内部读 wasInjected 决定走哪条建窗路径，
    // 顺序反了就永远进不去无 scene 分支。
    SpringBoardWindowHost.shared.markInjected()

    FloatingWindowManager.shared.show()
    NSLog("[QFSpeed] 已挂载（第 \(attempt + 1) 次尝试）")
}
