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

    func createReport(_ pendingInput: PendingReplay) async throws -> NukeReplaySubmitResult {
        var pending = pendingInput
        if let result = pending.result { return result }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        if pending.session == nil || (pending.session?.expiresAt ?? 0) <= nowMs {
            let started = ContinuousClock.now
            pending.session = try await configuration.sessionProvider.createReplaySession(
                NukeReplaySessionRequest(
                    idempotencyKey: pending.idempotencyKey,
                    appId: configuration.appID,
                    platform: "ios",
                    captureFormat: "nuke-ios@1",
                    release: configuration.release,
                    environment: configuration.environment,
                    sdkVersion: NukeReplaySDKVersion,
                    startedAt: pending.startedAtMs
                )
            )
            pending.clientTimings.append(.init(
                phase: "session", durationMs: Self.milliseconds(since: started),
                bytes: nil, chunkSequence: nil
            ))
            try await store.savePending(pending)
        }
        guard let session = pending.session else { throw NukeReplayError.invalidResponse }

        let started = ContinuousClock.now
        let result = try await submitReport(pending, session: session, finalChunkCount: Self.chunks(for: pending).count)
        pending.clientTimings.append(.init(
            phase: "report", durationMs: Self.milliseconds(since: started),
            bytes: nil, chunkSequence: nil
        ))
        pending.result = result
        try await store.savePending(pending)
        return result
    }

    func finishPending(
        progress: @escaping @Sendable (NukeReplayUploadProgress) -> Void
    ) async throws {
        guard var pending = try await store.pending() else { return }
        let result = try await createReport(pending)
        guard let refreshed = try await store.pending(), let session = refreshed.session else {
            throw NukeReplayError.invalidResponse
        }
        pending = refreshed

        let chunks = Self.chunks(for: pending)
        let alreadyUploadedBytes = chunks
            .filter { pending.uploadedSequences.contains($0.sequence) }
            .reduce(Int64(0)) { $0 + Int64($1.bytes) }
        let totalBytes = chunks.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        let accumulator = UploadProgressAccumulator(
            totalBytes: totalBytes,
            completedBytes: alreadyUploadedBytes,
            reference: result.reference,
            callback: progress
        )
        progress(.init(
            phase: .uploading,
            uploadedBytes: alreadyUploadedBytes,
            totalBytes: totalBytes,
            reference: result.reference
        ))

        let remaining = chunks.filter { !pending.uploadedSequences.contains($0.sequence) }
        let endpoint = configuration.endpoint
        let transport = transport
        try await withThrowingTaskGroup(of: ChunkUploadResult.self) { group in
            var iterator = remaining.makeIterator()
            for _ in 0..<min(4, remaining.count) {
                guard let chunk = iterator.next() else { break }
                group.addTask {
                    try await Self.uploadChunk(
                        chunk,
                        endpoint: endpoint,
                        session: session,
                        transport: transport,
                        accumulator: accumulator
                    )
                }
            }
            while let uploaded = try await group.next() {
                pending.uploadedSequences.insert(uploaded.sequence)
                pending.clientTimings.append(contentsOf: uploaded.timings)
                try await store.savePending(pending)
                accumulator.complete(sequence: uploaded.sequence, bytes: uploaded.bytes)
                if let next = iterator.next() {
                    group.addTask {
                        try await Self.uploadChunk(
                            next,
                            endpoint: endpoint,
                            session: session,
                            transport: transport,
                            accumulator: accumulator
                        )
                    }
                }
            }
        }

        progress(.init(
            phase: .processing,
            uploadedBytes: totalBytes,
            totalBytes: totalBytes,
            reference: result.reference
        ))
        let completionStarted = ContinuousClock.now
        try await completeReplay(pending, session: session, finalChunkCount: chunks.count)
        let completionDuration = Self.milliseconds(since: completionStarted)
        // Completion latency cannot be included in the completion request itself,
        // but remains visible through URLSession metrics and SDK logging.
        _ = completionDuration
        await store.clearPending(pending)
        progress(.init(
            phase: .complete,
            uploadedBytes: totalBytes,
            totalBytes: totalBytes,
            reference: result.reference
        ))
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
            let deferredReplayUpload: Bool
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
            durationMs: Self.duration(of: pending),
            finalChunkCount: finalChunkCount,
            deferredReplayUpload: true
        )
        let bodyURL = pending.eventsURL.deletingLastPathComponent().appending(path: "submit-\(pending.idempotencyKey).json")
        try encoder.encode(body).write(to: bodyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var request = URLRequest(url: configuration.endpoint.appending(path: "v1/sessions/\(session.sessionId)/report"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pending.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let (data, response) = try await transport.upload(
            request: request,
            file: bodyURL,
            taskDescription: "report:\(session.sessionId)"
        )
        try Self.requireSuccess(response)
        return try decoder.decode(NukeReplaySubmitResult.self, from: data)
    }

    private func completeReplay(
        _ pending: PendingReplay,
        session: NukeReplaySession,
        finalChunkCount: Int
    ) async throws {
        struct Body: Encodable {
            let durationMs: Int64
            let finalChunkCount: Int
            let clientTimings: [ReplayClientTiming]
        }
        let body = Body(
            durationMs: Self.duration(of: pending),
            finalChunkCount: finalChunkCount,
            clientTimings: Array(pending.clientTimings.suffix(100))
        )
        let bodyURL = pending.eventsURL.deletingLastPathComponent().appending(path: "complete-\(pending.idempotencyKey).json")
        try encoder.encode(body).write(to: bodyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var request = URLRequest(url: configuration.endpoint.appending(path: "v1/sessions/\(session.sessionId)/complete"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.capability)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await transport.upload(
            request: request,
            file: bodyURL,
            taskDescription: "complete:\(session.sessionId)"
        )
        try Self.requireSuccess(response)
    }

    private static func chunks(for pending: PendingReplay) -> [ReplayUploadChunk] {
        let eventBytes = (try? pending.eventsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var chunks = [ReplayUploadChunk(
            file: pending.eventsURL,
            contentType: "application/json",
            kind: "events",
            sequence: 0,
            startedAtMs: pending.startedAtMs,
            endedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
            sessionStartedAtMs: pending.startedAtMs,
            bytes: eventBytes
        )]
        chunks.append(contentsOf: pending.segments.enumerated().map { offset, segment in
            ReplayUploadChunk(
                file: segment.url,
                contentType: "video/mp4",
                kind: "video-segment",
                sequence: offset + 1,
                startedAtMs: segment.startedAtMs,
                endedAtMs: segment.endedAtMs,
                sessionStartedAtMs: pending.startedAtMs,
                bytes: segment.bytes
            )
        })
        return chunks
    }

    private static func uploadChunk(
        _ chunk: ReplayUploadChunk,
        endpoint: URL,
        session: NukeReplaySession,
        transport: ReplayUploadTransport,
        accumulator: UploadProgressAccumulator
    ) async throws -> ChunkUploadResult {
        guard chunk.bytes <= session.policy.maxChunkBytes else {
            throw NukeReplayError.unavailable("A replay segment exceeded the upload limit")
        }
        let hashingStarted = ContinuousClock.now
        let digest = try sha256(of: chunk.file)
        let hashingDuration = milliseconds(since: hashingStarted)

        var request = URLRequest(url: endpoint.appending(path: "v1/sessions/\(session.sessionId)/chunks/\(chunk.sequence)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.capability)", forHTTPHeaderField: "Authorization")
        request.setValue(chunk.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(digest, forHTTPHeaderField: "X-Replay-SHA256")
        request.setValue(chunk.kind, forHTTPHeaderField: "X-Replay-Kind")
        request.setValue(String(chunk.sequence), forHTTPHeaderField: "X-Replay-Sequence")
        request.setValue(String(max(0, chunk.startedAtMs - chunk.sessionStartedAtMs)), forHTTPHeaderField: "X-Replay-Start-Ms")
        request.setValue(String(max(0, chunk.endedAtMs - chunk.sessionStartedAtMs)), forHTTPHeaderField: "X-Replay-End-Ms")
        request.setValue(chunk.kind == "events" ? "1" : "0", forHTTPHeaderField: "X-Replay-Event-Count")
        let networkStarted = ContinuousClock.now
        let (_, response) = try await transport.upload(
            request: request,
            file: chunk.file,
            taskDescription: "chunk:\(session.sessionId):\(chunk.sequence)",
            progress: { sent, expected in
                accumulator.update(sequence: chunk.sequence, sent: sent, expected: expected > 0 ? expected : Int64(chunk.bytes))
            }
        )
        try requireSuccess(response)
        let networkDuration = milliseconds(since: networkStarted)
        return ChunkUploadResult(
            sequence: chunk.sequence,
            bytes: chunk.bytes,
            timings: [
                .init(phase: "hashing", durationMs: hashingDuration, bytes: chunk.bytes, chunkSequence: chunk.sequence),
                .init(phase: "network", durationMs: networkDuration, bytes: chunk.bytes, chunkSequence: chunk.sequence)
            ]
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func duration(of pending: PendingReplay) -> Int64 {
        min(30 * 60 * 1_000, max(0, Int64(Date().timeIntervalSince1970 * 1_000) - pending.startedAtMs))
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw NukeReplayError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw NukeReplayError.unavailable("Replay upload failed (HTTP \(response.statusCode))")
        }
    }
}

private struct ReplayUploadChunk: Sendable {
    let file: URL
    let contentType: String
    let kind: String
    let sequence: Int
    let startedAtMs: Int64
    let endedAtMs: Int64
    let sessionStartedAtMs: Int64
    let bytes: Int
}

private struct ChunkUploadResult: Sendable {
    let sequence: Int
    let bytes: Int
    let timings: [ReplayClientTiming]
}

private final class UploadProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let reference: String
    private let callback: @Sendable (NukeReplayUploadProgress) -> Void
    private var completedBytes: Int64
    private var inFlight: [Int: Int64] = [:]

    init(
        totalBytes: Int64,
        completedBytes: Int64,
        reference: String,
        callback: @escaping @Sendable (NukeReplayUploadProgress) -> Void
    ) {
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.reference = reference
        self.callback = callback
    }

    func update(sequence: Int, sent: Int64, expected: Int64) {
        let uploaded = lock.withLock {
            inFlight[sequence] = min(sent, max(0, expected))
            return min(totalBytes, completedBytes + inFlight.values.reduce(0, +))
        }
        callback(.init(phase: .uploading, uploadedBytes: uploaded, totalBytes: totalBytes, reference: reference))
    }

    func complete(sequence: Int, bytes: Int) {
        let uploaded = lock.withLock {
            inFlight.removeValue(forKey: sequence)
            completedBytes += Int64(bytes)
            return min(totalBytes, completedBytes + inFlight.values.reduce(0, +))
        }
        callback(.init(phase: .uploading, uploadedBytes: uploaded, totalBytes: totalBytes, reference: reference))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
