import CoreGraphics
import ImageIO
import RouteKit
import RoutePicStore
import ShapeKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything needed to build a share card, or a file to hand off directly.
struct ShareableCard: Identifiable {
    let id = UUID()

    var shape: OrientedShape?
    var statistics: ActivityStatistics = .zero
    var mode: RecordingMode = .walk
    var date: Date = Date()
    var placeName: String?
    var artwork: CGImage?
    var mapSnapshotIsUnsafe: Bool = false
    var timeZone: TimeZone = .current
    var fileURL: URL?

    init(
        shape: OrientedShape,
        statistics: ActivityStatistics,
        mode: RecordingMode,
        date: Date,
        placeName: String?,
        artwork: CGImage?,
        mapSnapshotIsUnsafe: Bool,
        timeZone: TimeZone
    ) {
        self.shape = shape
        self.statistics = statistics
        self.mode = mode
        self.date = date
        self.placeName = placeName
        self.artwork = artwork
        self.mapSnapshotIsUnsafe = mapSnapshotIsUnsafe
        self.timeZone = timeZone
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }
}

/// Builds the card, previews it, and hands it to the share sheet.
///
/// `DESIGN.md` §9 — the user chooses what goes on it, and the defaults leave
/// off everything that could locate them.
struct ShareCardSheet: View {

    let card: ShareableCard

    @Environment(\.dismiss) private var dismiss
    @State private var aspect: CardRenderer.Aspect = .square
    @State private var contents = CardRenderer.Contents.default
    @State private var rendered: CGImage?
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if card.fileURL != nil {
                    fileHandoff
                } else {
                    cardBuilder
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var fileHandoff: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.arrow.up").font(.system(size: 48))
            Text("Your route as a GPX file.").font(.subheadline)
            if let url = card.fileURL {
                ShareLink(item: url) { Label("Share GPX", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private var cardBuilder: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let rendered {
                    PlatformImage.from(rendered)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal)
                        .accessibilityLabel("Preview of the card you are about to share")
                } else {
                    ProgressView().frame(height: 320)
                }

                Picker("Shape", selection: $aspect) {
                    Text("1:1").tag(CardRenderer.Aspect.square)
                    Text("4:5").tag(CardRenderer.Aspect.portrait)
                    Text("9:16").tag(CardRenderer.Aspect.story)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Distance", isOn: $contents.showsDistance)
                    Toggle("Time", isOn: $contents.showsDuration)
                    Toggle("Date", isOn: $contents.showsDate)
                    Toggle("Route line", isOn: $contents.showsRouteLine)
                    Toggle("Place name", isOn: $contents.showsPlaceName)
                        .disabled(card.placeName == nil)
                }
                .padding(.horizontal)

                if contents.showsRouteLine || contents.showsPlaceName {
                    Label(
                        "The route line and place name can show where you live. They are off by default.",
                        systemImage: "eye.trianglebadge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }

                if card.mapSnapshotIsUnsafe {
                    Label(
                        "This route starts and ends in the same place, so trimming cannot hide it. Consider leaving the route line off.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share image", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.vertical)
        }
        .task(id: renderKey) { render() }
    }

    private var renderKey: String {
        "\(aspect.rawValue)-\(contents.showsDistance)-\(contents.showsDuration)"
            + "-\(contents.showsDate)-\(contents.showsRouteLine)-\(contents.showsPlaceName)"
    }

    private func render() {
        guard let shape = card.shape else { return }
        do {
            let image = try CardRenderer(aspect: aspect).render(
                shape: shape,
                statistics: card.statistics,
                mode: card.mode,
                date: card.date,
                placeName: card.placeName,
                contents: contents,
                artwork: card.artwork,
                timeZone: card.timeZone
            )
            rendered = image
            exportURL = try writeStrippedPNG(image)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes the card with no metadata at all.
    ///
    /// `DESIGN.md` §11 — the card is rendered from scratch so it has no EXIF to
    /// begin with, but the destination is created with an explicitly empty
    /// property dictionary so nothing the framework might add survives either.
    private func writeStrippedPNG(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutePic-card-\(UUID().uuidString).png")

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            )
        else { throw CocoaError(.fileWriteUnknown) }

        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [:] as CFDictionary,
            kCGImagePropertyGPSDictionary: [:] as CFDictionary,
            kCGImagePropertyTIFFDictionary: [:] as CFDictionary,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
