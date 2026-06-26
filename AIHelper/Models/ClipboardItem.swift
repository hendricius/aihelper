import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let sourceAppName: String?

    init(id: UUID = UUID(), date: Date = Date(), text: String, sourceAppName: String? = nil) {
        self.id = id
        self.date = date
        self.text = text
        self.sourceAppName = sourceAppName
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 {
            return trimmed
        }
        return String(trimmed.prefix(100)) + "..."
    }
}
