// QFShared.h
// App 侧（QFManaged.dylib）与 SpringBoard 侧（QFSpringBoard）共用的约定。
//
// 传输通道用 CFPreferences 的共享域：App 与 SpringBoard 各自都通过 cfprefsd 读写，
// 这样在 RootHide 这种 jbroot 路径随机化的环境下也不会因为硬编码路径而失配。
// 直接落盘的那份只是兜底，读的时候会挑得到的那一份。

#import <Foundation/Foundation.h>
#import <CoreFoundation/CFPreferences.h>
#import <CoreFoundation/CFPropertyList.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <arpa/inet.h>
#include <dlfcn.h>

#define QFDomainName "com.qfspeed.overlay"
#define QFChangeNotification "com.qfspeed.overlay.changed"
// 只让 SpringBoard 重建窗口（重置位置 / 换层级 / 手动重新加载）。
#define QFResetNotification "com.qfspeed.overlay.reset"
// App 探测 SpringBoard 侧在不在：App 发 ping，dylib 收到就把当前时间写进 sbpong。
// 只有越狱设备装了 deb 才会有回应，没回应就说明只能由 App 自己画。
#define QFPingNotification "com.qfspeed.overlay.ping"
#define QFPongKey "sbpong"
// 常驻窗口是否真的被 SpringBoard 收下（1=收下 0=没成）。
// 单独一个键，不塞进 state 字典：state 是 App 写的配置，这个是 HUD 进程写的运行结果，
// 两边各写各的才不会互相覆盖。
#define QFHudRegKey "hudreg"
// HUD 进程最后一次心跳的时间戳（秒）。
// 为什么需要它：App 侧判断"浮窗在不在跑"原来靠 kill(pid, 0) 探活，但沙盒里的 App
// 对数万毫秒前的陌生 pid 发信号经常拿到 EPERM（进程存在但无权限），
// 于是把活着的浮窗判成"未运行"——状态卡一直写未运行，屏幕上浮条却好好的。
// 心跳走 cfprefsd，跨进程一定读得到，比探活可靠。
#define QFHudBeatKey "hudbeat"
#define QFLogFilePath "/var/mobile/Library/Logs/QFOverlay.log"
#define QFDisableFilePath "/var/mobile/Library/Preferences/QFOverlay.disabled"

// 沙盒兜底日志。
// TrollStore 装的 App 若没有真正拿到 no-sandbox / platform-application（签名被系统按普通 App 对待），
// /var/mobile/Library/Logs 是写不进去的，而 QFLogMessage 又是静默失败 ——
// 现场表现就是"根本没有日志产生"，排查直接断线。这里再给一条沙盒内的路，
// 面板里的"查看运行日志 / 一键复制"读的是两份合并后的内容。
static inline NSString *QFLogFallbackPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) documents = NSTemporaryDirectory();
    if (documents.length == 0) return nil;
    return [documents stringByAppendingPathComponent:@"QFOverlay.log"];
}

