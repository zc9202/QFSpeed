import UIKit
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import SwiftUI

/// 跨 App 常驻（非越狱）实现 —— 系统画中画，移植自 2.1.6 的 QFPiPBar。
///
/// 上一版为什么不生效（这次修的就是这些）：
///   1. `prepare()` 只建了渲染层，**从来没激活过 AVAudioSession**。
///      系统判定「这段内容在播放」的唯一依据就是音频会话是 active 的，
///      没有它，`canStartPictureInPictureAutomaticallyFromInline` 永远不会触发。
///   2. 没有监听退到后台的通知，全靠系统自己猜时机，猜不中就什么都不发生。
///   3. 帧率 1fps 太稀，系统有时认为画面已停。
///
/// 现在：prepare 就把静音音轨跑起来（会话常亮），并在 `willResignActive` /
/// `didEnterBackground` 主动调一次 start，双保险。
final class PiPBarHost: NSObject {

    static let shared = PiPBarHost()

    /// 画布尺寸决定 PiP 窗口的宽高比。
    /// 按浮条自身比例算，PiP 窗口就是一条细长浮条（不会上下带黑边）。
    private var canvasWidth: CGFloat = 480
    private var canvasHeight: CGFloat = 150

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var contentSource: AVPictureInPictureController.ContentSource?
    private var anchorView: UIView?
    private var renderHost: UIHostingController<FloatingBarView>?
    private var feedTimer: Timer?
    private var timebase: CMTimebase?
    private var keepAlivePlayer: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var possibleObservation: NSKeyValueObservation?
    private var lastBuffer: CVPixelBuffer?
    private var lastRenderAt: TimeInterval = 0
    private var dirty = true

    private var snapshot: MetricsSnapshot = .empty
    private var metrics: [MetricKind] = []
    private var fontSize: CGFloat = 12
    private var useIcon = true
    private var backgroundOpacity: CGFloat = 0.55

    private(set) var isPrepared = false
    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var audioActive = false
    private(set) var frameCount: Int64 = 0
    private var startRetries = 0
    /// 用户明确关掉 PiP 后就不再自动拉起，否则关了又弹很烦
    private(set) var stopRequested = false

    /// PiP 起/停时通知外部（FloatingWindowManager 用它把 App 内那层浮窗暂时藏起来，
    /// 否则同一块屏上会出现两条一模一样的浮条）。
    var onActiveChanged: ((Bool) -> Void)?

    private override init() { super.init() }

    // MARK: - 对外

    func update(metrics: [MetricKind],
                snapshot: MetricsSnapshot,
                fontSize: CGFloat,
                useIcon: Bool,
                backgroundOpacity: CGFloat) {
        self.metrics = metrics
        self.snapshot = snapshot
        self.fontSize = fontSize
        self.useIcon = useIcon
        self.backgroundOpacity = backgroundOpacity
        dirty = true
    }

