import SwiftUI

/// The notch silhouette: flat top (sits flush with the screen edge) and
/// rounded bottom corners that mirror the physical notch's inner curves.
///
/// Uses `.continuous` (squircle) corners — curvature ramps in gradually
/// instead of jumping to a constant radius, matching how Apple draws the
/// hardware notch and the Dynamic Island. Plain circular arcs at this
/// scale show a visible kink at the tangent point.
struct IslandShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius: CGFloat = 14
#if compiler(>=5.9)
        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: 0
            ),
            style: .continuous
        ).path(in: r)
#else
        let corner = min(radius, r.width / 2, r.height)
        let control = corner * 0.552_284_749_8
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - corner))
        path.addCurve(
            to: CGPoint(x: r.maxX - corner, y: r.maxY),
            control1: CGPoint(x: r.maxX, y: r.maxY - corner + control),
            control2: CGPoint(x: r.maxX - corner + control, y: r.maxY)
        )
        path.addLine(to: CGPoint(x: r.minX + corner, y: r.maxY))
        path.addCurve(
            to: CGPoint(x: r.minX, y: r.maxY - corner),
            control1: CGPoint(x: r.minX + corner - control, y: r.maxY),
            control2: CGPoint(x: r.minX, y: r.maxY - corner + control)
        )
        path.closeSubpath()
        return path
#endif
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var s = self
        s.inset += amount
        return s
    }
}
