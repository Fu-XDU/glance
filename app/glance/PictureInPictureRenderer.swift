import AppKit
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import ObjectiveC

protocol PictureInPicturePresenting: AnyObject {
    var isActive: Bool { get }
    var onActiveChange: ((Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func attach(to container: NSView)
    func setLines(_ lines: [PiPLine])
    func prepareIfNeeded()
    func toggle()
    func parkIfNeeded()
}

enum PictureInPictureFactory {
    static func make() -> PictureInPicturePresenting? {
        guard #available(macOS 12.0, *) else { return nil }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        return PictureInPictureRenderer()
    }
}

@available(macOS 12.0, *)
private final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// 用一段 16:10 的视频交给系统画中画。拖动窗口时，系统会按这个比例缩放画面。
@available(macOS 12.0, *)
final class PictureInPictureRenderer: NSObject, PictureInPicturePresenting, AVPictureInPictureControllerDelegate {
    var onActiveChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private let sampleHost = PlayerHostView()
    private let player = AVPlayer()
    private var pipController: AVPictureInPictureController?
    private var lines: [PiPLine] = []
    private var hostConstraints: [NSLayoutConstraint] = []
    private var possibleObservation: NSKeyValueObservation?
    private var wantsStart = false
    private var startGeneration = 0
    private var movieGeneration = 0
    private var isPublishing = false
    private var movieURL: URL?
    private var carrierAsset: AVAsset?
    private weak var previewContainer: NSView?
    private let picturePixelSize = CGSize(width: 1600, height: 1000)

    private lazy var anchorWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        return window
    }()

    override init() {
        super.init()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        sampleHost.playerLayer.player = player
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(replayCurrentItem),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    var isActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    func attach(to container: NSView) {
        previewContainer = container
        guard !isActive else { return }
        guard sampleHost.superview !== container else { return }
        installHost(in: container)
    }

    func setLines(_ lines: [PiPLine]) {
        let changed = lines != self.lines || player.currentItem == nil
        self.lines = lines
        guard changed else { return }
        guard let pixelBuffer = PiPFrame.pixelBuffer(lines: lines, pixelSize: picturePixelSize) else { return }
        PiPFrameStore.shared.update(pixelBuffer)
        if player.currentItem == nil {
            publishMovie()
        } else {
            // 播放器停住时不会再要新帧，画中画就会一直停在旧画面上。
            player.play()
        }
    }

    func prepareIfNeeded() {
        guard pipController == nil, sampleHost.window != nil else { return }
        guard let controller = AVPictureInPictureController(playerLayer: sampleHost.playerLayer) else { return }
        controller.delegate = self
        controller.requiresLinearPlayback = true
        Self.hidePlaybackControls(controller)
        pipController = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
            DispatchQueue.main.async {
                guard let self, self.wantsStart, controller.isPictureInPicturePossible else { return }
                self.wantsStart = false
                controller.startPictureInPicture()
            }
        }
    }

    func toggle() {
        if isActive {
            wantsStart = false
            startGeneration += 1
            pipController?.stopPictureInPicture()
            return
        }
        if player.currentItem == nil {
            publishMovie()
        }
        player.play()
        prepareIfNeeded()
        guard let pipController else {
            onFailure?("当前系统不支持画中画")
            return
        }
        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            scheduleStart()
        }
    }

    func parkIfNeeded() {
        guard isActive else { return }
        moveHostToAnchor()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        wantsStart = false
        DispatchQueue.main.async { [weak self] in
            self?.player.play()
            self?.onActiveChange?(true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        wantsStart = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let previewContainer = self.previewContainer {
                self.installHost(in: previewContainer)
            }
            self.onActiveChange?(false)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        wantsStart = false
        startGeneration += 1
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error.localizedDescription)
            self?.onActiveChange?(false)
        }
    }

