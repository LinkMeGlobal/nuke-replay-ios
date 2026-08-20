import Foundation

struct ReplaySegment: Codable, Sendable {
    let id: UUID
    let url: URL
    let startedAtMs: Int64
    let endedAtMs: Int64
    let bytes: Int
}

struct PendingReplay: Codable, Sendable {
    let idempotencyKey: String
    var session: NukeReplaySession?
    let report: NukeReplayReport
    let createdAtMs: Int64
    let startedAtMs: Int64
    let segments: [ReplaySegment]
    let eventsURL: URL
    var result: NukeReplaySubmitResult?
    var uploadedSequences: Set<Int>
    var clientTimings: [ReplayClientTiming]

    init(
        idempotencyKey: String,
        session: NukeReplaySession?,
        report: NukeReplayReport,
        createdAtMs: Int64,
        startedAtMs: Int64,
        segments: [ReplaySegment],
        eventsURL: URL,
        result: NukeReplaySubmitResult? = nil,
        uploadedSequences: Set<Int> = [],
        clientTimings: [ReplayClientTiming] = []
    ) {
        self.idempotencyKey = idempotencyKey
        self.session = session
        self.report = report
        self.createdAtMs = createdAtMs
        self.startedAtMs = startedAtMs
        self.segments = segments
        self.eventsURL = eventsURL
        self.result = result
        self.uploadedSequences = uploadedSequences
        self.clientTimings = clientTimings
    }

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey, session, report, createdAtMs, startedAtMs, segments, eventsURL
        case result, uploadedSequences, clientTimings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        idempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
        session = try values.decodeIfPresent(NukeReplaySession.self, forKey: .session)
        report = try values.decode(NukeReplayReport.self, forKey: .report)
        createdAtMs = try values.decode(Int64.self, forKey: .createdAtMs)
        startedAtMs = try values.decode(Int64.self, forKey: .startedAtMs)
        segments = try values.decode([ReplaySegment].self, forKey: .segments)
        eventsURL = try values.decode(URL.self, forKey: .eventsURL)
        result = try values.decodeIfPresent(NukeReplaySubmitResult.self, forKey: .result)
        uploadedSequences = try values.decodeIfPresent(Set<Int>.self, forKey: .uploadedSequences) ?? []
        clientTimings = try values.decodeIfPresent([ReplayClientTiming].self, forKey: .clientTimings) ?? []
    }
}

struct ReplayClientTiming: Codable, Sendable {
    let phase: String
    let durationMs: Double
    let bytes: Int?
    let chunkSequence: Int?
}

actor ReplayStore {
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxAgeMs: Int64
    private let maxBytes: Int

    init(maxHistoryMinutes: Int, maxBytes: Int) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        root = support.appending(path: "NukeReplay", directoryHint: .isDirectory)
        maxAgeMs = Int64(maxHistoryMinutes * 60 * 1_000)
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.cleanOrphanedSegments(in: root, maxAgeMs: maxAgeMs, maxBytes: maxBytes)
        try (root as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    nonisolated func newSegmentURL() -> URL {
        root.appending(path: "segment-\(UUID().uuidString).mp4")
    }

    func eventsURL() -> URL {
        root.appending(path: "events-\(UUID().uuidString).json")
    }

    func saveEvents(_ events: [NukeReplaySemanticEvent], to url: URL) throws {
        try encoder.encode(events).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func savePending(_ pending: PendingReplay) throws {
        try encoder.encode(pending).write(
            to: root.appending(path: "pending.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func pending() throws -> PendingReplay? {
        let url = root.appending(path: "pending.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(PendingReplay.self, from: Data(contentsOf: url))
    }

    func clearPending(_ pending: PendingReplay) {
        try? FileManager.default.removeItem(at: root.appending(path: "pending.json"))
        try? FileManager.default.removeItem(at: pending.eventsURL)
    }

    func discardPendingIfPresent() {
        guard let pending = try? pending() else { return }
        clearPending(pending)
    }

    func prune(_ segments: [ReplaySegment], nowMs: Int64) -> [ReplaySegment] {
        var kept = segments.sorted { $0.startedAtMs < $1.startedAtMs }
        var bytes = kept.reduce(0) { $0 + $1.bytes }
        while let first = kept.first,
              nowMs - first.endedAtMs > maxAgeMs || bytes > maxBytes {
            kept.removeFirst()
            bytes -= first.bytes
            try? FileManager.default.removeItem(at: first.url)
        }
        return kept
    }

    private static func cleanOrphanedSegments(in root: URL, maxAgeMs: Int64, maxBytes: Int) {
        let manager = FileManager.default
        let pendingURL = root.appending(path: "pending.json")
        let protected: Set<URL> = {
            guard let data = try? Data(contentsOf: pendingURL),
                  let pending = try? JSONDecoder().decode(PendingReplay.self, from: data) else { return [] }
            return Set(pending.segments.map(\.url))
        }()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var candidates = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("segment-") && !protected.contains($0) }
            .compactMap { url -> (URL, Date, Int)? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            .sorted { $0.1 < $1.1 }
        let cutoff = Date().addingTimeInterval(-Double(maxAgeMs) / 1_000)
        for candidate in candidates where candidate.1 < cutoff {
            try? manager.removeItem(at: candidate.0)
        }
        candidates.removeAll { $0.1 < cutoff }
        var total = candidates.reduce(0) { $0 + $1.2 }
        while total > maxBytes, let candidate = candidates.first {
            candidates.removeFirst()
            total -= candidate.2
            try? manager.removeItem(at: candidate.0)
        }
    }
}
