# QFSpeed — 网速 · 性能 · 电量

iOS 悬浮性能条，按你给的两张截图复刻。核心是一个**穿透式 UIWindow + SwiftUI 渲染**的悬浮层，
自带设定面板（8 项指标开关 / 字号 / 缩放 / 定位 / 锁定 / 贴边隐藏）。

```
QFSpeed/
├── project.yml                    XcodeGen 工程定义（一条命令生成 .xcodeproj）
├── Resources/Info.plist
├── Sources/QFSpeed/
│   ├── Settings.swift             设置模型、指标枚举、配色
│   ├── MetricsProvider.swift      CPU / FPS / 网速 / 电池 采样
│   ├── PowerSampler.swift         电流 / 瓦数 / 温度（IOKit dlsym）
│   ├── FloatingBarView.swift      悬浮条本体
│   ├── OverlayRootView.swift      悬浮层根视图 + 拖拽手势
│   ├── FloatingWindowManager.swift 窗口生命周期、定位、命中区域
│   ├── SettingsPanelView.swift    设定面板
│   └── QFSpeedApp.swift           演示 App 入口
├── Tweak/QFSpeedOverlay.xm        Logos 注入模板（注入到宿主 App）
└── preview/index.html             HTML 可交互复刻，可先在这里调参数
```

---

## 先看效果

先开 `preview/index.html`：悬浮条能拖、能点开面板、所有开关实时生效。
参数（字号、缩放、间距）在这里调好之后，再对照改 `FloatingBarView.swift` 里的常量。

---

## 跑起来

需要 macOS + Xcode 15 以上。

```bash
brew install xcodegen
cd QFSpeed
xcodegen generate
open QFSpeed.xcodeproj
```

然后在 Xcode 里填 Team，真机运行。**必须真机**——模拟器没有 `AppleSmartBattery`，
电流 / 瓦数 / 温度会全部显示 `—`（这是设计如此，取不到就显示占位符，不编假数）。

---

## 三种用法

### 1. 独立 App（最简单的验证方式）

直接跑 `QFSpeed` target。悬浮条浮在自己的 App 上，用来调样式够用了。
但注意：**它只能浮在自己 App 上面**，切到别的 App 就看不见了。

### 2. 注入到宿主 App（截图里 `挂载 host UIWindow` 就是这个意思）

想要「在任何 App 上都显示」，有两种路：

**a) Theos Tweak（越狱设备）**

```
Tweak/QFSpeedOverlay.xm
```

把 `Sources/QFSpeed/*.swift` 一起编进 tweak（Theos 支持 Swift），
`%hook SpringBoard` 或 `UIApplication` 的 `didFinishLaunching` 里 `startQFSpeedOverlay()`。

**b) 嵌入式 dylib（非越狱，需重签名工具链）**

把 `FloatingWindowManager` + 视图文件编成 `.dylib`，
用 `insert_dylib` 注入宿主 IPA，再整体重签。这条路要求你自己有开发者证书。

> ⚠️ 我无法在这台设备上编译 Swift，所以上面这套代码是**按 SDK 接口逐个核对过**的，
> 但没有经过真实 `xcodebuild`。第一次编译如果报错，大概率是这两类：
> ① `host_statistics` 的 `host_info_t` 指针转换（不同 SDK 版本签名有差异）
> ② `#Preview` 宏（已用 `#if DEBUG` 包起来，Release 不受影响）
> 把报错贴给我，我直接改。

### 3. 只在 App 内当调试浮层

去掉 `windowScene` 相关代码，用普通的 `UIWindow` 挂在 keyWindow 上即可。
`PassThroughWindow` 的命中逻辑照样有效——它就是为「不吞宿主触摸」写的。

---

## 几个实现上的关键点

### 悬浮窗不会吞掉宿主 App 的点击

这是注入式浮窗最容易翻车的地方。一个铺满全屏的 `UIWindow` 会吃掉底下所有触摸，
宿主 App 就变成"点哪都没反应"。