// 按时间顺序合并主日志与兜底日志（两者通常只有一份有内容）。
static inline NSString *QFLogReadAll(void) {
    NSMutableString *merged = [NSMutableString string];
    NSString *primary = [NSString stringWithContentsOfFile:@QFLogFilePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (primary.length > 0) [merged appendString:primary];
    NSString *fallbackPath = QFLogFallbackPath();
    NSString *fallback = fallbackPath.length > 0
        ? [NSString stringWithContentsOfFile:fallbackPath encoding:NSUTF8StringEncoding error:nil]
        : nil;
    if (fallback.length > 0) [merged appendString:fallback];
    return merged;
}

// 日志会被 SpringBoard、设置面板、QFSpeed 三个进程同时写。
// 以前用 NSFileHandle + seekToEndOfFile：先取长度再写，两个进程同时进来会 seek 到同一偏移，
// 后写的直接覆盖前者——现场表现就是某一行被拦腰截断、后半句顶到别的行上。
// 现在改成 O_APPEND + 单次 write：追加位置由内核维护，一次 syscall 落一行，不再互相踩。
static inline void QFLogMessage(NSString *message) {
    if (message.length == 0) return;
    NSLog(@"[QFOverlay] %@", message);
    @autoreleasepool {
        @try {
            NSFileManager *manager = [NSFileManager defaultManager];
            NSString *path = [NSString stringWithUTF8String:QFLogFilePath];
            [manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
            if ([manager fileExistsAtPath:path]) {
                NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
                if (attributes && [attributes fileSize] > 256 * 1024) {
                    [manager removeItemAtPath:path error:nil];
                }
            }
            NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length == 0) return;
            int fd = open(QFLogFilePath, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd < 0) {
                // 主路径写不进去（沙盒没放开）→ 落到 App 自己沙盒里，至少面板能看见、能复制。
                NSString *fallbackPath = QFLogFallbackPath();
                if (fallbackPath.length > 0) {
                    fd = open(fallbackPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
                }
            }
            if (fd < 0) return;
            // 单次 write 控制在 4KB 以内，追加是原子的；超长内容截断，宁可少一行也不写坏别人。
            size_t length = MIN(data.length, (NSUInteger)4000);
            ssize_t written = write(fd, data.bytes, length);
            (void)written;
            close(fd);
        } @catch (__unused NSException *exception) {
        }
    }
}

static inline void QFLogFormat(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    QFLogMessage(message);
}

// 首选项落盘位置。
//
// ★ 2.1.4：第一位是 **App 容器内** 的 plist。
// App 本体和它 posix_spawn 出来的 HUD 进程是同一个可执行文件、同一个沙盒容器，
// 所以这个路径两边都能读写，而且是普通文件读写 —— 写完立刻可见，不经过 cfprefsd。
// 之前只靠 CFPreferences(AnyUser) 这一条：写入后 cfprefsd 那边是否马上让另一个进程
// 读到，取决于系统，实测会出现"HUD 收到了通知，但读回来还是旧字典"，
// 于是通知到了、界面不动 —— 这就是用户说的"不实时"。
// 后两条仍然保留：越狱 deb 版（SpringBoard 进程）读的是系统路径。
static inline NSArray<NSString *> *QFPreferenceFilePaths(void) {
    NSString *container = [NSHomeDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"Library/Preferences/%s.plist", QFDomainName]];
    return @[
        container,
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%s.plist", QFDomainName],
        [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%s.plist", QFDomainName]
    ];
}

// 每份配置都带写入时间戳，读的时候取最新的那一份。
// 没有时间戳的是旧版本写的，一律当 0 处理 —— 不会把新值压掉。
static inline double QFPreferencesStamp(NSDictionary *state) {
    id value = state[@"_savedAt"];
    return value ? [value doubleValue] : 0.0;
}

static inline NSDictionary *QFPreferencesRead(void) {
    NSDictionary *best = nil;
    double bestStamp = -1.0;

    for (NSString *path in QFPreferenceFilePaths()) {
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:path];
        if (file.count == 0) continue;
        id nested = file[@"state"];
        NSDictionary *candidate = [nested isKindOfClass:NSDictionary.class] ? nested : file;
        if (candidate.count == 0) continue;
        double stamp = QFPreferencesStamp(candidate);
        if (stamp > bestStamp) {
            bestStamp = stamp;
            best = candidate;
        }
    }

    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR("state"), CFSTR(QFDomainName),
                                                     kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (value) {
        if (CFGetTypeID(value) == CFDictionaryGetTypeID()) {
            NSDictionary *state = [(__bridge NSDictionary *)value copy];
            // >= 是为了让 CFPreferences 在"时间戳相同"时胜出：
            // 系统路径那份可能正是 cfprefsd 写下去的，内容一致，用谁都不影响。
            if (state.count && QFPreferencesStamp(state) >= bestStamp) {
                best = state;
            }
        }
        CFRelease(value);
    }
    return best ?: @{};
}

// 写入共享域。App 侧负责写，SpringBoard 侧只读，避免两边互相覆盖。
static inline BOOL QFPreferencesWrite(NSDictionary *state) {
    if (!state) return NO;
    NSMutableDictionary *payload = [state mutableCopy];
    payload[@"_savedAt"] = @([[NSDate date] timeIntervalSince1970]);
    state = payload;
    BOOL written = NO;
    CFPreferencesSetValue(CFSTR("state"), (__bridge CFPropertyListRef)state, CFSTR(QFDomainName),
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (CFPreferencesSynchronize(CFSTR(QFDomainName), kCFPreferencesAnyUser, kCFPreferencesAnyHost)) {
        written = YES;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"state": state}
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data) {
        for (NSString *path in QFPreferenceFilePaths()) {
            NSString *directory = [path stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            if ([data writeToFile:path atomically:YES]) written = YES;
        }
    }
    return written;
}

// 停用有两道闸：设置面板里的开关（共享域 disabled），以及万一设置进不去时手工建的熔断文件。
static inline BOOL QFOverlayDisabled(void) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:QFDisableFilePath]]) {
        return YES;
    }
    return [QFPreferencesRead()[@"disabled"] boolValue];
}

