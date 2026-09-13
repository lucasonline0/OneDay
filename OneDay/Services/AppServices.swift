import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

struct DateService {
    static func dayKey(for date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "invalid-date" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func dayKey(for date: Date, timeZoneIdentifier: String) -> String {
        dayKey(for: date, timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent)
    }

    static func currentDayKey(now: Date = .now) -> String {
        dayKey(for: now, timeZone: .autoupdatingCurrent)
    }

    static func monthStarts(endingAt date: Date = .now, count: Int) -> [Date] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        guard let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else {
            return []
        }
        return (0..<max(0, count)).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: currentMonth)
        }
    }

    static func days(in month: Date) -> [Date] {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { day in
            calendar.date(bySetting: .day, value: day, of: month)
        }
    }

    static func leadingBlankCount(for month: Date) -> Int {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let weekday = calendar.component(.weekday, from: month)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    static func monthTitle(for month: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: month).lowercased(with: .autoupdatingCurrent)
    }

    static func isPastDay(_ date: Date, now: Date = .now) -> Bool {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
    }

    static func isToday(_ date: Date, now: Date = .now) -> Bool {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar.isDate(date, inSameDayAs: now)
    }

    static func monthCountToCurrent(from earliestDayKey: String?, minimum: Int = 18) -> Int {
        guard let earliestDayKey else { return minimum }
        let parts = earliestDayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return minimum }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let earliestMonth = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: .now)),
              let months = calendar.dateComponents([.month], from: earliestMonth, to: currentMonth).month else {
            return minimum
        }
        return max(minimum, months + 1)
    }
}

actor PhotoStorage {
    static let shared = PhotoStorage()

    struct ImportFileChange: Sendable {
        let destinationRelativePath: String
        let sourceURL: URL
    }

    struct ImportCommitToken: Sendable {
        fileprivate let rollbackDirectory: URL
        fileprivate let touchedRelativePaths: [String]
        fileprivate let previouslyExisting: Set<String>
    }

    private let fileManager = FileManager.default
    private let photosRoot: URL

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        photosRoot = support.appendingPathComponent("OneDay/Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
    }

    func saveCaptured(data: Data, dayKey: String, fileExtension: String) throws -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3 else { throw OneDayError.invalidDate }
        let relative = "\(parts[0])/\(parts[1])/\(dayKey).\(fileExtension)"
        let destination = safeURL(relativePath: relative)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw OneDayError.dayAlreadyCaptured
        }
        try data.write(to: destination, options: [.atomic])
        return relative
    }

    func url(for relativePath: String) -> URL {
        safeURL(relativePath: relativePath)
    }

    func remove(relativePath: String) {
        try? fileManager.removeItem(at: safeURL(relativePath: relativePath))
    }

    func storageSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: photosRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    func commitImportFiles(_ changes: [ImportFileChange]) throws -> ImportCommitToken {
        let rollbackDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OneDayImportRollback-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)

        var touched: [String] = []
        var previouslyExisting = Set<String>()

        do {
            for change in changes {
                let destination = safeURL(relativePath: change.destinationRelativePath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

                if fileManager.fileExists(atPath: destination.path) {
                    previouslyExisting.insert(change.destinationRelativePath)
                    let backup = rollbackDirectory.appendingPathComponent(change.destinationRelativePath)
                    try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: destination, to: backup)
                }

                let temporary = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).importing")
                try fileManager.copyItem(at: change.sourceURL, to: temporary)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: temporary, to: destination)
                touched.append(change.destinationRelativePath)
            }
        } catch {
            let token = ImportCommitToken(
                rollbackDirectory: rollbackDirectory,
                touchedRelativePaths: touched,
                previouslyExisting: previouslyExisting
            )
            rollbackImportFiles(token)
            throw error
        }

        return ImportCommitToken(
            rollbackDirectory: rollbackDirectory,
            touchedRelativePaths: touched,
            previouslyExisting: previouslyExisting
        )
    }

    func rollbackImportFiles(_ token: ImportCommitToken) {
        for relative in token.touchedRelativePaths.reversed() {
            let destination = safeURL(relativePath: relative)
            try? fileManager.removeItem(at: destination)
            if token.previouslyExisting.contains(relative) {
                let backup = token.rollbackDirectory.appendingPathComponent(relative)
                try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.copyItem(at: backup, to: destination)
            }
        }
        try? fileManager.removeItem(at: token.rollbackDirectory)
    }

    func finalizeImportFiles(_ token: ImportCommitToken) {
        try? fileManager.removeItem(at: token.rollbackDirectory)
    }

    private func safeURL(relativePath: String) -> URL {
        let candidate = photosRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(photosRoot.standardizedFileURL.path + "/") else {
            return photosRoot.appendingPathComponent("__invalid_path__")
        }
        return candidate
    }
}

