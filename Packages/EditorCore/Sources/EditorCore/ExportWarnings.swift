import Foundation

/// What an interchange export left out or changed. Each message is listed once, naming every
/// clip or marker it affects, so a long sequence gives a short list.
struct ExportWarnings {
    private var messages: [String] = []
    private var subjects: [String: [String]] = [:]

    mutating func add(_ message: String, for subject: String? = nil) {
        if subjects[message] == nil { messages.append(message); subjects[message] = [] }
        if let subject, !subjects[message]!.contains(subject) { subjects[message]!.append(subject) }
    }

    var list: [String] {
        messages.map { message in
            let names = subjects[message]!
            guard !names.isEmpty else { return message }
            let shown = names.prefix(3).joined(separator: ", ")
            return "\(message) (\(names.count > 3 ? "\(shown) and \(names.count - 3) more" : shown))"
        }
    }
}