    /// 建渲染层 + 把静音音轨跑起来，并**立即**在前台拉起画中画。
    /// 拉起来以后切到任何 App 都留在那儿，回本 App 时系统自动收回。
    func prepare() {
        guard !SpringBoardWindowHost.shared.wasInjected else { return }
        if isPrepared {
            startAudioKeepAlive()   // 会话可能被系统回收，补一次
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "这台设备不支持画中画"
            return
        }
        guard let host = Self.anchorHostView() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.prepare()
            }
            return
        }

        // 渲染层必须真在视图层级里，且尺寸非零；2×2 是参考实现验证过能通过系统校验的尺寸。
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        anchor.backgroundColor = .black
        anchor.isUserInteractionEnabled = false
        host.addSubview(anchor)

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = anchor.bounds
        layer.videoGravity = .resizeAspect
        anchor.layer.addSublayer(layer)

        var tb: CMTimebase?
        let st = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                                 sourceClock: CMClockGetHostTimeClock(),
                                                 timebaseOut: &tb)
        if st == noErr, let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            layer.controlTimebase = tb
            timebase = tb
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        anchorView = anchor
        displayLayer = layer
        contentSource = source
        pipController = controller
        isPrepared = true
        lastError = nil

        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            // 只是让诊断卡片能实时反映出来，不在这里自动 start
            self?.dirty = true
        }

        installObservers()
        startFeedTimer()
        startAudioKeepAlive()   // ← 上一版缺的就是这一句
        NSLog("[QFSpeed] 画中画常驻已准备")
    }

    /// 主动浮起。会在 willResignActive（按 Home / 切 App，尚未挂起）时被调到。
    ///
    /// 失败的真实原因链（这次一并修了）：
    ///   1. 没有后台音频 → 一退后台就被挂起，定时器和渲染全停，PiP 根本来不及启动；
    ///   2. 音频会话没激活 → 系统认为「没有内容在播放」，直接拒绝 possible；
    ///   3. 帧太稀（1fps）→ 渲染层没进 readyForDisplay，start 被 -1003 扇回来。
    func start() {
        stopRequested = false
        prepare()
        guard let controller = pipController, isPrepared else { return }
        if controller.isPictureInPictureActive {
            isRunning = true
            return
        }
        guard controller.isPictureInPicturePossible else {
            if startRetries < 5 {
                startRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.start()
                }
            } else {
                lastError = "画中画暂不可用（渲染层未就绪）"
            }
            return
        }
        startAudioKeepAlive()
        controller.startPictureInPicture()
    }
    func stop() {
        startRetries = 0
        if let c = pipController, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        }
        isRunning = false
    }

    func teardown() {
        stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        feedTimer?.invalidate()
        feedTimer = nil
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        audioActive = false
        anchorView?.removeFromSuperview()
        anchorView = nil
        renderHost = nil
        displayLayer = nil
        contentSource = nil
        pipController = nil
        possibleObservation = nil
        isPrepared = false
    }

    var statusText: String {
        if SpringBoardWindowHost.shared.wasInjected { return "系统级（注入 SpringBoard）" }
        if !isPrepared { return lastError ?? "未准备" }
        if let c = pipController, c.isPictureInPictureActive { return "画中画常驻中（可拖到任意位置）" }
        if let e = lastError { return e }
        return audioActive ? "已准备（切后台自动浮起）" : "已准备（音频未激活）"
    }

    /// 诊断卡片用：把 PiP 每一步的判定都摊开，真机上不用猜。
    var detailRows: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("画中画支持", AVPictureInPictureController.isPictureInPictureSupported() ? "是" : "否"))
        if let c = pipController {
            rows.append(("pip possible", c.isPictureInPicturePossible ? "是" : "否"))
            rows.append(("pip active", c.isPictureInPictureActive ? "是" : "否"))
            rows.append(("自动浮起", c.canStartPictureInPictureAutomaticallyFromInline ? "开" : "关"))
        } else {
            rows.append(("pip", "未创建"))
        }
        rows.append(("音频会话", audioActive ? "active" : "未激活"))
        if let l = displayLayer {
            rows.append(("渲染层", l.status == .rendering ? "rendering"
                         : (l.status == .failed ? "failed" : "idle")))
        }
        rows.append(("已喂帧", "\(frameCount) 帧"))
        return rows
    }

    // MARK: - 后台时机

    private func installObservers() {
        let nc = NotificationCenter.default
        // 即将失去活跃状态（按 Home / 切 App）—— 这是拉起画中画最可靠的时机
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            guard SettingsStore.shared.isVisible, !self.stopRequested else { return }
            NSLog("[QFSpeed] willResignActive → 尝试浮起画中画")
            self.start()
        })
        // 彻底进后台再兜一次（自动浮起失败时用）
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            guard SettingsStore.shared.isVisible, !self.stopRequested else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let c = self.pipController, !c.isPictureInPictureActive else { return }
                NSLog("[QFSpeed] didEnterBackground → 补一次浮起")
                self.start()
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.startAudioKeepAlive()
        })
    }

    // MARK: - 锚点宿主

    private static func anchorHostView() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.sorted { a, b in
            let av = a.activationState == .foregroundActive ? 0 : 1
            let bv = b.activationState == .foregroundActive ? 0 : 1
            return av < bv
        }
        for scene in ordered {
            for w in scene.windows where !w.isHidden && w.alpha > 0.01 {
                if let v = w.rootViewController?.view { return v }
                return w
            }
        }
        for w in UIApplication.shared.windows where !w.isHidden {
            if let v = w.rootViewController?.view { return v }
        }
        return nil
    }

    // MARK: - 喂帧

    private func startFeedTimer() {
        feedTimer?.invalidate()
        // 4fps：既不至于让系统认为画面停了，也不至于把主线程画爆。
        // 图像本身只在数据变化 / 超过 1 秒时才重绘，其余时候重复喂同一帧。
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        feedTimer = timer
        tick()
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        if dirty || lastBuffer == nil || now - lastRenderAt > 1.0 {
            if let image = renderBarImage(), let buffer = pixelBuffer(from: image) {
                lastBuffer = buffer
                lastRenderAt = now
                dirty = false
            }
        }
        if let buffer = lastBuffer {
            enqueue(buffer)
        }
    }
    private func renderBarImage() -> CGImage? {
        let metrics = self.metrics.isEmpty ? SettingsStore.shared.visibleMetrics : self.metrics
        let bar = FloatingBarView(
            metrics: metrics,
            snapshot: snapshot,
            fontSize: fontSize,
            useIcon: useIcon,
            backgroundOpacity: Double(backgroundOpacity),
            useMaterial: false   // 离屏渲染没有 backdrop 可模糊，会出平灰
        )

        let host: UIHostingController<FloatingBarView>
        if let h = renderHost {
            h.rootView = bar
            host = h
        } else {
            host = UIHostingController(rootView: bar)
            host.view.backgroundColor = .clear
            host.view.isOpaque = false
            renderHost = host
        }
        let size = host.sizeThatFits(in: CGSize(width: 4096, height: 4096))
        guard size.width > 1, size.height > 1 else { return nil }

        // 画布比例跟浮条走：PiP 窗口就是一条浮条本身，而不是「浮条 + 黑边」。
        // 只在首次（或字号大幅变化）时重算，避免视频尺寸每帧抖动。
        let ratio = size.height / size.width
        let want = max(72, min(360, (canvasWidth * ratio).rounded()))
        if abs(want - canvasHeight) > 8 {
            canvasHeight = want
            NSLog("[QFSpeed] 画布调整为 %.0f×%.0f", canvasWidth, canvasHeight)
        }

        let s = canvasWidth / size.width
        if host.view.bounds.size != size {
            host.view.bounds = CGRect(origin: .zero, size: size)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasWidth, height: canvasHeight),
                                               format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
            // layer.render(in:) 不认 layer 自己的 transform，缩放只能压在 CTM 上
            cg.translateBy(x: canvasWidth / 2, y: canvasHeight / 2)
            cg.scaleBy(x: s, y: s)
            cg.translateBy(x: -size.width / 2, y: -size.height / 2)
            host.view.layer.render(in: cg)
        }
        return image.cgImage
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         image.width,
                                         image.height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        guard let ctx = CGContext(
            data: base,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        guard let layer = displayLayer else { return }
        if layer.status == .failed { layer.flush() }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        guard layer.isReadyForMoreMediaData else { return }   // 队列没消化完就别塞

        frameCount += 1
        let pts = CMTime(value: frameCount, timescale: 4)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 4),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: buffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        CMSetAttachment(sample,
                        key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        layer.enqueue(sample)
    }

    // MARK: - 保活音频（关键）

    /// 系统判断「可以画中画」的前提是内容在播放；对 sample buffer 层来说，
    /// 唯一可靠的信号就是音频会话 active + 有音轨在跑。所以这里必须常开。
    /// - Parameter allowMixing: 首次用可混音（不打断用户音乐）；
    ///   重试时改成独占 —— 部分系统版本里可混音会话会被判成
    ///   「没有主音频会话」而拒绝启动 PiP（这正是 2.1.6 踩到的坑）。
    private func startAudioKeepAlive(allowMixing: Bool = true) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback,
                                    mode: .moviePlayback,
                                    options: allowMixing ? [.mixWithOthers] : [])
            try session.setActive(true)
            audioActive = true
        } catch {
            audioActive = false
            lastError = "音频会话失败：\(error.localizedDescription)"
            NSLog("[QFSpeed] 音频会话失败 %@", String(describing: error))
        }
        if let p = keepAlivePlayer {
            p.play()
            return
        }
        do {
            let url = try Self.silentWavURL()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            keepAlivePlayer = player
        } catch {
            NSLog("[QFSpeed] 静音轨失败 %@", String(describing: error))
        }
    }

    private static func silentWavURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qfspeed-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 8000
        let frames = sampleRate
        let dataBytes = frames * 2
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2))
        le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8))
        le32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))
        try d.write(to: url)
        return url
    }
}

