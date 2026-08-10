import AVFoundation
import AppKit
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "CameraCapturer")

/// Grabs a single silent snapshot from the built-in camera and saves it to
/// ~/Downloads. Used only on a failed unlock attempt — never on lock, never on
/// a successful unlock, and never more than once per failure.
///
/// Never throws and never blocks the caller: a missing camera, a denied
/// permission, or a capture error all just log and return. Catching whoever's
/// at the keyboard is a bonus, not something that can be allowed to interfere
/// with the actual lock/unlock flow.
enum CameraCapturer {
    private static let session = AVCaptureSession()
    private static let photoOutput = AVCapturePhotoOutput()
    private static var delegate: PhotoDelegate?
    private static var isConfigured = false
    private static let queue = DispatchQueue(label: "in.pooya.bilakh.camera")

    static func captureAndSaveOnFailedUnlock() {
        guard CameraChecker.isEnabled else {
            logger.notice("Camera not authorized — skipping failed-unlock snapshot")
            return
        }

        queue.async {
            guard configureIfNeeded() else { return }

            session.startRunning()
            // Let the sensor settle for a beat before grabbing a frame — the very
            // first frame off a cold start is often under-exposed.
            Thread.sleep(forTimeInterval: 0.4)

            let settings = AVCapturePhotoSettings()
            let delegate = PhotoDelegate { image in
                session.stopRunning()
                guard let image else { return }
                save(image)
            }
            self.delegate = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Private

    private static func configureIfNeeded() -> Bool {
        if isConfigured { return true }

        guard let device = AVCaptureDevice.default(for: .video) else {
            logger.notice("No camera available — skipping failed-unlock snapshot")
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                logger.error("Could not wire up camera session")
                return false
            }
            session.addInput(input)
            session.addOutput(photoOutput)
            session.commitConfiguration()
            isConfigured = true
            return true
        } catch {
            logger.error("Camera input failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func save(_ image: CGImage) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            logger.error("Could not resolve Downloads folder")
            return
        }

        let timestamp = Date()
        let fileStamp = DateFormatter()
        fileStamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = "Bilakh Intruder \(fileStamp.string(from: timestamp))"
        let imageURL = downloads.appendingPathComponent("\(baseName).jpg")
        let descriptionURL = downloads.appendingPathComponent("\(baseName).txt")

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            logger.error("Could not encode snapshot")
            return
        }

        do {
            try data.write(to: imageURL)
            logger.notice("Saved failed-unlock snapshot to \(imageURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Could not save snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        let readableStamp = DateFormatter()
        readableStamp.dateStyle = .medium
        readableStamp.timeStyle = .medium
        let description = """
        Bilakh intruder snapshot

        Taken:  \(readableStamp.string(from: timestamp))
        Reason: Someone touched the keyboard, trackpad, or mouse while this Mac \
        was locked by Bilakh, or attempted to unlock it and failed.
        Image:  \(imageURL.lastPathComponent)

        This photo was captured automatically from the built-in camera. Turn it \
        off in Bilakh's settings under Lock Screen \u{2192} "Camera on failed unlock".
        """

        do {
            try description.write(to: descriptionURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Could not save snapshot description: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Bridges AVCapturePhotoOutput's delegate callback to a closure.
    private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        private let completion: (CGImage?) -> Void

        init(completion: @escaping (CGImage?) -> Void) {
            self.completion = completion
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error {
                logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            completion(photo.cgImageRepresentation())
        }
    }
}
