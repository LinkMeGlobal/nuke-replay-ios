import SwiftUI

struct NukeReplayReporter: View {
    @ObservedObject var client: NukeReplayClient
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [NukeReplayProject] = []
    @State private var title = ""
    @State private var whatDidYouDo = ""
    @State private var whatHappened = ""
    @State private var whatShouldHaveHappened = ""
    @State private var projectID = "all-in-challenge"
    @State private var historyMinutes = 15
    @State private var includeReplay = true
    @State private var preparing = true
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var reference: String?

    var body: some View {
        NavigationStack {
            Group {
                if let reference {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("Report submitted").font(.title2.bold())
                        Text("Thanks—your report is \(reference).")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Form {
                        Section("Issue") {
                            TextField("Short title", text: $title)
                            TextField("What did you do?", text: $whatDidYouDo, axis: .vertical).lineLimit(2...5)
                            TextField("What happened?", text: $whatHappened, axis: .vertical).lineLimit(2...5)
                            TextField("What should have happened?", text: $whatShouldHaveHappened, axis: .vertical).lineLimit(2...5)
                        }
                        Section("Routing") {
                            Picker("Project", selection: $projectID) {
                                ForEach(projects) { Text($0.name).tag($0.id) }
                            }
                            Picker("Recent history", selection: $historyMinutes) {
                                Text("Last 5 minutes").tag(5)
                                Text("Last 15 minutes").tag(15)
                                Text("Last 30 minutes").tag(30)
                            }
                        }
                        Section {
                            Toggle("Attach recent session replay", isOn: $includeReplay)
                            if includeReplay {
                                Label(
                                    "This attaches recent screen contents, visible form state, taps, errors, and capped text/JSON network request and response bodies. Authentication credentials are excluded.",
                                    systemImage: "exclamationmark.shield"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                        if let errorMessage {
                            Section { Text(errorMessage).foregroundStyle(.red) }
                        }
                    }
                }
            }
            .navigationTitle("Report a bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(reference == nil ? "Cancel" : "Done", action: close)
                }
                if reference == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Submit", action: submit)
                            .disabled(preparing || submitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectID.isEmpty)
                    }
                }
            }
            .overlay { if preparing || submitting { ProgressView().controlSize(.large) } }
            .task { prepare() }
            .interactiveDismissDisabled(submitting)
        }
    }

    private func prepare() {
        Task {
            do {
                let session = try await client.prepareReporter()
                projects = session.projects
                projectID = session.defaultProjectId
            } catch {
                errorMessage = error.localizedDescription
            }
            preparing = false
        }
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        let report = NukeReplayReport(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            whatDidYouDo: whatDidYouDo.trimmingCharacters(in: .whitespacesAndNewlines),
            whatHappened: whatHappened.trimmingCharacters(in: .whitespacesAndNewlines),
            whatShouldHaveHappened: whatShouldHaveHappened.trimmingCharacters(in: .whitespacesAndNewlines),
            projectId: projectID,
            historyMinutes: historyMinutes
        )
        Task {
            do {
                reference = try await client.submit(report, includeReplay: includeReplay).reference
                try? await Task.sleep(for: .milliseconds(700))
                close()
            }
            catch { errorMessage = error.localizedDescription }
            submitting = false
        }
    }

    private func close() {
        client.cancelReporter()
        dismiss()
    }
}
