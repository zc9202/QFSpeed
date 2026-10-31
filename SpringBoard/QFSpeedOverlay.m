// QFSpringBoard —— 常驻浮窗本体，运行在 SpringBoard 进程内。
//
// 为什么放这里：iOS 的窗口只有被 SpringBoard 合成才可能显示。App 自己的 UIWindow 一进后台
// 就失去合成权，再拿守护进程拉第二份 App 也换不来 FBScene。窗口生在 SpringBoard，切 App、
// 回桌面、锁屏都能显示，也不再依赖原 App 是否还活着。
//
// 这里不 hook 任何方法，只有「构造器 + 通知观察 + 1 秒定时器」，把弄崩 SpringBoard 的概率压到最低。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/processor_info.h>
#import <math.h>

#import "QFShared.h"

static UIWindow *gOverlayWindow;
static NSTimer *gRefreshTimer;
static NSTimeInterval gPreviousSampleTime;
static uint64_t gPreviousBytesIn;
static uint64_t gPreviousBytesOut;
static double gDownloadRate;
static double gUploadRate;
static double gCPUPercent;
static double gMemoryUsedGB;
static BOOL gCompact;
static BOOL gShowCPU;
static BOOL gShowMemory;
static BOOL gMounted;

#pragma mark - 指标采集

static double QFCPUPercent(void) {
    static processor_info_array_t previous = NULL;
    static mach_msg_type_number_t previousCount = 0;
    natural_t cpuCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count) != KERN_SUCCESS) {
        return 0.0;
    }
    double total = 0.0;
    if (previous && previousCount == count) {
        for (natural_t index = 0; index < cpuCount; index++) {
            natural_t base = index * CPU_STATE_MAX;
            uint32_t busy = (info[base + CPU_STATE_USER] - previous[base + CPU_STATE_USER]) +
                            (info[base + CPU_STATE_SYSTEM] - previous[base + CPU_STATE_SYSTEM]) +
                            (info[base + CPU_STATE_NICE] - previous[base + CPU_STATE_NICE]);
            uint32_t idle = info[base + CPU_STATE_IDLE] - previous[base + CPU_STATE_IDLE];
            uint32_t all = busy + idle;
            if (all > 0) total += (double)busy / (double)all;
        }
        if (cpuCount > 0) total = total / (double)cpuCount * 100.0;
    }
    if (previous) {
        vm_deallocate(mach_task_self(), (vm_address_t)previous, previousCount * sizeof(integer_t));
    }
    previous = info;
    previousCount = count;
    return total;
}

static double QFMemoryUsedGB(void) {
    vm_statistics64_data_t statistics;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&statistics, &count) != KERN_SUCCESS) {
        return 0.0;
    }
    uint64_t page = (uint64_t)vm_kernel_page_size;
    uint64_t used = ((uint64_t)statistics.active_count + (uint64_t)statistics.wire_count +
                     (uint64_t)statistics.compressor_page_count) * page;
    return (double)used / 1073741824.0;
}

// 走 getifaddrs 的公开 if_data 计数器：不碰私有 if_msghdr2，也不依赖 /proc。
static BOOL QFNetworkTotals(uint64_t *bytesIn, uint64_t *bytesOut) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || !list) return NO;
    uint64_t totalIn = 0;
    uint64_t totalOut = 0;
    for (struct ifaddrs *entry = list; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_LINK) continue;
        if (entry->ifa_flags & IFF_LOOPBACK) continue;
        struct if_data *data = (struct if_data *)entry->ifa_data;
        if (!data) continue;
        totalIn += data->ifi_ibytes;
        totalOut += data->ifi_obytes;
    }
    freeifaddrs(list);
    *bytesIn = totalIn;
    *bytesOut = totalOut;
    return YES;
}

