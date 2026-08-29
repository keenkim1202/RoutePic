import CoreGraphics
import RouteKit
import RoutePicStore
import ShapeKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Wraps the platform image type so views can stay platform-neutral.
enum PlatformImage {
    static func from(_ data: Data) -> Image? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    static func from(_ image: CGImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: UIImage(cgImage: image))
        #elseif canImport(AppKit)
        Image(nsImage: NSImage(cgImage: image, size: .zero))
        #else
        Image(systemName: "photo")
        #endif
    }
}

/// Draws the route line itself.
///
/// This is what the collection shows before any image exists, and what it falls
/// back to when generation is unavailable (`DESIGN.md` §4.4). Trimmed, because
/// a thumbnail is still a picture of where somebody lives.
struct RouteThumbnail: View {
    let activity: Activity

    @State private var shape: OrientedShape?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.12), Color(white: 0.22)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                if let shape {
                    RouteShapePath(shape: shape)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: proxy.size.width, height: proxy.size.width)
                }
            }
        }
        .task(id: activity.id) {
            // Always derived, never cached to disk: that is what makes a trim
            // change retroactive (`DESIGN.md` §8.4).
            shape = try? DerivedRoute
                .make(from: activity, purpose: .display, canvasSize: 256)
                .shape.canonical
        }
        // Carried here rather than at each use, so a bare one is never silent.
        // The route's own description, not the activity's: this draws the line
        // even when a picture exists, and the subject picker shows it while
        // choosing what to draw next.
        .accessibilityElement()
        .accessibilityLabel(activity.routeDescription)
    }
}

/// A `Shape` over the derived curves, so SwiftUI scales it for us.
struct RouteShapePath: Shape {
    let shape: OrientedShape

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height) / shape.canvasSize

        // Each moving run is its own subpath. Joining them would draw a straight
        // line across a dropout the person never walked (`DESIGN.md` §5.4).
        for curves in shape.curves {
            guard let first = curves.first else { continue }
            path.move(to: CGPoint(x: first.start.x * scale, y: first.start.y * scale))
            for segment in curves {
                path.addCurve(
                    to: CGPoint(x: segment.end.x * scale, y: segment.end.y * scale),
                    control1: CGPoint(x: segment.control1.x * scale, y: segment.control1.y * scale),
                    control2: CGPoint(x: segment.control2.x * scale, y: segment.control2.y * scale)
                )
            }
        }
        return path
    }
}