actor ThumbnailService {
    static let shared = ThumbnailService()

    private let fileManager = FileManager.default
    private let root: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = caches.appendingPathComponent("OneDay/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func thumbnailData(dayKey: String, originalURL: URL) throws -> Data {
        let destination = root.appendingPathComponent("\(dayKey).jpg")
        if fileManager.fileExists(atPath: destination.path) {
            return try Data(contentsOf: destination, options: [.mappedIfSafe])
        }

        guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil) else {
            throw OneDayError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OneDayError.invalidImage
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw OneDayError.thumbnailFailed
        }
        CGImageDestinationAddImage(writer, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw OneDayError.thumbnailFailed }
        return try Data(contentsOf: destination, options: [.mappedIfSafe])
    }

    func clear(dayKey: String) {
        try? fileManager.removeItem(at: root.appendingPathComponent("\(dayKey).jpg"))
    }
}

struct BackupSource: Sendable {
    let dayKey: String
    let capturedAt: Date
    let timeZoneIdentifier: String
    let photoFilename: String
    let width: Int
    let height: Int
}

struct BackupManifest: Codable, Sendable {
    let schemaVersion: Int
    let app: String
    let exportedAt: Date
    let entries: [BackupEntry]
}

struct BackupEntry: Codable, Sendable, Hashable {
    let dayKey: String
    let capturedAt: Date
    let timeZoneIdentifier: String
    let photoFilename: String
    let width: Int
    let height: Int
    let sha256: String

    var localRelativePhotoPath: String {
        photoFilename.hasPrefix("photos/") ? String(photoFilename.dropFirst("photos/".count)) : photoFilename
    }
}

struct ImportPlan: Sendable, Identifiable {
    let id = UUID()
    let workingDirectory: URL
    let entries: [BackupEntry]
}

