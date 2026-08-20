import CryptoKit
import Foundation

actor ReplayUploader {
    private let configuration: NukeReplayConfiguration
    private let store: ReplayStore
    nonisolated let transport: ReplayUploadTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: NukeReplayConfiguration, store: ReplayStore) {
        self.configuration = configuration
        self.store = store
        transport = ReplayUploadTransport(appID: configuration.appID)
    }

    func submit(_ pendingInput: PendingReplay) async throws -> NukeReplaySubmitResult {
        var pending = pendingInput
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        if pending.session == nil || (pending.session?.expiresAt ?? 0) <= nowMs {
            pending.session = try await configuration.sessionProvider.createReplaySession(
                NukeReplaySessionRequest(
                    idempotencyKey: pending.idempotencyKey,
                    appId: configuration.appID,
                    platform: "ios",
                    captureFormat: "nuke-ios@1",
                    release: configuration.release,
                    environment: configuration.environment,
                    sdkVersion: "0.1.0",
                    startedAt: pending.startedAtMs
                )
            )
            try await store.savePending(pending)
        }
        guard let session = pending.session else { throw NukeReplayError.invalidResponse }
        var sequence = 0
        try await uploadChunk(
            pending.eventsURL,
            contentType: "application/json",
            kind: "events",
            sequence: sequence,
            session: session,
            startedAtMs: pending.startedAtMs,
            endedAtMs: nowMs,
            sessionStartedAtMs: pending.startedAtMs
        )
        sequence += 1
        for segment in pending.segments {
            try await uploadChunk(
                segment.url,
                contentType: "video/mp4",
                kind: "video-segment",
                sequence: sequence,
                session: session,
                startedAtMs: segment.startedAtMs,
                endedAtMs: segment.endedAtMs,
                sessionStartedAtMs: pending.startedAtMs
            )
            sequence += 1
        }
        let result = try await submitReport(pending, session: session, finalChunkCount: sequence)
        await store.clearPending(pending)
        return result
    }

    private func uploadChunk(
        _ file: URL,
        contentType: String,
        kind: String,
        sequence: Int,
        session: NukeReplaySession,
        startedAtMs: Int64,
        endedAtMs: Int64,
        sessionStartedAtMs: Int64
    ) async throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= session.policy.maxChunkBytes else {
            throw NukeReplayError.unavailable("A replay segment exceeded the upload limit")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = configuration.endpoint
            .appending(path: "v1/sessions/\(session.sessionId)/chunks/\(sequence)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.capability)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(digest, forHTTPHeaderField: "X-Replay-SHA256")
        request.setValue(kind, forHTTPHeaderField: "X-Replay-Kind")
        request.setValue(String(sequence), forHTTPHeaderField: "X-Replay-Sequence")
        request.setValue(String(max(0, startedAtMs - sessionStartedAtMs)), forHTTPHeaderField: "X-Replay-Start-Ms")
        request.setValue(String(max(0, endedAtMs - sessionStartedAtMs)), forHTTPHeaderField: "X-Replay-End-Ms")
        request.setValue(kind == "events" ? "1" : "0", forHTTPHeaderField: "X-Replay-Event-Count")
        let (_, response) = try await transport.upload(request: request, file: file)
        try Self.requireSuccess(response)
    }

    private func submitReport(
        _ pending: PendingReplay,
        session: NukeReplaySession,
        finalChunkCount: Int
    ) async throws -> NukeReplaySubmitResult {
        struct Body: Encodable {
            let title: String
            let whatDidYouDo: String
            let whatHappened: String
            let whatShouldHaveHappened: String
            let projectId: String
            let priority: String
            let platforms: [String]
            let pageUrl: String
            let durationMs: Int64
            let finalChunkCount: Int
        }
        let body = Body(
            title: pending.report.title,
            whatDidYouDo: pending.report.whatDidYouDo,
            whatHappened: pending.report.whatHappened,
            whatShouldHaveHappened: pending.report.whatShouldHaveHappened,
            projectId: pending.report.projectId,
            priority: pending.report.priority,
            platforms: pending.report.platforms,
            pageUrl: pending.report.pageUrl,
            durationMs: min(30 * 60 * 1_000, Int64(Date().timeIntervalSince1970 * 1_000) - pending.startedAtMs),
            finalChunkCount: finalChunkCount
        )
        let bodyURL = pending.eventsURL.deletingLastPathComponent().appending(path: "submit-\(pending.idempotencyKey).json")
        try encoder.encode(body).write(to: bodyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var request = URLRequest(url: configuration.endpoint.appending(path: "v1/sessions/\(session.sessionId)/report"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pending.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let (data, response) = try await transport.upload(request: request, file: bodyURL)
        try Self.requireSuccess(response)
        return try decoder.decode(NukeReplaySubmitResult.self, from: data)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw NukeReplayError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw NukeReplayError.unavailable("Replay upload failed (HTTP \(response.statusCode))")
        }
    }
}
