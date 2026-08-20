import Foundation

final class ReplayUploadTransport: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var responseData: [Int: Data] = [:]
    private var backgroundCompletion: (() -> Void)?
    private let identifier: String
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(appID: String) {
        let bundle = Bundle.main.bundleIdentifier ?? "com.linkme"
        identifier = "\(bundle).nuke-replay.\(appID)"
        super.init()
    }

    func upload(request: URLRequest, file: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file)
            lock.withLock { continuations[task.taskIdentifier] = continuation }
            task.resume()
        }
    }

    func restore(completionHandler: @escaping () -> Void) -> Bool {
        lock.withLock { backgroundCompletion = completionHandler }
        _ = session
        return true
    }
}

extension ReplayUploadTransport: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { responseData[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { continuations.removeValue(forKey: task.taskIdentifier) }
        let data = lock.withLock { responseData.removeValue(forKey: task.taskIdentifier) ?? Data() }
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) }
        else if let response = task.response { continuation.resume(returning: (data, response)) }
        else { continuation.resume(throwing: NukeReplayError.invalidResponse) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        DispatchQueue.main.async { completion?() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
