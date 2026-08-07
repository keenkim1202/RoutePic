import Foundation
import ShapeKit

/// `shapelab` — the spike tool and golden-test runner.
///
/// `PLAN.md` §0.1 — the spike needs "GPX → 16 orientation PNGs", which is
/// exactly what `ShapeKit` produces for the app. Running the spike through a
/// separate script would mean validating something the app does not ship.

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("shapelab: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    shapelab — RoutePic shape pipeline tool

    USAGE
      shapelab render <route.gpx> --out <dir> [--mode walk|run|drive]
                                  [--trim <metres>] [--line-width <px>]
                                  [--only <index>]
          Render the 16 orientations (DESIGN.md §4.2) as PNGs.

      shapelab sheet <route.gpx> --out <file.png> [--mode ...] [--trim <metres>]
                                  [--size <px>] [--no-labels] [--all-orientations]
          Render the orientations as one labelled contact sheet: 8 rotations
          on a 3x3 by default, or all 16 on a 4x4 with --all-orientations.
          ~16x fewer image tokens than separate per-orientation renders, and
          the only shape that fits Apple's on-device 4K context.

      shapelab fingerprint <route.gpx> [--mode walk|run|drive] [--trim <metres>]
          Print the shape fingerprint (DESIGN.md §6.2) as JSON.

      shapelab info <route.gpx>
          Point counts, length, encoded blob size.

    OPTIONS
      --mode          Resample spacing preset. Default: run.
      --trim          Privacy trim in metres. Default: \(Int(RouteTrimmer.defaultTrimMeters)).
      --line-width    Control image stroke width. Default: 11.
      --only          Render a single orientation index (0–15) instead of all 16.
      --size          Contact sheet canvas size in pixels. Default: 1024.
      --no-labels     Omit cell numbers and separators from the sheet.
      --all-orientations
                      Put all 16 orientations on the sheet instead of the 8
                      rotations. The mirrored half is usually near-duplicate;
                      this exists so SP-2 can measure that rather than assume it.
    """)
    exit(0)
}

struct Options {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                let next = index + 1 < arguments.count ? arguments[index + 1] : nil
                if let next, !next.hasPrefix("--") {
                    flags[key] = next
                    index += 2
                } else {
                    flags[key] = "true"
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    func string(_ key: String) -> String? { flags[key] }
    func double(_ key: String) -> Double? { flags[key].flatMap(Double.init) }
    func int(_ key: String) -> Int? { flags[key].flatMap(Int.init) }
}

func configuration(from options: Options) -> ShapePipeline.Configuration {
    var config: ShapePipeline.Configuration
    switch options.string("mode") ?? "run" {
    case "walk": config = .walking
    case "drive": config = .driving
    case "run": config = .running
    case let other: fail("unknown mode '\(other)'. Use walk, run or drive.")
    }
    if let trim = options.double("trim") { config.trimMeters = trim }
    return config
}

func loadRoute(_ path: String) -> Route {
    let url = URL(fileURLWithPath: path)
    do {
        return try GPXDocument.parse(contentsOf: url)
    } catch {
        fail("could not read \(path): \(error)")
    }
}

func prepare(_ route: Route, _ options: Options) -> PreparedShape {
    let pipeline = ShapePipeline(configuration: configuration(from: options))
    do {
        return try pipeline.prepare(route)
    } catch {
        fail("pipeline failed: \(error)")
    }
}

// MARK: - Commands

func renderCommand(_ options: Options) {
    guard options.positional.count >= 2 else { fail("render needs a GPX path. See --help.") }
    guard let outputPath = options.string("out") else { fail("render needs --out <dir>.") }

    let route = loadRoute(options.positional[1])
    let prepared = prepare(route, options)

    let style = ControlImageRenderer.Style(lineWidth: options.double("line-width") ?? 11)
    let renderer = ControlImageRenderer(style: style)

    let outputDirectory = URL(fileURLWithPath: outputPath)
    do {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
    } catch {
        fail("could not create \(outputPath): \(error)")
    }

    let indices: [Int]
    if let only = options.int("only") {
        guard Orientation.all.indices.contains(only) else {
            fail("--only must be 0–\(Orientation.all.count - 1).")
        }
        indices = [only]
    } else {
        indices = Array(Orientation.all.indices)
    }

    for index in indices {
        let orientation = Orientation.all[index]
        let shape = prepared.oriented(orientation)
        let name = String(format: "%02d_%03d%@.png",
                          index, orientation.rotationDegrees,
                          orientation.mirrored ? "_mirror" : "")
        do {
            let png = try renderer.renderPNG(shape)
            try png.write(to: outputDirectory.appendingPathComponent(name))
        } catch {
            fail("render failed for orientation \(index): \(error)")
        }
    }

    print("Wrote \(indices.count) orientation(s) to \(outputPath)")
    print("  vertices: \(prepared.vertexCount)   length: \(Int(prepared.lengthMeters)) m")
    if prepared.trim.trimWasCapped {
        print("  note: privacy trim was capped to \(Int(RouteTrimmer.maximumTrimFraction * 100))% of the route")
    }
    if prepared.trim.isLoop {
        print("  note: loop route — trimming does not hide the start point (DESIGN.md §8.4)")
    }
    if prepared.trim.isTooShortToShare {
        print("  note: shorter than \(Int(RouteTrimmer.minimumShareableLength)) m — map snapshot sharing is blocked")
    }
}

func sheetCommand(_ options: Options) {
    guard options.positional.count >= 2 else { fail("sheet needs a GPX path.") }
    guard let outputPath = options.string("out") else { fail("sheet needs --out <file.png>.") }

    let prepared = prepare(loadRoute(options.positional[1]), options)

    var style = options.flags["no-labels"] != nil
        ? ContactSheetRenderer.Style.bare
        : ContactSheetRenderer.Style.standard
    if let size = options.double("size") { style.canvasSize = size }
    if options.flags["all-orientations"] != nil { style.orientations = Orientation.all }

    let renderer = ContactSheetRenderer(style: style)
    let url = URL(fileURLWithPath: outputPath)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try renderer.renderPNG(prepared).write(to: url)
    } catch {
        fail("could not write \(outputPath): \(error)")
    }

    let cells = renderer.orientations().count
    print("Wrote a \(Int(style.canvasSize))px sheet with \(cells) cells to \(outputPath)")
    print("  vertices: \(prepared.vertexCount)   length: \(Int(prepared.lengthMeters)) m")
    print("")
    print(renderer.layoutDescription())
}

func fingerprintCommand(_ options: Options) {
    guard options.positional.count >= 2 else { fail("fingerprint needs a GPX path.") }
    let prepared = prepare(loadRoute(options.positional[1]), options)
    let fingerprint = prepared.canonical.fingerprint

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let json = try? encoder.encode(fingerprint) else { fail("could not encode fingerprint.") }
    print(String(decoding: json, as: UTF8.self))

    if fingerprint.isDegenerate {
        print("// degenerate: near-straight route — DESIGN.md §4.4 blocks generation")
    }
}

func infoCommand(_ options: Options) {
    guard options.positional.count >= 2 else { fail("info needs a GPX path.") }
    let route = loadRoute(options.positional[1])
    let blob = PolylineCodec.encode(route.points)
    let length = RouteTrimmer.length(of: route.points)

    print("points:        \(route.points.count)")
    print("moving runs:   \(route.movingRuns.count)")
    print("gaps:          \(route.segments.filter { $0.kind == .gap }.count)")
    print("length:        \(String(format: "%.1f", length)) m")
    print("encoded blob:  \(blob.count) bytes"
        + (route.points.isEmpty
           ? ""
           : String(format: " (%.2f B/point)", Double(blob.count) / Double(route.points.count))))
}

// MARK: - Entry

guard let command = arguments.first else { usage() }
let options = Options(arguments)

switch command {
case "render": renderCommand(options)
case "sheet": sheetCommand(options)
case "fingerprint": fingerprintCommand(options)
case "info": infoCommand(options)
case "-h", "--help", "help": usage()
default: fail("unknown command '\(command)'. Try --help.")
}
