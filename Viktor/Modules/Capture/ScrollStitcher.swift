import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Joins frames of a scrolling region into one tall image.
/// For each new frame it finds how far the content moved up (by matching per-row luminance
/// signatures of a textured band from the previous frame) and appends only the new rows.
actor ScrollStitcher {
    /// Pixel rows kept at most (and never more than ~250 MB of pixels).
    static let maxHeight = 20_000
    private static let buckets = 48

    private var width = 0
    private var frameHeight = 0
    private var canvas: [UInt8] = []
    private var rows = 0
    private var maxRows = maxHeight
    private var previous: [Float] = []
    private var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var heightPixels: Int { rows }
    var isFull: Bool { rows >= maxRows }

    /// Adds a frame; returns the stitched height in pixels.
    @discardableResult
    func add(_ box: ImageBox) -> Int {
        let image = box.image
        if canvas.isEmpty, let cs = image.colorSpace, cs.model == .rgb { colorSpace = cs }
        guard let pixels = Self.rgba(image, colorSpace) else { return rows }
        let w = image.width, h = image.height
        let sig = Self.signature(pixels, w, h)

        if canvas.isEmpty {
            width = w; frameHeight = h
            maxRows = max(h, min(Self.maxHeight, 250_000_000 / max(1, w * 4)))
            canvas = pixels; rows = h; previous = sig
            return rows
        }
        guard w == width, h == frameHeight else { return rows }
        guard let d = Self.offset(prev: previous, new: sig, h: h) else { return rows } // no confident match: skip
        guard d > 0 else { return rows }                                                 // no movement
        let take = min(d, maxRows - rows)
        if take > 0 {
            let start = (h - d) * w * 4
            canvas.append(contentsOf: pixels[start ..< start + take * w * 4])
            rows += take
        }
        previous = sig
        return rows
    }

    /// Writes the stitched image as a PNG. `scale` is the screen's backing scale (for DPI).
    func writePNG(to url: URL, scale: CGFloat) -> Bool {
        guard rows > 0, width > 0 else { return false }
        let data = Data(canvas[0 ..< rows * width * 4]) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        let dpi = 72 * max(1, scale)
        let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Pixels

    private static func rgba(_ image: CGImage, _ space: CGColorSpace) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    /// For each row, the average luminance of `buckets` vertical strips. Row 0 is the top.
    private static func signature(_ px: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        let k = buckets
        var sig = [Float](repeating: 0, count: h * k)
        px.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let rowBase = y * w * 4
                for b in 0..<k {
                    let x0 = b * w / k, x1 = max(x0 + 1, (b + 1) * w / k)
                    let step = max(1, (x1 - x0) / 8)
                    var sum: Float = 0, n: Float = 0
                    var x = x0
                    while x < x1 {
                        let i = rowBase + x * 4
                        sum += 0.299 * Float(p[i]) + 0.587 * Float(p[i + 1]) + 0.114 * Float(p[i + 2])
                        n += 1
                        x += step
                    }
                    sig[y * k + b] = sum / n
                }
            }
        }
        return sig
    }

    /// How many pixel rows the content moved up between `prev` and `new`. 0 = no movement, nil = unsure.
    static func offset(prev: [Float], new: [Float], h: Int) -> Int? {
        let k = buckets
        func diff(_ a: [Float], _ ra: Int, _ b: [Float], _ rb: Int) -> Float {
            var s: Float = 0
            let ao = ra * k, bo = rb * k
            for i in 0..<k { s += abs(a[ao + i] - b[bo + i]) }
            return s / Float(k)
        }

        // Same picture? Then nothing moved.
        var same: Float = 0, n: Float = 0
        var r = 0
        while r < h { same += diff(prev, r, new, r); n += 1; r += 3 }
        if same / n < 0.8 { return 0 }

        // Try a tall band first (robust), then a short one that can follow faster scrolling.
        for (band, margin) in [(max(8, min(h / 3, 240)), min(h / 12, 30)), (max(8, min(h / 8, 120)), 2)] {
            if let d = match(prev: prev, new: new, h: h, band: band, margin: margin, diff: diff) { return d }
        }
        return nil
    }

    private static func match(prev: [Float], new: [Float], h: Int, band: Int, margin: Int,
                              diff: ([Float], Int, [Float], Int) -> Float) -> Int? {
        // Pick a template band in the previous frame, as low as possible, with enough vertical detail
        // to align on (a blank band would match anywhere).
        let highest = h - margin - band
        guard highest > 0 else { return nil }
        func texture(_ top: Int) -> Float {
            var t: Float = 0
            var j = 0
            while j < band - 1 { t += diff(prev, top + j, prev, top + j + 1); j += 2 }
            return t / Float(max(1, band / 2))
        }
        var top = -1
        var chosen: Float = 0
        var candidate = highest
        while candidate >= 0 {
            let t = texture(candidate)
            if t >= 3 { top = candidate; chosen = t; break }
            if t > chosen { chosen = t; top = candidate }
            candidate -= max(1, band / 2)
        }
        guard top >= 0, chosen >= 0.4 else { return nil }

        // Slide the band over the new frame; smallest movement wins ties.
        var bestP = -1
        var bestCost = Float.greatestFiniteMagnitude
        let samples = Float((band + 1) / 2)
        for p in stride(from: top, through: 0, by: -1) {
            var c: Float = 0
            var j = 0
            let limit = (bestCost - 0.05) * samples
            while j < band {
                c += diff(prev, top + j, new, p + j)
                if c > limit { break }
                j += 2
            }
            if c <= limit { bestCost = c / samples; bestP = p }
        }
        guard bestP >= 0, bestCost < 8 else { return nil }
        return top - bestP
    }
}
