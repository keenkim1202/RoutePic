import RouteKit
import RoutePicStore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The personal collection.
///
/// `DESIGN.md` OQ-A settled this as private-only for v1: no other people's
/// activities appear here, and a v2 "Explore" tab is where a social feed would
/// live. Two layouts because "Instagram-like" covers both a grid and a
/// chronological feed and the design left the choice open.
struct CollectionView: View {

    enum Layout: String, CaseIterable {
        case grid
        case timeline
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var layout: Layout = .grid
    @State private var modeFilter: RecordingMode?
    @State private var favouritesOnly = false
    @State private var activities: [Activity] = []
    @State private var loadError: String?
    @State private var showsImporter = false
    @State private var importProgress: String?
    @State private var importSummary: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Could not load your collection",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if activities.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "figure.walk")
                    } description: {
                        Text("Record a walk, run or drive — or bring in routes you have already recorded elsewhere.")
                    } actions: {
                        Button("Import GPX files") { showsImporter = true }
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Collection")
            .toolbar { toolbar }
            .task { reload() }
            .onChange(of: modeFilter) { _, _ in reload() }
            .onChange(of: favouritesOnly) { _, _ in reload() }
            .fileImporter(
                isPresented: $showsImporter,
                allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): Task { await runImport(urls) }
                case .failure(let error): importSummary = error.localizedDescription
                }
            }
            .overlay(alignment: .bottom) {
                if let importProgress {
                    Text(importProgress)
                        .font(.footnote)
                        .padding(12)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
            .alert(
                "Import",
                isPresented: Binding(
                    get: { importSummary != nil },
                    set: { if !$0 { importSummary = nil } }
                )
            ) {
                Button("OK") { importSummary = nil }
            } message: {
                Text(importSummary ?? "")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if layout == .grid {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(activities) { activity in
                        NavigationLink(value: activity.id) {
                            ActivityTile(activity: activity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                LazyVStack(spacing: 24) {
                    ForEach(activities) { activity in
                        NavigationLink(value: activity.id) {
                            ActivityFeedCard(activity: activity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let activity = activities.first(where: { $0.id == id }) {
                ActivityDetailView(activity: activity, onChange: reload)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Picker("Layout", selection: $layout) {
                Image(systemName: "square.grid.3x3").tag(Layout.grid)
                Image(systemName: "rectangle.grid.1x2").tag(Layout.timeline)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .accessibilityLabel("Layout")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Mode", selection: $modeFilter) {
                    Text("All").tag(RecordingMode?.none)
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(RecordingMode?.some(mode))
                    }
                }
                Toggle("Favourites only", isOn: $favouritesOnly)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filter")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Import", systemImage: "square.and.arrow.down") { showsImporter = true }
        }
    }

    /// Brings in GPX files exported from somewhere else.
    ///
    /// One file at a time with a yield between: a Strava export is hundreds of
    /// files and the repository is main-actor bound, so a tight loop freezes
    /// the collection until the last one lands.
    private func runImport(_ urls: [URL]) async {
        var imported = 0
        var skipped = 0
        var failures: [String] = []

        for (index, url) in urls.enumerated() {
            importProgress = "Importing \(index + 1) of \(urls.count)…"
            await Task.yield()

            // Files picked outside the app's own container stay unreadable
            // without this, and the failure is a permission error rather than a
            // parse error, which reads as a corrupt file to the person.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                try environment.repository.importGPX(at: url)
                imported += 1
            } catch ActivityRepository.ImportFailure.alreadyImported {
                skipped += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }

        importProgress = nil
        reload()

        var summary = "Imported \(imported) of \(urls.count)."
        if skipped > 0 { summary += " \(skipped) were already in your collection." }
        if let first = failures.first {
            summary += " \(failures.count) could not be read — \(first)"
        }
        importSummary = summary
    }

    private func reload() {
        do {
            activities = try environment.repository.activities(
                mode: modeFilter, favouritesOnly: favouritesOnly, limit: 200
            )
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// One square in the grid.
struct ActivityTile: View {
    let activity: Activity
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ZStack {
            if let artwork = activity.artworks.first(where: \.isSelected) ?? activity.artworks.first,
               let data = try? environment.artworkStore.data(named: artwork.thumbnailFileName),
               let image = PlatformImage.from(data) {
                image.resizable().scaledToFill()
            } else {
                RouteThumbnail(activity: activity)
            }
        }
        .frame(minHeight: 0)
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .accessibilityLabel(activity.accessibilityDescription)
    }
}

/// A single entry in the chronological layout.
struct ActivityFeedCard: View {
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityTile(activity: activity)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            HStack {
                Label(activity.mode.title, systemImage: activity.mode.symbol)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(CardFormatter.distance(activity.distanceMeters))
                    .font(.subheadline).monospacedDigit()
                Text(CardFormatter.duration(activity.movingDuration))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            if let note = activity.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension RecordingMode {
    var symbol: String {
        switch self {
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .drive: "car.fill"
        }
    }
}

extension Activity {
    /// `DESIGN.md` §9 — VoiceOver gets the subject and the reason, not "image".
    var accessibilityDescription: String {
        let artwork = artworks.first(where: \.isSelected) ?? artworks.first
        let base = "\(mode.title), \(CardFormatter.distance(distanceMeters))"
        guard let artwork else { return "\(base). Route drawing." }
        return "\(base). \(artwork.subject). \(artwork.why)"
    }
}