static void QFSampleNetworkRate(void) {
    uint64_t bytesIn = 0;
    uint64_t bytesOut = 0;
    if (!QFNetworkTotals(&bytesIn, &bytesOut)) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gPreviousSampleTime > 0 && now - gPreviousSampleTime > 0.2) {
        double elapsed = now - gPreviousSampleTime;
        gDownloadRate = bytesIn >= gPreviousBytesIn ? (bytesIn - gPreviousBytesIn) / elapsed : 0.0;
        gUploadRate = bytesOut >= gPreviousBytesOut ? (bytesOut - gPreviousBytesOut) / elapsed : 0.0;
    }
    gPreviousBytesIn = bytesIn;
    gPreviousBytesOut = bytesOut;
    gPreviousSampleTime = now;
}

static NSString *QFByteRateText(double bytesPerSecond) {
    if (bytesPerSecond < 1000.0) return [NSString stringWithFormat:@"%.0fB", bytesPerSecond];
    if (bytesPerSecond < 1000000.0) return [NSString stringWithFormat:@"%.0fK", bytesPerSecond / 1000.0];
    if (bytesPerSecond < 1000000000.0) return [NSString stringWithFormat:@"%.1fM", bytesPerSecond / 1000000.0];
    return [NSString stringWithFormat:@"%.2fG", bytesPerSecond / 1000000000.0];
}

#pragma mark - 视图

@interface QFOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end

@implementation QFOverlayWindow

// 只有落在浮条上的点才接收触摸，其余全部透传给下面正在用的应用。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *target = self.interactiveView;
    if (target && target.window == self && !target.hidden && target.alpha > 0.01) {
        CGPoint local = [target convertPoint:point fromView:self];
        if ([target pointInside:local withEvent:event]) {
            return [super hitTest:point withEvent:event];
        }
    }
    return nil;
}

@end

@interface QFBarView : UIView
@property (nonatomic, strong) UILabel *label;
- (void)setText:(NSString *)text;
@end

@implementation QFBarView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
        self.layer.cornerRadius = 9.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
        self.userInteractionEnabled = YES;
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 1;
        [self addSubview:_label];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.label.frame = CGRectInset(self.bounds, 9.0, 3.0);
}

- (void)setText:(NSString *)text {
    self.label.text = text;
    CGSize fitted = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    // 改 bounds 而不是 frame：保持中心不动，数值位数变化时浮条不会往右下漂。
    CGPoint center = self.center;
    CGRect bounds = self.bounds;
    bounds.size = CGSizeMake(MAX(ceil(fitted.width) + 18.0, 64.0), MAX(ceil(fitted.height) + 6.0, 22.0));
    self.bounds = bounds;
    self.center = center;
    [self setNeedsLayout];
}

@end

@interface QFOverlayController : UIViewController
@end

@implementation QFOverlayController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
}
@end

#pragma mark - 交互

@interface QFTouchHandler : NSObject
- (void)refreshText;
- (void)refreshTick:(NSTimer *)timer;
- (void)pan:(UIPanGestureRecognizer *)gesture;
- (void)tap:(UITapGestureRecognizer *)gesture;
- (void)longPress:(UILongPressGestureRecognizer *)gesture;
- (void)clampBar:(UIView *)bar;
- (void)persistBar:(UIView *)bar;
@end

@implementation QFTouchHandler

- (QFBarView *)bar {
    UIView *view = gOverlayWindow.rootViewController.view.subviews.firstObject;
    return [view isKindOfClass:QFBarView.class] ? (QFBarView *)view : nil;
}

- (void)refreshText {
    QFBarView *bar = [self bar];
    if (!bar) return;
    NSString *down = QFByteRateText(gDownloadRate);
    NSString *up = QFByteRateText(gUploadRate);
    if (gCompact) {
        [bar setText:[NSString stringWithFormat:@"↓%@ ↑%@", down, up]];
        return;
    }
    // 面板里关掉的项不占宽度，浮条会跟着缩回中心（setText 改 bounds 不改 center）。
    NSMutableString *text = [NSMutableString stringWithFormat:@"↓%@/s ↑%@/s", down, up];
    if (gShowCPU) [text appendFormat:@"  CPU %.0f%%", gCPUPercent];
    if (gShowMemory) [text appendFormat:@"  %.1fG", gMemoryUsedGB];
    [bar setText:text];
}

