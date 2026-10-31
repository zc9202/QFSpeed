import SwiftUI

// MARK: - 独立 App 模式入口

/// 如果你只是在自己 App 里用悬浮条，这个文件就够了。
/// 需要悬浮在**别的 App 之上**时，看 `Tweak/QFSpeedOverlay.xm`。
@main
struct QFSpeedApp: App {

    @StateObject private var store = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            DemoHostView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onAppear {
                    // 延迟到 window 就绪后再挂，避免 scene 还没 active
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        FloatingWindowManager.shared.show()
                    }
                }
        }
    }
}

// MARK: - 宿主界面

/// 一个假的宿主页：一是证明悬浮条能浮在内容之上，
/// 二是提供手动开关，方便调试。
struct DemoHostView: View {

    @EnvironmentObject private var store: SettingsStore
    @State private var tick: Int = 0

    /// 用 .publish 的常量 publisher 会随 body 重算反复新建，改成 static 只建一次
    private static let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.06, blue: 0.09),
                    Color(red: 0.10, green: 0.08, blue: 0.14)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("QFSpeed")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)

                    Text("悬浮性能条 · 独立 App 宿主")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))

                    statusCard
                    controlsCard
                    notesCard
                }
                .padding(20)
                .padding(.top, 40)
            }
        }
        .onReceive(Self.timer) { _ in tick += 1 }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("状态", systemImage: "waveform.path.ecg")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))

            row("悬浮窗", store.isVisible ? "显示中" : "已隐藏", 
                color: store.isVisible ? .green : .gray)
            row("位置锁定", store.isLocked ? "已锁定" : "可拖动",
                color: store.isLocked ? .orange : .green)
            row("贴边隐藏", store.edgeAutoHide ? "开启" : "关闭",
                color: store.edgeAutoHide ? .blue : .gray)
            row("显示项目", "\(store.visibleMetrics.count) / \(MetricKind.allCases.count)",
                color: .white.opacity(0.8))
            row("运行时长", "\(tick) s", color: .white.opacity(0.8))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var controlsCard: some View {
        VStack(spacing: 10) {
            Button {
                FloatingWindowManager.shared.toggle()
            } label: {
                Label(store.isVisible ? "隐藏悬浮窗" : "显示悬浮窗",
                      systemImage: store.isVisible ? "eye.slash" : "eye")
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(red: 0.30, green: 0.62, blue: 0.95)))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)

            Button {
                // 主界面直接打开设置面板。
                // 之前只能在悬浮条上轻点调出上下文菜单，悬浮条没显示或
                // 点击被手势吞掉时就没有任何入口 —— 这个按钮是硬保险。
                FloatingWindowManager.shared.openSettingsPanel()
            } label: {
                Label("设置面板", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.09)))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .buttonStyle(.plain)

            Button {
                store.isLocked.toggle()
            } label: {
                Label(store.isLocked ? "解锁位置" : "锁定位置",
                      systemImage: store.isLocked ? "lock.open" : "lock")
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.09)))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("调试提示")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))

            bullet("轻点悬浮条 → 上下文菜单（设定面板 / 锁定 / 重置 / 隐藏）")
            bullet("拖动悬浮条 → 移动位置，松手自动吸附屏幕边缘")
            bullet("拖到左右边缘 → 若开启贴边隐藏则半收进屏幕，点一下召回")
            bullet("面板里 8 项开关实时生效，字号 / 缩放 / 不透明度即时预览")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: 小工具

    private func row(_ key: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(key).font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.6))
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4).padding(.top, 7)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
            )
    }
}
