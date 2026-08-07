import RouteKit
import RoutePicStore
import SwiftData
import SwiftUI

@main
struct RoutePicApp: App {

    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(environment.container)
        }
    }
}

/// Everything the views need, assembled once.
///
/// `DESIGN.md` §10.1 — v0.2 collapsed the five planned packages down to two
/// plus feature folders, so this is the composition root rather than a DI
/// framework.
@Observable
@MainActor
final class AppEnvironment {

    let container: ModelContainer
    let repository: ActivityRepository
    let artworkStore: any ArtworkStore
    let recorder: RecordingController

    /// A storage problem the user needs to know about (`DESIGN.md` §14.1).
    var startupWarning: String?

    init(
        container: ModelContainer,
        artworkStore: any ArtworkStore,
        locationSource: any LocationSource
    ) {
        self.container = container
        self.artworkStore = artworkStore
        let context = ModelContext(container)
        self.repository = ActivityRepository(context: context, artworkStore: artworkStore)
        self.recorder = RecordingController(
            locationSource: locationSource,
            repository: repository
        )
    }

    static func live() -> AppEnvironment {
        do {
            let store = try FileArtworkStore.applicationDefault()
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let container = try ActivityRepository.onDiskContainer(
                url: base.appendingPathComponent("RoutePic.store")
            )
            return AppEnvironment(
                container: container,
                artworkStore: store,
                locationSource: ClassicLocationSource()
            )
        } catch {
            // A corrupt or unwritable store must not be a silent blank app: fall
            // back to memory so the user can still record, and say what happened.
            let environment = AppEnvironment(
                container: try! ActivityRepository.inMemoryContainer(),
                artworkStore: InMemoryArtworkStore(),
                locationSource: ClassicLocationSource()
            )
            environment.startupWarning =
                "Saved activities could not be opened, so this session will not be kept. \(error.localizedDescription)"
            return environment
        }
    }

    /// Sweeps image files no row points at (`DESIGN.md` §8.1).
    func runMaintenance() {
        guard let store = artworkStore as? FileArtworkStore else { return }
        try? OrphanCleaner.sweep(context: repository.context, store: store)
    }
}