- (void)refreshTick:(NSTimer *)timer {
    @autoreleasepool {
        // 只采当前真正要显示的指标，关掉的那项连采样都省了。
        if (gShowCPU) gCPUPercent = QFCPUPercent();
        if (gShowMemory) gMemoryUsedGB = QFMemoryUsedGB();
        QFSampleNetworkRate();
        [self refreshText];

        // 心跳（1.9.0）：常驻失败时这一行能一次说清是"窗口没建"、"没挂上场景"、
        // 还是"建了但被藏起来"。
        static NSUInteger tick;
        tick++;
        if (tick % 30 == 0 && gOverlayWindow) {
            QFBarView *bar = (QFBarView *)gOverlayWindow.rootViewController.view.subviews.firstObject;
            QFLogFormat(@"心跳 hidden=%d level=%.0f scene=%@ 位置=(%.0f,%.0f) 尺寸=%.0fx%.0f 文字=\"%@\"",
                        gOverlayWindow.hidden, gOverlayWindow.windowLevel,
                        gOverlayWindow.windowScene ? NSStringFromClass(gOverlayWindow.windowScene.class) : @"nil",
                        bar.center.x, bar.center.y,
                        bar.bounds.size.width, bar.bounds.size.height,
                        bar.label.text ?: @"");
        }
    }
}

- (void)pan:(UIPanGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    if (!bar || !gOverlayWindow) return;
    CGPoint translation = [gesture translationInView:gOverlayWindow];
    CGPoint center = bar.center;
    center.x += translation.x;
    center.y += translation.y;
    bar.center = center;
    [gesture setTranslation:CGPointZero inView:gOverlayWindow];
    [self clampBar:bar];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self persistBar:bar];
    }
}

- (void)tap:(UITapGestureRecognizer *)gesture {
    gCompact = !gCompact;
    [self refreshText];
    [self clampBar:gesture.view];
    [self persistBar:gesture.view];
    QFLogFormat(@"切换紧凑模式 compact=%d", (int)gCompact);
}

- (void)longPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || !gOverlayWindow) return;
    gOverlayWindow.hidden = YES;
    QFLogMessage(@"浮窗临时隐藏 8 秒");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gOverlayWindow) gOverlayWindow.hidden = NO;
    });
}

- (void)clampBar:(UIView *)bar {
    if (!bar || !gOverlayWindow) return;
    CGRect bounds = gOverlayWindow.bounds;
    if (bounds.size.width < 1 || bounds.size.height < 1) return;
    CGSize size = bar.bounds.size;
    CGPoint center = bar.center;
    CGFloat halfWidth = size.width / 2.0;
    CGFloat halfHeight = size.height / 2.0;
    center.x = MAX(halfWidth + 2.0, MIN(bounds.size.width - halfWidth - 2.0, center.x));
    center.y = MAX(halfHeight + 34.0, MIN(bounds.size.height - halfHeight - 34.0, center.y));
    bar.center = center;
}

- (void)persistBar:(UIView *)bar {
    if (!bar) return;
    NSMutableDictionary *state = [QFPreferencesRead() mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"x"] = @(bar.center.x);
    state[@"y"] = @(bar.center.y);
    state[@"compact"] = @(gCompact);
    state[@"enabled"] = @YES;
    QFPreferencesWrite(state);
}

@end

static QFTouchHandler *gHandler;

#pragma mark - 挂载 / 卸载

static UIWindowScene *QFHostScene(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (!application) return nil;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) return windowScene;
        if (!fallback) fallback = windowScene;
    }
    return fallback;
}

static void QFUnmount(void) {
    if (gRefreshTimer) {
        [gRefreshTimer invalidate];
        gRefreshTimer = nil;
    }
    if (gOverlayWindow) {
        // 先置空再摘 scene：直接 windowScene = nil 会触发 scene 重排，期间若还持有强引用
        // 有概率在 SpringBoard 主线程里撞上半销毁状态，逐次重建就会越攒越危险。
        UIWindow *window = gOverlayWindow;
        gOverlayWindow = nil;
        window.hidden = YES;
        window.windowScene = nil;
    }
    gMounted = NO;
}

