import CoreGraphics
import Foundation

/// Reading pixels back out of a rendered image.
///
/// One implementation, because the previous two were the same code twice and
/// both of them handed `CGContext` the address of a Swift array with `&`. That
/// pointer is only guaranteed for the duration of the call it appears in, so
/// the context was writing through a dangling pointer and the bytes read back
/// afterwards were whatever had last occupied that allocation — which reads as
/// "every image is the previous image", and makes a smoke test that cannot
/// fail. The buffer is held open across the draw and the read here.
enum RenderProbe {
    /// Fraction of pixels with something in them, `0...1`.
    static func inkCoverage(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let painted = pixels.withUnsafeMutableBytes { raw -> Int in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = raw.bindMemory(to: UInt8.self)
            var count = 0
            for i in stride(from: 3, to: bytes.count, by: 4) where bytes[i] > 8 { count += 1 }
            return count
        }
        return Double(painted) / Double(width * height)
    }
}
