import Foundation

let NukeReplaySDKVersion = "0.2.0"

public struct NukeReplayProject: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct NukeReplayPolicy: Codable, Sendable {
    public let maxChunkBytes: Int
    public let maxSessionBytes: Int
    public let maxDurationMs: Int
    public let retentionDays: Int
}

public struct NukeReplaySessionRequest: Codable, Sendable {
    public let idempotencyKey: String
    public let appId: String
    public let platform: String
    public let captureFormat: String
    public let release: String
    public let environment: String
    public let sdkVersion: String
    public let startedAt: Int64
}

public struct NukeReplaySession: Codable, Sendable {
    public let sessionId: String
    public let capability: String
    public let expiresAt: Int64
    public let serverTime: Int64
    public let projects: [NukeReplayProject]
    public let defaultProjectId: String
    public let policy: NukeReplayPolicy
}

public struct NukeReplayReport: Codable, Sendable {
    public let title: String
    public let whatDidYouDo: String
    public let whatHappened: String
    public let whatShouldHaveHappened: String
    public let projectId: String
    public let priority: String
    public let platforms: [String]
    public let pageUrl: String
    public let historyMinutes: Int

    public init(
        title: String,
        whatDidYouDo: String,
        whatHappened: String,
        whatShouldHaveHappened: String,
        projectId: String,
        priority: String = "medium",
        platforms: [String] = ["ios"],
        pageUrl: String = "",
        historyMinutes: Int = 15
    ) {
        self.title = title
        self.whatDidYouDo = whatDidYouDo
        self.whatHappened = whatHappened
        self.whatShouldHaveHappened = whatShouldHaveHappened
        self.projectId = projectId
        self.priority = priority
        self.platforms = platforms
        self.pageUrl = pageUrl
        self.historyMinutes = historyMinutes
    }
}

public struct NukeReplaySubmitResult: Codable, Sendable {
    public let reportId: String
    public let reference: String
    public let replayStatus: String
}

public struct NukeReplayUploadProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case preparing
        case uploading
        case processing
        case complete
        case failed
    }

    public let phase: Phase
    public let uploadedBytes: Int64
    public let totalBytes: Int64
    public let reference: String?

    public init(phase: Phase, uploadedBytes: Int64 = 0, totalBytes: Int64 = 0, reference: String? = nil) {
        self.phase = phase
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.reference = reference
    }
}

public struct NukeReplaySemanticEvent: Codable, Sendable {
    public let type: String
    public let timestampMs: Int64
    public let attributes: [String: String]

    public init(type: String, timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), attributes: [String: String] = [:]) {
        self.type = type
        self.timestampMs = timestampMs
        self.attributes = attributes
    }
}

public protocol NukeReplaySessionProviding: Sendable {
    func createReplaySession(_ request: NukeReplaySessionRequest) async throws -> NukeReplaySession
    func submitDiagnostics(_ report: NukeReplayReport) async throws -> NukeReplaySubmitResult
}

public struct NukeReplayConfiguration: Sendable {
    public let appID: String
    public let endpoint: URL
    public let environment: String
    public let release: String
    public let sessionProvider: any NukeReplaySessionProviding
    public let maxHistoryMinutes: Int
    public let maxStorageBytes: Int
    public let idleFramesPerSecond: Double
    public let activeFramesPerSecond: Double
    public let maxFrameDimension: Int

    public init(
        appID: String,
        endpoint: URL,
        environment: String,
        release: String,
        sessionProvider: any NukeReplaySessionProviding,
        maxHistoryMinutes: Int = 30,
        maxStorageBytes: Int = 200 * 1_024 * 1_024,
        idleFramesPerSecond: Double = 1,
        activeFramesPerSecond: Double = 6,
        maxFrameDimension: Int = 1_080
    ) {
        self.appID = appID
        self.endpoint = endpoint
        self.environment = environment
        self.release = release
        self.sessionProvider = sessionProvider
        self.maxHistoryMinutes = min(max(maxHistoryMinutes, 5), 30)
        self.maxStorageBytes = maxStorageBytes
        self.idleFramesPerSecond = min(max(idleFramesPerSecond, 0.5), 8)
        self.activeFramesPerSecond = min(max(activeFramesPerSecond, 1), 8)
        self.maxFrameDimension = min(max(maxFrameDimension, 480), 1_920)
    }
}

enum NukeReplayError: LocalizedError {
    case unavailable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidResponse: "The replay service returned an invalid response"
        }
    }
}
