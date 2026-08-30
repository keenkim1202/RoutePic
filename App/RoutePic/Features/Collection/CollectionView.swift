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
    /// One flag for both sources. They write the same progress and summary, so
    /// two at once means whichever finishes first clears the other's progress
    /// and whichever finishes last overwrites its result.
    @State private var isImporting = false
    @State private var monthFilter: MonthKey?
    @State private var monthSummaries: [MonthSummary] = []
    @State private var hasMore = false
    @State private var isLoadingMore = false

    /// One screen's worth and then some. The month picker narrows the query,
    /// but a single month can still hold more than a page — someone logging
    /// every drive does.
    private static let pageSize = 200

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    /// Section boundaries only — the repository's newest-first order is kept.
    private var months: [ActivityMonth] { activities.groupedByMonth() }

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
                        VStack(spacing: 8) {
                            if HealthWorkoutReader.isAvailable {
                                Button("Bring in your Health workouts") { importHealth() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(isImporting)
                            }
                            Button("Import GPX files") { showsImporter = true }
                                .disabled(isImporting)
                        }
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
            .onChange(of: monthFilter) { _, _ in reload() }
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
                LazyVGrid(columns: columns, spacing: 3, pinnedViews: [.sectionHeaders]) {
                    ForEach(months) { month in
                        Section {
                            ForEach(month.activities) { activity in
                                NavigationLink(value: activity.id) {
                                    ActivityTile(activity: activity)
                                }
                                .buttonStyle(.plain)
                                .onAppear { loadMoreIfLast(activity) }
                            }
                        } header: {
                            monthHeader(month)
                        }
                    }
                }
            } else {
                LazyVStack(spacing: 24, pinnedViews: [.sectionHeaders]) {
                    ForEach(months) { month in
                        Section {
                            ForEach(month.activities) { activity in
                                NavigationLink(value: activity.id) {
                                    ActivityFeedCard(activity: activity)
                                }
                                .buttonStyle(.plain)
                                .onAppear { loadMoreIfLast(activity) }
                            }
                        } header: {
                            monthHeader(month)
                        }
                    }
                }
                .padding(.horizontal)
            }

            if isLoadingMore {
                ProgressView().padding()
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let activity = activities.first(where: { $0.id == id }) {
                ActivityDetailView(activity: activity, onChange: reload)
            }
        }
    }

    /// Pages in the next block when the last loaded row comes on screen.
    ///
    /// A month can hold more than a page, and picking one is exactly when
    /// someone means to see all of it — a cap there is a dead end with no
    /// control to escape it.
    private func loadMoreIfLast(_ activity: Activity) {
        guard hasMore, !isLoadingMore, activity.id == activities.last?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try environment.repository.activities(
                mode: modeFilter, favouritesOnly: favouritesOnly,
                inMonth: monthFilter, offset: activities.count, limit: Self.pageSize
            )
            activities += next
            hasMore = next.count == Self.pageSize
        } catch {
            hasMore = false
            loadError = error.localizedDescription
        }
    }

    /// The count comes from the summary, not the loaded rows: a month holding
    /// more than a page would otherwise show 200 and climb as it pages.
    private func monthHeader(_ month: ActivityMonth) -> some View {
        HStack {
            Text(Self.monthTitle(month.id))
                .font(.headline)
            Spacer()
            Text("\(monthSummaries.first { $0.id == month.id }?.count ?? month.activities.count)")
                .font(.subheadline).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, layout == .grid ? 12 : 0)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    static func monthTitle(_ month: MonthKey) -> String {
        month.displayDate.formatted(.dateTime.year().month(.wide))
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
        // A month narrows the query rather than scrolling the loaded page: the
        // page holds 200 rows and a bulk import is thousands, so a scroll
        // target could not reach the months this menu exists for.
        if monthSummaries.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Month", selection: $monthFilter) {
                        Text("All months").tag(MonthKey?.none)
                        ForEach(monthSummaries) { month in
                            Text("\(Self.monthTitle(month.id))  ·  \(month.count)")
                                .tag(MonthKey?.some(month.id))
                        }
                    }
                } label: {
                    Image(systemName: monthFilter == nil ? "calendar" : "calendar.badge.clock")
                }
                .accessibilityLabel("Month")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if HealthWorkoutReader.isAvailable {
                    Button("From Health", systemImage: "heart") { importHealth() }
                }
                Button("From GPX files", systemImage: "doc") { showsImporter = true }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Import")
            .disabled(isImporting)
        }
    }

    /// Brings in GPX files exported from somewhere else.
    ///
    /// One file at a time with a yield between: a Strava export is hundreds of
    /// files and the repository is main-actor bound, so a tight loop freezes
    /// the collection until the last one lands.
    private func runImport(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }
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
            } catch let refusal as ActivityRepository.ImportFailure
                        where refusal.isDeliberate {
                skipped += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }

        importProgress = nil
        reload()

        // The same wording Health gets. Two copies drifted apart the moment
        // `.tooShort` started counting as skipped: this one still said every
        // skipped file was already in the collection.
        importSummary = ImportReport.summary(
            found: urls.count, imported: imported, skipped: skipped, failures: failures
        )
    }

    /// Health already holds years of this. `PLAN.md` P0.1 — the app is empty
    /// on the day it is installed, and asking somebody to walk for half an hour
    /// before anything appears is a poor first impression.
    private func importHealth() {
        isImporting = true
        Task {
            defer { isImporting = false }
            let reader = HealthWorkoutReader()
            do {
                try await reader.requestAuthorization()
                importProgress = "Reading Health…"

                let candidates = try await reader.workouts()
                // Workouts with a route, which is not the same as workouts of
                // a kind we support: a treadmill run passes the type check and
                // has nothing to draw. Counting candidates would report
                // "imported 0 of 47" for a history that never had a route.
                var found = 0
                var imported = 0
                var skipped = 0
                var failures: [String] = []

                for (index, workout) in candidates.enumerated() {
                    importProgress = "Checking \(index + 1) of \(candidates.count)…"
                    // One route at a time, so only one is ever in memory. The
                    // repository is main-actor bound, so the yield keeps the
                    // collection alive between workouts.
                    await Task.yield()
                    do {
                        let points = try await reader.points(for: workout)
                        guard !points.isEmpty else { continue }
                        found += 1
                        try environment.repository.importRoute(
                            points,
                            mode: workout.mode,
                            startedAt: workout.startedAt,
                            endedAt: workout.endedAt,
                            timeZoneID: workout.timeZoneID
                        )
                        imported += 1
                    } catch let refusal as ActivityRepository.ImportFailure
                                where refusal.isDeliberate {
                        // Read fine, refused on purpose — a 47 m walk to the
                        // shop is not a fault to report as one.
                        skipped += 1
                    } catch {
                        // This workout's problem, not the history's. A route
                        // deleted mid-import used to end the whole read and
                        // leave everything older unexamined.
                        failures.append(error.localizedDescription)
                    }
                }

                importProgress = nil
                reload()
                importSummary = ImportReport.summary(
                    found: found, imported: imported,
                    skipped: skipped, failures: failures
                )
            } catch {
                importProgress = nil
                importSummary = error.localizedDescription
            }
        }
    }

    private func reload() {
        do {
            monthSummaries = try environment.repository.activityMonths(
                mode: modeFilter, favouritesOnly: favouritesOnly
            )
            // A month that no longer matches the mode or favourite filter would
            // otherwise leave the screen empty with no way back.
            if let monthFilter, !monthSummaries.contains(where: { $0.id == monthFilter }) {
                self.monthFilter = nil
            }
            activities = try environment.repository.activities(
                mode: modeFilter, favouritesOnly: favouritesOnly,
                inMonth: monthFilter, limit: Self.pageSize
            )
            hasMore = activities.count == Self.pageSize
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
        // Once per evaluation. Reading it twice decodes the whole polyline
        // twice for every visible card, on the scrolling path.
        //
        // ponytail: still one decode per card per update. Cache it on the row
        // if a long collection ever feels slow.
        let readable = activity.isRouteReadable

        return ZStack {
            if let artwork = activity.artworks.first(where: \.isSelected) ?? activity.artworks.first,
               let data = try? environment.artworkStore.data(named: artwork.thumbnailFileName),
               let image = PlatformImage.from(data) {
                image.resizable().scaledToFill()
            } else {
                RouteThumbnail(activity: activity)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The thumbnail carries its own marker, but a damaged activity
            // with artwork never shows one — the picture is drawn instead.
            if !readable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(4)
            }
        }
        .frame(minHeight: 0)
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .accessibilityLabel(
            readable
                ? activity.accessibilityDescription
                : "\(activity.accessibilityDescription) This recording could not be read."
        )
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
