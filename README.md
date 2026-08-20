# NUKE Replay for iOS

Open-source Swift package for explicit NUKE bug reports. It maintains a bounded
rolling screen history as short H.264 segments, semantic interaction and
network events, protected on-disk storage, and durable uploads to
`replay.nuke.bio`.

## Installation

Add the package in Xcode using:

```text
https://github.com/LinkMeGlobal/nuke-replay-ios.git
```

Select version `0.2.1` or newer. The SDK is public, but the NUKE ingestion
service is not anonymous. A host must provide an authenticated session exchange
before capture can be submitted.

The package never persists a LinkMe access token. The host implements
`sessionProvider` and performs the one-time authenticated session exchange;
the package receives only the replay-scoped capability returned by the replay
service.

```swift
let client = try NukeReplayClient(configuration: .init(
    appID: "ios-linkme",
    endpoint: URL(string: "https://replay.nuke.bio")!,
    environment: "production",
    release: Bundle.main.releaseVersion,
    sessionProvider: LinkMeReplaySessionProvider()
))

client.start()
// Call from the host shake handler:
client.presentReporter(from: viewController)
```

The current internal pilot intentionally records visible screen/input state.
Automatic privacy masking is deferred; hosts can temporarily hide a view by
setting `view.nukeReplayExcluded = true`.
