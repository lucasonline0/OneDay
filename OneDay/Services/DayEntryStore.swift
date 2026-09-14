import Foundation
import SwiftData

@MainActor
enum DayEntryStore {
    static func entry(for dayKey: String, in context: ModelContext) throws -> DayEntry? {
        var descriptor = FetchDescriptor<DayEntry>(predicate: #Predicate { entry in
            entry.dayKey == dayKey
        })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func contains(dayKey: String, in context: ModelContext) throws -> Bool {
        try entry(for: dayKey, in: context) != nil
    }
}
