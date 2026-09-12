import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case unreadable
    case tooShort

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "This file couldn't be read. It may be DRM-protected or in an unsupported format."
        case .tooShort:
            return "This file is too short to analyze (need at least 3 seconds of audio)."
        }
    }
}

/// Copies a user-picked audio file into the app sandbox.
/// Only the copy is analyzed/played — the original stays where the user put it.
enum AudioImporter {
    static let supportedContentTypes: [UTType] = [.audio]

    struct ImportedFile: Sendable {
        var fileName: String
        var duration: Double
    }

    /// Copies the file and returns its sandbox file name + duration.
    static func importFile(from sourceURL: URL) async throws -> ImportedFile {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let fileName = UUID().uuidString + "." + ext
        let destURL = AppDirectories.songsDirectory.appendingPathComponent(fileName)

        try copyFile(from: sourceURL, to: destURL)

        let duration = try await duration(of: destURL)
        guard duration >= 3 else {
            try? FileManager.default.removeItem(at: destURL)
            throw ImportError.tooShort
        }
        return ImportedFile(fileName: fileName, duration: duration)
    }

    static func deleteFile(named fileName: String) {
        let url = AppDirectories.songsDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internals

    private static func copyFile(from source: URL, to dest: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return
        } catch {
            try? FileManager.default.removeItem(at: dest)
        }
        // Stream copy fallback for files that can't be hard-copied.
        guard let input = InputStream(url: source), let output = OutputStream(url: dest, append: false) else {
            throw ImportError.unreadable
        }
        input.open()
        output.open()
        defer { input.close(); output.close() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw ImportError.unreadable }
            if read == 0 { break }
            output.write(buffer, maxLength: read)
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw ImportError.unreadable }
    }

    private static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0 else {
            throw ImportError.unreadable
        }
        return duration.seconds
    }
}