actor BackupService {
    static let shared = BackupService()
    static let schemaVersion = 1

    private let fileManager = FileManager.default

    func copySecurityScopedImportToTemporary(_ source: URL) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("OneDayIncoming-\(UUID().uuidString).oneday")
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    func removeTemporaryImportCopy(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func export(sources: [BackupSource]) async throws -> URL {
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("OneDayExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        var entries: [BackupEntry] = []
        for source in sources {
            let original = await PhotoStorage.shared.url(for: source.photoFilename)
            guard fileManager.fileExists(atPath: original.path) else { throw OneDayError.missingPhoto }
            entries.append(
                BackupEntry(
                    dayKey: source.dayKey,
                    capturedAt: source.capturedAt,
                    timeZoneIdentifier: source.timeZoneIdentifier,
                    photoFilename: "photos/\(source.photoFilename)",
                    width: source.width,
                    height: source.height,
                    sha256: try sha256(of: original)
                )
            )
        }

        let manifest = BackupManifest(
            schemaVersion: Self.schemaVersion,
            app: "OneDay",
            exportedAt: .now,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = work.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])

        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("OneDay-\(nameFormatter.string(from: .now)).oneday")
        try? fileManager.removeItem(at: archiveURL)

        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "manifest.json", fileURL: manifestURL, compressionMethod: .deflate)
        for source in sources {
            let original = await PhotoStorage.shared.url(for: source.photoFilename)
            try archive.addEntry(
                with: "photos/\(source.photoFilename)",
                fileURL: original,
                compressionMethod: .none
            )
        }
        return archiveURL
    }

    func validateImport(sourceURL: URL) throws -> ImportPlan {
        let archive = try Archive(url: sourceURL, accessMode: .read)
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("OneDayImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        do {
            var archivePaths = Set<String>()
            for entry in archive {
                guard archivePaths.insert(entry.path).inserted else { throw OneDayError.unsafeArchive }
                guard isSafeArchivePath(entry.path) else { throw OneDayError.unsafeArchive }
                if entry.type == .directory { continue }
                guard entry.type == .file else { throw OneDayError.unsafeArchive }

                let destination = work.appendingPathComponent(entry.path).standardizedFileURL
                guard destination.path.hasPrefix(work.standardizedFileURL.path + "/") else {
                    throw OneDayError.unsafeArchive
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.extract(entry, to: destination)
            }

            let manifestURL = work.appendingPathComponent("manifest.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.app == "OneDay", manifest.schemaVersion == Self.schemaVersion else {
                throw OneDayError.unsupportedBackup
            }

            var dayKeys = Set<String>()
            for entry in manifest.entries {
                guard isValidDayKey(entry.dayKey), entry.width > 0, entry.height > 0 else {
                    throw OneDayError.unsupportedBackup
                }
                guard TimeZone(identifier: entry.timeZoneIdentifier) != nil else { throw OneDayError.unsupportedBackup }
                guard dayKeys.insert(entry.dayKey).inserted else { throw OneDayError.duplicateBackupDay }
                guard entry.photoFilename.hasPrefix("photos/"), isSafeArchivePath(entry.photoFilename) else {
                    throw OneDayError.unsafeArchive
                }
                let photoURL = work.appendingPathComponent(entry.photoFilename).standardizedFileURL
                guard fileManager.fileExists(atPath: photoURL.path) else { throw OneDayError.missingPhoto }
                guard try sha256(of: photoURL) == entry.sha256.lowercased() else {
                    throw OneDayError.hashMismatch
                }
            }

            return ImportPlan(workingDirectory: work, entries: manifest.entries)
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

    func cleanup(_ plan: ImportPlan) {
        try? fileManager.removeItem(at: plan.workingDirectory)
    }

    private func isValidDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) != nil
    }

    private func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\"),
              !path.contains(":") else { return false }
        return !NSString(string: path).pathComponents.contains("..")
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension UTType {
    static let oneDayBackup = UTType(exportedAs: "com.lucasonline0.oneday.backup", conformingTo: .zip)
}

enum OneDayError: LocalizedError {
    case invalidDate
    case dayAlreadyCaptured
    case invalidImage
    case thumbnailFailed
    case cameraUnavailable
    case cameraDenied
    case captureFailed
    case missingPhoto
    case unsupportedBackup
    case unsafeArchive
    case duplicateBackupDay
    case hashMismatch
    case importFailed

    var errorDescription: String? {
        switch self {
        case .invalidDate: "The date could not be stored."
        case .dayAlreadyCaptured: "Today already has a photo."
        case .invalidImage: "The captured photo could not be read."
        case .thumbnailFailed: "The photo preview could not be created."
        case .cameraUnavailable: "The camera is unavailable on this device."
        case .cameraDenied: "Camera access is disabled for OneDay."
        case .captureFailed: "The photo could not be captured."
        case .missingPhoto: "A photo referenced by the library is missing."
        case .unsupportedBackup: "This OneDay backup version is not supported."
        case .unsafeArchive: "This backup contains an unsafe or invalid file path."
        case .duplicateBackupDay: "This backup contains more than one photo for the same day."
        case .hashMismatch: "A photo in this backup failed its integrity check."
        case .importFailed: "The backup could not be imported safely."
        }
    }
}
