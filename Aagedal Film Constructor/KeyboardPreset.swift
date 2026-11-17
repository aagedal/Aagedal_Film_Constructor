import Foundation

/// A named keymap that can be saved, switched to, and shared as a file.
nonisolated struct KeyboardPreset: Codable, Equatable, Identifiable {
    static let builtInName = "Film Constructor Default"
    static let fileExtension = "afckeys"
    static let fileFormat = "com.aagedal.filmconstructor.keyboard-preset"
    static let fileVersion = 1
    var name: String
    /// Every command's shortcuts by command name, so the preset reads the same on any machine.
    var shortcuts: [String: [ShortcutBinding]]
    var id: String { name }
    /// The preset's keymap, and how many of its shortcuts this version cannot use.
    var resolved: (keymap: Keymap, rejected: Int) { Keymap.restoring(shortcuts) }

    private struct File: Codable {
        var format: String
        var version: Int
        var name: String
        var shortcuts: [String: [ShortcutBinding]]
    }
    func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(format: Self.fileFormat, version: Self.fileVersion, name: name, shortcuts: shortcuts))
    }
}

nonisolated extension KeyboardPreset {
    init(name: String, keymap: Keymap) { self.init(name: name, shortcuts: keymap.savedForm) }
    init(fileData data: Data) throws {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == Self.fileFormat else {
            throw KeyboardPresetError.notAPreset
        }
        guard file.version <= Self.fileVersion else { throw KeyboardPresetError.newerVersion }
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: name.isEmpty ? "Imported Shortcuts" : name, shortcuts: file.shortcuts)
    }
}

nonisolated enum KeyboardPresetError: LocalizedError {
    case notAPreset, newerVersion
    var errorDescription: String? {
        switch self {
        case .notAPreset: "This file is not a Film Constructor keyboard preset."
        case .newerVersion: "This keyboard preset was made by a newer version of Film Constructor."
        }
    }
}
