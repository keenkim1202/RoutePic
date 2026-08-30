import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ShapeKit

/// Golden image regression (`PLAN.md` M1 / `DESIGN.md` §14.2 T-4).
///
/// The control image is the model's only view of the route, so a silent change
/// to stroke width, smoothing, or the normalise transform changes every
/// generation the app will ever make. These hashes make that change loud.
///
/// To re-baseline after an intentional change, run:
///   swift test --filter GoldenTests 2>&1 | grep 'golden:'
/// and paste the printed values back into `expectedHashes`.
@Suite("Golden images")
struct GoldenTests {

    /// SHA-256 of the rendered PNG, per fixture, at `Style.control` on a 1024² canvas.
    ///
    /// `straightLine`, `twoPoints` and `datelineCrossing` share a hash on
    /// purpose: all three normalise to the same horizontal line filling the
    /// canvas. Identical shapes must render identically.
    static let expectedHashes: [String: String] = [
        "straightLine": "707f350c507d25b4f6def6b2d018468277b29f9f07e1e2130d426e7e0853775b",
        "closedLoop": "f54432db48f91722ca8b6f3e7acecc7be11b8127aad153625801297eedb9f4f0",
        "figureEight": "25d4ad47b8f03d0a9ffaf557e3534eaadce207fba8d7b5c2a741546c3c685075",
        "wanderingWalk": "d9b3f63dbeb16b4fddba04eb84efd0e423bc4d4f388c989e60b109c7000d1c86",
        "multipleGaps": "e2e65d49855dd80151d712a8ca7bcae10c4f6633c8276c367e858c5f73df9e17",
        "duplicateCoordinates": "c75c9483796b8e1a0a3505809657177fa2e8e8f5889def24ce3d1d503c1729c0",
        "datelineCrossing": "707f350c507d25b4f6def6b2d018468277b29f9f07e1e2130d426e7e0853775b",
        "highLatitude": "cc640a03f3e9e78e3c53180eae51b4599812d751debff8b7f67a0ce23bb1a2c0",
        "twoPoints": "707f350c507d25b4f6def6b2d018468277b29f9f07e1e2130d426e7e0853775b",
    ]

    static let fixtures: [(String, Route)] = [
        ("straightLine", Fixtures.straightLine),
        ("closedLoop", Fixtures.closedLoop()),
        ("figureEight", Fixtures.figureEight()),
        ("wanderingWalk", Fixtures.wanderingWalk()),
        ("multipleGaps", Fixtures.multipleGaps),
        ("duplicateCoordinates", Fixtures.duplicateCoordinates),
        ("datelineCrossing", Fixtures.datelineCrossing),
        ("highLatitude", Fixtures.highLatitude),
        ("twoPoints", Fixtures.twoPoints),
    ]

    private static func render(_ route: Route) throws -> Data {
        let pipeline = ShapePipeline(configuration: .init(trimMeters: 0))
        let shape = try pipeline.prepare(route).canonical
        return try ControlImageRenderer(style: .control).renderPNG(shape)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Control images match their recorded hashes", arguments: fixtures)
    func matchesGolden(name: String, route: Route) throws {
        let actual = Self.hash(try Self.render(route))
        print("golden: \"\(name)\": \"\(actual)\",")

        guard let expected = Self.expectedHashes[name], expected != "PENDING" else {
            Issue.record("No baseline recorded for \(name). Paste the printed hash into expectedHashes.")
            return
        }
        #expect(actual == expected, "Control image for \(name) changed.")
    }

    @Test("Rendering is deterministic across runs")
    func deterministic() throws {
        // A hash mismatch is only meaningful if the renderer is stable to begin with.
        for (name, route) in Self.fixtures {
            let first = try Self.render(route)
            let second = try Self.render(route)
            #expect(first == second, "\(name) rendered differently on two consecutive runs.")
        }
    }

    @Test("Rendered images are the requested size and actually contain a line")
    func renderInvariants() throws {
        for (name, route) in Self.fixtures {
            let pipeline = ShapePipeline(configuration: .init(trimMeters: 0))
            let shape = try pipeline.prepare(route).canonical
            let image = try ControlImageRenderer(style: .control).render(shape)

            #expect(image.width == 1024, "\(name) wrong width")
            #expect(image.height == 1024, "\(name) wrong height")

            // A blank canvas would hash consistently and pass the golden test
            // while telling the model nothing.
            let coverage = try Self.strokeCoverage(image)
            #expect(coverage > 0.0005, "\(name) rendered almost nothing (\(coverage))")
            #expect(coverage < 0.9, "\(name) is nearly solid white")
        }
    }

    @Test("Stroke width changes the image", arguments: [ControlImageRenderer.Style.thin, .thick])
    func strokeWidthMatters(style: ControlImageRenderer.Style) throws {
        let pipeline = ShapePipeline(configuration: .init(trimMeters: 0))
        let shape = try pipeline.prepare(Fixtures.wanderingWalk()).canonical

        let control = try ControlImageRenderer(style: .control).renderPNG(shape)
        let variant = try ControlImageRenderer(style: style).renderPNG(shape)
        #expect(control != variant)
    }

    /// Fraction of pixels that are meaningfully lit.
    private static func strokeCoverage(_ image: CGImage) throws -> Double {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return 0 }

        var lit = 0
        var total = 0
        for row in 0..<image.height {
            let rowStart = row * image.bytesPerRow
            for column in 0..<image.width {
                let offset = rowStart + column * bytesPerPixel
                guard offset + 2 < data.count else { continue }
                total += 1
                let red = Int(data[offset])
                let green = Int(data[offset + 1])
                let blue = Int(data[offset + 2])
                if red + green + blue > 384 { lit += 1 }
            }
        }
        guard total > 0 else { return 0 }
        return Double(lit) / Double(total)
    }
}

