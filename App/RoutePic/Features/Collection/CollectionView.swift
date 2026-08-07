import RouteKit
import RoutePicStore
import SwiftData
import SwiftUI

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
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "figure.walk",
                        description: Text("Record a walk, run or drive and it will appear here.")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Collection")
            .toolbar { toolbar }
            .task { reload() }
            .onChange(of: modeFilter) { _, _ in reload() }
            .onChange(of: favouritesOnly) { _, _ in reload() }
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
