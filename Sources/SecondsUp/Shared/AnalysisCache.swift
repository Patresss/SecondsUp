import Foundation

/// Cache wynikow analizy w ~/Library/Caches/SecondsUp.
/// Klucz: sciezka pliku; walidacja: rozmiar + data modyfikacji.
enum AnalysisCache {
    static let schemaVersion = 2

    struct Entry: Codable {
        let schemaVersion: Int
        let path: String
        let fileSize: Int
        let modifiedAt: Double
        let metadata: VideoMetadata
        let analysis: AnalysisResult
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SecondsUp", isDirectory: true)
    }

    static func load(for url: URL) -> Entry? {
        guard let stamp = fileStamp(for: url) else {
            return nil
        }
        let cacheURL = cacheURL(for: url)
        guard let data = try? Data(contentsOf: cacheURL),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.schemaVersion == schemaVersion,
              entry.path == url.path,
              entry.fileSize == stamp.size,
              abs(entry.modifiedAt - stamp.modified) < 1.0 else {
            return nil
        }
        return entry
    }

    static func store(metadata: VideoMetadata, analysis: AnalysisResult, for url: URL) {
        guard let stamp = fileStamp(for: url) else {
            return
        }
        let entry = Entry(
            schemaVersion: schemaVersion,
            path: url.path,
            fileSize: stamp.size,
            modifiedAt: stamp.modified,
            metadata: metadata,
            analysis: analysis
        )
        guard let data = try? JSONEncoder().encode(entry) else {
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(for: url), options: .atomic)
    }

    private static func cacheURL(for url: URL) -> URL {
        directory.appendingPathComponent("\(stableHash(url.path)).json")
    }

    private static func fileStamp(for url: URL) -> (size: Int, modified: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return (size, modified.timeIntervalSince1970)
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
