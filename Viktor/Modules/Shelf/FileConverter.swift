@preconcurrency import AVFoundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Converts images (PNG/JPEG/HEIC/TIFF/PDF) and video/audio (MP4/M4A).
/// The original is never touched; the new file is saved next to it (or in Downloads).
enum FileConverter {
    enum Format: String, CaseIterable, Sendable {
        case png, jpeg, heic, tiff, pdf, mp4, m4a

        var label: String { self == .jpeg ? "JPG" : rawValue.uppercased() }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var utType: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            case .pdf: .pdf
            case .mp4: .mpeg4Movie
            case .m4a: .mpeg4Audio
            }
        }
    }

    enum ConversionError: LocalizedError {
        case unreadable, writeFailed, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read that file."
            case .writeFailed: "Couldn't save the converted file."
            case .exportFailed(let why): "Export failed: \(why)"
            }
        }
    }

    static func type(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
    }

    /// Formats this file can be turned into (never its own format).
    static func formats(for url: URL) -> [Format] {
        guard let type = type(of: url) else { return [] }
        let options: [Format]
        if type.conforms(to: .image) && !type.conforms(to: .pdf) {
            options = [.png, .jpeg, .heic, .tiff, .pdf]
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            options = [.mp4, .m4a]
        } else if type.conforms(to: .audio) {
            options = [.m4a]
        } else {
            options = []
        }
        return options.filter { !type.conforms(to: $0.utType) }
    }

    static func convert(_ url: URL, to format: Format) async throws -> URL {
        let out = outputURL(for: url, ext: format.fileExtension)
        switch format {
        case .png, .jpeg, .heic, .tiff:
            try await Task.detached { try convertImage(url, to: out, type: format.utType) }.value
        case .pdf:
            try await Task.detached { try imageToPDF(url, to: out) }.value
        case .mp4:
            try await export(url, to: out, preset: AVAssetExportPresetHighestQuality, fileType: .mp4)
        case .m4a:
            try await export(url, to: out, preset: AVAssetExportPresetAppleM4A, fileType: .m4a)
        }
        return out
    }

    /// "photo.heic" → "photo.png" beside it, or "photo 2.png" if that exists.
    /// Falls back to Downloads when the folder isn't writable.
    static func outputURL(for url: URL, ext: String) -> URL {
        var dir = url.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    private static func convertImage(_ url: URL, to out: URL, type: UTType) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ConversionError.unreadable }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.writeFailed }
    }

    private static func imageToPDF(_ url: URL, to out: URL) throws {
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw ConversionError.unreadable }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        guard doc.write(to: out) else { throw ConversionError.writeFailed }
    }

    /// Wraps the export session so it can cross into the completion handler.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }

    private static func export(_ url: URL, to out: URL, preset: String, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: url)
        if fileType == .m4a, (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty ?? true {
            throw ConversionError.exportFailed("this file has no sound to save")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.exportFailed("this file can't be exported as \(fileType.rawValue)")
        }
        session.outputURL = out
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        let box = SessionBox(session)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                if box.session.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: ConversionError.exportFailed(box.session.error?.localizedDescription ?? "unknown error"))
                }
            }
        }
    }
}
