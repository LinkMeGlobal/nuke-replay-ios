# NUKE Replay for iOS

Private LinkMe Swift package for explicit internal bug reports. It maintains a
bounded rolling screen history as short H.264 segments, semantic interaction
and network events, protected on-disk storage, and durable uploads to
`replay.nuke.bio`.

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
