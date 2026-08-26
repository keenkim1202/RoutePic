import RouteKit
import RoutePicStore
import SwiftUI

struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @AppStorage("privacyTrimMeters") private var trimMeters: Int = 200
    @State private var showsDeleteAllConfirmation = false
    @State private var message: String?
    @State private var isExporting = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Trim start and end", selection: $trimMeters) {
                        Text("Off").tag(0)
                        Text("200 m").tag(200)
                        Text("500 m").tag(500)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    // DESIGN.md §11 — say plainly that trimming is not a complete
                    // defence, rather than implying it is.
                    Text("""
                    Removing the start and end of a route keeps your home off a \
                    shared picture. It is not a complete defence: a distinctive \
                    route shape can still be matched against a public map. Routes \
                    that finish where they started cannot be hidden this way at all.
                    """)
                }

                Section {
                    LabeledContent("Coordinates sent to a server", value: "None")
                    LabeledContent("Activities stored", value: "On this device only")
                } header: {
                    Text("Where your data is")
                } footer: {
                    Text("""
                    RoutePic keeps everything locally. Pictures are drawn on \
                    this device, so not even the shape of a route is sent \
                    anywhere — there is no server in the picture path at all.
                    """)
                }

                Section {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Preparing your export…").foregroundStyle(.secondary)
                        }
                    } else if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share your export", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("Export everything") { export() }
                    }
                    Button("Delete all data", role: .destructive) {
                        showsDeleteAllConfirmation = true
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("""
                    A zip holding one GPX file per activity, every picture, and \
                    an index with your notes. Routes are exported whole — the \
                    privacy trim applies to what you share, not to your own copy.
                    """)
                }

                Section {
                    LabeledContent("Version", value: "0.9")
                    LabeledContent("Picture generation", value: "On this device")
                } footer: {
                    Text("""
                    Recording, your collection, notes and sharing work without \
                    picture generation and always will.
                    """)
                }
            }
            .navigationTitle("Settings")
            // A finished archive is a snapshot. Recording, importing, editing a
            // note or deleting all happen on other tabs while this view stays
            // alive, so the link is dropped on the way back in rather than
            // sharing a zip that no longer matches the collection.
            .onAppear { exportURL = nil }
            .confirmationDialog(
                "Delete everything?",
                isPresented: $showsDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every activity, picture and note will be permanently removed from this device. This cannot be undone.")
            }
            .alert(
                "RoutePic",
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )
            ) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func export() {
        isExporting = true
        Task {
            // A yield so the row can swap to the spinner: the archive is built
            // on the main actor, and without this the screen freezes with the
            // button still showing.
            await Task.yield()
            do {
                exportURL = try environment.repository.exportArchive()
            } catch {
                message = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func deleteAll() {
        exportURL = nil
        do {
            try environment.repository.deleteAllData()
            message = "All data deleted."
        } catch {
            message = error.localizedDescription
        }
    }
}
