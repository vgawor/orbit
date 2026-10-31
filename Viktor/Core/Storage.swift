import Foundation
import ViktorKit

/// Saves small Codable values as JSON in ~/Library/Application Support/Orbit.
enum Storage {
    static var folder: URL { APIConfig.supportFolder }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = folder.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Saved with ISO 8601 dates (see save); older files may use the default format.
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        return (try? iso.decode(T.self, from: data)) ?? (try? JSONDecoder().decode(T.self, from: data))
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = folder.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
