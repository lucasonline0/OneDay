import SwiftData
import SwiftUI
import UIKit

struct CameraExperienceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var controller: CameraController
    let canCaptureToday: Bool
    @Binding var isExpanded: Bool
    @State private var reviewPhoto: CapturedPhoto?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        GeometryReader { proxy in
            let collapsedWidth: CGFloat = 108
            let collapsedHeight: CGFloat = 42
            let expandedWidth = proxy.size.width
            let expandedHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let collapsedY = proxy.size.height - proxy.safeAreaInsets.bottom - 28

            ZStack {
                if isExpanded {
                    Color.black.ignoresSafeArea()
                }

                if controller.accessState == .authorized {
                    CameraPreview(session: controller.session)
                        .frame(
                            width: isExpanded ? expandedWidth : collapsedWidth,
                            height: isExpanded ? expandedHeight : collapsedHeight
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: isExpanded ? 0 : collapsedHeight / 2,
                                style: .continuous
                            )
                        )
                        .overlay {
                            if !isExpanded {
                                Capsule()
                                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isExpanded else { return }
                            openCamera()
                        }
                        .position(
                            x: proxy.size.width / 2,
                            y: isExpanded ? proxy.size.height / 2 : collapsedY
                        )
                        .shadow(color: .black.opacity(isExpanded ? 0 : 0.13), radius: 9, y: 4)
                        .accessibilityLabel(canCaptureToday ? "Open camera" : "Today's photo is already captured")
                } else if !isExpanded {
                    permissionCapsule
                        .position(x: proxy.size.width / 2, y: collapsedY)
                }

                if isExpanded, reviewPhoto == nil {
                    cameraControls(proxy: proxy)
                }

                if let reviewPhoto {
                    review(photo: reviewPhoto, proxy: proxy)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.16) : .spring(duration: 0.46, bounce: 0.08), value: isExpanded)
        }
        .ignoresSafeArea()
        .alert("OneDay", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
            if controller.accessState == .denied || controller.accessState == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private var permissionCapsule: some View {
        Button {
            Task {
                guard canCaptureToday else {
                    report("Today already has a photo.")
                    return
                }
                if await controller.requestAccessAndStart() {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    isExpanded = true
                } else {
                    report(controller.accessState == .denied ? OneDayError.cameraDenied.localizedDescription : OneDayError.cameraUnavailable.localizedDescription)
                }
            }
        } label: {
            Image(systemName: canCaptureToday ? "camera" : "checkmark")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 108, height: 42)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(canCaptureToday ? "Enable camera" : "Today's photo is already captured")
    }

    @ViewBuilder
    private func cameraControls(proxy: GeometryProxy) -> some View {
        VStack {
            HStack {
                Button {
                    collapse()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Close camera")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, proxy.safeAreaInsets.top + 10)

            Spacer()

            Button {
                Task { await capture() }
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 72, height: 72)
                    Circle().stroke(.black.opacity(0.22), lineWidth: 1.2).frame(width: 62, height: 62)
                }
            }
            .buttonStyle(.plain)
            .disabled(!controller.isReady)
            .opacity(controller.isReady ? 1 : 0.55)
            .accessibilityLabel("Take photo")
            .padding(.bottom, proxy.safeAreaInsets.bottom + 24)
        }
    }

    private func review(photo: CapturedPhoto, proxy: GeometryProxy) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let uiImage = UIImage(data: photo.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                HStack(spacing: 14) {
                    Button {
                        reviewPhoto = nil
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(isSaving)

                    Button {
                        Task { await usePhoto(photo) }
                    } label: {
                        if isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Use Photo", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isSaving)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, proxy.safeAreaInsets.bottom + 18)
            }
        }
    }

    private func openCamera() {
        guard canCaptureToday else {
            report("Today already has a photo.")
            return
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        Task {
            guard await controller.start() else {
                report(OneDayError.cameraUnavailable.localizedDescription)
                return
            }
            isExpanded = true
        }
    }

    private func collapse() {
        reviewPhoto = nil
        isExpanded = false
    }

    private func capture() async {
        guard canCaptureToday else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        do {
            reviewPhoto = try await controller.capture()
        } catch {
            report(error.localizedDescription)
        }
    }

    @MainActor
    private func usePhoto(_ photo: CapturedPhoto) async {
        isSaving = true
        defer { isSaving = false }

        let dayKey = DateService.dayKey(for: photo.capturedAt, timeZoneIdentifier: photo.timeZoneIdentifier)
        do {
            var descriptor = FetchDescriptor<DayEntry>(predicate: #Predicate { entry in
                entry.dayKey == dayKey
            })
            descriptor.fetchLimit = 1
            guard try modelContext.fetch(descriptor).isEmpty else {
                throw OneDayError.dayAlreadyCaptured
            }

            let filename = try await PhotoStorage.shared.saveCaptured(
                data: photo.data,
                dayKey: dayKey,
                fileExtension: photo.fileExtension
            )

            let entry = DayEntry(
                dayKey: dayKey,
                capturedAt: photo.capturedAt,
                timeZoneIdentifier: photo.timeZoneIdentifier,
                photoFilename: filename,
                width: photo.width,
                height: photo.height
            )
            modelContext.insert(entry)

            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                await PhotoStorage.shared.remove(relativePath: filename)
                throw error
            }

            let original = await PhotoStorage.shared.url(for: filename)
            _ = try? await ThumbnailService.shared.thumbnailData(dayKey: dayKey, originalURL: original)

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            reviewPhoto = nil
            isExpanded = false
        } catch {
            report(error.localizedDescription)
        }
    }

    private func report(_ message: String) {
        errorMessage = message
        showingError = true
    }
}
