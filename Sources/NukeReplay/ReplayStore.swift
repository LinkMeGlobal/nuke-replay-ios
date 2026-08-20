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
        try (root as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    func newSegmentURL() -> URL {
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
        for segment in pending.segments { try? FileManager.default.removeItem(at: segment.url) }
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
}
