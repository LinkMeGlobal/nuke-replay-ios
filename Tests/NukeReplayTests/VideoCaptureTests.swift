import CoreVideo
import UIKit
import XCTest
@testable import NukeReplay

final class VideoCaptureTests: XCTestCase {
    @MainActor
    func testTargetPixelSizeIsBoundedAndEven() {
        let portrait = ReplayVideoCapture.targetPixelSize(
            for: CGSize(width: 393, height: 852),
            screenScale: 3,
            maxDimension: 1_080
        )
        XCTAssertEqual(portrait.height, 1_080)
        XCTAssertEqual(portrait.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertLessThanOrEqual(max(portrait.width, portrait.height), 1_080)

        let landscape = ReplayVideoCapture.targetPixelSize(
            for: CGSize(width: 852, height: 393),
            screenScale: 3,
            maxDimension: 1_080
        )
        XCTAssertEqual(landscape.width, 1_080)
        XCTAssertEqual(landscape.height.truncatingRemainder(dividingBy: 2), 0)
    }

    func testCapturePolicyAdaptsToThermalPressure() {
        XCTAssertEqual(
            ReplayCapturePolicy.adjustedInterval(
                1.0 / 6.0,
                recentlyActive: true,
                thermalState: .critical,
                lowPowerMode: false
            ),
            1
        )
        XCTAssertEqual(
            ReplayCapturePolicy.adjustedInterval(
                1,
                recentlyActive: false,
                thermalState: .nominal,
                lowPowerMode: false
            ),
            2
        )
    }

    @MainActor
    func testPixelBufferPreservesUIKitTopToBottomOrientation() throws {
        let size = CGSize(width: 8, height: 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }

        let buffer = try XCTUnwrap(image.pixelBuffer())
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        // 32BGRA stores blue, green, red, alpha at each byte offset.
        let top = base + rowBytes
        let bottom = base + rowBytes * 6
        XCTAssertGreaterThan(top[2], top[0], "the top row should remain red")
        XCTAssertGreaterThan(bottom[0], bottom[2], "the bottom row should remain blue")
    }
}
