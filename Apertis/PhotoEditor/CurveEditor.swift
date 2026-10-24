import SwiftUI
import ApertisCore

/// Éditeur de courbe tactile. Les points sont en coordonnées [0, 1], y vers le haut.
/// Les extrémités restent sur les bords gauche et droit ; un point intérieur glissé hors du
/// cadre est supprimé.
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    var color: Color
    let onCommit: () -> Void

    @State private var dragIndex: Int?
    private static let maxPoints = 14

    private var workingPoints: [CurvePoint] {
        points.count >= 2 ? points.sorted { $0.x < $1.x } : [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let pts = workingPoints
            ZStack {
                Path { path in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        path.move(to: CGPoint(x: size.width * f, y: 0))
                        path.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * f))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [4]))
                Path { path in
                    for i in 0...100 {
                        let x = Double(i) / 100
                        let y = ToneCurve.interpolate(pts, at: x)
                        let point = CGPoint(x: size.width * x, y: size.height * (1 - y))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(color, lineWidth: 2)
                ForEach(pts.indices, id: \.self) { i in
                    Circle()
                        .fill(i == dragIndex ? color : Color(.systemBackground))
                        .overlay(Circle().stroke(color, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(x: size.width * pts[i].x, y: size.height * (1 - pts[i].y))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in drag(to: value.location, in: size) }
                .onEnded { value in endDrag(at: value.location, in: size) })
        }
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func normalized(_ location: CGPoint, in size: CGSize) -> CurvePoint {
        CurvePoint(x: Double(location.x / size.width), y: Double(1 - location.y / size.height))
    }

    private func drag(to location: CGPoint, in size: CGSize) {
        var pts = workingPoints
        let p = normalized(location, in: size)
        if dragIndex == nil {
            let hitRadius = 28 / Double(size.width)
            if let nearest = pts.indices.min(by: { hypot(pts[$0].x - p.x, pts[$0].y - p.y) < hypot(pts[$1].x - p.x, pts[$1].y - p.y) }),
               hypot(pts[nearest].x - p.x, pts[nearest].y - p.y) < hitRadius {
                dragIndex = nearest
            } else if pts.count < Self.maxPoints, p.x > 0.01, p.x < 0.99 {
                pts.append(CurvePoint(x: p.x, y: ToneCurve.interpolate(pts, at: p.x)))
                pts.sort { $0.x < $1.x }
                dragIndex = pts.firstIndex { $0.x == p.x }
            } else {
                return
            }
        }
        guard let i = dragIndex else { return }
        let isEndpoint = i == 0 || i == pts.count - 1
        let lower = i == 0 ? 0 : pts[i - 1].x + 0.01
        let upper = i == pts.count - 1 ? 1 : pts[i + 1].x - 0.01
        let x = isEndpoint ? pts[i].x : min(max(p.x, lower), upper)
        pts[i] = CurvePoint(x: x, y: min(max(p.y, 0), 1))
        points = pts
    }

    private func endDrag(at location: CGPoint, in size: CGSize) {
        defer {
            dragIndex = nil
            onCommit()
        }
        guard let i = dragIndex else { return }
        var pts = workingPoints
        let p = normalized(location, in: size)
        let outside = p.y < -0.12 || p.y > 1.12
        if outside, i > 0, i < pts.count - 1 {
            pts.remove(at: i)
            points = pts
        }
    }
}
