import Foundation
import SwiftData

@Model
final class DayEntry {
    @Attribute(.unique) var dayKey: String
    var capturedAt: Date
    var timeZoneIdentifier: String
    var photoFilename: String
    var width: Int
    var height: Int
    var createdAt: Date

    init(
        dayKey: String,
        capturedAt: Date,
        timeZoneIdentifier: String,
        photoFilename: String,
        width: Int,
        height: Int,
        createdAt: Date = .now
    ) {
        self.dayKey = dayKey
        self.capturedAt = capturedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.photoFilename = photoFilename
        self.width = width
        self.height = height
        self.createdAt = createdAt
    }
}
