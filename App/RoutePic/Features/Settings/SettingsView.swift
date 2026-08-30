import RouteKit
import RoutePicStore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {

    /// What the Core ML pack is doing, as far as this screen is concerned.

    @Environment(AppEnvironment.self) private var environment
    @AppStorage("privacyTrimMeters") private var trimMeters: Int = 200
    @State private var showsDeleteAllConfirmation = false
    @State private var message: String?
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var pictureBytes: Int64 = 0

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
                    LabeledContent(
                        "Pictures on this device",
                        value: pictureBytes.formatted(.byteCount(style: .file))
                    )
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Preparing your export…").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
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
                    Pictures are the largest thing stored and the only part \
                    measured above; routes and notes grow too, far more slowly. \
                    An activity's pictures can be removed without losing its \
                    route. A zip holding one GPX file per activity, every picture, and \
                    an index with your notes. Routes are exported whole — the \
                    privacy trim applies to what you share, not to your own copy.
                    """)
                }

                Section {
                    LabeledContent("RoutePic's claim over them", value: "None")
                } header: {
                    Text("Pictures you make")
                } footer: {
                    // `PLAN.md` M7.9. The generative arm is not in this
                    // version, so the model-licence half of the old wording
                    // described something the app no longer does.
                    Text("""
                    RoutePic claims nothing over the cards it draws. They are \
                    made here on your phone from your own route, by drawing it \
                    rather than by generating anything, so no model licence \
                    stands between you and what you share.
                    """)
                }

                Section {
                    LabeledContent("Version", value: "0.9")
                    LabeledContent("Cards are drawn", value: "On this device")
                } footer: {
                    Text("""
                    Every card is drawn from the route itself. Nothing is \
                    generated, nothing is downloaded, and nothing is sent \
                    anywhere to make one.
                    """)
                }
            }
            .navigationTitle("Settings")
            .task { refreshStorage() }
            // A finished archive is a snapshot. Recording, importing, editing a
            // note or deleting all happen on other tabs while this view stays
            // alive, so the link is dropped on the way back in rather than
            // sharing a zip that no longer matches the collection.
            .onAppear {
                exportURL = nil
                refreshStorage()
            }
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

    private func refreshStorage() {
        pictureBytes = (try? environment.artworkStore.totalBytes()) ?? 0
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
            // The screen stays up after this, so the figure has to move with it.
            refreshStorage()
            message = "All data deleted."
        } catch {
            message = error.localizedDescription
        }
    }
}
