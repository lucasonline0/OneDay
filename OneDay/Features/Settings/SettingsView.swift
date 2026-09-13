import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum ConflictResolution {
        case keepCurrent
        case useBackup
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DayEntry.capturedAt, order: .reverse) private var entries: [DayEntry]

    @State private var storageBytes: Int64 = 0
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showingImporter = false
    @State private var shareURL: URL?
    @State private var pendingPlan: ImportPlan?
    @State private var conflictDayKeys = Set<String>()
    @State private var showingImportConfirmation = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Data") {
                    Button {
                        Task { await exportBackup() }
                    } label: {
                        HStack {
                            Label("Export Backup", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isExporting { ProgressView() }
                        }
                    }
                    .disabled(isExporting || isImporting || entries.isEmpty)

                    Button {
                        showingImporter = true
                    } label: {
                        HStack {
                            Label("Import Backup", systemImage: "square.and.arrow.down")
                            Spacer()
                            if isImporting { ProgressView() }
                        }
                    }
                    .disabled(isExporting || isImporting)
                }

                Section("Storage") {
                    LabeledContent("Captured days", value: "\(entries.count)")
                    LabeledContent("Photos", value: "\(entries.count)")
                    LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                }

                Section("Privacy") {
                    Text("Your photos stay on this iPhone unless you explicitly export a OneDay backup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("OneDay", value: "1.0")
                    Text("One day. One photo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { storageBytes = await PhotoStorage.shared.storageSize() }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.oneDayBackup, .zip],
            allowsMultipleSelection: false
        ) { result in
            Task { await receiveImport(result) }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .confirmationDialog(
            importDialogTitle,
            isPresented: $showingImportConfirmation,
            titleVisibility: .visible
        ) {
            if conflictDayKeys.isEmpty {
                Button("Import") { Task { await applyImport(.keepCurrent) } }
            } else {
                Button("Keep Current") { Task { await applyImport(.keepCurrent) } }
                Button("Use Backup", role: .destructive) { Task { await applyImport(.useBackup) } }
            }
            Button("Cancel", role: .cancel) { cleanupPendingPlan() }
        } message: {
            Text(importDialogMessage)
        }
        .alert("OneDay", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
        .overlay(alignment: .bottom) {
            if let successMessage {
                Text(successMessage)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect()
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var importDialogTitle: String {
        guard let pendingPlan else { return "Import backup?" }
        return "Import \(pendingPlan.entries.count) day\(pendingPlan.entries.count == 1 ? "" : "s")?"
    }

    private var importDialogMessage: String {
        guard !conflictDayKeys.isEmpty else {
            return "The backup was validated and no existing days will be overwritten."
        }
        return "\(conflictDayKeys.count) day\(conflictDayKeys.count == 1 ? "" : "s") already exist. Choose which copy to keep for those dates."
    }

    @MainActor
    private func exportBackup() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let sources = entries.map {
                BackupSource(
                    dayKey: $0.dayKey,
                    capturedAt: $0.capturedAt,
                    timeZoneIdentifier: $0.timeZoneIdentifier,
                    photoFilename: $0.photoFilename,
                    width: $0.width,
                    height: $0.height
                )
            }
            shareURL = try await BackupService.shared.export(sources: sources)
        } catch {
            report(error.localizedDescription)
        }
    }

    @MainActor
    private func receiveImport(_ result: Result<[URL], Error>) async {
        isImporting = true
        defer { isImporting = false }
        do {
            guard let selectedURL = try result.get().first else { return }
            let localCopy = try await BackupService.shared.copySecurityScopedImportToTemporary(selectedURL)
            defer { Task { await BackupService.shared.removeTemporaryImportCopy(localCopy) } }

            let plan = try await BackupService.shared.validateImport(sourceURL: localCopy)
            let currentKeys = Set(entries.map(\.dayKey))
            conflictDayKeys = Set(plan.entries.map(\.dayKey)).intersection(currentKeys)
            pendingPlan = plan
            showingImportConfirmation = true
        } catch {
            report(error.localizedDescription)
        }
    }

    @MainActor
    private func applyImport(_ resolution: ConflictResolution) async {
        guard let plan = pendingPlan else { return }
        isImporting = true
        defer { isImporting = false }

        let selectedEntries: [BackupEntry]
        switch resolution {
        case .keepCurrent:
            selectedEntries = plan.entries.filter { !conflictDayKeys.contains($0.dayKey) }
        case .useBackup:
            selectedEntries = plan.entries
        }

        let changes = selectedEntries.map { entry in
            PhotoStorage.ImportFileChange(
                destinationRelativePath: entry.localRelativePhotoPath,
                sourceURL: plan.workingDirectory.appendingPathComponent(entry.photoFilename)
            )
        }

        var fileToken: PhotoStorage.ImportCommitToken?
        let previousAutosave = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosave }

        do {
            fileToken = try await PhotoStorage.shared.commitImportFiles(changes)
            var oldFilesToDelete = Set<String>()

            for record in selectedEntries {
                var descriptor = FetchDescriptor<DayEntry>(predicate: #Predicate { entry in
                    entry.dayKey == record.dayKey
                })
                descriptor.fetchLimit = 1
                if let existing = try modelContext.fetch(descriptor).first {
                    if existing.photoFilename != record.localRelativePhotoPath {
                        oldFilesToDelete.insert(existing.photoFilename)
                    }
                    existing.capturedAt = record.capturedAt
                    existing.timeZoneIdentifier = record.timeZoneIdentifier
                    existing.photoFilename = record.localRelativePhotoPath
                    existing.width = record.width
                    existing.height = record.height
                } else {
                    modelContext.insert(
                        DayEntry(
                            dayKey: record.dayKey,
                            capturedAt: record.capturedAt,
                            timeZoneIdentifier: record.timeZoneIdentifier,
                            photoFilename: record.localRelativePhotoPath,
                            width: record.width,
                            height: record.height
                        )
                    )
                }
            }

            try modelContext.save()
            if let fileToken { await PhotoStorage.shared.finalizeImportFiles(fileToken) }
            for oldFile in oldFilesToDelete {
                await PhotoStorage.shared.remove(relativePath: oldFile)
            }

            for record in selectedEntries {
                await ThumbnailService.shared.clear(dayKey: record.dayKey)
                let original = await PhotoStorage.shared.url(for: record.localRelativePhotoPath)
                _ = try? await ThumbnailService.shared.thumbnailData(dayKey: record.dayKey, originalURL: original)
            }

            await BackupService.shared.cleanup(plan)
            pendingPlan = nil
            conflictDayKeys = []
            storageBytes = await PhotoStorage.shared.storageSize()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showSuccess("Imported \(selectedEntries.count) day\(selectedEntries.count == 1 ? "" : "s")")
        } catch {
            modelContext.rollback()
            if let fileToken { await PhotoStorage.shared.rollbackImportFiles(fileToken) }
            await BackupService.shared.cleanup(plan)
            pendingPlan = nil
            conflictDayKeys = []
            report(error.localizedDescription)
        }
    }

    private func cleanupPendingPlan() {
        guard let pendingPlan else { return }
        Task { await BackupService.shared.cleanup(pendingPlan) }
        self.pendingPlan = nil
        conflictDayKeys = []
    }

    private func report(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private func showSuccess(_ message: String) {
        withAnimation { successMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            await MainActor.run {
                withAnimation { successMessage = nil }
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
