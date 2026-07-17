import Foundation

struct ImportedMeal: Identifiable {
    let id = UUID()
    let establishment: String
    let address: String?
    let category: DiningCategory?
    let cuisines: [String]
    let date: Date
    let reaction: Reaction?
    let dish: String?
    let memory: String?
    let hazy: Bool
}

struct CSVImportSummary {
    let meals: [ImportedMeal]
    let skippedRows: Int
}

enum CSVImporter {
    enum ImportError: LocalizedError {
        case unreadable, noHeader, noRestaurantColumn
        var errorDescription: String? {
            switch self {
            case .unreadable: "The file could not be read as UTF-8 or UTF-16 text."
            case .noHeader: "The CSV has no header row."
            case .noRestaurantColumn: "The CSV needs a restaurant, establishment, place, or name column."
            }
        }
    }

    static func parse(data: Data) throws -> CSVImportSummary {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw ImportError.unreadable }
        let rows = parseRows(text)
        guard let header = rows.first, !header.isEmpty else { throw ImportError.noHeader }
        let normalized = header.map(normalize)
        guard let nameIndex = index(of: ["restaurant", "establishment", "place", "location", "name", "venue"], in: normalized) else {
            throw ImportError.noRestaurantColumn
        }
        let dateIndex = index(of: ["date", "visitedat", "visitdate", "timestamp", "createdat"], in: normalized)
        let scoreIndex = index(of: ["score", "rating", "reaction", "overall", "beliscore"], in: normalized)
        let categoryIndex = index(of: ["category", "type"], in: normalized)
        let cuisineIndex = index(of: ["cuisine", "cuisines"], in: normalized)
        let dishIndex = index(of: ["dish", "item", "food"], in: normalized)
        let memoryIndex = index(of: ["memory", "notes", "note", "review"], in: normalized)
        let addressIndex = index(of: ["address", "streetaddress"], in: normalized)

        var meals: [ImportedMeal] = []
        var skipped = 0
        for row in rows.dropFirst() {
            let name = value(row, nameIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { skipped += 1; continue }
            let categoryString = optionalValue(row, categoryIndex)
            let category = categoryString.flatMap { value in DiningCategory.allCases.first { $0.rawValue.localizedCaseInsensitiveContains(value) || $0.shortTitle.localizedCaseInsensitiveContains(value) } }
            let cuisine = optionalValue(row, cuisineIndex)?.split(whereSeparator: { ",;/|".contains($0) }).map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
            meals.append(ImportedMeal(
                establishment: name,
                address: optionalValue(row, addressIndex),
                category: category,
                cuisines: cuisine,
                date: optionalValue(row, dateIndex).flatMap(parseDate) ?? .now,
                reaction: optionalValue(row, scoreIndex).flatMap(parseReaction),
                dish: optionalValue(row, dishIndex),
                memory: optionalValue(row, memoryIndex),
                hazy: dateIndex == nil
            ))
        }
        return .init(meals: meals, skippedRows: skipped)
    }

    static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else { quoted.toggle() }
            } else if character == ",", !quoted {
                row.append(field); field = ""
            } else if character == "\n", !quoted {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(character) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
    private static func index(of aliases: [String], in header: [String]) -> Int? {
        aliases.compactMap { header.firstIndex(of: $0) }.first
    }
    private static func value(_ row: [String], _ index: Int) -> String { row.indices.contains(index) ? row[index] : "" }
    private static func optionalValue(_ row: [String], _ index: Int?) -> String? {
        guard let index else { return nil }
        let result = value(row, index).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
    private static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd HH:mm:ss", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
    private static func parseReaction(_ value: String) -> Reaction? {
        if let reaction = Reaction.allCases.first(where: { $0.rawValue.localizedCaseInsensitiveCompare(value) == .orderedSame }) { return reaction }
        guard let score = Double(value.filter { $0.isNumber || $0 == "." }) else { return nil }
        let normalized = score <= 10 ? score * 10 : score
        switch normalized {
        case 80...: return .loved
        case 65..<80: return .liked
        case 45..<65: return .fine
        default: return .notForMe
        }
    }
}
