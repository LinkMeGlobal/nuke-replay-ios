import UIKit

@MainActor
final class ReplayInteractionMonitor: NSObject, UIGestureRecognizerDelegate {
    var onInteraction: ((NukeReplaySemanticEvent) -> Void)?
    private var recognizers: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    private var timer: Timer?

    func start() {
        install()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.install() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let recognizer = recognizers[ObjectIdentifier(window)] { window.removeGestureRecognizer(recognizer) }
            }
        }
        recognizers.removeAll()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func install() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where recognizers[ObjectIdentifier(window)] == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                recognizer.cancelsTouchesInView = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
                recognizers[ObjectIdentifier(window)] = recognizer
            }
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let window = recognizer.view else { return }
        let location = recognizer.location(in: window)
        let hit = window.hitTest(location, with: nil)
        onInteraction?(NukeReplaySemanticEvent(type: "interaction", attributes: [
            "action": "tap",
            "view": String(describing: type(of: hit ?? window)),
            "identifier": hit?.accessibilityIdentifier ?? "",
            "x": String(format: "%.1f", location.x),
            "y": String(format: "%.1f", location.y)
        ]))
    }
}