// 常驻窗口的注册结果。HUD 进程每轮注册/自检都会刷一次，App 侧读它决定要不要启用前台兜底浮条。
// 判定"常驻真的在屏幕上"不能只看进程活着 —— 进程活着、窗口对象正常、日志全绿但屏幕空白，
// 正是 1.4.0~1.8.1 一路踩的坑。这里记的是 registerWindow 的真实返回值，比进程存活可信。
static inline void QFWriteHudRegistered(BOOL registered) {
    NSNumber *flag = @(registered ? 1 : 0);
    CFPreferencesSetValue(CFSTR(QFHudRegKey), (__bridge CFPropertyListRef)flag, CFSTR(QFDomainName),
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(QFDomainName), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
}

static inline BOOL QFReadHudRegistered(void) {
    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR(QFHudRegKey), CFSTR(QFDomainName),
                                                     kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    BOOL flag = NO;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFBooleanGetTypeID()) {
            flag = [(__bridge NSNumber *)value boolValue];
        }
        CFRelease(value);
    }
    return flag;
}

// 心跳只占域里独立的 sbpong 键，不碰 state 字典，免得和设置读写互相覆盖。
static inline void QFWriteHudBeat(void) {
    NSNumber *now = @([[NSDate date] timeIntervalSince1970]);
    CFPreferencesSetValue(CFSTR(QFHudBeatKey), (__bridge CFPropertyListRef)now, CFSTR(QFDomainName),
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(QFDomainName), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
}

// 心跳是否新鲜。超过 aliveWithin 秒就当它已经死了（进程被 jetsam / 崩溃 / 卸载）。
static inline BOOL QFHudBeatAlive(double aliveWithin) {
    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR(QFHudBeatKey), CFSTR(QFDomainName),
                                                     kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    double stamp = 0.0;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            stamp = [(__bridge NSNumber *)value doubleValue];
        }
        CFRelease(value);
    }
    if (stamp <= 0.0) return NO;
    return [[NSDate date] timeIntervalSince1970] - stamp < aliveWithin;
}

