import UIKit
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import SwiftUI

/// 跨 App 常驻 + 全局拖动的**非越狱**实现（移植自 2.1.6 的 QFPiPBar）。
///
/// 为什么必须有这一层：
///   App 自己的 UIWindow 一退到后台就失去合成权，这是系统物理限制，不是 bug。
///   `SBSAccessibilityWindowHostingController` 那条托管路在真机上被证死过：
///   注册成功、层级够高，屏幕上依然什么都没有。
///   1.zip 里 2.1.6 给出的唯一「不越狱也能跨 App 常驻」的路径就是画中画：
///   由**系统**合成 PiP 窗口，浮在任意 App 之上，而且用户可以随手把它拖到屏幕任何位置，
///   系统还会记住位置。这正是「全局拖动 + 常驻显示」能落地的那条路。
///
/// 样式怎么保持不变：
///   不另画一套 UI。直接把 App 内同一个 `FloatingBarView` 渲染成位图，
///   每秒喂进 AVSampleBufferDisplayLayer —— 字号、间距、配色、圆角、图标全部与 App 内一致。
///
/// 注入 SpringBoard（TrollFools / deb）时不需要它：那条路是真的系统级窗口，会自动跳过。
final class PiPBarHost: NSObject {

    static let shared = PiPBarHost()

    /// 画布宽高比决定 PiP 窗口比例。2.5:1 接近横条，字又不会太小（沿用 2.1.6 的取值）。
    private let canvasWidth: CGFloat = 480
    private let canvasHeight: CGFloat = 192

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var anchorView: UIView?
    private var feedTimer: Timer?
    private var timebase: CMTimebase?
    private var keepAlivePlayer: AVAudioPlayer?

    /// 当前要画的快照，由 OverlayRootView 每次采样后推过来
    private var snapshot: MetricsSnapshot = .empty
    private var metrics: [MetricKind] = []
    private var fontSize: CGFloat = 12
    private var useIcon = true
    private var backgroundOpacity: CGFloat = 0.55

    private(set) var isPrepared = false
    private(set) var isRunning = false
    private(set) var lastError: String?
    private var startRetries = 0
    private var frameIndex: Int64 = 0

    private override init() { super.init() }

    // MARK: - 对外

