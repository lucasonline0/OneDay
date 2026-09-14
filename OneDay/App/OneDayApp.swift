import SwiftData
import SwiftUI

@main
@MainActor
struct OneDayApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: DayEntry.self)
            modelContainer.mainContext.autosaveEnabled = false
        } catch {
            fatalError("Unable to initialize the local OneDay store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            TimelineView()
        }
        .modelContainer(modelContainer)
    }
}
