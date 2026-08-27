import GenerationCoreML
import GenerationKit
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

    /// Where the Core ML pack lives, and the one thing that puts it there.
    /// Both the installer and each generator read the same directory, so
    /// holding one here is bookkeeping rather than shared state.
    let modelPackURL: URL
    let modelPackInstaller: ModelPackInstaller

    /// A storage problem the user needs to know about (`DESIGN.md` §14.1).
    var startupWarning: String?

    init(
        container: ModelContainer,
        artworkStore: any ArtworkStore,
        locationSource: any LocationSource
    ) {
        self.container = container
        self.artworkStore = artworkStore
        self.modelPackURL = (try? CoreMLImageGenerator.Configuration.defaultResourcesURL())
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("StableDiffusionPack", isDirectory: true)
        self.modelPackInstaller = ModelPackInstaller(destination: modelPackURL)
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
            // If even that fails there is nothing left to run, so the crash is
            // honest rather than a `try!` hidden in a recovery path.
            guard let memory = try? ActivityRepository.inMemoryContainer() else {
                fatalError("SwiftData could not create an in-memory container: \(error)")
            }
            let environment = AppEnvironment(
                container: memory,
                artworkStore: InMemoryArtworkStore(),
                locationSource: ClassicLocationSource()
            )
            environment.startupWarning =
                "Saved activities could not be opened, so this session will not be kept. \(error.localizedDescription)"
            return environment
        }
    }

    /// One generation's worth of state, made fresh each time the sheet opens.
    ///
    /// On-device: no provider account, no per-generation cost, and the shape
    /// never leaves the phone. The ledger exists only because the client takes
    /// one — an unmetered transport never touches it.
    func makeGenerationCoordinator() -> GenerationCoordinator {
        let generator = CoreMLImageGenerator(configuration: .init(resourcesURL: modelPackURL))
        let interpreter = FingerprintInterpreter()
        return GenerationCoordinator(
            client: GenerationClient(
                transport: OnDeviceTransport(generator: generator, interpreter: interpreter),
                quota: QuotaLedger(allowance: 0, periodStart: Date())
            ),
            interpreter: interpreter,
            repository: repository
        )
    }

    /// Sweeps image files no row points at (`DESIGN.md` §8.1).
    func runMaintenance() {
        // Nothing resumes a model-pack copy across a launch, so whatever is
        // staged now is from a session that was killed. Left there it reports
        // itself as an install in progress on every screen, for ever.
        Task { await modelPackInstaller.discardStaged() }

        guard let store = artworkStore as? FileArtworkStore else { return }
        try? OrphanCleaner.sweep(context: repository.context, store: store)
    }
}
