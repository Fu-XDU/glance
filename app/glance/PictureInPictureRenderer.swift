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
    private var movieURL: URL?
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
        publishMovie()
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

    private func publishMovie() {
        guard let pixelBuffer = PiPFrame.pixelBuffer(lines: lines, pixelSize: picturePixelSize) else { return }
        movieGeneration += 1
        let generation = movieGeneration
        let previousURL = movieURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let url = try? PiPMovie.write(pixelBuffer: pixelBuffer) else { return }
            DispatchQueue.main.async {
                guard let self, self.movieGeneration == generation else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                let item = AVPlayerItem(url: url)
                self.player.replaceCurrentItem(with: item)
                self.player.play()
                self.movieURL = url
                if let previousURL {
                    try? FileManager.default.removeItem(at: previousURL)
                }
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

private enum PiPMovie {
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
                AVVideoMaxKeyFrameIntervalKey: 1,
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

        let ready = DispatchSemaphore(value: 0)
        let holdUntil = CMTime(seconds: 36000, preferredTimescale: 600)
        let samples = [pixelBuffer, Self.copy(pixelBuffer) ?? pixelBuffer]
        let times = [CMTime.zero, holdUntil]
        var nextIndex = 0
        var didFinish = false
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "glance.pip.movie")) {
            while input.isReadyForMoreMediaData, nextIndex < times.count {
                guard adaptor.append(samples[nextIndex], withPresentationTime: times[nextIndex]) else {
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
            guard nextIndex == times.count, !didFinish else { return }
            didFinish = true
            input.markAsFinished()
            writer.endSession(atSourceTime: holdUntil)
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

    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var copy: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            CVPixelBufferGetPixelFormatType(source),
            attrs as CFDictionary,
            &copy
        ) == kCVReturnSuccess, let copy else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess,
              let sourceAddress = CVPixelBufferGetBaseAddress(source),
              let copyAddress = CVPixelBufferGetBaseAddress(copy) else { return nil }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy, [])
        }
        let sourceRow = CVPixelBufferGetBytesPerRow(source)
        let copyRow = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = min(sourceRow, copyRow)
        for row in 0..<height {
            memcpy(
                copyAddress.advanced(by: row * copyRow),
                sourceAddress.advanced(by: row * sourceRow),
                rowBytes
            )
        }
        return copy
    }
}