static void QFMount(void) {
    if (gMounted && gOverlayWindow && gOverlayWindow.windowScene) {
        // 已挂载就不重建，但把面板刚改的层级顺手应用上，省得用户还要点一次「重新加载」。
        NSDictionary *state = QFPreferencesRead();
        double level = [state[@"level"] doubleValue];
        double want = level >= 1000.0 ? level : 10000000.0;
        if (fabs(gOverlayWindow.windowLevel - want) > 0.5) {
            gOverlayWindow.windowLevel = want;
            QFLogFormat(@"层级更新为 %.0f", want);
        }
        gOverlayWindow.hidden = NO;
        return;
    }
    UIWindowScene *scene = QFHostScene();
    if (!scene) return;

    if (gOverlayWindow) {
        gOverlayWindow.hidden = YES;
        gOverlayWindow = nil;
    }

    NSDictionary *state = QFPreferencesRead();
    gCompact = [state[@"compact"] boolValue];
    gShowCPU = state[@"showCPU"] ? [state[@"showCPU"] boolValue] : YES;
    gShowMemory = state[@"showMemory"] ? [state[@"showMemory"] boolValue] : YES;

    QFOverlayWindow *window = [[QFOverlayWindow alloc] initWithWindowScene:scene];
    // 层级可通过共享域里的 level 覆盖：锁屏看不到时调高（如 10000001、11000000），不用重编。
    double level = [state[@"level"] doubleValue];
    window.windowLevel = level >= 1000.0 ? level : 10000000.0;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.userInteractionEnabled = YES;
    window.rootViewController = [QFOverlayController new];

    QFBarView *bar = [[QFBarView alloc] initWithFrame:CGRectMake(0, 0, 220, 22)];
    [window.rootViewController.view addSubview:bar];
    window.interactiveView = bar;

    if (!gHandler) gHandler = [QFTouchHandler new];
    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gHandler action:@selector(pan:)]];
    [bar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gHandler action:@selector(tap:)]];
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gHandler action:@selector(longPress:)];
    longPress.minimumPressDuration = 1.2;
    [bar addGestureRecognizer:longPress];

    CGSize screen = window.bounds.size;
    if (screen.width < 1) screen = [UIScreen mainScreen].bounds.size;
    double savedX = [state[@"x"] doubleValue];
    double savedY = [state[@"y"] doubleValue];
    bar.center = (savedX > 1.0 && savedY > 1.0) ? CGPointMake(savedX, savedY)
                                                : CGPointMake(screen.width / 2.0, 90.0);

    gOverlayWindow = window;
    gMounted = YES;
    window.hidden = NO;
    [window layoutIfNeeded];
    [gHandler clampBar:bar];

    gPreviousSampleTime = 0;
    QFSampleNetworkRate();
    [gHandler refreshText];

    if (gRefreshTimer) [gRefreshTimer invalidate];
    gRefreshTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [gHandler refreshTick:timer];
    }];
    [[NSRunLoop mainRunLoop] addTimer:gRefreshTimer forMode:NSRunLoopCommonModes];

    QFLogFormat(@"浮窗已挂载 scene=%@ level=%.0f 屏幕=%.0fx%.0f 位置=(%.0f,%.0f)",
                NSStringFromClass(scene.class), window.windowLevel,
                screen.width, screen.height, bar.center.x, bar.center.y);
}

static void QFScheduleApply(NSUInteger attempt);

static void QFApplyState(void) {
    if (QFOverlayDisabled()) {
        QFUnmount();
        QFLogMessage(@"已停用（面板开关或熔断文件），浮窗不加载");
        return;
    }
    NSDictionary *state = QFPreferencesRead();
    BOOL enabled = state[@"enabled"] ? [state[@"enabled"] boolValue] : YES;
    gCompact = [state[@"compact"] boolValue];
    gShowCPU = state[@"showCPU"] ? [state[@"showCPU"] boolValue] : YES;
    gShowMemory = state[@"showMemory"] ? [state[@"showMemory"] boolValue] : YES;
    if (!enabled) {
        QFUnmount();
        QFLogMessage(@"开关为关闭，浮窗隐藏");
        return;
    }
    QFMount();
}

