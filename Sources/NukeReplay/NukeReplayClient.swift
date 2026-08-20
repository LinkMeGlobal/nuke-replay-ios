import Foundation
import SwiftUI
import UIKit

@MainActor
public final class NukeReplayClient: ObservableObject {
    public enum State: Equatable {
        case idle
        case preparing
        case submitting
        case submitted(String)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private let configuration: NukeReplayConfiguration
    private let store: ReplayStore
    private let uploader: ReplayUploader
    private let capture: ReplayVideoCapture
    private let monitor = ReplayInteractionMonitor()
    private var segments: [ReplaySegment] = []
    private var events: [NukeReplaySemanticEvent] = []
    private var preparedSession: NukeReplaySession?
    private var preparedKey: String?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    public init(configuration: NukeReplayConfiguration) throws {
        self.configuration = configuration
        let store = try ReplayStore(
            maxHistoryMinutes: configuration.maxHistoryMinutes,
            maxBytes: configuration.maxStorageBytes
        )
        self.store = store
        uploader = ReplayUploader(configuration: configuration, store: store)
        capture = ReplayVideoCapture(
            store: store,
            idleFPS: configuration.idleFramesPerSecond,
            activeFPS: configuration.activeFramesPerSecond
        )
        capture.onSegment = { [weak self] segment in
            Task { @MainActor in await self?.accept(segment) }
        }
        monitor.onInteraction = { [weak self] event in
            self?.capture.markInteraction()
            self?.append(event)
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        capture.start()
        monitor.start()
        observeLifecycle()
        Task { await retryPendingIfNeeded() }
    }

    public func stop() {
        guard started else { return }
        started = false
        capture.stop()
        monitor.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    public func installShakeHandler(on window: NukeReplayShakeWindow, presenter: @escaping () -> UIViewController?) {
        window.onNukeReplayShake = { [weak self] in
            guard let self, let presenter = presenter() else { return }
            self.presentReporter(from: presenter)
        }
    }

    public func presentReporter(from presenter: UIViewController) {
        guard started else { return }
        guard presenter.presentedViewController == nil else { return }
        let reporter = NukeReplayReporter(client: self)
        let hosting = UIHostingController(rootView: reporter)
        hosting.modalPresentationStyle = .formSheet
        hosting.view.nukeReplayExcluded = true
        presenter.present(hosting, animated: true)
    }

    public func recordNavigation(route: String) {
        guard started else { return }
        append(.init(type: "navigation", attributes: ["route": route]))
    }

    public func recordError(_ error: Error, context: [String: String] = [:]) {
        guard started else { return }
        append(.init(type: "error", attributes: context.merging([
            "name": String(describing: type(of: error)),
            "message": String(error.localizedDescription.prefix(2_000))
        ]) { _, new in new }))
    }

    public func recordNetwork(
        method: String,
        url: URL,
        statusCode: Int?,
        requestBody: Data?,
        responseBody: Data?,
        duration: TimeInterval?,
        error: Error?
    ) {
        guard started else { return }
        let safeURL = url.deletingQueryAndFragment().absoluteString
        guard !Self.isCredentialEndpoint(safeURL) else { return }
        var attributes: [String: String] = ["method": method, "url": safeURL]
        if let statusCode { attributes["status"] = String(statusCode) }
        if let duration { attributes["durationMs"] = String(Int(duration * 1_000)) }
        if let requestBody { attributes["requestBody"] = Self.cappedText(requestBody, bytes: 64 * 1_024) }
        if let responseBody { attributes["responseBody"] = Self.cappedText(responseBody, bytes: 128 * 1_024) }
        if let error { attributes["failure"] = String(describing: type(of: error)) }
        append(.init(type: "network", attributes: attributes))
    }

    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        uploader.transport.restore(completionHandler: completionHandler)
    }

    func prepareReporter() async throws -> NukeReplaySession {
        if let preparedSession, preparedSession.expiresAt > Self.nowMs { return preparedSession }
        state = .preparing
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let session = try await configuration.sessionProvider.createReplaySession(.init(
            idempotencyKey: key,
            appId: configuration.appID,
            platform: "ios",
            captureFormat: "nuke-ios@1",
            release: configuration.release,
            environment: configuration.environment,
            sdkVersion: NukeReplaySDKVersion,
            startedAt: Self.nowMs - Int64(configuration.maxHistoryMinutes * 60 * 1_000)
        ))
        preparedKey = key
        preparedSession = session
        state = .idle
        return session
    }

    func submit(_ report: NukeReplayReport, includeReplay: Bool) async throws -> NukeReplaySubmitResult {
        state = .submitting
        do {
            let result: NukeReplaySubmitResult
            if includeReplay {
                let now = Self.nowMs
                let cutoff = now - Int64(report.historyMinutes * 60 * 1_000)
                let selected = segments.filter { $0.endedAtMs >= cutoff }
                let selectedEvents = events.filter { $0.timestampMs >= cutoff }
                let eventsURL = await store.eventsURL()
                try await store.saveEvents(selectedEvents, to: eventsURL)
                let pending = PendingReplay(
                    idempotencyKey: preparedKey ?? UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    session: preparedSession,
                    report: report,
                    createdAtMs: now,
                    startedAtMs: min(selected.first?.startedAtMs ?? now, selectedEvents.first?.timestampMs ?? now),
                    segments: selected,
                    eventsURL: eventsURL
                )
                try await store.savePending(pending)
                result = try await uploader.submit(pending)
            } else {
                result = try await configuration.sessionProvider.submitDiagnostics(report)
            }
            preparedKey = nil
            preparedSession = nil
            state = .submitted(result.reference)
            return result
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func cancelReporter() {
        preparedKey = nil
        preparedSession = nil
        state = .idle
    }

    private func accept(_ segment: ReplaySegment) async {
        segments.append(segment)
        segments = await store.prune(segments, nowMs: Self.nowMs)
    }

    private func append(_ event: NukeReplaySemanticEvent) {
        events.append(event)
        let cutoff = Self.nowMs - Int64(configuration.maxHistoryMinutes * 60 * 1_000)
        if let firstKept = events.firstIndex(where: { $0.timestampMs >= cutoff }), firstKept > 0 {
            events.removeFirst(firstKept)
        }
        if events.count > 20_000 { events.removeFirst(events.count - 20_000) }
    }

    private func retryPendingIfNeeded() async {
        guard let pending = try? await store.pending(),
              pending.createdAtMs + 24 * 60 * 60 * 1_000 > Self.nowMs else { return }
        _ = try? await uploader.submit(pending)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let notifications: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground")
        ]
        for (name, value) in notifications {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.append(.init(type: "lifecycle", attributes: ["state": value]))
                    if value == "active" || value == "foreground" { await self?.retryPendingIfNeeded() }
                }
            })
        }
    }

    private static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private static func cappedText(_ data: Data, bytes: Int) -> String {
        let capped = data.prefix(bytes)
        if let text = String(data: capped, encoding: .utf8) { return text }
        return Data(capped).base64EncodedString()
    }

    private static func isCredentialEndpoint(_ value: String) -> Bool {
        ["/login", "/oauth", "/token", "/password", "/payment", "/checkout"].contains { value.localizedCaseInsensitiveContains($0) }
    }
}

private extension URL {
    func deletingQueryAndFragment() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.query = nil
        components.fragment = nil
        return components.url ?? self
    }
}
