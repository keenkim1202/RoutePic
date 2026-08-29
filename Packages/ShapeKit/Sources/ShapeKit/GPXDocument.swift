import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimal GPX reading and writing.
///
/// Only what RoutePic needs: `trkpt` latitude/longitude, elevation, and time.
/// Route metadata, waypoints and extensions are ignored on read and not
/// produced on write. This is the entry point for the spike's real-world GPX
/// corpus (`PLAN.md` M0.5) and for the app's export (`DESIGN.md` §9).
public enum GPXDocument {

    public enum Failure: DescribedError {
        case malformed(String)
        case noTrackPoints

        public var description: String {
            switch self {
            case .malformed(let detail): return "Malformed GPX: \(detail)"
            case .noTrackPoints: return "GPX contains no <trkpt> elements."
            }
        }
    }

    /// Parses track points, preserving `<trkseg>` boundaries as separate runs.
    ///
    /// A GPX segment break means the recorder lost the signal, which is the same
    /// thing as `SegmentKind.gap` — joining them would draw a route the person
    /// never took.
    public static func parse(_ data: Data) throws -> Route {
        let parser = XMLParser(data: data)
        let delegate = TrackParser()
        parser.delegate = delegate

        guard parser.parse() else {
            throw Failure.malformed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        delegate.closeSegment()
        guard !delegate.runs.isEmpty else { throw Failure.noTrackPoints }

        var points: [RoutePoint] = []
        var segments: [RouteSegment] = []
        for (index, run) in delegate.runs.enumerated() {
            if index > 0 {
                segments.append(
                    RouteSegment(startIndex: points.count, endIndex: points.count, kind: .gap)
                )
            }
            let start = points.count
            points.append(contentsOf: run)
            segments.append(RouteSegment(startIndex: start, endIndex: points.count, kind: .moving))
        }

        return Route(points: points, segments: segments)
    }

    public static func parse(contentsOf url: URL) throws -> Route {
        try parse(Data(contentsOf: url))
    }

    public static func write(_ route: Route, creator: String = "RoutePic") -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(creator)" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>

        """

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for segment in route.segments where segment.kind == .moving && segment.count > 0 {
            xml += "    <trkseg>\n"
            for point in route.points[segment.startIndex..<segment.endIndex] {
                xml += "      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
                if let altitude = point.altitude {
                    xml += "<ele>\(altitude)</ele>"
                }
                if let timestamp = point.timestamp {
                    xml += "<time>\(formatter.string(from: timestamp))</time>"
                }
                xml += "</trkpt>\n"
            }
            xml += "    </trkseg>\n"
        }

        xml += "  </trk>\n</gpx>\n"
        return xml
    }

    private final class TrackParser: NSObject, XMLParserDelegate {
        var runs: [[RoutePoint]] = []
        private var current: [RoutePoint] = []
        private var pending: RoutePoint?
        private var text = ""

        private let formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let fallbackFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func closeSegment() {
            if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }

        func parser(
            _ parser: XMLParser,
            didStartElement element: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            text = ""
            switch element {
            case "trkseg":
                closeSegment()
            case "trkpt":
                guard
                    let latitude = attributes["lat"].flatMap(Double.init),
                    let longitude = attributes["lon"].flatMap(Double.init)
                else { return }
                pending = RoutePoint(latitude: latitude, longitude: longitude)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement element: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "ele":
                pending?.altitude = Double(trimmed)
            case "time":
                pending?.timestamp = formatter.date(from: trimmed)
                    ?? fallbackFormatter.date(from: trimmed)
            case "trkpt":
                if let point = pending { current.append(point) }
                pending = nil
            case "trkseg":
                closeSegment()
            default:
                break
            }
            text = ""
        }
    }
}
