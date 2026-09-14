@preconcurrency import AVFoundation
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CapturedPhoto: Sendable {
    let data: Data
    let capturedAt: Date
    let timeZoneIdentifier: String
    let width: Int
    let height: Int
    let fileExtension: String
}

private final class CameraBackend: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.lucasonline0.OneDay.camera", qos: .userInitiated)
    private var configured = false
    private var captureContinuation: CheckedContinuation<CapturedPhoto, Error>?
    private var captureDate: Date?
    private var captureTimeZoneIdentifier: String?

    func configureAndStart() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if !configured {
                        try configure()
                        configured = true
                    }
                    if !session.isRunning {
                        session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func capture() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard configured, session.isRunning else {
                    continuation.resume(throwing: OneDayError.cameraUnavailable)
                    return
                }
                guard captureContinuation == nil else {
                    continuation.resume(throwing: OneDayError.captureFailed)
                    return
                }
                captureContinuation = continuation
                captureDate = .now
                captureTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier

                let settings: AVCapturePhotoSettings
                if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.photoQualityPrioritization = .quality
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw OneDayError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw OneDayError.cameraUnavailable
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        queue.async { [self] in
            guard let continuation = captureContinuation else { return }
            let capturedAt = captureDate ?? .now
            let timeZoneIdentifier = captureTimeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier
            captureContinuation = nil
            captureDate = nil
            captureTimeZoneIdentifier = nil

            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let data = photo.fileDataRepresentation(),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                continuation.resume(throwing: OneDayError.captureFailed)
                return
            }

            let type = CGImageSourceGetType(source) as String?
            let ext: String
            if let type, UTType(type)?.conforms(to: .heic) == true {
                ext = "heic"
            } else {
                ext = "jpg"
            }

            continuation.resume(
                returning: CapturedPhoto(
                    data: data,
                    capturedAt: capturedAt,
                    timeZoneIdentifier: timeZoneIdentifier,
                    width: width,
                    height: height,
                    fileExtension: ext
                )
            )
        }
    }
}

@MainActor
final class CameraController: ObservableObject {
    enum AccessState: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
        case unavailable
    }

    @Published private(set) var accessState: AccessState = .notDetermined
    @Published private(set) var isReady = false

    private let backend = CameraBackend()
    var session: AVCaptureSession { backend.session }

    init() {
        refreshAuthorization()
    }

    func refreshAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            accessState = .notDetermined
        case .authorized:
            accessState = .authorized
        case .denied:
            accessState = .denied
        case .restricted:
            accessState = .restricted
        @unknown default:
            accessState = .unavailable
        }
    }

    func requestAccessAndStart() async -> Bool {
        if accessState == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            accessState = granted ? .authorized : .denied
        }
        guard accessState == .authorized else { return false }
        return await start()
    }

    @discardableResult
    func start() async -> Bool {
        refreshAuthorization()
        guard accessState == .authorized else { return false }
        do {
            try await backend.configureAndStart()
            isReady = true
            return true
        } catch {
            accessState = .unavailable
            isReady = false
            return false
        }
    }

    func stop() {
        backend.stop()
        isReady = false
    }

    func capture() async throws -> CapturedPhoto {
        try await backend.capture()
    }
}
