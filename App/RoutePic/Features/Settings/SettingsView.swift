import GenerationCoreML
import RouteKit
import RoutePicStore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {

    /// What the Core ML pack is doing, as far as this screen is concerned.
    enum ModelState: Equatable {
        case checking
        case absent
        case installing(Double)
        case installed(Int64)
    }

    @Environment(AppEnvironment.self) private var environment
    @AppStorage("privacyTrimMeters") private var trimMeters: Int = 200
    @State private var showsDeleteAllConfirmation = false
    @State private var message: String?
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var modelState: ModelState = .checking
    @State private var showsModelPicker = false
    @State private var installTask: Task<Void, Never>?
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

                modelSection

                Section {
                    LabeledContent("RoutePic's claim over them", value: "None")
                } header: {
                    Text("Pictures you make")
                } footer: {
                    // `PLAN.md` M7.9. What RoutePic decides is the only thing
                    // it can state. Whether an output can be owned, and whose
                    // rights it might touch, are not RoutePic's to answer — and
                    // the model's licence is one constraint among those, not
                    // the whole of them.
                    Text("""
                    RoutePic claims nothing over the pictures it draws. That is \
                    a decision about RoutePic, not a statement of your rights: \
                    whether an AI-generated picture can be owned at all, and \
                    whether one touches somebody else's copyright, trademark or \
                    likeness, are separate questions. The model's licence is \
                    another — Stable Diffusion 1.5 ships under CreativeML Open \
                    RAIL-M, which restricts some uses. RoutePic cannot check \
                    which model a pack holds, and cannot advise you on any of it.
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
            .task {
                refreshStorage()
                await refreshModelState()
            }
            .fileImporter(
                isPresented: $showsModelPicker,
                allowedContentTypes: [.folder]
            ) { result in
                switch result {
                case .success(let url): install(from: url)
                case .failure(let error): message = error.localizedDescription
                }
            }
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

    @ViewBuilder
    private var modelSection: some View {
        Section {
            switch modelState {
            case .checking:
                HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
            case .absent:
                Button("Add a picture model") { showsModelPicker = true }
            case .installing(let fraction):
                ProgressView(value: fraction) {
                    Text("Copying the picture model…")
                }
                Button("Stop", role: .destructive) { installTask?.cancel() }
            case .installed(let bytes):
                LabeledContent("Installed", value: bytes.formatted(.byteCount(style: .file)))
                Button("Replace") { showsModelPicker = true }
                Button("Remove the picture model", role: .destructive) { removeModel() }
            }
        } header: {
            Text("Picture model")
        } footer: {
            // Nothing is downloaded from anywhere: there is no server behind
            // this app, which is the same reason no route ever leaves it.
            Text("""
            Drawing runs on this device and needs a converted Stable Diffusion \
            model, which is too large to ship inside the app. Convert one on a \
            Mac following OnDevice/README.md, put the folder in Files or \
            iCloud Drive, and pick it here. Everything else works without it.
            """)
        }
    }

    private func refreshStorage() {
        pictureBytes = (try? environment.artworkStore.totalBytes()) ?? 0
    }

    private func refreshModelState() async {
        if let fraction = await environment.modelPackInstaller.stagedFraction() {
            guard installTask == nil else {
                modelState = .installing(fraction)
                return
            }
            // Staged bytes with no task behind them are from a launch that was
            // killed mid-copy. Nothing resumes it, so it goes rather than
            // showing a bar that never moves.
            await environment.modelPackInstaller.discardStaged()
        }
        if await environment.modelPackInstaller.installed() != nil {
            modelState = .installed(await environment.modelPackInstaller.installedBytes())
        } else {
            modelState = .absent
        }
    }

    private func install(from source: URL) {
        modelState = .installing(0)
        installTask = Task {
            // A folder picked in Files is unreadable without this, and the
            // failure reads as a missing model rather than a denied one.
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            do {
                try await environment.modelPackInstaller.install(from: source) { progress in
                    await MainActor.run { modelState = .installing(progress.fraction) }
                }
            } catch is CancellationError {
                // Nothing to report: the swap happens only after a complete
                // copy, so whatever was installed is still installed.
            } catch let problem as ModelPackProblem {
                message = problem.description
            } catch {
                message = error.localizedDescription
            }
            installTask = nil
            // Always re-read the disk. A failed replacement leaves the previous
            // pack in place, and saying "not installed" over one that still
            // works takes away the only way to remove it.
            await refreshModelState()
        }
    }

    private func removeModel() {
        Task {
            do {
                try await environment.modelPackInstaller.remove()
            } catch {
                message = error.localizedDescription
            }
            await refreshModelState()
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
            // The screen stays up after this, so the figure has to move with it.
            refreshStorage()
            message = "All data deleted."
        } catch {
            message = error.localizedDescription
        }
    }
}
