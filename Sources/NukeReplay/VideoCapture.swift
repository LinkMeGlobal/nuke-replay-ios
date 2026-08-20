@preconcurrency import AVFoundation
import OSLog
import UIKit

@MainActor
final class ReplayVideoCapture {
    var onSegment: (@Sendable (ReplaySegment) -> Void)? {
        didSet { encoder.onSegment = onSegment }
    }

    private static let logger = Logger(subsystem: "bio.nuke.replay", category: "capture")
    private let idleInterval: TimeInterval
    private let activeInterval: TimeInterval
    private let maxFrameDimension: Int
    private let encoder: ReplayVideoEncoder
    private var timer: Timer?
    private var lastCapture = Date.distantPast
    private var lastInteraction = Date.distantPast
    private var running = false

    init(store: ReplayStore, idleFPS: Double, activeFPS: Double, maxFrameDimension: Int) {
        idleInterval = 1 / idleFPS
        activeInterval = 1 / activeFPS
        self.maxFrameDimension = maxFrameDimension
        encoder = ReplayVideoEncoder(store: store)
    }

    func start() {
        guard !running else { return }
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1 / 60
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        Task { [weak self] in
            guard let self, let segment = await self.encoder.flush() else { return }
            self.onSegment?(segment)
        }
    }

    func flush() async -> ReplaySegment? {
        await encoder.flush()
    }

    func markInteraction() {
        lastInteraction = Date()
    }

    private func tick() {
        guard UIApplication.shared.applicationState == .active else { return }
        let now = Date()
        let recentlyActive = now.timeIntervalSince(lastInteraction) < 2
        let baseInterval = recentlyActive ? activeInterval : idleInterval
        let interval = ReplayCapturePolicy.adjustedInterval(
            baseInterval,
            recentlyActive: recentlyActive,
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        guard now.timeIntervalSince(lastCapture) >= interval, encoder.reserveFrame() else { return }
        lastCapture = now

        let started = ContinuousClock.now
        guard let frame = Self.captureVisibleWindows(maxDimension: maxFrameDimension, capturedAt: now) else {
            encoder.cancelReservedFrame()
            return
        }
        let elapsed = started.duration(to: .now)
        Self.logger.debug("Captured replay frame in \(elapsed.components.seconds, privacy: .public)s + \(elapsed.components.attoseconds / 1_000_000_000_000_000, privacy: .public)ms at \(frame.image.width, privacy: .public)x\(frame.image.height, privacy: .public)")
        encoder.enqueue(frame)
    }

    static func targetPixelSize(for pointSize: CGSize, screenScale: CGFloat, maxDimension: Int) -> CGSize {
        guard pointSize.width > 0, pointSize.height > 0 else { return .zero }
        let nativeWidth = pointSize.width * screenScale
        let nativeHeight = pointSize.height * screenScale
        let scaleDown = min(1, CGFloat(maxDimension) / max(nativeWidth, nativeHeight))
        func even(_ value: CGFloat) -> CGFloat {
            max(2, floor(value * scaleDown / 2) * 2)
        }
        return CGSize(width: even(nativeWidth), height: even(nativeHeight))
    }

    private static func captureVisibleWindows(maxDimension: Int, capturedAt: Date) -> CapturedReplayFrame? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0 && !$0.nukeReplayExcluded }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        guard let reference = windows.last, !reference.bounds.isEmpty else { return nil }
        let bounds = reference.bounds
        let target = targetPixelSize(for: bounds.size, screenScale: reference.screen.scale, maxDimension: maxDimension)
        guard target.width > 0, target.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let image = renderer.image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: target))
            context.cgContext.scaleBy(x: target.width / bounds.width, y: target.height / bounds.height)
            for window in windows { window.drawHierarchy(in: bounds, afterScreenUpdates: false) }
        }
        guard let cgImage = image.cgImage else { return nil }
        return CapturedReplayFrame(image: cgImage, capturedAt: capturedAt)
    }
}

enum ReplayCapturePolicy {
    static func adjustedInterval(
        _ base: TimeInterval,
        recentlyActive: Bool,
        thermalState: ProcessInfo.ThermalState,
        lowPowerMode: Bool
    ) -> TimeInterval {
        var minimum: TimeInterval = recentlyActive ? 0 : 2
        if lowPowerMode { minimum = max(minimum, recentlyActive ? 1.0 / 3.0 : 2) }
        switch thermalState {
        case .serious:
            minimum = max(minimum, recentlyActive ? 0.5 : 2)
        case .critical:
            minimum = max(minimum, recentlyActive ? 1 : 3)
        default:
            break
        }
        return max(base, minimum)
    }
}

