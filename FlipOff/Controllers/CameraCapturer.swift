import AVFoundation
import AppKit
import CoreImage
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "CameraCapturer")

/// Grabs a single silent snapshot from the built-in camera and saves it to
/// ~/Downloads. Used only when someone touches the locked machine — never on
/// lock, never on a successful unlock, and never more than once per lock.
///
/// Uses `AVCaptureVideoDataOutput` (pull a frame off the live stream) rather than
/// `AVCapturePhotoOutput` (request a dedicated still). The photo path fails with
/// AVError -11800 whenever another process already holds the camera — Teams,
/// avconferenced, a browser tab — which on a normal desktop is most of the time.
/// Reading the video stream tolerates that shared access.
///
/// Never throws and never blocks the caller: a missing camera, a denied
/// permission, or a capture error all just log and return. Catching whoever's at
/// the keyboard is a bonus, not something allowed to interfere with the lock.
enum CameraCapturer {
    private static let session = AVCaptureSession()
    private static let videoOutput = AVCaptureVideoDataOutput()
    private static let frameGrabber = FrameGrabber()
    private static var isConfigured = false
    private static let queue = DispatchQueue(label: "in.pooya.bilakh.camera")
    /// Frames must be delivered on their own queue: `queue` blocks in
    /// `Thread.sleep` while waiting for them, so sharing it would deadlock the
    /// delegate and no frame would ever arrive.
    private static let sampleQueue = DispatchQueue(label: "in.pooya.bilakh.camera.frames")
    private static let ciContext = CIContext()

    static func captureAndSaveOnFailedUnlock() {
        guard CameraChecker.isEnabled else {
            logger.notice("Camera not authorized — skipping snapshot")
            return
        }

        queue.async {
            guard configureIfNeeded() else { return }

            frameGrabber.reset()
            session.startRunning()

            // `startRunning()` returns before the session is live, and a camera
            // already in use elsewhere can take a moment to come up.
            let startDeadline = Date().addingTimeInterval(3.0)
            while !session.isRunning && Date() < startDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            guard session.isRunning else {
                logger.error("Camera session never started — camera may be unavailable")
                session.stopRunning()
                return
            }

            // Discard the first frames: a cold sensor delivers black or wildly
            // under-exposed images until auto-exposure settles. Settle for as
            // long as we can, but take whatever arrived rather than nothing.
            let frameDeadline = Date().addingTimeInterval(4.0)
            while frameGrabber.frameCount < 8 && Date() < frameDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            let image = frameGrabber.latestImage
            let frames = frameGrabber.frameCount
            session.stopRunning()

            guard let image else {
                logger.error("No frame arrived from the camera within the timeout (frames=\(frames, privacy: .public))")
                return
            }
            logger.info("Grabbed frame after \(frames, privacy: .public) frame(s)")
            save(image)
        }
    }

    // MARK: - Private

    /// The built-in camera, explicitly — never `AVCaptureDevice.default(for:)`.
    ///
    /// That default follows the *system preferred camera*, which on a Mac paired
    /// with an iPhone is Continuity Camera. Continuity only delivers frames when
    /// the phone is awake, unlocked and nearby, so at lock time the session
    /// starts and then produces zero frames forever. The soldered-in FaceTime
    /// camera is always there, which is the whole point here.
    private static func preferredCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices

        // A Continuity Camera reports as .builtInWideAngleCamera too, so filter
        // it out by transport type rather than trusting the device type alone.
        if let builtIn = devices.first(where: { $0.deviceType == .builtInWideAngleCamera && !$0.isContinuityCamera }) {
            return builtIn
        }
        // Then any real external webcam, before falling back to whatever's left.
        return devices.first(where: { !$0.isContinuityCamera }) ?? AVCaptureDevice.default(for: .video)
    }

    private static func configureIfNeeded() -> Bool {
        if isConfigured { return true }

        guard let device = preferredCamera() else {
            logger.notice("No camera available — skipping snapshot")
            return false
        }
        logger.info("Using camera: \(device.localizedName, privacy: .public)")

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
                session.commitConfiguration()
                logger.error("Could not wire up camera session")
                return false
            }
            session.addInput(input)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(frameGrabber, queue: sampleQueue)
            session.addOutput(videoOutput)
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

        let fileStamp = DateFormatter()
        fileStamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let imageURL = downloads.appendingPathComponent("Bilakh Intruder \(fileStamp.string(from: Date())).jpg")

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            logger.error("Could not encode snapshot")
            return
        }

        do {
            try data.write(to: imageURL)
            logger.notice("Saved snapshot to \(imageURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Could not save snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the most recent frame off the video stream so the capture can pick
    /// one up once auto-exposure has settled.
    private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let lock = NSLock()
        private var _latestImage: CGImage?
        private var _frameCount = 0

        var latestImage: CGImage? {
            lock.lock(); defer { lock.unlock() }
            return _latestImage
        }

        var frameCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _frameCount
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            _latestImage = nil
            _frameCount = 0
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            lock.lock()
            _latestImage = cgImage
            _frameCount += 1
            lock.unlock()
        }
    }
}
