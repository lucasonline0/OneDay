import SwiftData
import SwiftUI
import UIKit

extension Color {
    static let oneDayCanvas = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.075, green: 0.071, blue: 0.071, alpha: 1)
        }
        return UIColor(red: 0.965, green: 0.949, blue: 0.941, alpha: 1)
    })
}

struct TimelineView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \DayEntry.capturedAt, order: .reverse) private var entries: [DayEntry]

    @StateObject private var camera = CameraController()
    @State private var selectedEntry: DayEntry?
    @State private var showingViewer = false
    @State private var showingSettings = false
    @State private var now = Date()
    @State private var cameraExpanded = false

    private var entryByDay: [String: DayEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.dayKey, $0) })
    }

    private var currentDayCaptured: Bool {
        entryByDay[DateService.currentDayKey(now: now)] != nil
    }

    private var monthsToDisplay: Int {
        DateService.monthCountToCurrent(from: entries.last?.dayKey)
    }

    var body: some View {
        ZStack {
            Color.oneDayCanvas.ignoresSafeArea()

            ScrollView(.vertical) {
                LazyVStack(spacing: 34) {
                    ForEach(DateService.monthStarts(count: monthsToDisplay), id: \.self) { month in
                        MonthSectionView(month: month, entries: entryByDay) { entry in
                            selectedEntry = entry
                            showingViewer = true
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 112)
            }
            .scrollIndicators(.hidden)
            .opacity(cameraExpanded ? 0.72 : 1)
            .scaleEffect(cameraExpanded ? 0.985 : 1)
            .animation(.smooth(duration: 0.28), value: cameraExpanded)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Settings")
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            CameraExperienceView(
                controller: camera,
                canCaptureToday: !currentDayCaptured,
                isExpanded: $cameraExpanded
            )
        }
        .fullScreenCover(isPresented: $showingViewer, onDismiss: { selectedEntry = nil }) {
            if let selectedEntry {
                PhotoViewer(entry: selectedEntry) {
                    showingViewer = false
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            camera.refreshAuthorization()
            if camera.accessState == .authorized {
                _ = await camera.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                now = .now
                Task { _ = await camera.start() }
            case .inactive, .background:
                camera.stop()
            @unknown default:
                break
            }
        }
    }
}

private struct MonthSectionView: View {
    let month: Date
    let entries: [String: DayEntry]
    let onSelect: (DayEntry) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(DateService.monthTitle(for: month))
                    .font(.system(size: 15, weight: .medium, design: .default))
                    .foregroundStyle(.primary.opacity(0.82))
                Spacer()
                let count = DateService.days(in: month).reduce(0) { partial, date in
                    partial + (entries[DateService.dayKey(for: date)] == nil ? 0 : 1)
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary.opacity(0.58))
                }
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(0..<DateService.leadingBlankCount(for: month), id: \.self) { _ in
                    Color.clear.frame(height: 42)
                }
                ForEach(DateService.days(in: month), id: \.self) { day in
                    DayCell(day: day, entry: entries[DateService.dayKey(for: day)], onSelect: onSelect)
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let entry: DayEntry?
    let onSelect: (DayEntry) -> Void

    var body: some View {
        Group {
            if let entry {
                Button {
                    onSelect(entry)
                } label: {
                    ThumbnailImage(entry: entry)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityDate(entry.capturedAt, timeZoneIdentifier: entry.timeZoneIdentifier))
            } else if DateService.isPastDay(day) {
                Circle()
                    .fill(.secondary.opacity(0.24))
                    .frame(width: 3.5, height: 3.5)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .accessibilityLabel("No photo, \(accessibilityDate(day, timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier))")
            } else if DateService.isToday(day) {
                Circle()
                    .stroke(.primary.opacity(0.38), lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .accessibilityLabel("Today, not captured yet")
            } else {
                Color.clear.frame(height: 42)
            }
        }
        .frame(minHeight: 42)
    }

    private func accessibilityDate(_ date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        return formatter.string(from: date)
    }
}

private struct ThumbnailImage: View {
    let entry: DayEntry
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.primary.opacity(0.045))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .task(id: entry.photoFilename) {
            let original = await PhotoStorage.shared.url(for: entry.photoFilename)
            if let data = try? await ThumbnailService.shared.thumbnailData(dayKey: entry.dayKey, originalURL: original) {
                image = UIImage(data: data)
            }
        }
    }
}
