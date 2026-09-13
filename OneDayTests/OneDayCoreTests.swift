import CryptoKit
import Foundation
import SwiftData
import XCTest
import ZIPFoundation
@testable import OneDay

final class OneDayCoreTests: XCTestCase {
    private let fileManager = FileManager.default

    func testLocalDayKeyGenerationUsesCaptureTimeZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-13T02:00:00Z"))
        let belem = try XCTUnwrap(TimeZone(identifier: "America/Belem"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

        XCTAssertEqual(DateService.dayKey(for: date, timeZone: belem), "2026-09-12")
        XCTAssertEqual(DateService.dayKey(for: date, timeZone: tokyo), "2026-09-13")
        XCTAssertTrue(DateService.isValidDayKey("2026-09-13"))
        XCTAssertFalse(DateService.isValidDayKey("2026-02-30"))
    }

    func testDayEntryPreservesOriginalTimeZoneIdentifier() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-13T12:00:00Z"))
        let entry = DayEntry(
            dayKey: "2026-09-13",
            capturedAt: date,
            timeZoneIdentifier: "America/Belem",
            photoFilename: "2026/09/2026-09-13.heic",
            width: 4032,
            height: 3024
        )

        XCTAssertEqual(entry.timeZoneIdentifier, "America/Belem")
        XCTAssertEqual(DateService.dayKey(for: entry.capturedAt, timeZoneIdentifier: entry.timeZoneIdentifier), entry.dayKey)
    }