static void QFScheduleApply(NSUInteger attempt) {
    // 同一时刻只留一条重试链：锁屏/解锁、面板连点都会连续触发，
    // 要是每次都起一条 40 次的重试，定时器会叠成一堆，互相抢着建/拆窗口。
    static BOOL pending = NO;
    if (attempt == 0) {
        if (pending) return;
        pending = YES;
    }
    if (QFOverlayDisabled()) {
        if (attempt == 0) pending = NO;
        QFUnmount();
        QFLogMessage(@"检测到熔断文件 QFOverlay.disabled，放弃加载");
        return;
    }
    NSTimeInterval delay = attempt == 0 ? 0.8 : 2.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (attempt == 0) pending = NO;
            NSDictionary *state = QFPreferencesRead();
            BOOL enabled = state[@"enabled"] ? [state[@"enabled"] boolValue] : YES;
            if (!enabled) return;
            if (!QFHostScene()) {
                if (attempt < 40) {
                    QFScheduleApply(attempt + 1);
                } else {
                    QFLogMessage(@"等待 SpringBoard 场景超时，放弃本次挂载");
                }
                return;
            }
            QFApplyState();
        }
    });
}

static void QFInstallObservation(void) {
    static int changeToken;
    notify_register_dispatch(QFChangeNotification, &changeToken, dispatch_get_main_queue(), ^(int token) {
        @autoreleasepool {
            @try {
                QFLogMessage(@"收到 App 侧开关变更通知");
                QFApplyState();
            } @catch (NSException *exception) {
                QFLogFormat(@"处理开关通知异常 %@", exception);
            }
        }
    });

    // 设置面板的「重置位置 / 重新加载」：卸掉重建，位置、层级、显示项全部重新读一遍。
    static int resetToken;
    notify_register_dispatch(QFResetNotification, &resetToken, dispatch_get_main_queue(), ^(int token) {
        @autoreleasepool {
            @try {
                QFLogMessage(@"收到重建通知，重新挂载浮窗");
                QFUnmount();
                QFScheduleApply(0);
            } @catch (NSException *exception) {
                QFLogFormat(@"处理重建通知异常 %@", exception);
            }
        }
    });

    // 独立 App（tipa）启动时会 ping 一下，用来判断这台设备上到底有没有 SpringBoard 侧浮窗。
    // 有回应就由 App 当遥控器，没回应就由 App 自己画。
    static int pingToken;
    notify_register_dispatch(QFPingNotification, &pingToken, dispatch_get_main_queue(), ^(int token) {
        @autoreleasepool {
            QFWritePong();
        }
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification *note) {
        @autoreleasepool {
            if (!gMounted) {
                QFScheduleApply(0);
            } else if (gOverlayWindow && !gOverlayWindow.windowScene) {
                QFUnmount();
                QFScheduleApply(0);
            }
        }
    }];
}

#pragma mark - 入口

__attribute__((constructor))
static void QFOverlayLoad(void) {
    @autoreleasepool {
        // 加载期只排队，不碰 UIApplication：SpringBoard 启动瞬间同步访问会被 watchdog 判死。
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                if (QFOverlayDisabled()) return;
                QFLogMessage(@"SpringBoard 侧已加载，等待场景就绪");
                // 诊断（1.9.0）：浮窗住在这个进程里，窗口能不能显示就看这两行。
                // 场景一直拿不到 → scene 那条会一直是 nil；权限缺失 → 面板/日志直接变红。
                QFLogFormat(@"[诊断] 权限 %@", QFEntitlementsSummary());
                QFLogFormat(@"[诊断] 场景数=%lu 窗口数=%lu level=%.0f",
                            (unsigned long)[UIApplication sharedApplication].connectedScenes.count,
                            (unsigned long)[UIApplication sharedApplication].windows.count,
                            (double)10000000.0);
                @try {
                    QFInstallObservation();
                    static int startupToken;
                    notify_register_dispatch("com.apple.springboard.finishedstartup", &startupToken,
                                             dispatch_get_main_queue(), ^(int token) {
                        QFScheduleApply(0);
                    });
                    QFScheduleApply(0);
                } @catch (NSException *exception) {
                    QFLogFormat(@"初始化异常 %@", exception);
                }
            }
        });
    }
}
