import SwiftUI

// MARK: - 悬浮条本体

/// 单行胶囊条，按 `metrics` 顺序横向排布 8 项彩色指标。
/// 纯展示视图，不含手势 —— 拖动/点击由 OverlayRootView 统一处理。
struct FloatingBarView: View {

    let metrics: [MetricKind]
    let snapshot: MetricsSnapshot
    let fontSize: CGFloat
    let useIcon: Bool
    let backgroundOpacity: Double

    var body: some View {
        HStack(spacing: fontSize * 0.38) {
            if metrics.isEmpty {
                Text("无显示项")
                    .font(.system(size: fontSize * 0.9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            } else {
                ForEach(metrics) { kind in
                    item(kind)
                    if kind != metrics.last { divider }
                }
            }
        }
        .padding(.horizontal, fontSize * 0.67)
        .padding(.vertical, fontSize * 0.42)
        .background(background)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
        .fixedSize()
    }

    // MARK: 单项

    private func item(_ kind: MetricKind) -> some View {
        HStack(spacing: fontSize * 0.22) {
            if useIcon {
                Image(systemName: iconName(for: kind))
                    .font(.system(size: fontSize * 0.95, weight: .semibold))
                    .foregroundStyle(kind.tint)
            } else if !kind.shortLabel.isEmpty {
                // CPU / 电池不写标签：CPU 只显示百分比，电池只要图标（shortLabel 为空自然跳过）
                Text(kind.shortLabel)
                    .font(.system(size: fontSize * 0.90, weight: .medium, design: .rounded))
                    .foregroundStyle(kind.tint.opacity(0.95))
            }

            Text(formatted(kind))
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white)
                .monospacedDigit()
        }
    }

    /// 电池图标跟着电量走（battery.0 / .25 / .50 / .75 / .100 都是 iOS 13+ 符号），
    /// 其余指标用 MetricKind 里的固定符号。
    private func iconName(for kind: MetricKind) -> String {
        guard kind == .battery, let level = snapshot.battery else { return kind.icon }
        switch level {
        case ..<0.13:  return "battery.0"
        case ..<0.38:  return "battery.25"
        case ..<0.63:  return "battery.50"
        case ..<0.88:  return "battery.75"
        default:       return "battery.100"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 0.5, height: fontSize * 1.05)
    }

    private var background: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
        }
    }

    // MARK: 数值格式化

    private func formatted(_ kind: MetricKind) -> String {
        guard let v = snapshot.value(for: kind) else { return "—" }

        switch kind {
        case .cpu:         return String(format: "%.0f%%", v * 100)
        case .fps:         return String(format: "%.0f", v)
        case .upload, .download: return Self.byteRate(v)
        case .battery:     return String(format: "%.0f%%", v * 100)
        // 单位跟着数值走，和截图一致：3.72V / 233mA / 0.9W / 37.5
        case .voltage:     return String(format: "%.2fV", v / 1000.0)   // mV → V
        case .current:     return String(format: "%.0fmA", v)
        case .watt:        return String(format: "%.1fW", v)
        case .temperature: return String(format: "%.1f", v)
        }
    }

    /// 字节速率。截图里是 "16B" / "39B" 这种极短形式，所以 KB 以上才带小数
    static func byteRate(_ bytesPerSec: Double) -> String {
        let b = max(bytesPerSec, 0)
        if b < 1024 {
            return String(format: "%.0fB", b)
        } else if b < 1024 * 1024 {
            return String(format: "%.0fK", b / 1024)
        } else if b < 1024 * 1024 * 1024 {
            return String(format: "%.1fM", b / 1024 / 1024)
        } else {
            return String(format: "%.2fG", b / 1024 / 1024 / 1024)
        }
    }
}