    private static func hidePlaybackControls(_ controller: AVPictureInPictureController) {
        let selector = NSSelectorFromString("setControlsStyle:")
        guard controller.responds(to: selector) else { return }
        typealias SetStyle = @convention(c) (AnyObject, Selector, Int) -> Void
        let setStyle = unsafeBitCast(controller.method(for: selector), to: SetStyle.self)
        setStyle(controller, selector, 0)
    }

    private func installHost(in container: NSView) {
        anchorWindow.orderOut(nil)
        NSLayoutConstraint.deactivate(hostConstraints)
        sampleHost.removeFromSuperview()
        sampleHost.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sampleHost)
        hostConstraints = [
            sampleHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sampleHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sampleHost.topAnchor.constraint(equalTo: container.topAnchor),
            sampleHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostConstraints)
    }

    private func moveHostToAnchor() {
        NSLayoutConstraint.deactivate(hostConstraints)
        hostConstraints = []
        guard let content = anchorWindow.contentView else { return }
        if sampleHost.superview !== content {
            sampleHost.removeFromSuperview()
            sampleHost.translatesAutoresizingMaskIntoConstraints = true
            sampleHost.autoresizingMask = [.width, .height]
            content.addSubview(sampleHost)
        }
        anchorWindow.alphaValue = 0
        anchorWindow.setFrame(NSRect(x: 40, y: 40, width: 640, height: 400), display: true)
        sampleHost.frame = content.bounds
        if !anchorWindow.isVisible {
            anchorWindow.orderFrontRegardless()
        }
    }

    /// 承载视频只生成一次。之后每帧都由合成器重画，刷新时不再换片，所以不会闪。
    private func publishMovie() {
        guard player.currentItem == nil, !isPublishing else { return }
        guard let pixelBuffer = PiPFrameStore.shared.current() else { return }
        isPublishing = true
        movieGeneration += 1
        let generation = movieGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url: URL
            do {
                url = try PiPMovie.write(pixelBuffer: pixelBuffer)
            } catch {
                DispatchQueue.main.async { self?.isPublishing = false }
                return
            }
            let asset = AVURLAsset(url: url)
            asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
                DispatchQueue.main.async {
                    guard let self, self.movieGeneration == generation, self.player.currentItem == nil else {
                        try? FileManager.default.removeItem(at: url)
                        self?.isPublishing = false
                        return
                    }
                    guard asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
                          let sourceTrack = asset.tracks(withMediaType: .video).first,
                          let item = self.makeCarrierItem(sourceTrack: sourceTrack) else {
                        try? FileManager.default.removeItem(at: url)
                        self.isPublishing = false
                        return
                    }
                    self.carrierAsset = asset
                    self.movieURL = url
                    self.player.replaceCurrentItem(with: item)
                    self.player.play()
                    if self.wantsStart {
                        self.prepareIfNeeded()
                        if self.pipController?.isPictureInPicturePossible == true {
                            self.wantsStart = false
                            self.pipController?.startPictureInPicture()
                        }
                    }
                }
            }
        }
    }

    /// 把同一段短片接成一小时，播放器会一直要新帧，合成器就能把最新行情画上去。
    private func makeCarrierItem(sourceTrack: AVAssetTrack) -> AVPlayerItem? {
        let loadedDuration = sourceTrack.timeRange.duration
        let clipDuration = loadedDuration.isNumeric && loadedDuration.seconds > 0.1
            ? loadedDuration
            : CMTime(value: CMTimeValue(PiPMovie.frameCount), timescale: PiPMovie.timescale)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        let repeats = max(1, Int((3600 / clipDuration.seconds).rounded(.up)))
        var cursor = CMTime.zero
        for _ in 0..<repeats {
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: clipDuration), of: sourceTrack, at: cursor)
            } catch {
                return nil
            }
            cursor = CMTimeAdd(cursor, clipDuration)
        }
        guard let videoComposition = makeComposition(track: track, duration: cursor) else { return nil }
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }

    private func makeComposition(track: AVAssetTrack, duration: CMTime) -> AVVideoComposition? {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: track)]

        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = PiPCompositor.self
        composition.renderSize = picturePixelSize
        composition.frameDuration = CMTime(value: 1, timescale: PiPMovie.timescale)
        composition.instructions = [instruction]
        return composition
    }

    @objc private func replayCurrentItem(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem, item == player.currentItem else { return }
        player.seek(to: .zero)
        player.play()
    }

    private func scheduleStart() {
        startGeneration += 1
        let generation = startGeneration
        wantsStart = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.wantsStart, self.startGeneration == generation else { return }
            self.wantsStart = false
            self.onFailure?("当前无法开启画中画")
        }
    }
}

