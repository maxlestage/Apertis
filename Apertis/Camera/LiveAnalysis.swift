import CoreMotion
import CoreVideo
import SwiftUI

extension Histogram {
    /// Histogramme d'une image du viseur (BGRA 8 bits), échantillonnée : quelques milliers de
    /// pixels suffisent à la forme de la courbe et à la détection de l'écrêtage.
    init(bgra buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var high = 0, low = 0, total = 0
        if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self), width > 0, height > 0 {
            let step = max(1, Int((Double(width * height) / 20_000).squareRoot()))
            for y in stride(from: 0, to: height, by: step) {
                let row = base + y * rowBytes
                for x in stride(from: 0, to: width, by: step) {
                    let p = row + x * 4
                    let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                    bins[0][r] += 1
                    bins[1][g] += 1
                    bins[2][b] += 1
                    if r >= 254 || g >= 254 || b >= 254 { high += 1 }
                    if r <= 1 && g <= 1 && b <= 1 { low += 1 }
                    total += 1
                }
            }
        }
        self.init(bins: bins, clippedHighlights: high, clippedShadows: low, total: max(total, 1))
    }
}

/// Niveau électronique : inclinaison de l'appareil par rapport à l'horizontale ou à la
/// verticale la plus proche, en portrait comme en paysage (iPhone et iPad).
@MainActor
final class LevelMonitor: ObservableObject {
    /// Écart en degrés avec l'horizon (positif : sens horaire).
    @Published private(set) var tilt: Double = 0
    @Published private(set) var isAvailable = false

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        isAvailable = true
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            // Appareil presque à plat : le niveau n'a pas de sens.
            let angle = atan2(gravity.x, -gravity.y) * 180 / .pi
            let tilt = abs(gravity.z) < 0.85 ? angle - (angle / 90).rounded() * 90 : 0
            // La file `.main` exécute ce bloc sur le fil principal.
            MainActor.assumeIsolated { self?.tilt = tilt }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}

/// Trait d'horizon : vert quand l'appareil est de niveau (à 0,5° près).
struct LevelIndicator: View {
    let tilt: Double

    var body: some View {
        let level = abs(tilt) < 0.5
        ZStack {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 120, height: 1)
            Capsule().fill(level ? Color.green : Color.white).frame(width: 80, height: level ? 2 : 1.5)
                .rotationEffect(.degrees(level ? 0 : -tilt))
        }
        .animation(.easeOut(duration: 0.1), value: tilt)
        .allowsHitTesting(false)
        .accessibilityLabel(level ? "Appareil de niveau" : String(format: "Inclinaison %.0f degrés", tilt))
    }
}