// 心跳清零：进程要退出时调用，App 侧下一次读取立刻知道"停了"，
// 不用等 12 秒的过期窗口。
static inline void QFClearHudBeat(void) {
    CFPreferencesSetValue(CFSTR(QFHudBeatKey), (__bridge CFPropertyListRef)@(0.0),
                          CFSTR(QFDomainName), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(QFDomainName), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
}

static inline void QFWritePong(void) {
    NSNumber *now = @([[NSDate date] timeIntervalSince1970]);
    CFPreferencesSetValue(CFSTR(QFPongKey), (__bridge CFPropertyListRef)now, CFSTR(QFDomainName),
                          kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(QFDomainName), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
}

// ---------------------------------------------------------------------------
// 权限自检（1.9.0）
//
// 为什么非要有这一段：ldid 打进去的 entitlements 有可能被系统**整个忽略**
// （签名结构不完整、CodeDirectory 对不上、DER 段缺失时都会这样）。
// 但进程照样能启动、能 spawn 自己、能写沙盒里的日志 —— 看上去"一切正常"，
// 实际上所有私有权限都是空的，于是 registerWindowWithContextID: 被 SpringBoard
// 静默丢弃，屏幕上永远不出现浮条，错误码/异常一个都拿不到。
//
// csops(CS_OPS_ENTITLEMENTS_BLOB) 读的是**内核当前认可的** blob，不是文件里写的那份，
// 所以它是唯一能一锤定音的判断依据。
// ---------------------------------------------------------------------------
static inline NSString *QFEntitlementsXML(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        typedef int (*QFCsopsFn)(pid_t, unsigned int, void *, size_t);
        QFCsopsFn csops = (QFCsopsFn)dlsym(RTLD_DEFAULT, "csops");
        if (!csops) return;
        const size_t size = 64 * 1024;
        unsigned char *buffer = (unsigned char *)calloc(1, size);
        if (!buffer) return;
        // 7 = CS_OPS_ENTITLEMENTS_BLOB
        if (csops(getpid(), 7, buffer, size) == 0) {
            unsigned int magic = 0, length = 0;
            memcpy(&magic, buffer, 4);
            memcpy(&length, buffer + 4, 4);
            magic = ntohl(magic);        // blob 头是大端
            length = ntohl(length);
            // 0xfade7171 = CSMAGIC_EMBEDDED_ENTITLEMENTS，后面紧跟 XML plist
            if (magic == 0xfade7171u && length > 8 && length <= size) {
                NSData *xml = [NSData dataWithBytes:buffer + 8 length:length - 8];
                cached = [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
            }
        }
        free(buffer);
    });
    return cached ?: @"";
}

static inline BOOL QFHasEntitlement(NSString *key) {
    NSString *xml = QFEntitlementsXML();
    if (xml.length == 0 || key.length == 0) return NO;
    return [xml rangeOfString:[NSString stringWithFormat:@"<key>%@</key>", key]].location != NSNotFound;
}

// 沙盒探测：能往 /var/mobile/Library/Logs 落一个空文件，才说明 no-sandbox 真的生效。
// 只靠"日志有内容"是判断不出来的 —— 沙盒没放开时日志会自动落到 App 自己的 Documents 里。
static inline BOOL QFCanWriteSystemPath(void) {
    const char *probe = "/var/mobile/Library/Logs/.qf_probe";
    int fd = open(probe, O_WRONLY | O_CREAT, 0644);
    if (fd < 0) return NO;
    close(fd);
    unlink(probe);
    return YES;
}

static inline NSString *QFEntitlementsSummary(void) {
    if (QFEntitlementsXML().length == 0) return @"读不到 entitlements（csops 失败）";
    return [NSString stringWithFormat:@"platform=%@ sandbox=%@ winHosting=%@ backboard=%@ hid=%@ 系统目录=%@",
            QFHasEntitlement(@"platform-application") ? @"✓" : @"✗",
            QFHasEntitlement(@"com.apple.private.security.no-sandbox") ? @"✓" : @"✗",
            QFHasEntitlement(@"com.apple.springboard.accessibility-window-hosting") ? @"✓" : @"✗",
            QFHasEntitlement(@"com.apple.backboard.client") ? @"✓" : @"✗",
            QFHasEntitlement(@"com.apple.private.hid.client.event-monitor") ? @"✓" : @"✗",
            QFCanWriteSystemPath() ? @"可写" : @"不可写"];
}

static inline double QFReadPong(void) {
    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR(QFPongKey), CFSTR(QFDomainName),
                                                     kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    double stamp = 0.0;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            stamp = [(__bridge NSNumber *)value doubleValue];
        }
        CFRelease(value);
    }
    return stamp;
}
