import CryptoKit
import Foundation
import ZIPFoundation

struct BeliRankingRow: Identifiable, Hashable, Sendable {
    let id: String
    let rank: Int
    let restaurantName: String
    let city: String
    let createdAt: Date
    let visitDates: [Date]
}

struct BeliPhotoRow: Identifiable, Hashable, Sendable {
    let id: String
    let restaurantName: String
    let city: String
    let caption: String?
    let isFavoriteDish: Bool
    let uploadDate: Date
    let imageURL: URL
}

struct BeliDishNoteRow: Identifiable, Hashable, Sendable {
    let id: String
    let restaurantName: String
    let city: String
    let name: String
    let createdAt: Date
}

struct BeliParsedArchive: Sendable {
    let namespace: String
    let exportDate: Date?
    let rankings: [BeliRankingRow]
    let photos: [BeliPhotoRow]
    let dishNotes: [BeliDishNoteRow]

    var knownVisitCount: Int { rankings.reduce(0) { $0 + $1.visitDates.count } }
    var unknownVisitCount: Int { rankings.count(where: { $0.visitDates.isEmpty }) }
}

enum BeliLocationResolution: Hashable, Sendable {
    case existing(UUID)
    case map(PlaceCandidate)
    case unresolved(markClosed: Bool)
    case skip
}

struct BeliDownloadedPhoto: Sendable {
    let row: BeliPhotoRow
    let photo: BackfillPhoto
    let contentHash: String
}

struct BeliPhotoDownloadResult: Sendable {
    let photos: [String: BeliDownloadedPhoto]
    let failures: [String: String]
}

struct BeliImportRequest: Sendable {
    let archive: BeliParsedArchive
    let resolutions: [String: BeliLocationResolution]
    let photoRankingAssignments: [String: String]
    let dishRankingAssignments: [String: String]
    let downloadedPhotos: [String: BeliDownloadedPhoto]
}

struct BeliImportSummary: Equatable, Sendable {
    var restaurantsCreated = 0
    var restaurantsLinked = 0
    var outingsCreated = 0
    var outingsLinked = 0
    var photosAdded = 0
    var dishesAdded = 0
    var rankingsSeeded = 0
    var skippedRows = 0
    var failedPhotos = 0
}

struct BeliImportDeletionSummary: Equatable, Sendable {
    var restaurantsDeleted = 0
    var restaurantsPreserved = 0
    var outingsDeleted = 0
    var photosDeleted = 0
    var dishesDeleted = 0
    var rankingsDeleted = 0
}

enum BeliPhotoDownloader {
    static let maximumPhotoBytes: Int64 = 25 * 1_024 * 1_024

    static func download(_ rows: [BeliPhotoRow], maxConcurrent: Int = 3) async -> BeliPhotoDownloadResult {
        var photos: [String: BeliDownloadedPhoto] = [:]
        var failures: [String: String] = [:]
        let size = max(1, maxConcurrent)
        for start in stride(from: 0, to: rows.count, by: size) {
            if Task.isCancelled { break }
            let batch = Array(rows[start..<min(rows.count, start + size)])
            let values = await withTaskGroup(of: (String, Result<BeliDownloadedPhoto, Error>).self) { group in
                for row in batch {
                    group.addTask { (row.id, await fetch(row)) }
                }
                var output: [(String, Result<BeliDownloadedPhoto, Error>)] = []
                for await value in group { output.append(value) }
                return output
            }
            for (id, result) in values {
                switch result {
                case .success(let photo): photos[id] = photo
                case .failure(let error): failures[id] = error.localizedDescription
                }
            }
        }
        return .init(photos: photos, failures: failures)
    }

    private static func fetch(_ row: BeliPhotoRow) async -> Result<BeliDownloadedPhoto, Error> {
        do {
            var request = URLRequest(url: row.imageURL)
            request.timeoutInterval = 45
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard response.expectedContentLength <= maximumPhotoBytes, Int64(data.count) <= maximumPhotoBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            guard response.mimeType?.lowercased().hasPrefix("image/") != false,
                  let photo = await ImageSanitizer.processOffMain(data, date: row.uploadDate) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return .success(.init(row: row, photo: photo, contentHash: BeliImporter.digest(data)))
        } catch {
            return .failure(error)
        }
    }
}

enum BeliImporter {
    static let maximumArchiveBytes: Int64 = 100 * 1_024 * 1_024
    static let maximumCSVBytes: UInt32 = 50 * 1_024 * 1_024
    static let maximumRowsPerFile = 10_000

