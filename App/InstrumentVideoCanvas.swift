import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Shared canvas for Ninebot JPEG and Ninebot/ZEEHO H.264 outputs. Used only on the output queue.
final class InstrumentVideoCanvas {
    private var bmsOverlay: CIImage?
    private var bmsConfiguration = ANTBMSCardConfiguration()
    private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private var cachedJPEG: Data?
    private var cachedBounds: CGRect?

    func setBMSOverlay(_ image: CGImage?, configuration: ANTBMSCardConfiguration) {
        bmsOverlay = image.map { CIImage(cgImage: $0) }
        bmsConfiguration = configuration
        cachedJPEG = nil
    }

    func jpeg(_ image: CVPixelBuffer, in bounds: CGRect, refresh: Bool) -> Data? {
        if refresh || cachedJPEG == nil || cachedBounds != bounds {
            cachedJPEG = compositor.jpegRepresentation(of: fittedCanvas(image, in: bounds),
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
            cachedBounds = bounds
        }
        return cachedJPEG
    }

    private enum CanvasError: LocalizedError {
        case allocation(CVReturn)
        var errorDescription: String? {
            switch self { case .allocation(let status): "无法分配仪表缩放画面（\(status)）" }
        }
    }

    func fittedImage(_ image: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        if bmsOverlay == nil, CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw CanvasError.allocation(status) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        compositor.render(fittedCanvas(image, in: bounds), to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    func fittedCanvas(_ image: CVPixelBuffer, in bounds: CGRect) -> CIImage {
        let source = CIImage(cvPixelBuffer: image)
        let scale = min(bounds.width / source.extent.width, bounds.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: (bounds.width - scaled.extent.width) / 2,
            y: (bounds.height - scaled.extent.height) / 2))
        let canvas = positioned.composited(over: CIImage(color: .black)).cropped(to: bounds)
        guard let bmsOverlay else { return canvas }
        let overlayWidth = bounds.width * CGFloat(bmsConfiguration.size.widthFraction)
        let factor = overlayWidth / bmsOverlay.extent.width
        let scaledOverlay = bmsOverlay.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let margin = max(6, bounds.width * 0.007)
        let overlay = scaledOverlay.transformed(by: CGAffineTransform(
            translationX: bmsConfiguration.position.isAtRight ? bounds.maxX - margin - scaledOverlay.extent.width : margin,
            y: bmsConfiguration.position.isAtTop ? bounds.maxY - margin - scaledOverlay.extent.height : margin))
        return overlay.composited(over: canvas).cropped(to: bounds)
    }
}
