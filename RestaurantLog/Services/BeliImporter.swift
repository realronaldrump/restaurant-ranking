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
    struct Limits: Sendable {
        let maximumConcurrentDownloads: Int
        let maximumResponseBytes: Int64
        let maximumPreparedPhotoBytes: Int
        let maximumRetainedPhotoCount: Int
        let maximumRetainedPreparedBytes: Int

        static let `default` = Limits(
            maximumConcurrentDownloads: 3,
            maximumResponseBytes: 25 * 1_024 * 1_024,
            maximumPreparedPhotoBytes: 8 * 1_024 * 1_024,
            maximumRetainedPhotoCount: 500,
            maximumRetainedPreparedBytes: 64 * 1_024 * 1_024
        )
    }

    enum DownloadError: LocalizedError, Equatable {
        case insecureSource
        case insecureRedirect
        case badResponse
        case responseTooLarge
        case invalidImage
        case preparedPhotoTooLarge
        case retainedMemoryLimit

        var errorDescription: String? {
            switch self {
            case .insecureSource:
                "The photo URL is not a secure HTTPS URL."
            case .insecureRedirect:
                "The photo download redirected to a non-HTTPS URL."
            case .badResponse:
                "Beli returned an invalid photo response."
            case .responseTooLarge:
                "The photo download is too large to import safely."
            case .invalidImage:
                "The downloaded file is not a valid image."
            case .preparedPhotoTooLarge:
                "The prepared photo is too large to retain safely."
            case .retainedMemoryLimit:
                "The photo was skipped because this import reached its safe photo memory limit."
            }
        }
    }

    typealias Fetcher = @Sendable (BeliPhotoRow, Limits) async -> Result<BeliDownloadedPhoto, Error>

    static let maximumPhotoBytes = Limits.default.maximumResponseBytes

    static func download(
        _ rows: [BeliPhotoRow],
        maxConcurrent: Int = 3,
        limits: Limits = .default,
        fetcher: @escaping Fetcher = fetch
    ) async -> BeliPhotoDownloadResult {
        var photos: [String: BeliDownloadedPhoto] = [:]
        var failures: [String: String] = [:]
        var retainedPreparedBytes = 0
        let size = min(max(1, maxConcurrent), max(1, limits.maximumConcurrentDownloads))
        let maximumRetainedPhotoCount = max(0, limits.maximumRetainedPhotoCount)
        let maximumRetainedPreparedBytes = max(0, limits.maximumRetainedPreparedBytes)
        for start in stride(from: 0, to: rows.count, by: size) {
            if Task.isCancelled { break }
            guard photos.count < maximumRetainedPhotoCount,
                  retainedPreparedBytes < maximumRetainedPreparedBytes else {
                for row in rows[start...] {
                    failures[row.id] = DownloadError.retainedMemoryLimit.localizedDescription
                }
                break
            }
            let batch = Array(rows[start..<min(rows.count, start + size)])
            let values = await withTaskGroup(of: (Int, String, Result<BeliDownloadedPhoto, Error>).self) { group in
                for (offset, row) in batch.enumerated() {
                    group.addTask { (offset, row.id, await fetcher(row, limits)) }
                }
                var output: [(Int, String, Result<BeliDownloadedPhoto, Error>)] = []
                for await value in group { output.append(value) }
                return output.sorted { $0.0 < $1.0 }
            }
            var reachedRetainedLimit = false
            for (_, id, result) in values {
                switch result {
                case .success(let photo):
                    let preparedBytes = photo.photo.fullData.count + (photo.photo.thumbnailData?.count ?? 0)
                    guard preparedBytes <= max(0, limits.maximumPreparedPhotoBytes) else {
                        failures[id] = DownloadError.preparedPhotoTooLarge.localizedDescription
                        continue
                    }
                    let remainingBytes = maximumRetainedPreparedBytes - retainedPreparedBytes
                    guard photos.count < maximumRetainedPhotoCount, preparedBytes <= remainingBytes else {
                        failures[id] = DownloadError.retainedMemoryLimit.localizedDescription
                        reachedRetainedLimit = true
                        continue
                    }
                    photos[id] = photo
                    retainedPreparedBytes += preparedBytes
                case .failure(let error):
                    failures[id] = error.localizedDescription
                }
            }
            if reachedRetainedLimit ||
                photos.count >= maximumRetainedPhotoCount ||
                retainedPreparedBytes >= maximumRetainedPreparedBytes {
                let nextIndex = start + batch.count
                if nextIndex < rows.count {
                    for row in rows[nextIndex...] where photos[row.id] == nil && failures[row.id] == nil {
                        failures[row.id] = DownloadError.retainedMemoryLimit.localizedDescription
                    }
                }
                break
            }
        }
        return .init(photos: photos, failures: failures)
    }

    static func fetch(_ row: BeliPhotoRow, limits: Limits) async -> Result<BeliDownloadedPhoto, Error> {
        do {
            guard row.imageURL.scheme?.lowercased() == "https" else {
                throw DownloadError.insecureSource
            }
            var request = URLRequest(url: row.imageURL)
            request.timeoutInterval = 45
            request.cachePolicy = .reloadRevalidatingCacheData
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            let data = try loadDownloadedFile(temporaryURL, response: response, limits: limits)
            guard response.mimeType?.lowercased().hasPrefix("image/") != false,
                  let photo = await ImageSanitizer.processOffMain(data, date: row.uploadDate) else {
                throw DownloadError.invalidImage
            }
            let preparedBytes = photo.fullData.count + (photo.thumbnailData?.count ?? 0)
            guard preparedBytes <= max(0, limits.maximumPreparedPhotoBytes) else {
                throw DownloadError.preparedPhotoTooLarge
            }
            return .success(.init(row: row, photo: photo, contentHash: BeliImporter.digest(data)))
        } catch {
            return .failure(error)
        }
    }

    static func loadDownloadedFile(_ fileURL: URL, response: URLResponse, limits: Limits) throws -> Data {
        guard response.url?.scheme?.lowercased() == "https" else {
            throw DownloadError.insecureRedirect
        }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw DownloadError.badResponse
        }
        let maximumBytes = max(0, limits.maximumResponseBytes)
        if response.expectedContentLength > maximumBytes {
            throw DownloadError.responseTooLarge
        }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, Int64(fileSize) <= maximumBytes else {
            throw DownloadError.responseTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard Int64(data.count) <= maximumBytes else {
            throw DownloadError.responseTooLarge
        }
        return data
    }
}

