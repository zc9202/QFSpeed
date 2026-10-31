import SwiftUI

// MARK: - 设定面板

/// 按截图 2 的信息层次还原：
/// 标题区 → 显示项目（8 项开关）→ 外观（字号 / 缩放）→ 位置调节（中心 / 微调 / 自由移动）
/// → 底部 4 动作（锁定 / 重置 / 贴边隐藏 / 隐藏悬浮窗）+ 关闭面板 + 说明脚注
struct SettingsPanelView: View {

    @ObservedObject var store: SettingsStore
    /// 只用于算面板最大高度（几何变化要能触发重绘）。位置计算一律走 manager。
    let bounds: CGSize
    var onClose: () -> Void

    @State private var nudgeStep: NudgeStep = .normal

    private var manager: FloatingWindowManager { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                section("显示项目") { displaySection }
                section("外观") { appearanceSection }
                section("位置调节") { positionSection }
                actionSection
                footnote
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: max(bounds.height * 0.78, 360))
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .environment(\.colorScheme, .dark)
    }

    // MARK: 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("QFSpeed")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            Text("网速 · 性能 · 电量")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))

            // 真实挂载状态：托管成功才是系统级（退出 App 也在），
            // 失败则是普通 UIWindow（只在本 App 内可见）。
            // 之前这个位置写死 "lv=0"，看不出到底有没有生效。
            HStack(spacing: 6) {
                Image(systemName: hostState.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(hostState.title)
                if let extra = hostState.detail {
                    Text(extra)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(hostState.color)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }

    // MARK: 分区容器

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // tracking 是 Text 专有的，必须先于任何返回 some View 的修饰符
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.42))

            content()
        }
        .padding(.bottom, 20)
    }

    // MARK: 显示项目

    private var displaySection: some View {
        VStack(spacing: 0) {
            ForEach(store.order) { kind in
                metricRow(kind)
                if kind != store.order.last {
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(rowBackground)
    }

    private var hostState: (icon: String, title: String, detail: String?, color: Color) {
        let h = SpringBoardWindowHost.shared
        if h.isHosted {
            // 托管成功后再探一次 remote 状态：只有 SpringBoard 真正接管渲染，
            // 本 App 退出后才不会消失
            let remote = SpringBoardWindowHost.shared.isRemoteActive
            return ("checkmark.seal.fill",
                    "SpringBoard 托管",
                    remote ? "远程渲染 · 系统级" : "已托管（remote 未激活）",
                    Color(red: 0.42, green: 0.88, blue: 0.62))
        }
        if let reason = h.failureReason {
            return ("exclamationmark.triangle.fill", "托管失败", reason,
                    Color(red: 0.98, green: 0.72, blue: 0.30))
        }
        return ("window.ceiling", "普通 UIWindow", "仅本 App",
                Color.white.opacity(0.38))
    }

    private func metricRow(_ kind: MetricKind) -> some View {
        let isOn = store.enabled[kind] ?? true
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { store.toggle(kind) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: kind.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? kind.tint : Color.white.opacity(0.25))
                    .frame(width: 20)

                Text(kind.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.42))

                Spacer(minLength: 8)

                // 用圆点勾选而非系统 Toggle：截图是紧凑列表，不是 Settings 那种大开关
                ZStack {
                    Circle()
                        .fill(isOn ? kind.tint : Color.white.opacity(0.12))
                        .frame(width: 21, height: 21)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.75))
                    }
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 外观

    private var appearanceSection: some View {
        VStack(spacing: 14) {
            sliderRow(
                title: "字体大小",
                valueText: String(format: "%.0fpt", store.fontSize),
                value: Binding(
                    get: { store.fontSize },
                    set: { store.fontSize = $0 }
                ),
                range: 9...20,
                step: 1
            )

            sliderRow(
                title: "整体缩放",
                valueText: String(format: "%.2fx", store.scale),
                value: Binding(
                    get: { store.scale },
                    set: { store.scale = $0 }
                ),
                range: 0.6...1.6,
                step: 0.01
            )

            HStack {
                Text("显示图标")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.useIcon },
                    set: { store.useIcon = $0 }
                ))
                .labelsHidden()
                .tint(Color(red: 0.36, green: 0.72, blue: 0.98))
            }

            sliderRow(
                title: "背景不透明度",
                valueText: String(format: "%.0f%%", store.backgroundOpacity * 100),
                value: Binding(
                    get: { store.backgroundOpacity },
                    set: { store.backgroundOpacity = $0 }
                ),
                range: 0.15...0.95,
                step: 0.01
            )
        }
        .padding(14)
        .background(rowBackground)
    }

    private func sliderRow(
        title: String,
        valueText: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                Spacer()
                Text(valueText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Slider(value: value, in: range, step: step)
                .tint(Color(red: 0.36, green: 0.72, blue: 0.98))
        }
    }

    // MARK: 位置调节

    private var positionSection: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                nudgeButton("chevron.up", "上移") {
                    manager.nudge(dx: 0, dy: -nudgeStep.points, in: manager.currentBounds)
                }

                HStack(spacing: 6) {
                    nudgeButton("chevron.left", "左移") {
                        manager.nudge(dx: -nudgeStep.points, dy: 0, in: manager.currentBounds)
                    }

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            manager.resetPosition(in: manager.currentBounds)
                        }
                    } label: {
                        Text("中心")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 62, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                            .foregroundStyle(Color.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)

                    nudgeButton("chevron.right", "右移") {
                        manager.nudge(dx: nudgeStep.points, dy: 0, in: manager.currentBounds)
                    }
                }

                nudgeButton("chevron.down", "下移") {
                    manager.nudge(dx: 0, dy: nudgeStep.points, in: manager.currentBounds)
                }
            }

            HStack(spacing: 8) {
                Text("微调步长")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Picker("微调步长", selection: $nudgeStep) {
                    Text("1pt").tag(NudgeStep.fine)
                    Text("8pt").tag(NudgeStep.normal)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            Divider().overlay(Color.white.opacity(0.06))

            Text(store.isLocked
                 ? "位置已锁定 · 只能用微调按钮移动"
                 : "自由移动（直接拖动悬浮条）")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(rowBackground)
    }

    private func nudgeButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 44, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .foregroundStyle(Color.white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: 底部动作

    private var actionSection: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                actionButton(
                    store.isLocked ? "lock.fill" : "lock.open",
                    store.isLocked ? "已锁定" : "锁定位置",
                    active: store.isLocked
                ) {
                    withAnimation(.easeOut(duration: 0.2)) { store.isLocked.toggle() }
                }

                actionButton("arrow.counterclockwise", "重置位置") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        manager.resetPosition(in: manager.currentBounds)
                    }
                }
            }

            HStack(spacing: 9) {
                actionButton(
                    "sidebar.left",
                    "贴边隐藏",
                    active: store.edgeAutoHide
                ) {
                    withAnimation(.easeOut(duration: 0.2)) { store.edgeAutoHide.toggle() }
                }

                actionButton("eye.slash", "隐藏悬浮窗", destructive: true) {
                    manager.hide()
                }
            }

            Button {
                onClose()
            } label: {
                Text("关闭面板")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.white.opacity(0.11))
                    )
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
        }
        .padding(.bottom, 14)
    }

    private func actionButton(
        _ icon: String,
        _ title: String,
        active: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        active
                        ? Color(red: 0.36, green: 0.72, blue: 0.98).opacity(0.22)
                        : Color.white.opacity(0.07)
                    )
            )
            .foregroundStyle(
                destructive
                ? Color(red: 1.0, green: 0.45, blue: 0.42)
                : (active ? Color(red: 0.5, green: 0.82, blue: 1.0) : Color.white.opacity(0.82))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 脚注

    private var footnote: some View {
        Text("「锁定位置」开启后悬浮条无法拖动，只能靠定位按钮 / 微调移动；关闭则可在任意位置自由拖动。")
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.32))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 背景

    private var panelBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.94))
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )
    }
}
