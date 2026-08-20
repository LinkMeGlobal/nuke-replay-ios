@preconcurrency import AVFoundation
import UIKit

@MainActor
final class ReplayVideoCapture {
    var onSegment: (@Sendable (ReplaySegment) -> Void)?

    private let store: ReplayStore
    private let idleInterval: TimeInterval
    private let activeInterval: TimeInterval
    private var timer: Timer?
    private var writer: SegmentWriter?
    private var lastCapture = Date.distantPast
    private var lastInteraction = Date.distantPast
    private var running = false

    init(store: ReplayStore, idleFPS: Double, activeFPS: Double) {
        self.store = store
        idleInterval = 1 / idleFPS
        activeInterval = 1 / activeFPS
    }

    func start() {
        guard !running else { return }
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        finishWriter()
    }

    func markInteraction() {
        lastInteraction = Date()
    }

    private func tick() {
        guard UIApplication.shared.applicationState == .active else { return }
        let now = Date()
        let interval = now.timeIntervalSince(lastInteraction) < 2 ? activeInterval : idleInterval
        guard now.timeIntervalSince(lastCapture) >= interval else { return }
        lastCapture = now
        guard let image = Self.captureVisibleWindows(), let pixelBuffer = image.pixelBuffer() else { return }
        Task {
            if writer == nil || writer?.duration ?? 0 >= 10 {
                finishWriter()
                guard let url = await store.newSegmentURL() as URL? else { return }
                writer = try? SegmentWriter(
                    url: url,
                    size: CGSize(
                        width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer)
                    ),
                    startedAt: now
                )
            }
            writer?.append(pixelBuffer, at: now)
        }
    }

    private func finishWriter() {
        guard let current = writer else { return }
        writer = nil
        current.finish { [weak self] segment in
            Task { @MainActor in self?.onSegment?(segment) }
        }
    }

    private static func captureVisibleWindows() -> UIImage? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0 && !$0.nukeReplayExcluded }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        guard let bounds = windows.last?.bounds, !bounds.isEmpty else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            for window in windows { window.drawHierarchy(in: bounds, afterScreenUpdates: false) }
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

    var duration: TimeInterval { lastTime.seconds }

    init(url: URL, size: CGSize, startedAt: Date) throws {
        self.startedAt = startedAt
        startedAtMs = Int64(startedAt.timeIntervalSince1970 * 1_000)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: max(2, Int(size.width)),
            AVVideoHeightKey: max(2, Int(size.height)),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 900_000,
                AVVideoExpectedSourceFrameRateKey: 6,
                AVVideoMaxKeyFrameIntervalKey: 12
            ]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ buffer: CVPixelBuffer, at date: Date) {
        guard input.isReadyForMoreMediaData else { return }
        lastTime = CMTime(seconds: max(0, date.timeIntervalSince(startedAt)), preferredTimescale: 600)
        adaptor.append(buffer, withPresentationTime: lastTime)
    }

    func finish(completion: @escaping @Sendable (ReplaySegment) -> Void) {
        input.markAsFinished()
        writer.finishWriting { [self] in
            guard writer.status == .completed else { return }
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

private extension UIImage {
    func pixelBuffer() -> CVPixelBuffer? {
        guard let cgImage else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            cgImage.width,
            cgImage.height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(cgImage.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
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