enum BeliImporter {
    static let maximumArchiveBytes: Int64 = 100 * 1_024 * 1_024
    static let maximumCSVBytes: UInt32 = 16 * 1_024 * 1_024
    static let maximumRowsPerFile = 10_000
    static let maximumFieldsPerRow = 256
    static let maximumFieldCharacters = 256 * 1_024
    static let maximumVisitDatesPerRanking = 1_000
    static let maximumTotalOutings = 25_000

    enum ImportError: LocalizedError, Equatable {
        case archiveTooLarge
        case unreadableArchive
        case missingRankings
        case oversizedEntry(String)
        case unreadableCSV(String)
        case missingColumn(file: String, column: String)
        case invalidRow(file: String, row: Int, detail: String)
        case tooManyOutings

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge: "That Beli export is too large to import safely."
            case .unreadableArchive: "The selected file is not a readable ZIP archive."
            case .missingRankings: "This ZIP does not contain Beli's rankings.csv file."
            case .oversizedEntry(let name): "\(name) is too large to import safely."
            case .unreadableCSV(let name): "\(name) could not be read as text."
            case .missingColumn(let file, let column): "\(file) is missing its \(column) column."
            case .invalidRow(let file, let row, let detail): "\(file) row \(row) is invalid: \(detail)"
            case .tooManyOutings: "That Beli export contains too many outings to import safely."
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
        var totalBytes: Int64 = 0
        for (name, data) in files {
            guard data.count <= Int(maximumCSVBytes) else {
                throw ImportError.oversizedEntry(name)
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(Int64(data.count))
            guard !overflow, nextTotal <= maximumArchiveBytes else {
                throw ImportError.archiveTooLarge
            }
            totalBytes = nextTotal
        }
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
        var rankings: [BeliRankingRow] = []
        rankings.reserveCapacity(csv.rows.count)
        var totalOutings = 0
        for (offset, row) in csv.rows.enumerated() {
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
            let visits: [Date]
            switch BeliDateParser.parseVisitDates(visitText, maximumCount: maximumVisitDatesPerRanking) {
            case .dates(let values):
                visits = values
            case .tooMany:
                throw ImportError.invalidRow(file: "rankings.csv", row: line, detail: "Visit Dates contains too many dates.")
            case .invalid:
                throw ImportError.invalidRow(file: "rankings.csv", row: line, detail: "Visit Dates is not recognized.")
            }
            let outingCount = max(1, visits.count)
            guard totalOutings <= maximumTotalOutings - outingCount else {
                throw ImportError.tooManyOutings
            }
            totalOutings += outingCount
            let key = digest([namespace, normalize(name), normalize(city), BeliDateParser.key(createdAt)].joined(separator: "|"))
            rankings.append(.init(
                id: key, rank: rank, restaurantName: name, city: city,
                createdAt: createdAt, visitDates: visits
            ))
        }
        return rankings.sorted { $0.rank < $1.rank }
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
        guard data.count <= Int(maximumCSVBytes) else {
            throw ImportError.oversizedEntry(filename)
        }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian) else {
            throw ImportError.unreadableCSV(filename)
        }
        let normalizedText = text.first == "\u{feff}" ? String(text.dropFirst()) : text
        let limits = CSVImporter.ParseLimits(
            maxRows: maximumRowsPerFile + 1,
            maxFieldsPerRow: maximumFieldsPerRow,
            maxFieldCharacters: maximumFieldCharacters
        )
        let rows: [[String]]
        do {
            rows = try CSVImporter.parseRows(normalizedText, limits: limits)
        } catch is CSVImporter.ParseLimitError {
            throw ImportError.oversizedEntry(filename)
        }
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
    enum VisitDatesResult {
        case dates([Date])
        case invalid
        case tooMany
    }

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

