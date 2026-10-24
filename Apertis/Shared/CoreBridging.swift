import AVFoundation
import ApertisCore

extension Rational {
    /// Conversion exacte quand le dénominateur tient dans un `CMTimeScale`.
    var cmTime: CMTime {
        if denominator <= Int64(Int32.max) {
            return CMTime(value: numerator, timescale: CMTimeScale(denominator))
        }
        return CMTime(seconds: seconds, preferredTimescale: 600_000)
    }

    init(_ time: CMTime) {
        if time.isValid && time.isNumeric && time.timescale != 0 {
            self.init(time.value, Int64(time.timescale))
        } else {
            self.init(0)
        }
    }
}
