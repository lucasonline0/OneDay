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

@MainActor
final class ThumbnailMemoryCache {
    static let shared = ThumbnailMemoryCache()

    private let cache = NSCache<NSString, UIImage>()

    func image(for entry: DayEntry) async -> UIImage? {
        let key = entry.dayKey as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let original = try? await PhotoStorage.shared.url(for: entry.photoFilename),
              let data = try? await ThumbnailService.shared.thumbnailData(dayKey: entry.dayKey, originalURL: original),
              let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    func clear(dayKey: String) {
        cache.removeObject(forKey: dayKey as NSString)
    }
}

struct TimelineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \DayEntry.capturedAt, order: .reverse) private var entries: [DayEntry]

    @Namespace private var photoNamespace
    @StateObject private var camera = CameraController()
    @State private var selectedEntry: DayEntry?
    @State private var showingViewer = false
    @State private var showingSettings = false
    @State private var now = Date()
    @State private var cameraExpanded = false
    @State private var renderedMonthCount = 18
    @State private var didPositionInitialMonth = false

    private var entryByDay: [String: DayEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.dayKey, $0) })
    }

    private var currentDayCaptured: Bool {
        entryByDay[DateService.currentDayKey(now: now)] != nil
    }

    private var displayedMonths: [Date] {
        DateService.monthStarts(endingAt: now, count: renderedMonthCount).reversed()
    }

    var body: some View {
        ZStack {
            Color.oneDayCanvas.ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 34) {
                        ForEach(displayedMonths, id: \.self) { month in
                            MonthSectionView(
                                month: month,
                                entries: entryByDay,
                                namespace: photoNamespace
                            ) { entry in
                                openViewer(entry)
                            }
                            .id(month)
                            .onAppear {
                                guard didPositionInitialMonth,
                                      month == displayedMonths.first else { return }
                                renderedMonthCount += 12
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 112)
                }
                .scrollIndicators(.hidden)
                .task {
                    guard !didPositionInitialMonth else { return }
                    await Task.yield()
                    if let currentMonth = displayedMonths.last {
                        scrollProxy.scrollTo(currentMonth, anchor: .bottom)
                    }
                    didPositionInitialMonth = true
                }
            }
            .opacity(cameraExpanded || showingViewer ? 0.72 : 1)
            .scaleEffect(cameraExpanded || showingViewer ? 0.985 : 1)
            .animation(.smooth(duration: 0.28), value: cameraExpanded)
            .animation(.smooth(duration: 0.24), value: showingViewer)

            if !showingViewer {
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
                .transition(.opacity)
            }

            CameraExperienceView(
                controller: camera,
                canCaptureToday: !currentDayCaptured,
                isExpanded: $cameraExpanded
            )
            .opacity(showingViewer ? 0 : 1)
            .allowsHitTesting(!showingViewer)

            if let selectedEntry, showingViewer {
                PhotoViewer(entry: selectedEntry, namespace: photoNamespace) {
                    closeViewer()
                }
                .zIndex(10)
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            camera.refreshAuthorization()
            if camera.accessState == .authorized, !currentDayCaptured {
                _ = await camera.start()
            }
        }
        .onChange(of: currentDayCaptured) { _, captured in
            if captured {
                camera.stop()
            } else if scenePhase == .active {
                Task { _ = await camera.start() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                now = .now
                if !currentDayCaptured {
                    Task { _ = await camera.start() }
                }
            case .inactive, .background:
                camera.stop()
            @unknown default:
                break
            }
        }
    }

    private func openViewer(_ entry: DayEntry) {
        selectedEntry = entry
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.4, bounce: 0.04)) {
            showingViewer = true
        }
    }

    private func closeViewer() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.36, bounce: 0.03)) {
            showingViewer = false
        }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 170 : 380))
            await MainActor.run { selectedEntry = nil }
        }
    }
}

private struct MonthSectionView: View {
    let month: Date
    let entries: [String: DayEntry]
    let namespace: Namespace.ID
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
                    DayCell(
                        day: day,
                        entry: entries[DateService.dayKey(for: day)],
                        namespace: namespace,
                        onSelect: onSelect
                    )
                }
            }
        }
    }
}

private struct DayCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let day: Date
    let entry: DayEntry?
    let namespace: Namespace.ID
    let onSelect: (DayEntry) -> Void

    var body: some View {
        Group {
            if let entry {
                Button {
                    onSelect(entry)
                } label: {
                    thumbnail(entry)
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

    @ViewBuilder
    private func thumbnail(_ entry: DayEntry) -> some View {
        let content = ThumbnailImage(entry: entry)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

        if reduceMotion {
            content
        } else {
            content.matchedGeometryEffect(id: "photo-\(entry.dayKey)", in: namespace)
        }
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
            image = await ThumbnailMemoryCache.shared.image(for: entry)
        }
    }
}