`PassThroughWindow.hitTest` 的做法是**显式声明可交互区域**：

```swift
override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if fullScreenInteractive { return super.hitTest(point, with: event) }
    let inside = interactiveRegions.contains {
        $0.insetBy(dx: -6, dy: -6).contains(point)
    }
    guard inside else { return nil }   // 区域外 → 放行给宿主
    return super.hitTest(point, with: event)
}
```

没用「`hit.test` 结果是不是 hosting view」这种判断——依赖 SwiftUI 内部实现，
换系统版本就会在某些机型上变成整条点不动。

### 位置用归一化坐标存

`BarAnchor` 存的是 0…1 的比例而不是绝对像素。换设备、转屏、分屏都不会跑偏。
`relayout()` 是唯一的定位入口，`setAnchor` / `nudge` / 旋转回调都汇到它。

### 拖拽松手的时序

如果先清零位移、再改锚点，会看到条子**先弹回原位再飞过去**。正确做法是把这两步
放进同一个无动画 `Transaction` 里提交（互相抵消），再单独给吸附加动画：

```swift
var tx = Transaction(); tx.animation = nil
withTransaction(tx) {
    dragTranslation = .zero
    manager.setAnchor(center: target, in: b)
}
withAnimation(.spring(...)) { manager.snap(in: b) }
```

### 超宽自动收缩

8 项全开 + 12pt 在 iPhone SE 上放不下。`fitScale` 会按可用宽度再乘一个系数
（下限 0.42，再小就看不清了），而不是让内容被裁掉。

### 取不到就显示 `—`

电流 / 瓦数 / 温度依赖 `AppleSmartBattery`，模拟器、部分机型、部分系统版本上根本没有这个节点。
`PowerSampler` 对这些情况一律返回 `nil`，UI 显示 `—`。**不拿 0 或编造值糊弄**。

---

## 采样成本

| 指标 | 方式 | 频率 | 备注 |
|---|---|---|---|
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` | 跟刷新间隔 | 差分算占用率，微秒级 |
| FPS | `CADisplayLink` 计数 | 每帧 | 统计窗口 1s |
| 网速 | `getifaddrs` 求和 | 跟刷新间隔 | 跳过 lo0 / utun / ipsec |
| 电池 | `UIDevice.batteryLevel` | 跟刷新间隔 | 需开 `isBatteryMonitoringEnabled` |
| 电流/瓦数/温度 | IOKit `AppleSmartBattery` | 温度节流 3s | 走 dlsym，避免链接问题 |

默认刷新间隔按截图里的实时感设成 1s，可在面板调。

---

## 和截图的差异（我主动改的地方）

| 截图 | 这里 | 原因 |
|---|---|---|
| `电池 94%` `电流 382mA` `瓦 1.5` | `电池94%` `mA382` `W1.5` | 原图里标签和数值是分开配色的两段文字，但中间塞了空格更宽；HTML 实测缩短 14px 才放得下 8 项 |
| 8 项常常溢出边缘 | 自动 `fitScale` 收缩 | 原图 664pt 宽设备；390pt 设备必须缩 |
| — | `—` 占位 | 取不到值时不留空白，也不显示 0 |

配色取自截图采样（悬浮条各段平均色）：

| 项 | 采样色 | 实际用色 |
|---|---|---|
| CPU | `#4e7990` | 青蓝 |
| FPS | `#75699a` | 紫 |
| 上传 | `#428770` | 绿 |
| 下载 | `#479479` | 青绿 |
| 电池 | `#957942` | 琥珀 |
| 电流 | `#985a7d` | 品红 |
| 瓦数 | `#924e5a` | 正红 |
| 温度 | `#7c4f35` | 橙棕 |

原图色偏暗是因为半透明底 + 叠了宿主内容，实际用色已按不透明度还原到饱和态。