private struct CapturedReplayFrame: @unchecked Sendable {
    let image: CGImage
    let capturedAt: Date
}

private final class PendingFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func reserve() -> Bool {
        lock.withLock {
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() {
        lock.withLock { count = max(0, count - 1) }
    }
}

private final class ReplayVideoEncoder: @unchecked Sendable {
    private static let logger = Logger(subsystem: "bio.nuke.replay", category: "encoder")
    private let queue = DispatchQueue(label: "bio.nuke.replay.video-encoder", qos: .utility)
    private let gate = PendingFrameGate(limit: 2)
    private let store: ReplayStore
    private var writer: SegmentWriter?
    var onSegment: (@Sendable (ReplaySegment) -> Void)?

    init(store: ReplayStore) { self.store = store }

    func reserveFrame() -> Bool { gate.reserve() }
    func cancelReservedFrame() { gate.release() }

    func enqueue(_ frame: CapturedReplayFrame) {
        queue.async { [self] in
            defer { gate.release() }
            let size = CGSize(width: frame.image.width, height: frame.image.height)
            if writer?.size != size || (writer?.duration ?? 0) >= 15 { finishCurrent(deliver: true) }
            if writer == nil {
                writer = try? SegmentWriter(url: store.newSegmentURL(), size: size, startedAt: frame.capturedAt)
            }
            guard let writer else { return }
            let started = ContinuousClock.now
            if !writer.append(frame.image, at: frame.capturedAt) {
                Self.logger.debug("Dropped replay frame because the video writer was backpressured")
            }
            let elapsed = started.duration(to: .now)
            Self.logger.debug("Encoded replay frame in \(elapsed.components.seconds, privacy: .public)s + \(elapsed.components.attoseconds / 1_000_000_000_000_000, privacy: .public)ms")
        }
    }

    func flush() async -> ReplaySegment? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let current = writer else {
                    continuation.resume(returning: nil)
                    return
                }
                writer = nil
                current.finish { continuation.resume(returning: $0) }
            }
        }
    }

    private func finishCurrent(deliver: Bool) {
        guard let current = writer else { return }
        writer = nil
        current.finish { [weak self] segment in
            guard deliver, let segment else { return }
            self?.onSegment?(segment)
        }
    }
}

private final class SegmentWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let startedAt: Date
    private let startedAtMs: Int64
    private var lastTime = CMTime.zero
    let size: CGSize

    var duration: TimeInterval { lastTime.seconds }

    init(url: URL, size: CGSize, startedAt: Date) throws {
        self.size = size
        self.startedAt = startedAt
        startedAtMs = Int64(startedAt.timeIntervalSince1970 * 1_000)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 900_000,
                AVVideoExpectedSourceFrameRateKey: 6,
                AVVideoMaxKeyFrameIntervalKey: 12
            ]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, at date: Date) -> Bool {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return false }
        var candidate: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &candidate) == kCVReturnSuccess,
              let buffer = candidate, buffer.draw(image) else { return false }
        let timestamp = CMTime(seconds: max(0, date.timeIntervalSince(startedAt)), preferredTimescale: 600)
        guard adaptor.append(buffer, withPresentationTime: timestamp) else { return false }
        lastTime = timestamp
        return true
    }

    func finish(completion: @escaping @Sendable (ReplaySegment?) -> Void) {
        input.markAsFinished()
        writer.finishWriting { [self] in
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: writer.outputURL)
                completion(nil)
                return
            }
            let values = try? writer.outputURL.resourceValues(forKeys: [.fileSizeKey])
            completion(ReplaySegment(
                id: UUID(),
                url: writer.outputURL,
                startedAtMs: startedAtMs,
                endedAtMs: startedAtMs + Int64(lastTime.seconds * 1_000),
                bytes: values?.fileSize ?? 0
            ))
        }
    }
}

extension CVPixelBuffer {
    func draw(_ image: CGImage) -> Bool {
        CVPixelBufferLockBaseAddress(self, [])
        defer { CVPixelBufferUnlockBaseAddress(self, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(self), width: CVPixelBufferGetWidth(self),
            height: CVPixelBufferGetHeight(self), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(self), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return true
    }
}

extension UIImage {
    func pixelBuffer() -> CVPixelBuffer? {
        guard let cgImage else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, cgImage.width, cgImage.height,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer, buffer.draw(cgImage) else { return nil }
        return buffer
    }
}

@MainActor private var replayExcludedKey: UInt8 = 0

@MainActor public extension UIView {
    var nukeReplayExcluded: Bool {
        get { (objc_getAssociatedObject(self, &replayExcludedKey) as? Bool) == true }
        set { objc_setAssociatedObject(self, &replayExcludedKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
