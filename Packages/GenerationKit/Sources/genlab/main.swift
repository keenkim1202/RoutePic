import Foundation
import GenerationKit
import RouteKit
import ShapeKit

// What Stage 1 would choose for a route, on the command line.
//
// SP-1 #7 — every arm uses the subject Stage 1 picked, never a hand-written
// prompt. Without this the sweep is measuring somebody's phrasing.
//
// It takes the GPX rather than a fingerprint, because two of the app's three
// refusals cannot be seen in a fingerprint: route length is not in one, and
// the resample spacing that produces it depends on the mode.
//
//     genlab subject route.gpx --mode walk --trim 200

let usage = "usage: genlab subject <route.gpx> [--mode walk|run|drive] [--trim <metres>]"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("genlab: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "-h" || arguments.first == "--help" {
    print(usage)
    exit(0)
}
// Anything else that is not a real invocation goes to stderr and fails. On
// stdout at exit 0 it becomes the prompt in `--prompt "$(genlab ...)"`, and the
// sweep generates fifteen images of the usage text.
guard arguments.first == "subject", arguments.count >= 2 else { fail(usage) }

/// A trailing `--mode` with nothing after it is a typo, not a crash: the
/// unchecked lookahead traps before `fail` can report the invocation.
func value(for option: String) -> String? {
    guard let index = arguments.firstIndex(of: option) else { return nil }
    guard index + 1 < arguments.count else { fail("\(option) wants a value") }
    return arguments[index + 1]
}

let mode: RecordingMode
switch value(for: "--mode") ?? "run" {
case "walk": mode = .walk
case "run": mode = .run
case "drive": mode = .drive
case let other: fail("unknown mode '\(other)'. Use walk, run or drive.")
}

// `DerivedRoute.make` overrides the mode's own trim with the activity's, which
// a person can set to 0, 200 or 500. A different trim is a different shape and
// can be a different subject, so it has to be given, not assumed.
let trimMeters: Double
if let given = value(for: "--trim") {
    guard let parsed = Double(given), parsed >= 0 else { fail("--trim wants metres") }
    trimMeters = parsed
} else {
    trimMeters = RouteTrimmer.defaultTrimMeters
}

let route: Route
do {
    let parsed = try GPXDocument.parseWithCreator(contentsOf: URL(fileURLWithPath: arguments[1]))
    if parsed.creator != GPXDocument.appCreator {
        FileHandle.standardError.write(
            Data("genlab: \(GPXDocument.foreignExportWarning)\n".utf8)
        )
    }
    route = parsed.route
} catch {
    fail("could not read \(arguments[1]): \(error)")
}

// The same configuration `DerivedRoute.make` builds.
var configuration = mode.shapeConfiguration
configuration.trimMeters = trimMeters

let prepared: PreparedShape
do {
    prepared = try ShapePipeline(configuration: configuration).prepare(route)
} catch {
    fail("the shape pipeline refused this route: \(error)")
}

// What is left after trimming, which is what production measures — a 400 m
// route can fall under the bar once its ends are removed. And a fingerprint
// carries no length at all, so this refusal is invisible without the route.
guard prepared.lengthMeters >= RouteTrimmer.minimumShareableLength else {
    fail(
        "this route keeps \(Int(prepared.lengthMeters)) m after trimming, under the "
            + "\(Int(RouteTrimmer.minimumShareableLength)) m the app requires"
    )
}

let fingerprint = prepared.canonical.fingerprint
guard !fingerprint.isDegenerate else {
    fail("this route is almost a straight line, and the app blocks generation for one")
}

let interpretation = try await FingerprintInterpreter().interpret(
    sheet: Data(), layout: "", fingerprint: fingerprint
)

// What `GenerationCoordinator.prepare` requires before it will draw anything.
// A refused route is not drawn at all — the screen says so and stops — so
// printing the fallback would have the sweep judge images the app never makes.
guard interpretation.recognizable, let candidate = interpretation.candidates.first else {
    fail("this route suggests nothing to draw, and the app would not generate for it")
}
print(candidate.prompt)
