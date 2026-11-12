import ImmichKit
import SwiftUI

/// The Bloom logo: six aperture blades that swirl into a flower around an open centre.
///
/// Drawn from the same geometry as `Branding/bloom-logo` (source/kit.py), so it stays sharp at any
/// size and needs no image asset in the package.
struct BloomMark: View {
    enum Style: Equatable {
        /// The six spectrum colours.
        case color
        /// Every blade in one colour (tinted icons, reversed use).
        case monochrome(Color)
    }

    var style: Style = .color

    var body: some View {
        Canvas { context, size in
            let blades = BloomMarkGeometry.blades(in: CGRect(origin: .zero, size: size))
            for (index, blade) in blades.enumerated() {
                context.fill(blade, with: .color(color(at: index)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func color(at index: Int) -> Color {
        switch style {
        case .color: BloomMarkGeometry.palette[index]
        case .monochrome(let color): color
        }
    }
}

/// The logo's construction on a 256-unit canvas.
enum BloomMarkGeometry {
    /// Orange, yellow, green, cyan, indigo, pink: one colour per blade, in drawing order.
    static let palette: [Color] = [
        Color(red: 1.000, green: 0.541, blue: 0.000),  // #FF8A00
        Color(red: 1.000, green: 0.769, blue: 0.000),  // #FFC400
        Color(red: 0.184, green: 0.788, blue: 0.420),  // #2FC96B
        Color(red: 0.118, green: 0.702, blue: 0.941),  // #1EB3F0
        Color(red: 0.353, green: 0.361, blue: 0.949),  // #5A5CF2
        Color(red: 1.000, green: 0.239, blue: 0.498),  // #FF3D7F
    ]

    private static let canvas: CGFloat = 256
    private static let outerRadius: CGFloat = 108
    private static let openingRadius: CGFloat = 22
    private static let cutRadius: CGFloat = 58
    private static let gap: CGFloat = 9
    /// Convex corners are rounded by eroding the blades this much and growing them back with a round join.
    private static let softening: CGFloat = 4
    private static let phaseDegrees: CGFloat = -15

    /// The six blade outlines, fitted as a centred square into `rect`.
    static func blades(in rect: CGRect) -> [Path] {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return [] }
        let scale = side / canvas
        let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
        return unitBlades.map { $0.applying(transform) }
    }

    /// Built once: boolean path operations are too slow to repeat on every draw.
    private static let unitBlades: [Path] = (0..<6).map(unitBlade)

    private static func unitBlade(_ index: Int) -> Path {
        let centre = CGPoint(x: canvas / 2, y: canvas / 2)
        let erodedGap = gap + 2 * softening
        func cutCentre(_ step: Int) -> CGPoint {
            let angle = (CGFloat(step) * 60 + phaseDegrees) * .pi / 180
            return CGPoint(x: centre.x + cutRadius * cos(angle), y: centre.y + cutRadius * sin(angle))
        }
        // A blade lies inside the next cut circle and outside its own, between the opening and the rim.
        let blade = circle(centre, outerRadius - softening)
            .intersection(circle(cutCentre(index + 1), cutRadius - erodedGap / 2))
            .subtracting(circle(cutCentre(index), cutRadius + erodedGap / 2))
            .subtracting(circle(centre, openingRadius + erodedGap / 2))
        let grown = blade.strokedPath(StrokeStyle(lineWidth: 2 * softening, lineJoin: .round))
        return blade.union(grown)
    }

    private static func circle(_ centre: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

/// An app icon tile as it looks on the Home Screen, for the icon picker.
struct BloomIconTile: View {
    let choice: AppIconChoice

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            switch choice {
            case .automatic:
                tile(background: .white, mark: .color)
                tile(background: .black, mark: .color).clipShape(LowerRightTriangle())
            case .light:
                tile(background: .white, mark: .color)
            case .dark:
                tile(background: .black, mark: .color)
            case .tinted:
                tile(background: .black, mark: .monochrome(Color(white: 0.85)))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func tile(background: Color, mark: BloomMark.Style) -> some View {
        background.overlay(BloomMark(style: mark).padding(9))
    }
}

/// The lower-right half of a square, split along the diagonal.
private struct LowerRightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

#Preview("Bloom mark") {
    let _ = MockImmichService.preview
    VStack(spacing: 24) {
        BloomMark().frame(width: 160)
        HStack(spacing: 16) {
            BloomMark().frame(width: 32)
            BloomMark().frame(width: 16)
            BloomMark(style: .monochrome(.primary)).frame(width: 32)
        }
        HStack(spacing: 12) {
            ForEach(AppIconChoice.allCases) { BloomIconTile(choice: $0).frame(width: 60) }
        }
    }
    .padding(40)
}
