import SwiftUI

@available(iOS 17.0, *)
struct SettingsScreen: View {
    @State private var model = SettingsViewModel()
    @State private var showingResetConfirmation = false

    /// Observed so the "Save logs to file" section re-renders when the writer opens / closes
    /// the current log file.
    @State private var logWriter = LogFileWriter.shared

    /// Wraps a single URL for the Share sheet. Optional because the sheet only presents when
    /// the user taps "Share latest log" AND there's a file to share. `nil` → sheet not shown.
    @State private var shareLogURL: URL?

    /// "Are you sure?" confirmation for the destructive Clear-all-logs button.
    @State private var showingClearLogsConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Preferred quality", selection: Bindable(model).preferredQuality) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    Toggle("Autoplay next video", isOn: Bindable(model).autoplayNext)
                    Toggle("Sync watch progress with YouTube", isOn: Bindable(model).syncWatchProgress)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("When signed in, videos you watch are added to your YouTube history and resume where you left off on any device.")
                }

                Section("Search") {
                    Toggle("Restricted search mode", isOn: Bindable(model).restrictedSearchMode)
                }

                Section {
                    Toggle("Save logs to file", isOn: Bindable(model).logToFile)
                    if model.logToFile, let url = logWriter.currentLogFileURL {
                        LabeledContent("Current log") {
                            Text(url.lastPathComponent)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Button {
                        // Prefer the active file; fall back to the latest historical one
                        // so the Share button still works right after the toggle is flipped
                        // off (writer closes the file, currentLogFileURL goes nil, but the
                        // file is still on disk and shareable).
                        shareLogURL = logWriter.currentLogFileURL ?? LogFileWriter.allLogFiles().first
                    } label: {
                        Label("Share latest log…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(LogFileWriter.allLogFiles().isEmpty)
                    if MacIntegration.isRunningOnMac {
                        Button {
                            MacIntegration.revealInFinder(LogFileWriter.logsDirectory())
                        } label: {
                            Label("Show log folder", systemImage: "folder")
                        }
                    }
                    Button(role: .destructive) {
                        showingClearLogsConfirmation = true
                    } label: {
                        Label("Clear all logs", systemImage: "trash")
                    }
                    .disabled(LogFileWriter.allLogFiles().isEmpty)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("When enabled, every app launch creates a new log file under Documents/Logs/ (visible in the Files app). Each file starts with the app version, build, iOS version, and device model, followed by timestamped entries from FreeTube's subsystem. Useful for sharing diagnostics with the developer when something breaks in TestFlight or sideload installs.")
                }

                Section {
                    Button {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset session", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(.white)
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Wipes stored cookies and the visitor token. The next playback attempt will run anonymously. Use this if playback or sign-in is stuck.")
                }

                Section {
                    Text("FreeTube is a personal/sideload-only YouTube client. It uses YouTubeKit (cookie-based, no Google API key) and streams videos directly. YouTube can change its internal API at any time — please be patient when things break.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                } footer: {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                    Text("v\(version) (\(build)) — [freetube.io](https://freetube.io)")
                }
            }
            .readableContentWidth(gutter: .grouped)
            .navigationTitle("Settings")
            .confirmationDialog("Reset session?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    Task { await SessionManager.shared.handleExpiredSession() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This signs you out and clears cached cookies.")
            }
            // System Share sheet for the log file. `ShareLink` would be cleaner, but
            // file:// URLs inside SwiftUI's `ShareLink` sometimes serialize as plain text
            // — UIActivityViewController via the existing `ActivityShareSheet` is the
            // reliable path for picking "Save to Files", AirDrop, Mail, etc.
            .sheet(isPresented: Binding(
                get: { shareLogURL != nil },
                set: { if !$0 { shareLogURL = nil } }
            )) {
                if let url = shareLogURL {
                    ActivityShareSheet(activityItems: [url])
                }
            }
            .confirmationDialog(
                "Delete all log files?",
                isPresented: $showingClearLogsConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    model.clearLogFiles()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every file under Documents/Logs/. If \"Save logs to file\" is on, a fresh log file will be opened for new entries.")
            }
        }
    }
}
