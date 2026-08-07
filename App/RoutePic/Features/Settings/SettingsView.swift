import RouteKit
import RoutePicStore
import SwiftUI

struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @AppStorage("privacyTrimMeters") private var trimMeters: Int = 200
    @State private var showsDeleteAllConfirmation = false
    @State private var message: String?

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
                    RoutePic keeps everything locally. When picture generation \
                    arrives it will send only the normalised shape of a route — \
                    never the coordinates — and the server will not keep it.
                    """)
                }

                Section {
                    Button("Export everything") { message = "Export arrives with the next build." }
                    Button("Delete all data", role: .destructive) {
                        showsDeleteAllConfirmation = true
                    }
                } header: {
                    Text("Your data")
                }

                Section {
                    LabeledContent("Version", value: "0.9")
                    LabeledContent("Picture generation", value: "Not enabled yet")
                } footer: {
                    Text("""
                    Recording, your collection, notes and sharing work without \
                    picture generation and always will.
                    """)
                }
            }
            .navigationTitle("Settings")
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
            .alert("RoutePic", isPresented: .constant(message != nil)) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func deleteAll() {
        do {
            try environment.repository.deleteAllData()
            message = "All data deleted."
        } catch {
            message = error.localizedDescription
        }
    }
}