// MARK: - 代理

extension PiPBarHost: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[QFSpeed] 画中画即将浮起")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isRunning = true
        lastError = nil
        startRetries = 0
        onActiveChanged?(true)
        NSLog("[QFSpeed] 画中画已浮起（可拖到任意位置）")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isRunning = false
        // 两种「停止」要分开：用户在后台点 PiP 窗口的关闭键 = 真想关；
        // 用户回到本 App 被系统自动收回 = 不能当成关闭，否则状态就假了。
        let userClosed = UIApplication.shared.applicationState == .background
        if userClosed {
            stopRequested = true
            NSLog("[QFSpeed] 用户关闭了画中画")
        }
        onActiveChanged?(false)
        NSLog("[QFSpeed] 画中画已收起（userClosed=\(userClosed)）")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        let ns = error as NSError
        isRunning = false
        NSLog("[QFSpeed] 画中画启动失败 %@ %d %@", ns.domain, ns.code, ns.localizedDescription)
        // AVSampleBufferDisplayLayer 源的已知毛病：首次 start 会失败，紧接着再试通常就成了。
        // 重试时切到「独占」音频会话（见 startAudioKeepAlive 注释）。
        if startRetries < 3 {
            startRetries += 1
            startAudioKeepAlive(allowMixing: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.start()
            }
            return
        }
        lastError = "画中画启动失败 \(ns.domain) \(ns.code)"
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }
}

extension PiPBarHost: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // 无限时长 = 直播语义，系统不显示进度条、也不会自己暂停。
        // 起点必须是 0 而不是 negativeInfinity —— 后者在部分系统版本上会让
        // 控制器判定「时长非法」直接拒绝启动。
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
