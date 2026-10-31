import SwiftUI
import Foundation
import Combine

// MARK: - 指标类型

/// 悬浮条上可显示的 8 项指标。rawValue 用作 @AppStorage 的 key 后缀。
enum MetricKind: String, CaseIterable, Identifiable, Codable {
    case cpu, fps, upload, download, battery, voltage, current, watt, temperature

    var id: String { rawValue }

    /// 面板里的中文标题（与截图一致）
    var title: String {
        switch self {
        case .cpu:         return "CPU 占用"
        case .fps:         return "FPS 帧率"
        case .upload:      return "上传速度"
        case .download:    return "下载速度"
        case .battery:     return "电池电量"
        case .voltage:     return "电压"
        case .current:     return "电流"
        case .watt:        return "瓦数"
        case .temperature: return "温度"
        }
    }

    /// 悬浮条上的短标签（图标用 SF Symbol，见 icon）
    var shortLabel: String {
        switch self {
        case .cpu:         return ""
        case .fps:         return "FPS"
        case .upload:      return "↑"
        case .download:    return "↓"
        case .battery:     return ""     // 只要图标，不要文字
        case .voltage:     return "V"
        case .current:     return "mA"
        case .watt:        return "W"
        case .temperature: return "°C"
        }
    }

    var icon: String {
        switch self {
        case .cpu:         return "cpu"
        case .fps:         return "speedometer"
        case .upload:      return "arrow.up.circle.fill"
        case .download:    return "arrow.down.circle.fill"
        case .battery:     return "battery.75"
        case .voltage:     return "gauge.medium"             // iOS 14+
        case .current:     return "bolt.horizontal"
        case .watt:        return "bolt"
        case .temperature: return "thermometer.medium"
        }
    }

    /// 统一单色 —— 截图里是白底深色细线图标，所有项同一个颜色，
    /// 靠图形区分而不是靠色相。悬浮条本身是深色半透明底，
    /// 所以用接近白的高亮度中性色保证对比度。
    var tint: Color { Color.white.opacity(0.92) }

}

// MARK: - 位置模型

/// 悬浮窗的锚点定义。用归一化坐标（0...1）存，换设备/旋转自动适配。
struct BarAnchor: Codable, Equatable {
    /// 相对屏幕宽度的比例，代表**中心点**
    var x: CGFloat = 0.5
    /// 相对屏幕高度的比例，代表**中心点**
    var y: CGFloat = 0.20

    static let center = BarAnchor(x: 0.5, y: 0.20)

