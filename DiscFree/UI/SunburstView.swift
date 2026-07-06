import SwiftUI

/// Maps sunburst segments (depth + angles) to on-screen geometry for a given view size,
/// and back again for hit-testing. Angles are measured from the top, increasing clockwise.
struct SunburstGeometry {
    let center: CGPoint
    let innerRadius: CGFloat
    let ringThickness: CGFloat
    let ringCount: Int

    init(size: CGSize, ringCount: Int) {
        self.ringCount = max(1, ringCount)
        let side = min(size.width, size.height)
        let outer = max(1, side / 2 - 8)
        let inner = outer * 0.30
        self.center = CGPoint(x: size.width / 2, y: size.height / 2)
        self.innerRadius = inner
        self.ringThickness = (outer - inner) / CGFloat(self.ringCount)
    }

    var outerRadius: CGFloat { innerRadius + ringThickness * CGFloat(ringCount) }
    func innerRadius(depth: Int) -> CGFloat { innerRadius + ringThickness * CGFloat(depth - 1) }
    func outerRadius(depth: Int) -> CGFloat { innerRadius + ringThickness * CGFloat(depth) }

    func point(radius: CGFloat, angle: Double) -> CGPoint {
        let a = angle - .pi / 2  // rotate so 0 is at the top
        return CGPoint(x: center.x + radius * CGFloat(cos(a)),
                       y: center.y + radius * CGFloat(sin(a)))
    }

    /// Annular sector for a segment, approximated with short line steps (~2° each) so the
    /// arc is smooth without relying on `addArc` orientation conventions.
    func path(for segment: SunburstSegment) -> Path {
        let ri = innerRadius(depth: segment.depth)
        let ro = outerRadius(depth: segment.depth)
        let a0 = segment.startAngle
        let a1 = segment.endAngle
        let steps = max(2, Int((a1 - a0) / (2 * .pi / 180)))

        var path = Path()
        for i in 0...steps {
            let t = a0 + (a1 - a0) * Double(i) / Double(steps)
            let p = point(radius: ro, angle: t)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        for i in 0...steps {
            let t = a1 - (a1 - a0) * Double(i) / Double(steps)
            path.addLine(to: point(radius: ri, angle: t))
        }
        path.closeSubpath()
        return path
    }

    /// Returns the ring depth (0 = center hole) and angle for a point, or nil if outside.
    func hitTest(_ p: CGPoint) -> (depth: Int, angle: Double)? {
        let dx = Double(p.x - center.x)
        let dy = Double(p.y - center.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < Double(innerRadius) { return (0, 0) }
        if distance > Double(outerRadius) { return nil }

        let depth = Int((distance - Double(innerRadius)) / Double(ringThickness)) + 1
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        if angle >= 2 * .pi { angle -= 2 * .pi }
        return (min(depth, ringCount), angle)
    }
}

/// The sunburst chart: focus in the center hole, descendant rings outward, click to drill,
/// click the center to go up, hover to highlight and inspect.
struct SunburstView: View {
    let segments: [SunburstSegment]
    let focus: FileNode
    /// The focus's size for the current mode (its effective dev total in `.devOnly`).
    let focusTotal: Int64
    let mode: DisplayMode
    let onDrill: (FileNode) -> Void
    let onAscend: () -> Void

    /// Shared with the contents panel so hovering in either place highlights both.
    @Binding var hovered: FileNode?

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size, ringCount: SunburstLayout.maxDepth)
            let hoveredID = hovered.map(ObjectIdentifier.init)

            ZStack {
                Canvas { context, size in
                    let g = SunburstGeometry(size: size, ringCount: SunburstLayout.maxDepth)
                    for segment in segments {
                        let path = g.path(for: segment)
                        let fill = segment.id == hoveredID ? segment.highlightedColor : segment.color
                        context.fill(path, with: .color(fill))
                        context.stroke(path, with: .color(.black.opacity(0.10)), lineWidth: 0.5)
                    }
                }
                centerLabel(geometry)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in handleTap(value.location, geometry) })
            .onContinuousHover { phase in handleHover(phase, geometry) }
        }
    }

    @ViewBuilder
    private func centerLabel(_ geometry: SunburstGeometry) -> some View {
        let shown = hovered ?? focus
        // The focus total is precomputed for the mode; a hovered node's effective size is
        // resolved on demand (only while hovering a single node).
        let shownSize = shown === focus ? focusTotal : displaySize(shown)
        VStack(spacing: 3) {
            Text(shown.displayName)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
            Text(byteString(shownSize))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if hovered == nil, focus.parent != nil {
                Text("Click center to go up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .frame(width: max(64, geometry.innerRadius * 1.7))
        .position(geometry.center)
    }

    private func handleTap(_ location: CGPoint, _ geometry: SunburstGeometry) {
        guard let hit = geometry.hitTest(location) else { return }
        if hit.depth == 0 {
            onAscend()
            return
        }
        if let segment = segment(at: hit) {
            onDrill(segment.node)
        }
    }

    private func handleHover(_ phase: HoverPhase, _ geometry: SunburstGeometry) {
        switch phase {
        case .active(let location):
            if let hit = geometry.hitTest(location), hit.depth > 0,
               let segment = segment(at: hit) {
                hovered = segment.node
            } else {
                hovered = nil
            }
        case .ended:
            hovered = nil
        }
    }

    private func segment(at hit: (depth: Int, angle: Double)) -> SunburstSegment? {
        segments.first {
            $0.depth == hit.depth && hit.angle >= $0.startAngle && hit.angle < $0.endAngle
        }
    }

    /// The size shown for a hovered node, matching the slice it labels. In `.devOnly` this is
    /// the node's effective dev size, so the text agrees with the drawn angle.
    private func displaySize(_ node: FileNode) -> Int64 {
        switch mode {
        case .all, .devHighlight:
            return node.allocatedSize
        case .devOnly:
            return DevClassifier.isWithinDevItem(node) ? node.allocatedSize : node.devSize
        }
    }
}
