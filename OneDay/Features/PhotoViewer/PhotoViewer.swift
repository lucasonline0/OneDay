import SwiftUI
import UIKit

struct PhotoViewer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entry: DayEntry
    let namespace: Namespace.ID
    let onClose: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                photo(image)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Close photo")
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 3) {
                    Text(dateText)
                        .font(.callout.weight(.medium))
                    Text(timeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect()
                .padding(.bottom, 18)
            }
        }
        .task(id: entry.photoFilename) {
            guard let url = try? await PhotoStorage.shared.url(for: entry.photoFilename) else { return }
            let data = try? await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            if let data {
                image = UIImage(data: data)
            }
        }
        .statusBarHidden()
    }

    @ViewBuilder
    private func photo(_ image: UIImage) -> some View {
        let content = Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        if reduceMotion {
            content
        } else {
            content.matchedGeometryEffect(id: "photo-\(entry.dayKey)", in: namespace)
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: entry.timeZoneIdentifier)
        return formatter.string(from: entry.capturedAt)
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: entry.timeZoneIdentifier)
        return formatter.string(from: entry.capturedAt)
    }
}
