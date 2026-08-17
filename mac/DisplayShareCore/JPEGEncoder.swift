import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// BGRA CVPixelBuffer -> JPEG.
///
/// Phase 1 only. MJPEG is deliberately the dumbest possible transport so the
/// display and capture layers can be validated in isolation; Phase 2 replaces
/// this with hardware H.264 and roughly quarters the bandwidth.
public final class JPEGEncoder: @unchecked Sendable {

    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// 0.0–1.0. Exposed so Task 1.4 can put a quality slider in the menu bar.
    public var quality: Double

    public private(set) var lastEncodeSeconds: Double = 0
    public private(set) var lastByteCount: Int = 0

    public init(quality: Double = 0.7) {
        self.quality = quality
        // GPU-backed; software rendering here would blow the frame budget.
        self.context = CIContext(options: [.useSoftwareRenderer: false])
    }

    public func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let start = CFAbsoluteTimeGetCurrent()
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(
            destination, cgImage,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        lastEncodeSeconds = CFAbsoluteTimeGetCurrent() - start
        lastByteCount = data.length
        return data as Data
    }
}