private final class PiPFrameStore {
    static let shared = PiPFrameStore()
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func update(_ buffer: CVPixelBuffer) {
        lock.lock()
        self.buffer = buffer
        lock.unlock()
    }

    func current() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

@objc(GlancePiPCompositor)
final class PiPCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
        ],
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        for trackID in request.sourceTrackIDs {
            _ = request.sourceFrame(byTrackID: trackID.int32Value)
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CocoaError(.coderInvalidValue))
            return
        }
        if let latest = PiPFrameStore.shared.current() {
            Self.draw(latest, into: output)
        }
        request.finish(withComposedVideoFrame: output)
    }

    private static func draw(_ source: CVPixelBuffer, into destination: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess,
              let sourceAddress = CVPixelBufferGetBaseAddress(source),
              let destinationAddress = CVPixelBufferGetBaseAddress(destination) else { return }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        let width = min(CVPixelBufferGetWidth(source), CVPixelBufferGetWidth(destination))
        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        let sourceRow = CVPixelBufferGetBytesPerRow(source)
        let destinationRow = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(width * 4, min(sourceRow, destinationRow))
        for row in 0..<height {
            memcpy(
                destinationAddress.advanced(by: row * destinationRow),
                sourceAddress.advanced(by: row * sourceRow),
                rowBytes
            )
        }
    }
}

private enum PiPMovie {
    static let timescale: Int32 = 4
    static let frameCount = 32

    static func write(pixelBuffer: CVPixelBuffer) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-pip-\(UUID().uuidString).mov")
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 8, 8_000_000),
                AVVideoMaxKeyFrameIntervalKey: Int(timescale),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )
        guard writer.canAdd(input) else {
            throw CocoaError(.fileWriteUnknown)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw CocoaError(.fileWriteUnknown)
        }

        let ready = DispatchSemaphore(value: 0)
        var nextIndex = 0
        var didFinish = false
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "glance.pip.movie")) {
            while input.isReadyForMoreMediaData, nextIndex < frameCount {
                guard let sample = Self.pooledCopy(of: pixelBuffer, pool: pool),
                      adaptor.append(sample, withPresentationTime: CMTime(value: CMTimeValue(nextIndex), timescale: timescale)) else {
                    if !didFinish {
                        didFinish = true
                        input.markAsFinished()
                        writer.cancelWriting()
                        ready.signal()
                    }
                    return
                }
                nextIndex += 1
            }
            guard nextIndex == frameCount, !didFinish else { return }
            didFinish = true
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: timescale))
            writer.finishWriting {
                ready.signal()
            }
        }
        ready.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private static func pooledCopy(of source: CVPixelBuffer, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess,
              let sourceAddress = CVPixelBufferGetBaseAddress(source),
              let destinationAddress = CVPixelBufferGetBaseAddress(destination) else { return nil }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        let width = min(CVPixelBufferGetWidth(source), CVPixelBufferGetWidth(destination))
        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        let sourceRow = CVPixelBufferGetBytesPerRow(source)
        let destinationRow = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(width * 4, min(sourceRow, destinationRow))
        for row in 0..<height {
            memcpy(
                destinationAddress.advanced(by: row * destinationRow),
                sourceAddress.advanced(by: row * sourceRow),
                rowBytes
            )
        }
        return destination
    }
}