    func clamped() -> BarAnchor {
        BarAnchor(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// 微调步长档位（对应截图里的「微调」按钮）
///
/// 用 Double 做 rawValue 而不是 CGFloat：CGFloat 是结构体，虽然能字面量初始化，
/// 但作为 RawRepresentable 的 RawValue 在部分 Swift 版本上不稳定，
/// Double 是纯编译期可保证的，这里换算一次而已。
enum NudgeStep: Double, CaseIterable, Identifiable {
    case fine = 1      // 1pt
    case normal = 8    // 8pt

    var id: Double { rawValue }
    var points: CGFloat { CGFloat(rawValue) }
}

// MARK: - 全局设置

/// 所有可调参数。用 ObservableObject 而非 @AppStorage 直连，
/// 是因为注入模式下跨宿主进程也要能读到同一份配置 —— 见 SettingsStore 的 suiteName。
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    /// 注入模式建议改成一个 App Group，让宿主进程能读到你的 App 写入的配置：
    /// static let suiteName = "group.com.yourteam.qfspeed"
    private static let suiteName: String? = nil

    private let defaults: UserDefaults

    // MARK: 显示项目（8 项开关）
    @Published var enabled: [MetricKind: Bool] {
        didSet { persistEnabled() }
    }
    /// 用户手动排序后的顺序
    @Published var order: [MetricKind] {
        didSet { defaults.set(order.map(\.rawValue), forKey: "order") }
    }

    // MARK: 外观
    @Published var fontSize: CGFloat = 12 {
        didSet { defaults.set(Double(fontSize), forKey: "fontSize") }
    }
    /// 整体缩放，截图值 0.92x
    @Published var scale: CGFloat = 0.92 {
        didSet { defaults.set(Double(scale), forKey: "scale") }
    }
    @Published var useIcon: Bool = true {    // 默认用图标（电池/电压/电流/温度都带符号）
        didSet { defaults.set(useIcon, forKey: "useIcon") }
    }
    @Published var backgroundOpacity: CGFloat = 0.55 {
        didSet { defaults.set(Double(backgroundOpacity), forKey: "backgroundOpacity") }
    }

    // MARK: 位置
    @Published var anchor: BarAnchor = .center {
        didSet { persistAnchor() }
    }
    /// 锁定位置：开启后禁止拖动，只能用微调按钮移动
    @Published var isLocked: Bool = false {
        didSet { defaults.set(isLocked, forKey: "isLocked") }
    }
    /// 贴边隐藏：拖到边缘后半收进屏幕，露出 6pt 把手
    @Published var edgeAutoHide: Bool = false {
        didSet { defaults.set(edgeAutoHide, forKey: "edgeAutoHide") }
    }
    /// 外部请求打开设置面板的信号。
    /// 用自增计数而不是 Bool：连续点两次按钮也要能重新打开，
    /// Bool 从 true 再置 true 不会触发 onChange。
    @Published var panelRequestTick: Int = 0

    @Published var isVisible: Bool = true {
        didSet { defaults.set(isVisible, forKey: "isVisible") }
    }

    // MARK: 刷新频率
    @Published var refreshInterval: Double = 1.0 {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval") }
    }

    private init() {
        let d = SettingsStore.suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = d

        // 默认全部显示
        var e: [MetricKind: Bool] = [:]
        for k in MetricKind.allCases { e[k] = true }
        if let raw = d.dictionary(forKey: "enabled") {
            for (key, val) in raw {
                guard let k = MetricKind(rawValue: key) else { continue }
                // UserDefaults 存的是 NSNumber / __NSCFBoolean，
                // 整体 as? [String: Bool] 转换在部分系统版本上会失败，逐项解才可靠
                if let n = val as? NSNumber { e[k] = n.boolValue }
            }
        }
        self.enabled = e

        if let raw = d.array(forKey: "order") as? [String] {
            let parsed = raw.compactMap(MetricKind.init(rawValue:))
            // 补上后续版本新增但旧配置里没有的项
            let missing = MetricKind.allCases.filter { !parsed.contains($0) }
            self.order = parsed + missing
        } else {
            // 顺序：CPU / FPS / 上传 / 下载 / 电量 / 电压 / 电流 / 瓦 / 温度
            self.order = MetricKind.allCases
        }

        self.fontSize = (d.object(forKey: "fontSize") as? Double).map { CGFloat($0) } ?? 12
        self.scale    = (d.object(forKey: "scale") as? Double).map { CGFloat($0) } ?? 0.92
        // 用户没存过时默认 true；存过就尊重用户选择
        self.useIcon  = d.object(forKey: "useIcon") as? Bool ?? true
        self.backgroundOpacity = (d.object(forKey: "backgroundOpacity") as? Double).map { CGFloat($0) } ?? 0.55
        self.isLocked = d.bool(forKey: "isLocked")
        self.edgeAutoHide = d.bool(forKey: "edgeAutoHide")
        self.isVisible = d.object(forKey: "isVisible") as? Bool ?? true
        self.refreshInterval = (d.object(forKey: "refreshInterval") as? Double) ?? 1.0

        if let data = d.data(forKey: "anchor"),
           let a = try? JSONDecoder().decode(BarAnchor.self, from: data) {
            self.anchor = a
        }
    }

    // MARK: 便捷访问

    /// 当前生效、且按用户顺序排好的指标
    var visibleMetrics: [MetricKind] {
        order.filter { enabled[$0] == true }
    }

    func toggle(_ kind: MetricKind) {
        enabled[kind] = !(enabled[kind] ?? true)
    }

    // MARK: 持久化

    private func persistEnabled() {
        let raw = Dictionary(uniqueKeysWithValues: enabled.map { ($0.key.rawValue, $0.value) })
        defaults.set(raw, forKey: "enabled")
    }

    private func persistAnchor() {
        if let data = try? JSONEncoder().encode(anchor) {
            defaults.set(data, forKey: "anchor")
        }
    }
}
