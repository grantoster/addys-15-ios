import AVFoundation
import SwiftUI
import UIKit

/// The back camera, shown live inside the app so Addy never leaves her screen.
final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum State { case starting, running, denied, unavailable }
    @Published var state: State = .starting

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "addys15.camera")
    private var device: AVCaptureDevice?
    private var configured = false
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<UIImage?, Never>?

    weak var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet { setUpRotation() }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { self.configureAndRun() } else { self.set(.denied) }
            }
        default: set(.denied)
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func set(_ s: State) { DispatchQueue.main.async { self.state = s } }

    private func configureAndRun() {
        queue.async {
            if !self.configured {
                guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: dev) else { self.set(.unavailable); return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if self.session.canAddInput(input) { self.session.addInput(input) }
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                self.session.commitConfiguration()
                self.configured = true
                DispatchQueue.main.async { self.device = dev; self.setUpRotation() }
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.set(.running)
        }
    }

    private func setUpRotation() {
        guard coordinator == nil, let dev = device, let layer = previewLayer else { return }
        let c = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: layer)
        coordinator = c
        layer.connection?.videoRotationAngle = c.videoRotationAngleForHorizonLevelPreview
        observation = c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak layer] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { layer?.connection?.videoRotationAngle = angle }
        }
    }

    /// Takes one photo. Returns nil if the camera isn't running or is already busy.
    func capture() async -> UIImage? {
        guard state == .running, continuation == nil else { return nil }
        let angle = coordinator?.videoRotationAngleForHorizonLevelCapture
        return await withCheckedContinuation { cont in
            continuation = cont
            queue.async {
                if let a = angle, let conn = self.output.connection(with: .video), conn.isVideoRotationAngleSupported(a) {
                    conn.videoRotationAngle = a
                }
                self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.continuation?.resume(returning: img)
            self.continuation = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraModel

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = camera.session
        v.previewLayer.videoGravity = .resizeAspectFill
        camera.previewLayer = v.previewLayer
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