@Suite("GPXDocument")
struct GPXDocumentTests {

    @Test("Parses track points with elevation and time")
    func parsesTrackPoints() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="37.5665" lon="126.9780"><ele>38.0</ele><time>2026-08-07T09:00:00Z</time></trkpt>
            <trkpt lat="37.5666" lon="126.9781"><ele>38.5</ele><time>2026-08-07T09:00:05Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let route = try GPXDocument.parse(Data(gpx.utf8))
        #expect(route.points.count == 2)
        #expect(abs(route.points[0].latitude - 37.5665) < 1e-9)
        #expect(route.points[0].altitude == 38.0)
        #expect(route.points[1].timestamp != nil)
    }

    @Test("Separate trksegs become separate runs with a gap between them")
    func segmentsBecomeGaps() throws {
        // A GPX segment break means the recorder lost signal — the same thing as
        // SegmentKind.gap. Merging them would draw a route nobody took.
        let gpx = """
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk>
          <trkseg><trkpt lat="37.5" lon="127.0"/><trkpt lat="37.51" lon="127.0"/></trkseg>
          <trkseg><trkpt lat="37.6" lon="127.0"/><trkpt lat="37.61" lon="127.0"/></trkseg>
        </trk></gpx>
        """
        let route = try GPXDocument.parse(Data(gpx.utf8))
        #expect(route.movingRuns.count == 2)
        #expect(route.segments.contains { $0.kind == .gap })
    }

    @Test("A GPX with no track points is refused")
    func noTrackPoints() {
        let gpx = "<gpx version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk/></gpx>"
        #expect(throws: GPXDocument.Failure.self) {
            try GPXDocument.parse(Data(gpx.utf8))
        }
    }

    @Test("Malformed XML is refused")
    func malformed() {
        #expect(throws: (any Error).self) {
            try GPXDocument.parse(Data("<gpx><trk>".utf8))
        }
    }

    @Test("Write then parse preserves coordinates and run structure")
    func roundTrip() throws {
        let original = Fixtures.multipleGaps
        let reparsed = try GPXDocument.parse(Data(GPXDocument.write(original).utf8))

        #expect(reparsed.points.count == original.points.count)
        #expect(reparsed.movingRuns.count == original.movingRuns.count)
        for (a, b) in zip(original.points, reparsed.points) {
            #expect(abs(a.latitude - b.latitude) < 1e-9)
            #expect(abs(a.longitude - b.longitude) < 1e-9)
        }
    }

    @Test("The creator is read, so a tool can tell the app's export from a recorder's")
    func creatorIsRead() throws {
        let foreign = try GPXDocument.parseWithCreator(
            Data("""
            <?xml version="1.0"?>
            <gpx version="1.1" creator="Garmin Connect">
              <trk><trkseg>
                <trkpt lat="37.5" lon="127.0"><time>2026-08-01T00:00:00Z</time></trkpt>
                <trkpt lat="37.501" lon="127.001"><time>2026-08-01T00:00:10Z</time></trkpt>
              </trkseg></trk>
            </gpx>
            """.utf8)
        )
        #expect(foreign.creator == "Garmin Connect")
        #expect(foreign.creator != GPXDocument.appCreator)

        let ours = try GPXDocument.parseWithCreator(Data(GPXDocument.write(foreign.route).utf8))
        #expect(ours.creator == GPXDocument.appCreator)
    }

}