    @MainActor
    func testDayEntryStoreFindsExistingDayAndRejectsSecondStorageWrite() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: DayEntry.self, configurations: configuration)
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_757_764_800)
        context.insert(
            DayEntry(
                dayKey: "2026-09-13",
                capturedAt: date,
                timeZoneIdentifier: "America/Belem",
                photoFilename: "2026/09/2026-09-13.heic",
                width: 10,
                height: 10
            )
        )
        try context.save()

        XCTAssertTrue(try DayEntryStore.contains(dayKey: "2026-09-13", in: context))
        XCTAssertFalse(try DayEntryStore.contains(dayKey: "2026-09-14", in: context))

        let root = temporaryDirectory(named: "photo-storage")
        defer { try? fileManager.removeItem(at: root) }
        let storage = PhotoStorage(rootURL: root)
        _ = try await storage.saveCaptured(data: Data([0x01]), dayKey: "2026-09-13", fileExtension: "heic")

        do {
            _ = try await storage.saveCaptured(data: Data([0x02]), dayKey: "2026-09-13", fileExtension: "heic")
            XCTFail("A second photo for the same day must be rejected")
        } catch OneDayError.dayAlreadyCaptured {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManifestRoundTrip() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-13T12:00:00Z"))
        let manifest = BackupManifest(
            schemaVersion: 1,
            app: "OneDay",
            exportedAt: date,
            entries: [
                BackupEntry(
                    dayKey: "2026-09-13",
                    capturedAt: date,
                    timeZoneIdentifier: "America/Belem",
                    photoFilename: "photos/2026/09/2026-09-13.heic",
                    width: 4032,
                    height: 3024,
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackupManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
    }

    func testUnsupportedSchemaIsRejectedBeforeImport() async throws {
        let archiveURL = try makeBackupArchive(schemaVersion: 999, photoData: nil, hashOverride: nil)
        defer { try? fileManager.removeItem(at: archiveURL.deletingLastPathComponent()) }

        do {
            _ = try await BackupService().validateImport(sourceURL: archiveURL)
            XCTFail("Unsupported schema must fail validation")
        } catch OneDayError.unsupportedBackup {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testArchivePathSanitization() {
        XCTAssertTrue(BackupService.isSafeArchivePath("manifest.json"))
        XCTAssertTrue(BackupService.isSafeArchivePath("photos/2026/09/2026-09-13.heic"))
        XCTAssertFalse(BackupService.isSafeArchivePath("../manifest.json"))
        XCTAssertFalse(BackupService.isSafeArchivePath("photos/../../escape"))
        XCTAssertFalse(BackupService.isSafeArchivePath("/absolute/path"))
        XCTAssertFalse(BackupService.isSafeArchivePath("C:\\escape"))
        XCTAssertFalse(BackupService.isSafeArchivePath("photos\\escape.heic"))
    }

    func testBackupIntegrityAcceptsCorrectHashAndRejectsMismatch() async throws {
        let photoData = Data("OneDay test photo bytes".utf8)
        let validArchive = try makeBackupArchive(schemaVersion: 1, photoData: photoData, hashOverride: nil)
        defer { try? fileManager.removeItem(at: validArchive.deletingLastPathComponent()) }

        let service = BackupService()
        let validPlan = try await service.validateImport(sourceURL: validArchive)
        XCTAssertEqual(validPlan.entries.map(\.dayKey), ["2026-09-13"])
        await service.cleanup(validPlan)

        let invalidArchive = try makeBackupArchive(
            schemaVersion: 1,
            photoData: photoData,
            hashOverride: String(repeating: "0", count: 64)
        )
        defer { try? fileManager.removeItem(at: invalidArchive.deletingLastPathComponent()) }

        do {
            _ = try await service.validateImport(sourceURL: invalidArchive)
            XCTFail("A hash mismatch must fail validation")
        } catch OneDayError.hashMismatch {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testImportConflictDetection() {
        let entries = sampleConflictEntries()
        let conflicts = ImportPlanner.conflictDayKeys(
            entries: entries,
            existingDayKeys: ["2026-09-13", "2026-09-15"]
        )

        XCTAssertEqual(conflicts, ["2026-09-13"])
    }

    func testKeepCurrentConflictBehavior() {
        let entries = sampleConflictEntries()
        let conflicts: Set<String> = ["2026-09-13"]
        let selected = ImportPlanner.selectedEntries(
            from: entries,
            conflictDayKeys: conflicts,
            resolution: .keepCurrent
        )

        XCTAssertEqual(selected.map(\.dayKey), ["2026-09-14"])
    }

    func testUseBackupConflictBehavior() {
        let entries = sampleConflictEntries()
        let conflicts: Set<String> = ["2026-09-13"]
        let selected = ImportPlanner.selectedEntries(
            from: entries,
            conflictDayKeys: conflicts,
            resolution: .useBackup
        )

        XCTAssertEqual(selected.map(\.dayKey), ["2026-09-13", "2026-09-14"])
    }

    func testPhotoStorageRejectsTraversalDuringImportCommit() async throws {
        let root = temporaryDirectory(named: "photo-storage-traversal")
        let source = root.appendingPathComponent("source.heic")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x01]).write(to: source)
        defer { try? fileManager.removeItem(at: root) }

        let storage = PhotoStorage(rootURL: root.appendingPathComponent("library", isDirectory: true))
        do {
            _ = try await storage.commitImportFiles([
                .init(destinationRelativePath: "../escape.heic", sourceURL: source)
            ])
            XCTFail("Traversal paths must never be committed")
        } catch OneDayError.unsafeArchive {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func sampleConflictEntries() -> [BackupEntry] {
        let date = Date(timeIntervalSince1970: 1_757_764_800)
        return [
            BackupEntry(
                dayKey: "2026-09-13",
                capturedAt: date,
                timeZoneIdentifier: "America/Belem",
                photoFilename: "photos/2026/09/2026-09-13.heic",
                width: 10,
                height: 10,
                sha256: String(repeating: "a", count: 64)
            ),
            BackupEntry(
                dayKey: "2026-09-14",
                capturedAt: date.addingTimeInterval(86_400),
                timeZoneIdentifier: "America/Belem",
                photoFilename: "photos/2026/09/2026-09-14.heic",
                width: 10,
                height: 10,
                sha256: String(repeating: "b", count: 64)
            )
        ]
    }

    private func makeBackupArchive(
        schemaVersion: Int,
        photoData: Data?,
        hashOverride: String?
    ) throws -> URL {
        let root = temporaryDirectory(named: "backup-fixture")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("fixture.oneday")

        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-13T12:00:00Z"))
        let entries: [BackupEntry]
        if let photoData {
            entries = [
                BackupEntry(
                    dayKey: "2026-09-13",
                    capturedAt: date,
                    timeZoneIdentifier: "America/Belem",
                    photoFilename: "photos/2026/09/2026-09-13.heic",
                    width: 10,
                    height: 10,
                    sha256: hashOverride ?? sha256(photoData)
                )
            ]
        } else {
            entries = []
        }

        let manifest = BackupManifest(
            schemaVersion: schemaVersion,
            app: "OneDay",
            exportedAt: date,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = root.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL)

        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "manifest.json", fileURL: manifestURL, compressionMethod: .deflate)

        if let photoData {
            let photoURL = root.appendingPathComponent("2026-09-13.heic")
            try photoData.write(to: photoURL)
            try archive.addEntry(
                with: "photos/2026/09/2026-09-13.heic",
                fileURL: photoURL,
                compressionMethod: .none
            )
        }

        return archiveURL
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory(named name: String) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("OneDayTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}
