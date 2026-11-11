import CoreGraphics
import Foundation
import ImageIO

/// Draws deterministic placeholder photos in code (a two-colour gradient "sky" with a sun and hills),
/// encoded as JPEG so they decode like real server thumbnails. Colours derive from the asset id.
public enum PlaceholderImage {
    /// Long side in pixels for each server size.
    public static func longSide(for size: ImageSize) -> Int {
        switch size {
        case .thumbnail: return 250
        case .preview: return 1024
        }
    }

    /// JPEG bytes for `assetID` at `size`, shaped to `aspectRatio` (width / height).
    /// Same inputs always give the same bytes.
    public static func jpegData(assetID: String, size: ImageSize, aspectRatio: Double = 1) -> Data {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? min(max(aspectRatio, 0.25), 4) : 1
        let long = longSide(for: size)
        let width = ratio >= 1 ? long : max(1, Int((Double(long) * ratio).rounded()))
        let height = ratio >= 1 ? max(1, Int((Double(long) / ratio).rounded())) : long
        guard let image = render(seed: stableHash(assetID), width: width, height: height),
              let data = encodeJPEG(image)
        else { return Data("\(size.rawValue):\(assetID)".utf8) }
        return data
    }

    /// FNV-1a, stable across launches (unlike `Hasher`).
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func render(seed: UInt64, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        var rng = SplitMix64(seed: seed)
        let hue = rng.double()
        let top = rgb(hue: hue, saturation: 0.45 + 0.3 * rng.double(), brightness: 0.85)
        let bottom = rgb(hue: (hue + 0.08 + 0.15 * rng.double()).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.55)
        let w = CGFloat(width), h = CGFloat(height)

        // Sky gradient (CoreGraphics origin is bottom-left).
        if let gradient = CGGradient(colorSpace: space, colorComponents: top + [1] + bottom + [1], locations: [0, 1], count: 2) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }

        // Sun.
        let sunRadius = min(w, h) * CGFloat(0.08 + 0.08 * rng.double())
        let sunCenter = CGPoint(x: w * CGFloat(0.2 + 0.6 * rng.double()), y: h * CGFloat(0.6 + 0.25 * rng.double()))
        context.setFillColor(red: 1, green: 0.97, blue: 0.85, alpha: 0.9)
        context.fillEllipse(in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))

        // Two layers of hills.
        for layer in 0..<2 {
            let base = h * CGFloat(0.25 + 0.15 * rng.double()) - CGFloat(layer) * h * 0.1
            let shade = rgb(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.35 - 0.1 * Double(layer))
            context.setFillColor(red: shade[0], green: shade[1], blue: shade[2], alpha: 1)
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: 0, y: base))
            let peaks = 2 + rng.int(3)
            for peak in 1...peaks {
                let x = w * CGFloat(peak) / CGFloat(peaks)
                let control = CGPoint(x: x - w / CGFloat(peaks * 2), y: base + h * CGFloat(0.05 + 0.2 * rng.double()))
                context.addQuadCurve(to: CGPoint(x: x, y: base), control: control)
            }
            context.addLine(to: CGPoint(x: w, y: 0))
            context.closePath()
            context.fillPath()
        }
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// HSB → sRGB components in 0...1.
    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> [CGFloat] {
        let h = hue * 6
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (brightness, t, p)
        case 1: (r, g, b) = (q, brightness, p)
        case 2: (r, g, b) = (p, brightness, t)
        case 3: (r, g, b) = (p, q, brightness)
        case 4: (r, g, b) = (t, p, brightness)
        default: (r, g, b) = (brightness, p, q)
        }
        return [CGFloat(r), CGFloat(g), CGFloat(b)]
    }
}
