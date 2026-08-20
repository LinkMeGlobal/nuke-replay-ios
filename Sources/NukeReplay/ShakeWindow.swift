import UIKit

open class NukeReplayShakeWindow: UIWindow {
    public var onNukeReplayShake: (() -> Void)?

    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake { onNukeReplayShake?() }
    }
}
