import CoreVideo
import Foundation

/// Quantitative checks that a captured frame is real content.
///
/// The acceptance criterion for Task 0.2 is "not a black or duplicated frame",
/// which is a claim about pixels — so measure pixels rather than eyeballing a
/// PNG. All sampling is strided; we only need statistics, not exactness.
struct FrameStats {
    var meanLuma: Double = 0
    var nonBlackRatio: Double = 0
    var uniqueColors: Int = 0
    /// Mean absolute per-channel difference against the previous frame.
    var diffFromPrevious: Double = 0

    static func compute(from pixelBuffer: CVPixelBuffer, previous: [UInt8]?) -> (FrameStats, [UInt8]) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (FrameStats(), [])
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Sample a grid of at most ~64x64 points to keep this cheap enough to
        // run inside the capture callback without perturbing the measurement.
        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)

        var lumaSum = 0.0
        var nonBlack = 0
        var samples = 0
        var signature: [UInt8] = []
        var colorSet = Set<UInt32>()

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * stride + x * 4
                let b = ptr[offset]
                let g = ptr[offset + 1]
                let r = ptr[offset + 2]
                // Rec. 601 luma
                lumaSum += 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                if r > 8 || g > 8 || b > 8 { nonBlack += 1 }
                colorSet.insert(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
                signature.append(contentsOf: [r, g, b])
                samples += 1
                x += stepX
            }
            y += stepY
        }

        var stats = FrameStats()
        if samples > 0 {
            stats.meanLuma = lumaSum / Double(samples)
            stats.nonBlackRatio = Double(nonBlack) / Double(samples)
            stats.uniqueColors = colorSet.count
        }
        if let previous, previous.count == signature.count, !signature.isEmpty {
            var total = 0.0
            for i in 0..<signature.count {
                total += abs(Double(signature[i]) - Double(previous[i]))
            }
            stats.diffFromPrevious = total / Double(signature.count)
        }
        return (stats, signature)
    }
}