    enum ImportError: LocalizedError, Equatable {
        case archiveTooLarge
        case unreadableArchive
        case missingRankings
        case oversizedEntry(String)
        case unreadableCSV(String)
        case missingColumn(file: String, column: String)
        case invalidRow(file: String, row: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge: "That Beli export is too large to import safely."
            case .unreadableArchive: "The selected file is not a readable ZIP archive."
            case .missingRankings: "This ZIP does not contain Beli's rankings.csv file."
            case .oversizedEntry(let name): "\(name) is too large to import safely."
            case .unreadableCSV(let name): "\(name) could not be read as text."
            case .missingColumn(let file, let column): "\(file) is missing its \(column) column."
            case .invalidRow(let file, let row, let detail): "\(file) row \(row) is invalid: \(detail)"
            }
        }
    }

    static func parse(url: URL) throws -> BeliParsedArchive {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maximumArchiveBytes { throw ImportError.archiveTooLarge }
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw ImportError.unreadableArchive }

        var files: [String: Data] = [:]
        var totalExtractedBytes: UInt64 = 0
        for entry in archive where entry.type == .file {
            let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
            guard ["rankings.csv", "photos.csv", "notes_dishes.csv", "export_details.csv", "user_profile.csv"].contains(name) else { continue }
            guard entry.uncompressedSize <= maximumCSVBytes else { throw ImportError.oversizedEntry(name) }
            totalExtractedBytes += UInt64(entry.uncompressedSize)
            guard totalExtractedBytes <= UInt64(maximumArchiveBytes) else { throw ImportError.archiveTooLarge }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
            files[name] = data
        }
        return try parse(files: files)
    }

    static func parse(files: [String: Data]) throws -> BeliParsedArchive {
        guard let rankingData = files["rankings.csv"] else { throw ImportError.missingRankings }

        let details = try files["export_details.csv"].map { try table(data: $0, filename: "export_details.csv") }
        let profile = try files["user_profile.csv"].map { try table(data: $0, filename: "user_profile.csv") }
        let rawNamespace = details?.rows.first.flatMap { details?.value($0, aliases: ["user_id"]) }
            ?? profile?.rows.first.flatMap { profile?.value($0, aliases: ["User ID"]) }
            ?? "anonymous-beli-export"
        let namespace = digest(rawNamespace)
        let exportDate = details?.rows.first
            .flatMap { details?.value($0, aliases: ["export_date"]) }
            .flatMap(BeliDateParser.parseTimestamp)

        let rankings = try parseRankings(rankingData, namespace: namespace)
        let photos = try files["photos.csv"].map { try parsePhotos($0, namespace: namespace) } ?? []
        let dishes = try files["notes_dishes.csv"].map { try parseDishes($0, namespace: namespace) } ?? []
        return .init(namespace: namespace, exportDate: exportDate, rankings: rankings, photos: photos, dishNotes: dishes)
    }

    private static func parseRankings(_ data: Data, namespace: String) throws -> [BeliRankingRow] {
        let csv = try table(data: data, filename: "rankings.csv")
        try csv.require(["Rank", "Restaurant Name", "City", "Created Date", "Visit Dates"], filename: "rankings.csv")
        guard csv.rows.count <= maximumRowsPerFile else { throw ImportError.oversizedEntry("rankings.csv") }
        return try csv.rows.enumerated().map { offset, row in
            let line = offset + 2
            guard let rankText = csv.value(row, aliases: ["Rank"]), let rank = Int(rankText) else {
                throw ImportError.invalidRow(file: "rankings.csv", row: line, detail: "Rank is not a number.")
            }
            guard let name = csv.value(row, aliases: ["Restaurant Name"]), !name.isEmpty else {
                throw ImportError.invalidRow(file: "rankings.csv", row: line, detail: "Restaurant Name is empty.")
            }
            let city = csv.value(row, aliases: ["City"]) ?? ""
            guard let createdText = csv.value(row, aliases: ["Created Date"]),
                  let createdAt = BeliDateParser.parseTimestamp(createdText) else {
                throw ImportError.invalidRow(file: "rankings.csv", row: line, detail: "Created Date is not recognized.")
            }
            let visitText = csv.value(row, aliases: ["Visit Dates"]) ?? ""
            guard let visits = BeliDateParser.parseVisitDates(visitText) else {
                throw ImportError.invalidRow(file: "rankings.csv", row: line, detail: "Visit Dates is not recognized.")
            }
            let key = digest([namespace, normalize(name), normalize(city), BeliDateParser.key(createdAt)].joined(separator: "|"))
            return .init(id: key, rank: rank, restaurantName: name, city: city, createdAt: createdAt, visitDates: visits)
        }.sorted { $0.rank < $1.rank }
    }

    private static func parsePhotos(_ data: Data, namespace: String) throws -> [BeliPhotoRow] {
        let csv = try table(data: data, filename: "photos.csv")
        try csv.require(["Business Name", "City", "Upload Date", "Image URL"], filename: "photos.csv")
        guard csv.rows.count <= maximumRowsPerFile else { throw ImportError.oversizedEntry("photos.csv") }
        return try csv.rows.enumerated().map { offset, row in
            let line = offset + 2
            guard let name = csv.value(row, aliases: ["Business Name"]),
                  let urlText = csv.value(row, aliases: ["Image URL"]),
                  let url = URL(string: urlText), url.scheme?.lowercased() == "https",
                  let uploadText = csv.value(row, aliases: ["Upload Date"]),
                  let uploadDate = BeliDateParser.parseTimestamp(uploadText) else {
                throw ImportError.invalidRow(file: "photos.csv", row: line, detail: "Name, HTTPS Image URL, or Upload Date is invalid.")
            }
            let city = csv.value(row, aliases: ["City"]) ?? ""
            return .init(
                id: digest([namespace, url.absoluteString].joined(separator: "|")),
                restaurantName: name,
                city: city,
                caption: csv.value(row, aliases: ["Description"]),
                isFavoriteDish: (csv.value(row, aliases: ["Is Favorite Dish"]) ?? "").lowercased() == "true",
                uploadDate: uploadDate,
                imageURL: url
            )
        }
    }

    private static func parseDishes(_ data: Data, namespace: String) throws -> [BeliDishNoteRow] {
        let csv = try table(data: data, filename: "notes_dishes.csv")
        try csv.require(["Field Type", "Business Name", "City", "Note Text", "Created Date"], filename: "notes_dishes.csv")
        guard csv.rows.count <= maximumRowsPerFile else { throw ImportError.oversizedEntry("notes_dishes.csv") }
        return try csv.rows.enumerated().compactMap { offset, row in
            guard (csv.value(row, aliases: ["Field Type"]) ?? "").localizedCaseInsensitiveContains("favorite") else { return nil }
            let line = offset + 2
            guard let restaurant = csv.value(row, aliases: ["Business Name"]),
                  let dish = csv.value(row, aliases: ["Note Text"]),
                  let createdText = csv.value(row, aliases: ["Created Date"]),
                  let createdAt = BeliDateParser.parseTimestamp(createdText) else {
                throw ImportError.invalidRow(file: "notes_dishes.csv", row: line, detail: "Restaurant, dish, or Created Date is invalid.")
            }
            let city = csv.value(row, aliases: ["City"]) ?? ""
            let key = digest([namespace, normalize(restaurant), normalize(city), normalize(dish), BeliDateParser.key(createdAt)].joined(separator: "|"))
            return .init(id: key, restaurantName: restaurant, city: city, name: dish, createdAt: createdAt)
        }
    }

    private static func table(data: Data, filename: String) throws -> CSVTable {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian) else {
            throw ImportError.unreadableCSV(filename)
        }
        let rows = CSVImporter.parseRows(text.replacingOccurrences(of: "\u{feff}", with: ""))
        guard let header = rows.first else { throw ImportError.unreadableCSV(filename) }
        return CSVTable(header: header, rows: Array(rows.dropFirst()))
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CSVTable {
    let header: [String]
    let rows: [[String]]

    private var normalizedHeader: [String] { header.map(BeliImporter.normalize) }

    func value(_ row: [String], aliases: [String]) -> String? {
        let header = normalizedHeader
        guard let index = aliases.lazy.compactMap({ alias in header.firstIndex(of: BeliImporter.normalize(alias)) }).first,
              row.indices.contains(index) else { return nil }
        let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func require(_ columns: [String], filename: String) throws {
        for column in columns where !normalizedHeader.contains(BeliImporter.normalize(column)) {
            throw BeliImporter.ImportError.missingColumn(file: filename, column: column)
        }
    }
}

private enum BeliDateParser {
    static func parseTimestamp(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: value) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: value) { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX"
        if let result = formatter.date(from: value) { return result }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return formatter.date(from: value)
    }

    static func parseVisitDates(_ value: String) -> [Date]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[]" { return [] }
        let pattern = #"datetime\.date\((\d{4}),\s*(\d{1,2}),\s*(\d{1,2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        let matches = regex.matches(in: value, range: range)
        guard !matches.isEmpty else { return nil }
        let dates: [Date] = matches.compactMap { match -> Date? in
            guard match.numberOfRanges == 4,
                  let yearRange = Range(match.range(at: 1), in: value),
                  let monthRange = Range(match.range(at: 2), in: value),
                  let dayRange = Range(match.range(at: 3), in: value),
                  let year = Int(value[yearRange]), let month = Int(value[monthRange]), let day = Int(value[dayRange]) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        }
        return dates.count == matches.count ? dates : nil
    }

    static func key(_ date: Date) -> String { String(format: "%.3f", date.timeIntervalSince1970) }
}
