import Foundation
import UIKit
import QuartzCore
import Darwin

// MARK: - 采样快照

/// 一次采样得到的所有原始值。nil 表示该设备/权限下取不到。
struct MetricsSnapshot {
    var cpu: Double? = nil          // 0...1
    var fps: Double? = nil          // 次/秒
    var upload: Double? = nil       // bytes/s
    var download: Double? = nil     // bytes/s
    var battery: Double? = nil      // 0...1
    var voltage: Double? = nil      // mV
    var current: Double? = nil      // mA，放/充都取绝对值
    var watt: Double? = nil         // W
    var temperature: Double? = nil  // °C

    static let empty = MetricsSnapshot()

    func value(for kind: MetricKind) -> Double? {
        switch kind {
        case .cpu:         return cpu
        case .fps:         return fps
        case .upload:      return upload
        case .download:    return download
        case .battery:     return battery
        case .voltage:     return voltage
        case .current:     return current
        case .watt:        return watt
        case .temperature: return temperature
        }
    }
}

// MARK: - 采样器

/// 所有指标的采集源。线程模型：`start()` / `stop()` 必须在主线程调用，
/// 内部的重活（getifaddrs、host_statistics）同步执行但耗时在微秒级，不会卡主线程。
/// 注意：所有方法只能在主线程调用（Timer / CADisplayLink 都在 main RunLoop 上）。
final class MetricsProvider {

    /// 每次采样回调
    var onUpdate: ((MetricsSnapshot) -> Void)?

    private let store: SettingsStore
    private var timer: Timer?
    private var displayLink: CADisplayLink?
    private var fpsProxy: FPSProxy?

    // 上次采样基线
    private var lastCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var lastNet: (up: UInt64, down: UInt64, at: TimeInterval)?

    // FPS 统计
    private var frameCount: Int = 0
    private var fpsWindowStart: CFTimeInterval = 0
    /// nil = 还没测够一个统计窗口，界面显示「—」而不是编个 60
    private var smoothedFPS: Double?

    init(store: SettingsStore = .shared) {
        self.store = store
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    // MARK: 生命周期

    func start() {
        guard timer == nil else { return }
        lastNet = nil
        lastCPUTicks = nil
        startDisplayLink()

        let t = Timer(timeInterval: max(store.refreshInterval, 0.2), repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        sample()   // 立即出一次值，别让用户看到空条
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        displayLink?.invalidate()
        displayLink = nil
        fpsProxy = nil
        smoothedFPS = nil
        frameCount = 0
    }

    /// 设置变更后重新起定时器（刷新频率改了）
    func restartIfNeeded() {
        guard timer != nil else { return }
        stop()
        start()
    }

    // MARK: FPS

    private func startDisplayLink() {
        let proxy = FPSProxy { [weak self] in
            self?.tickFrame()
        }
        let link = CADisplayLink(target: proxy, selector: #selector(FPSProxy.step))
        // 120Hz 设备上限高，但统计窗口按秒算，不影响结果
        link.add(to: .main, forMode: .common)
        displayLink = link
        fpsProxy = proxy

        frameCount = 0
        fpsWindowStart = CACurrentMediaTime()
    }

    private func tickFrame() {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - fpsWindowStart
        guard elapsed >= 1.0 else { return }

        let raw = Double(frameCount) / elapsed
        // 指数平滑，避免数字乱跳
        smoothedFPS = (smoothedFPS ?? raw) * 0.4 + raw * 0.6
        frameCount = 0
        fpsWindowStart = now
    }

    // MARK: 采样

    private func sample() {
        let now = CACurrentMediaTime()
        var s = MetricsSnapshot.empty

        s.cpu = readCPU()
        if let f = smoothedFPS, f > 0 { s.fps = min(f, 240) }
        s.battery = readBattery()

        let net = readNetwork()
        if let last = lastNet, last.at > 0 {
            let dt = now - last.at
            if dt > 0.05 {
                // 单接口的 ifi_ibytes 是 32 位、会回绕到 0；但我们这里是**多接口求和**，
                // 累加后早已越过 2^32，没法用固定模数补正。所以只做保守判断：
                // 计数变小 = 接口列表变动或某接口归零，把这次增量当作 0，等下一拍恢复。
                let up   = net.up   >= last.up   ? net.up   - last.up   : 0
                let down = net.down >= last.down ? net.down - last.down : 0
                s.upload   = Double(up) / dt
                s.download = Double(down) / dt
            }
        }
        lastNet = (net.up, net.down, now)

        let power = readPower()
        s.voltage = power.voltage
        s.current = power.current
        s.watt = power.watt
        s.temperature = power.temperature

        onUpdate?(s)
    }

    // MARK: - CPU

    /// 全局 CPU 占用：用 host_statistics 读 HOST_CPU_LOAD_INFO 的累计 tick，求差值得占比。
    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        // host_cpu_load_info.cpu_ticks 是 (natural_t × 4)，natural_t == UInt32。
        // 32 位会在约 497 天后回绕，所以下面必须用 &- 做模减。
        let cur = (user: info.cpu_ticks.0,
                   system: info.cpu_ticks.1,
                   idle: info.cpu_ticks.2,
                   nice: info.cpu_ticks.3)

        defer {
            lastCPUTicks = (user: cur.user, system: cur.system, idle: cur.idle, nice: cur.nice)
        }

        guard let prev = lastCPUTicks else { return nil }

        let user   = Double(cur.user   &- prev.user)
        let system = Double(cur.system &- prev.system)
        let idle   = Double(cur.idle   &- prev.idle)
        let nice   = Double(cur.nice   &- prev.nice)

        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        return ((user + system + nice) / total).clamped(to: 0...1)
    }

    // MARK: - 网络

    private func readNetwork() -> (up: UInt64, down: UInt64) {
        var up: UInt64 = 0
        var down: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&addrs) == 0, let head = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }

            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let name = String(cString: ifa.ifa_name)
            // 跳过回环与虚拟隧道，避免统计重复
            if name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("ipsec") { continue }

            guard let dataPtr = ifa.ifa_data else { continue }
            let d = dataPtr.assumingMemoryBound(to: if_data.self).pointee

            // ifi_obytes / ifi_ibytes 在 if_data 里是 u_int32_t（单接口 < 4GB 时不会回绕），
            // 多接口求和用 UInt64 装，安全。注意 obytes = 发出、ibytes = 收到。
            up   += UInt64(d.ifi_obytes)
            down += UInt64(d.ifi_ibytes)
        }
        return (up, down)
    }

    // MARK: - 电池

    private func readBattery() -> Double? {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Double(level).clamped(to: 0...1)
    }

    // MARK: - 电流 / 瓦数 / 温度

    /// 全部走 PowerSampler（dlopen/dlsym），原因见该文件头注释。
    private func readPower() -> (voltage: Double?, current: Double?, watt: Double?, temperature: Double?) {
        let r = PowerSampler.read()
        return (r.voltage, r.current, r.watt, r.temperature)
    }
}

// MARK: - CADisplayLink 代理

/// CADisplayLink 会强引用 target，用独立代理对象避免循环引用。
final class FPSProxy: NSObject {
    private let onStep: () -> Void
    init(_ onStep: @escaping () -> Void) {
        self.onStep = onStep
    }
    @objc func step() { onStep() }
}

// MARK: - 工具

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