    static func parseVisitDates(_ value: String, maximumCount: Int) -> VisitDatesResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[]" { return .dates([]) }
        let pattern = #"datetime\.date\((\d{4}),\s*(\d{1,2}),\s*(\d{1,2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .invalid }
        let range = NSRange(value.startIndex..., in: value)
        var dates: [Date] = []
        dates.reserveCapacity(min(maximumCount, 32))
        var invalid = false
        var tooMany = false
        regex.enumerateMatches(in: value, range: range) { match, _, stop in
            guard let match else { return }
            guard dates.count < maximumCount else {
                tooMany = true
                stop.pointee = true
                return
            }
            guard match.numberOfRanges == 4,
                  let yearRange = Range(match.range(at: 1), in: value),
                  let monthRange = Range(match.range(at: 2), in: value),
                  let dayRange = Range(match.range(at: 3), in: value),
                  let year = Int(value[yearRange]),
                  let month = Int(value[monthRange]),
                  let day = Int(value[dayRange]) else {
                invalid = true
                stop.pointee = true
                return
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
                invalid = true
                stop.pointee = true
                return
            }
            dates.append(date)
        }
        if tooMany { return .tooMany }
        if invalid || dates.isEmpty { return .invalid }
        return .dates(dates)
    }

    static func key(_ date: Date) -> String { String(format: "%.3f", date.timeIntervalSince1970) }
}
