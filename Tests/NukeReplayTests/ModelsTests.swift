import XCTest
@testable import NukeReplay

final class ModelsTests: XCTestCase {
    func testSessionRequestWireKeys() throws {
        let request = NukeReplaySessionRequest(
            idempotencyKey: "0123456789abcdef",
            appId: "ios-linkme",
            platform: "ios",
            captureFormat: "nuke-ios@1",
            release: "1.0",
            environment: "test",
            sdkVersion: "0.1.0",
            startedAt: 1
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["captureFormat"] as? String, "nuke-ios@1")
        XCTAssertEqual(object["appId"] as? String, "ios-linkme")
    }

    func testConfigurationCapsFrameRate() {
        struct Provider: NukeReplaySessionProviding {
            func createReplaySession(_ request: NukeReplaySessionRequest) async throws -> NukeReplaySession { fatalError() }
            func submitDiagnostics(_ report: NukeReplayReport) async throws -> NukeReplaySubmitResult { fatalError() }
        }
        let config = NukeReplayConfiguration(
            appID: "test",
            endpoint: URL(string: "https://example.com")!,
            environment: "test",
            release: "test",
            sessionProvider: Provider(),
            idleFramesPerSecond: 100,
            activeFramesPerSecond: 100,
            maxFrameDimension: 10_000
        )
        XCTAssertEqual(config.idleFramesPerSecond, 8)
        XCTAssertEqual(config.activeFramesPerSecond, 8)
        XCTAssertEqual(config.maxFrameDimension, 1_920)
    }
}
