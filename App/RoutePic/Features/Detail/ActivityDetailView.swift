import CoreGraphics
import RouteKit
import RoutePicStore
import ShapeKit
import SwiftUI

/// One activity in full: the picture, the route, the numbers, the note.
struct ActivityDetailView: View {

    let activity: Activity
    var onChange: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var showsRouteOverlay = false
    @State private var showsGenerate = false
    @State private var note: String = ""
    @State private var shareItem: ShareableCard?
    @State private var showsDeleteConfirmation = false
    @State private var showsPictureDeleteConfirmation = false
    @State private var errorMessage: String?

    private var selectedArtwork: Artwork? {
        activity.artworks.first(where: \.isSelected) ?? activity.artworks.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if let artwork = selectedArtwork { interpretation(artwork) }
                statistics
                // One decode for both, and for the sentence inside the notice.
                let route = activity.routeSummary()
                if !route.isReadable { unreadableNotice }
                if route.gapCount > 0 { gapNotice(route.gapCount) }
                noteEditor
            }
            .padding()
        }
        .navigationTitle(activity.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { note = activity.note ?? "" }
        .sheet(item: $shareItem) { ShareCardSheet(card: $0) }
        .sheet(isPresented: $showsGenerate) { GenerateSheet(activity: activity) }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            activity.artworks.count == 1 ? "Delete the picture?" : "Delete all pictures?",
            isPresented: $showsPictureDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deletePictures() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                activity.artworks.count == 1
                    ? "The route, its note and everything else stay."
                    : """
                        All \(activity.artworks.count) pictures for this activity go. \
                        The route, its note and everything else stay.
                        """
            )
        }
        .confirmationDialog(
            "Delete this activity?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The route, its pictures and your note will be permanently removed from this device.")
        }
    }

    // MARK: - Sections

    private var hero: some View {
        ZStack {
            if let artwork = selectedArtwork,
               let data = try? environment.artworkStore.data(named: artwork.imageFileName),
               let image = PlatformImage.from(data) {
                image.resizable().scaledToFit()
                if showsRouteOverlay {
                    RouteThumbnail(activity: activity).opacity(0.9).blendMode(.screen)
                }
            } else {
                RouteThumbnail(activity: activity).aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture {
            guard selectedArtwork != nil else { return }
            showsRouteOverlay.toggle()
        }
        .accessibilityLabel(activity.accessibilityDescription)
        .accessibilityHint(selectedArtwork == nil ? "" : "Double tap to overlay the route line")
    }

    private func interpretation(_ artwork: Artwork) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(artwork.subject).font(.title3.weight(.semibold))
            // DESIGN.md §7.2 — showing the reason is what makes the user see the
            // shape in their own route, so it is displayed verbatim.
            Text(artwork.why).font(.subheadline).foregroundStyle(.secondary)

            if artwork.trimIsStale {
                Label(
                    "Made with a looser privacy trim than your current setting.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var statistics: some View {
        let values = activity.statistics
        return VStack(spacing: 14) {
            HStack {
                StatisticTile(title: "Distance", value: CardFormatter.distance(values.distanceMeters))
                StatisticTile(title: "Moving", value: CardFormatter.duration(values.movingDuration))
                if activity.mode != .drive, let pace = values.paceSecondsPerKilometre {
                    StatisticTile(title: "Pace", value: CardFormatter.pace(pace))
                }
            }
            HStack {
                StatisticTile(
                    title: "Climb",
                    value: "\(Int(values.elevationGainMeters.rounded())) m"
                )
                StatisticTile(title: "Date", value: formattedDate)
                if let place = activity.placeName {
                    StatisticTile(title: "Near", value: place)
                }
            }
        }
    }

    private var unreadableNotice: some View {
        // Refusing to draw the route only tells somebody something if they are
        // told. `gapCount` is zero here, so the gap notice says nothing.
        Label(
            "This recording's structure could not be read, so its route is not drawn."
                + " Pictures and notes are unaffected.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func gapNotice(_ gapCount: Int) -> some View {
        // DESIGN.md §5.4 — a dropout is shown, never quietly bridged.
        Label(
            "\(gapCount) stretch\(gapCount == 1 ? "" : "es") of this route were not recorded"
                + (activity.gapDuration > 0
                   ? " (about \(CardFormatter.duration(activity.gapDuration)))." : "."),
            systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note").font(.headline)
            TextField("How did it go?", text: $note, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveNote)
            Button("Save note", action: saveNote)
                .buttonStyle(.bordered)
                .disabled(note == (activity.note ?? ""))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Make a picture", systemImage: "wand.and.stars") { showsGenerate = true }
                Button("Share…", systemImage: "square.and.arrow.up") { prepareShare() }
                Button("Export GPX", systemImage: "arrow.down.doc") { exportGPX() }
                Divider()
                // The repository could always do this; nothing ever offered it,
                // so the only way to reclaim space was to delete the run too.
                // Every picture, not the shown one. Only the selected artwork
                // is ever displayed and nothing calls `select`, so a second
                // generation leaves one nobody can see — offering to delete
                // "this picture" would leave that one behind, still costing
                // space nobody can account for.
                if !activity.artworks.isEmpty {
                    Button(
                        activity.artworks.count == 1 ? "Delete the picture" : "Delete the pictures",
                        systemImage: "photo.badge.minus",
                        role: .destructive
                    ) { showsPictureDeleteConfirmation = true }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    showsDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
        }
    }

    // MARK: - Actions

    private var formattedDate: String {
        CardFormatter.date(
            activity.startedAt,
            timeZone: TimeZone(identifier: activity.timeZoneID) ?? .current
        )
    }

    private func saveNote() {
        do {
            try environment.repository.updateNote(note.isEmpty ? nil : note, on: activity)
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try environment.repository.delete(activity)
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareShare() {
        do {
            // Always recomputed at share time (`DESIGN.md` §8.4), never reused
            // from the display path — that is how a stale, less-trimmed route
            // would leak after the user tightened the setting.
            let derived = try DerivedRoute.make(from: activity, purpose: .share)
            let artworkImage = selectedArtwork
                .flatMap { try? environment.artworkStore.data(named: $0.imageFileName) }
                .flatMap(CGImage.fromPNG)

            shareItem = ShareableCard(
                shape: derived.shape.canonical,
                statistics: activity.statistics,
                mode: activity.mode,
                date: activity.startedAt,
                placeName: activity.placeName,
                artwork: artworkImage,
                mapSnapshotIsUnsafe: derived.mapSnapshotIsUnsafe,
                timeZone: TimeZone(identifier: activity.timeZoneID) ?? .current
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePictures() {
        do {
            for artwork in activity.artworks {
                try environment.repository.delete(artwork)
            }
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportGPX() {
        do {
            // Export carries the *original* route: this is the user's own data
            // leaving on their instruction, not a public share.
            let route = try activity.route()
            let gpx = GPXDocument.write(route)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RoutePic-\(activity.id.uuidString).gpx")
            try gpx.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareableCard(fileURL: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension CGImage {
    static func fromPNG(_ data: Data) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }
}