    /// 把最新的显示内容推给常驻层（与 App 内浮条同一份数据、同一个视图）
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
        guard isPrepared else { return }
        renderFrame()
    }

    /// 准备渲染层。真正「浮起来」由系统在 App 进后台时自动完成。
    func prepare() {
        guard !SpringBoardWindowHost.shared.wasInjected else {
            // 注入形态已经是真的系统级窗口，不需要画中画
            return
        }
        guard !isPrepared else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "这台设备不支持画中画"
            return
        }
        guard let host = Self.anchorHostView() else {
            // 窗口还没就绪，稍后重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.prepare()
            }
            return
        }

        // 渲染层必须真的挂在视图层级里（hidden / alpha 0 会让 isPictureInPicturePossible 变 false），
        // 所以塞一个 2x2 的锚点：用户看不见，系统认为它在渲染。
        let anchor = UIView(frame: CGRect(x: 2, y: 2, width: 2, height: 2))
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
        } else {
            NSLog("[QFSpeed] 建 timebase 失败 status=%d", st)
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // 用户按 Home / 切到别的 App 时自动浮起来，不必先回本 App 点按钮。
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // 不设 requiresLinearPlayback：配合无限时长（直播语义）它是多余的，
        // 而首次启动失败（PGPegasusErrorDomain -1003）往往就出在这种多余配置上。

        // 提前喂帧：让渲染层在系统拉起 PiP 之前就 readyForDisplay。
        // 层没真正开始渲染时调 start，系统直接甩 -1003。
        anchorView = anchor
        displayLayer = layer
        pipController = controller
        isPrepared = true
        lastError = nil
        startFeedTimer()
        NSLog("[QFSpeed] 画中画常驻已准备")
    }

    /// 手动浮起（面板 / 主界面按钮）
    func start() {
        prepare()
        guard let controller = pipController, isPrepared else { return }
        if controller.isPictureInPictureActive {
            isRunning = true
            return
        }
        guard controller.isPictureInPicturePossible else {
            // 层还没 ready，等一拍再试（最多 3 次，与 2.1.6 一致）
            if startRetries < 3 {
                startRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.start()
                }
            } else {
                lastError = "画中画暂不可用（渲染层未就绪）"
            }
            return
        }
        startAudioKeepAlive()
        controller.startPictureInPicture()
        isRunning = true
    }

    func stop() {
        startRetries = 0
        if let c = pipController, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        }
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        isRunning = false
    }

    func teardown() {
        stop()
        feedTimer?.invalidate()
        feedTimer = nil
        anchorView?.removeFromSuperview()
        anchorView = nil
        displayLayer = nil
        pipController = nil
        isPrepared = false
    }

    var statusText: String {
        if SpringBoardWindowHost.shared.wasInjected { return "系统级（注入 SpringBoard）" }
        if !isPrepared { return lastError ?? "未准备" }
        if let c = pipController, c.isPictureInPictureActive { return "画中画常驻中" }
        if let e = lastError { return e }
        return "已准备（切后台自动浮起）"
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
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.renderFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        feedTimer = timer
        renderFrame()
    }

    private func renderFrame() {
        guard let image = renderBarImage(), let buffer = pixelBuffer(from: image) else { return }
        enqueue(buffer)
    }

    /// 把**同一个** FloatingBarView 渲染成位图：样式与 App 内同源，不可能跑偏。
    /// 用 UIHostingController 而不是 ImageRenderer —— 后者在 iOS 16 上有
    /// main-actor 隔离限制，前者对 16.4 起的所有系统都稳。
    private func renderBarImage() -> CGImage? {
        let metrics = self.metrics.isEmpty ? SettingsStore.shared.visibleMetrics : self.metrics
        let bar = FloatingBarView(
            metrics: metrics,
            snapshot: snapshot,
            fontSize: fontSize,
            useIcon: useIcon,
            backgroundOpacity: Double(backgroundOpacity),
            useMaterial: false   // 离屏渲染没有 backdrop 可模糊，会出一层平灰，反而不像
        )

        let host = UIHostingController(rootView: bar)
        host.view.backgroundColor = .clear
        let size = host.sizeThatFits(in: CGSize(width: 4096, height: 4096))
        guard size.width > 1, size.height > 1 else { return nil }

        // 缩放策略：等比放大到几乎占满画布（PiP 窗口本身很小，字必须够大才看得清）
        let s = min(canvasWidth * 0.94 / size.width,
                    canvasHeight * 0.78 / size.height,
                    6.0)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.transform = CGAffineTransform(scaleX: s, y: s)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasWidth, height: canvasHeight),
                                               format: format)
        let image = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
            ctx.cgContext.translateBy(x: canvasWidth / 2, y: canvasHeight / 2)
            ctx.cgContext.translateBy(x: -size.width / 2, y: -size.height / 2)
            host.view.layer.render(in: ctx.cgContext)
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

        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: 1)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: buffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        // 直播语义：每帧立即显示，避免层等时间戳造成「卡住不动」
        CMSetAttachment(sample,
                        key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        layer.enqueue(sample)
    }

    // MARK: - 保活音频

    /// PiP 需要音频会话处于播放态，否则切到后台会被系统收掉。
    /// 放一段自己生成的静音 WAV 循环（不引入资源文件，也不增加包体）。
    private func startAudioKeepAlive() {
        guard keepAlivePlayer == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let url = try Self.silentWavURL()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            keepAlivePlayer = player
        } catch {
            lastError = "保活音频失败：\(error.localizedDescription)"
            NSLog("[QFSpeed] 保活音频失败 %@", String(describing: error))
        }
    }

    private static func silentWavURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("qfspeed-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 8000
        let frames = sampleRate          // 1 秒
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

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isRunning = true
        lastError = nil
        NSLog("[QFSpeed] 画中画已浮起（可拖到任意位置）")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isRunning = false
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        NSLog("[QFSpeed] 画中画已收起")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        let ns = error as NSError
        // -1003 = PGPegasusErrorDomain：渲染层还没 ready，重试即可（2.1.6 同样处理）
        if ns.code == -1003, startRetries < 3 {
            startRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.start()
            }
            return
        }
        lastError = "画中画启动失败 \(ns.code)"
        NSLog("[QFSpeed] 画中画启动失败 %@", String(describing: ns))
    }
}

extension PiPBarHost: AVPictureInPictureSampleBufferPlaybackDelegate {

    /// 直播语义：无限时长 —— 系统不给进度条，也不会自动暂停
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
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
