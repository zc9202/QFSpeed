// QFSpeedOverlay.xm — Logos 注入模板
//
// 需要 theos：
//   $THEOS/bin/logify.pl Tweak/QFSpeedOverlay.xm > Tweak/QFSpeedOverlay.x
//
// 用途：把同一份 FloatingWindowManager / FloatingBarView 注入到**任意宿主 App**，
// 实现截图里那种"悬浮在别的 App 之上"的效果。
//
// ⚠️ 前提：设备已越狱，或使用 TrollStore / 侧载签名（需自签 dylib 注入）。
// 普通 App Store 应用**无法**跨进程悬浮，这是沙盒硬限制，不是代码问题。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Swift 侧需要用 @objc 暴露一个入口。在 Swift 包里加：
//
//   import Foundation
//   @objc public final class QFSpeedBridge: NSObject {
//       @objc public static func install() {
//           DispatchQueue.main.async { FloatingWindowManager.shared.show() }
//       }
//       @objc public static func uninstall() {
//           DispatchQueue.main.async { FloatingWindowManager.shared.hide() }
//       }
//   }
//
// 然后在 Xcode 里把该 Swift 文件所在 target 编成 dylib（或静态库）。

%group QFSpeed

// MARK: - 注入时机
// 用 UIApplication 的 didFinishLaunching 之后作为锚点：此时 keyWindow / scene 已就绪。

%hook UIApplication

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    BOOL ret = %orig;
    [self qfs_installOverlay];
    return ret;
}

%new
- (void)qfs_installOverlay {
    Class bridge = NSClassFromString(@"QFSpeedBridge");
    if (!bridge) {
        NSLog(@"[QFSpeed] bridge 未找到，检查 dylib 是否已加载");
        return;
    }
    SEL sel = NSSelectorFromString(@"install");
    if ([bridge respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(bridge, sel);
        NSLog(@"[QFSpeed] 悬浮层已挂载");
    }
}

%end

// MARK: - 场景兜底
// 有些宿主走 SceneDelegate 启动，didFinishLaunching 时 windowScene 还空。
// 这里在 scene 激活后再尝试一次。

%hook UIWindowScene

- (void)setActivationState:(UISceneActivationState)state {
    %orig;
    if (state == UISceneActivationStateForegroundActive) {
        [[UIApplication sharedApplication] qfs_installOverlay_ifNeeded];
    }
}

%new
- (void)qfs_installOverlay_ifNeeded {
    // 已挂载则跳过；具体判断交给 Swift 侧的 FloatingWindowManager.show() 幂等处理
}

%end

%end  // group QFSpeed

// MARK: - 配置说明
//
// 1) Makefile（theos）
//    ARCHS = arm64 arm64e
//    TARGET = iphone:clang:latest:14.0
//    include $(THEOS)/makefiles/common.mk
//
//    TWEAK_NAME = QFSpeedOverlay
//    QFSpeedOverlay_FILES = QFSpeedOverlay.x
//    QFSpeedOverlay_CFLAGS = -fobjc-arc
//    QFSpeedOverlay_LIBRARIES = substrate
//    QFSpeedOverlay_SWIFT_BRIDGING_HEADER = ...  // 若 dylib 里含 Swift
//    include $(THEOS_MAKE_PATH)/tweak.mk
//
// 2) 只挂某个 App 时，用 Info.plist 的 Filter/Bundles 限定，而不是全局注入 ——
//    全局注入会让每个 App 都多起一个采样定时器，白耗电。
//
//    Filter = {
//        Bundles = ("com.apple.mobilesafari", "com.tencent.xin");
//    };
//
// 3) UIWindow level
//    截图里写 "level=0" 是因为宿主自身的窗口就是 level=0（normal）。
//    要盖住宿主的 alert，用 UIWindowLevelAlert + 1；要盖住键盘，至少 Alert 级。
//    别用 UIWindowLevelStatusBar 以上 —— 会挡住系统权限弹窗，用户无法授权。
