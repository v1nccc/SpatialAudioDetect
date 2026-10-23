@preconcurrency import AVFoundation
import CoreML
import SwiftUI
import UIKit
@preconcurrency import Vision

/// One processed camera frame, handed from the camera queue to the screen.
nonisolated struct CameraFrame: Sendable {
    var tracks: [VehicleTrack]
    var detectMs: Double
    var depth: String  // "LiDAR 320×240", "no depth this frame"
    var recorded: Double?  // seconds recorded so far, while recording
    var depthModel: String  // Depth Anything V2 status: "fit 812 LiDAR pts · R² 0.94 · 27 ms", "off", …
    var road: String        // "1.12 m below the camera, looking 8° down (534 LiDAR pts)", "no road in LiDAR range"
}

/// Which vision model finds the vehicles (switchable in the camera test to compare).
nonisolated enum CameraDetector: String, CaseIterable, Sendable {
    case yolo26Large = "YOLO26s · 960", yolo26Small = "YOLO26s · 640", yolov3 = "YOLOv3 (old)"
    var resource: String { [.yolo26Large: "YOLO26s_960x736", .yolo26Small: "YOLO26s_640", .yolov3: "YOLOv3Int8LUT"][self]! }
}

/// Calls `body` with a reader for a one-channel half-float map (the depth model's output): value at pixel (x, y).
nonisolated func withHalfFloatMap<T>(_ map: CVPixelBuffer, _ body: ((Int, Int) -> Double) -> T) -> T? {
    guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent16Half else { return nil }
    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
    let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
    return body { x, y in Double((base + min(max(y, 0), h - 1) * row).assumingMemoryBound(to: Float16.self)[min(max(x, 0), w - 1)]) }
}

/// Median LiDAR distance (m) in the middle of a box (sensor-normalized rect), so the road around it doesn't count.
nonisolated func medianDepth(in rect: CGRect, of map: CVPixelBuffer) -> Double? {
    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
    let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
    let inner = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
    let x0 = max(Int(inner.minX * CGFloat(w)), 0), x1 = min(Int(inner.maxX * CGFloat(w)), w - 1)
    let y0 = max(Int(inner.minY * CGFloat(h)), 0), y1 = min(Int(inner.maxY * CGFloat(h)), h - 1)
    guard x0 <= x1, y0 <= y1 else { return nil }
    let sx = max((x1 - x0) / 20, 1), sy = max((y1 - y0) / 20, 1)  // ≤ ~400 samples
    var values: [Float] = []
    for y in stride(from: y0, through: y1, by: sy) {
        let line = (base + y * row).assumingMemoryBound(to: Float32.self)
        for x in stride(from: x0, through: x1, by: sx) where line[x].isFinite && line[x] > 0 { values.append(line[x]) }
    }
    guard values.count >= 3 else { return nil }
    values.sort()
    return Double(values[values.count / 2])
}

/// Camera queue: video (+ LiDAR depth, synchronized) in, tracked vehicles out.
nonisolated final class CameraWorker: NSObject, AVCaptureDataOutputSynchronizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    let videoOutput = AVCaptureVideoDataOutput()
    let depthOutput = AVCaptureDepthDataOutput()
    var onFrame: (@Sendable (CameraFrame) -> Void)?
    var camera = CameraIntrinsics()   // from the lens until LiDAR calibration data arrives
    var method = DistanceMethod.calculation  // camera queue, like everything below
    private(set) var detector = CameraDetector.yolo26Large
    private var requests: [CameraDetector: VNCoreMLRequest] = [:]
    private let depthRequest: VNCoreMLRequest?
    private var road: (plane: GroundPlane, at: Double)?
    private var frameCount = 0
    private var depthMap: CVPixelBuffer?   // the depth model's latest output (every 3rd frame)
    private var depthFit: DepthFit?
    private var depthMs = 0.0
    private var tracker = VehicleTracker()
    private var recordTo: URL?             // camera queue only, like recorder
    private var recorder: CameraRecorder?

    /// Record from the next frame into `folder`. Camera queue.
    func startRecording(_ folder: URL) { recordTo = folder }

    /// Camera queue. `done` gets the files once the video is written.
    func stopRecording(_ done: @escaping @Sendable ([URL]) -> Void) {
        recordTo = nil
        guard let r = recorder else { return done([]) }
        recorder = nil
        r.finish { done(r.files) }
    }

    func mark(_ note: String) { recorder?.mark(note) }

    init(depthModel: MLModel?) {
        depthRequest = depthModel.flatMap { try? VNCoreMLRequest(model: VNCoreMLModel(for: $0)) }
        depthRequest?.imageCropAndScaleOption = .scaleFill  // with the region below: an undistorted middle band
    }

    /// Switch vision model (loaded the first time it's picked). False if it's missing from the app. Camera queue.
    @discardableResult
    func use(_ d: CameraDetector) -> Bool {
        if requests[d] == nil, let url = Bundle.main.url(forResource: d.resource, withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: url), let vn = try? VNCoreMLModel(for: model) {
            // Ask the model for weak boxes too: they may keep a vehicle that's already tracked, never start one.
            vn.featureProvider = try? MLDictionaryFeatureProvider(dictionary: ["confidenceThreshold": VehicleTracker.keepConfidence, "iouThreshold": 0.5])
            let request = VNCoreMLRequest(model: vn)
            request.imageCropAndScaleOption = .scaleFill  // the whole frame (the 960×736 model has the picture's own shape)
            requests[d] = request
        }
        detector = d
        return requests[d] != nil
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let video = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !video.sampleBufferWasDropped, let pixels = CMSampleBufferGetImageBuffer(video.sampleBuffer) else { return }
        let depth = (collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData)
            .flatMap { $0.depthDataWasDropped ? nil : $0.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32) }
        process(video.sampleBuffer, pixels, at: video.timestamp.seconds, depth: depth)
    }

    /// Without LiDAR: plain video frames.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        process(sampleBuffer, pixels, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, depth: nil)
    }

    private func process(_ sample: CMSampleBuffer, _ pixels: CVPixelBuffer, at t: Double, depth: AVDepthData?) {
        if let cal = depth?.cameraCalibrationData {
            let m = cal.intrinsicMatrix, ref = cal.intrinsicMatrixReferenceDimensions
            camera = CameraIntrinsics(fx: Double(m.columns.0.x) / Double(ref.width), fy: Double(m.columns.1.y) / Double(ref.height),
                                      cx: Double(m.columns.2.x) / Double(ref.width), cy: Double(m.columns.2.y) / Double(ref.height))
        }
        // The road from LiDAR, every other frame; kept half a second if it can't be seen for a moment.
        if frameCount % 2 == 0, let map = depth?.depthDataMap, let plane = fitGroundPlane(roadPoints(map)) { road = (plane, t) }
        if let r = road, t - r.at > 0.5 { road = nil }
        // Depth Anything V2 on every 3rd frame (~10 per second), calibrated against this frame's LiDAR.
        let crop = DepthCrop(uprightAspect: Double(CVPixelBufferGetHeight(pixels)) / Double(CVPixelBufferGetWidth(pixels)),
                             modelAspect: 518.0 / 392)
        frameCount += 1
        let useDepthModel = method == .calculationDepth
        if useDepthModel, let depthRequest, frameCount % 3 == 0 {
            let started = CACurrentMediaTime()
            depthRequest.regionOfInterest = crop.region
            try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right).perform([depthRequest])
            depthMs = (CACurrentMediaTime() - started) * 1000
            depthMap = (depthRequest.results?.first as? VNPixelBufferObservation)?.pixelBuffer
            depthFit = nil
            if let map = depthMap, let lidar = depth?.depthDataMap {
                depthFit = calibrate(map, lidar: lidar, crop: crop)
            }
        }
        if !useDepthModel { depthMap = nil; depthFit = nil }
        let start = CACurrentMediaTime()
        var found: [VehicleDetection] = []
        if let request = requests[detector] {
            // Upright phone, back camera: the model sees the picture the right way up.
            try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right).perform([request])
            for o in (request.results as? [VNRecognizedObjectObservation]) ?? [] {
                // The box's own score: the label's confidence is only "which class", ~1.0 for every box.
                guard let top = o.labels.first, Double(o.confidence) >= VehicleTracker.keepConfidence else { continue }
                let rect = sensorRect(fromVision: o.boundingBox)
                found.append(VehicleDetection(label: top.identifier, confidence: Double(o.confidence), rect: rect,
                                              lidar: depth.flatMap { medianDepth(in: rect, of: $0.depthDataMap) },
                                              modelDepth: modelDistance(of: rect, crop: crop)))
            }
        }
        let ms = (CACurrentMediaTime() - start) * 1000
        let tracks = tracker.update(found, at: t, camera: camera, road: road?.plane, method: method)
        if let folder = recordTo, recorder == nil {
            recorder = try? CameraRecorder(folder: folder, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            if recorder == nil { recordTo = nil }
        }
        if let recorder {
            drawOverlay(tracks, on: pixels)  // after the model has seen the frame
            recorder.add(sample, tracks: tracks, modelMs: ms, depth: depth != nil, fit: depthFit, detector: detector.rawValue,
                         method: method.rawValue, road: road?.plane)
        }
        let map = depth?.depthDataMap
        onFrame?(CameraFrame(tracks: tracks, detectMs: ms,
                             depth: map.map { "LiDAR \(CVPixelBufferGetWidth($0))×\(CVPixelBufferGetHeight($0))" } ?? "no depth this frame",
                             recorded: recorder?.seconds, depthModel: depthStatus,
                             road: road.map { String(format: "%.2f m below the camera, looking %.0f° down (%d LiDAR pts)", $0.plane.height, $0.plane.tilt, $0.plane.points) }
                                 ?? "no road in LiDAR range (needs ground 0.5–5 m behind you)"))
    }

    /// LiDAR points (camera coordinates, m) in the lower part of the upright picture, where the road behind you is.
    private func roadPoints(_ map: CVPixelBuffer) -> [SIMD3<Double>] {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return [] }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
        var out: [SIMD3<Double>] = []
        for py in stride(from: 0, to: h, by: 4) {
            let line = (base + py * row).assumingMemoryBound(to: Float32.self)
            for px in stride(from: Int(Double(w) * 0.55), to: w, by: 4) {  // upright: the lower 45% of the picture
                let z = Double(line[px])
                guard z.isFinite, z >= 0.5, z <= 5 else { continue }
                let u = (Double(px) + 0.5) / Double(w), v = (Double(py) + 0.5) / Double(h)
                out.append(SIMD3((u - camera.cx) / camera.fx * z, (v - camera.cy) / camera.fy * z, z))
            }
        }
        return out
    }

    private var depthStatus: String {
        guard depthRequest != nil else { return "model missing from the app" }
        guard method == .calculationDepth else { return "off (pick \"\(DistanceMethod.calculationDepth.rawValue)\")" }
        guard depthMap != nil else { return "starting…" }
        guard let f = depthFit else { return String(format: "not calibrated: too few LiDAR points 0.4–5 m · %.0f ms", depthMs) }
        return String(format: "fit on %d LiDAR points · R² %.2f · %.0f ms", f.points, f.r2, depthMs)
    }

    /// This frame's metres-from-model-value conversion, from LiDAR pixels 0.4–5 m away.
    private func calibrate(_ map: CVPixelBuffer, lidar: CVPixelBuffer, crop: DepthCrop) -> DepthFit? {
        CVPixelBufferLockBaseAddress(lidar, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(lidar, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(lidar) else { return nil }
        let lw = CVPixelBufferGetWidth(lidar), lh = CVPixelBufferGetHeight(lidar), row = CVPixelBufferGetBytesPerRow(lidar)
        let mw = CVPixelBufferGetWidth(map), mh = CVPixelBufferGetHeight(map)
        let pairs = withHalfFloatMap(map) { value -> [(value: Double, metres: Double)] in
            var out: [(value: Double, metres: Double)] = []
            for y in stride(from: 0, to: lh, by: 4) {
                let line = (base + y * row).assumingMemoryBound(to: Float32.self)
                for x in stride(from: 0, to: lw, by: 4) {
                    let z = Double(line[x])
                    guard z.isFinite, z >= 0.4, z <= 5,
                          let p = crop.modelPoint(sensorX: (Double(x) + 0.5) / Double(lw), sensorY: (Double(y) + 0.5) / Double(lh)) else { continue }
                    out.append((value(Int(p.x * Double(mw)), Int(p.y * Double(mh))), z))
                }
            }
            return out
        } ?? []
        return fitDepth(pairs)
    }

    /// The model's distance for a vehicle: median value in the middle of its box, converted with this frame's fit.
    private func modelDistance(of rect: CGRect, crop: DepthCrop) -> Double? {
        guard let map = depthMap, let fit = depthFit,
              let a = crop.modelPoint(sensorX: Double(rect.midX - rect.width * 0.2), sensorY: Double(rect.midY + rect.height * 0.2)),
              let b = crop.modelPoint(sensorX: Double(rect.midX + rect.width * 0.2), sensorY: Double(rect.midY - rect.height * 0.2)) else { return nil }
        let mw = Double(CVPixelBufferGetWidth(map)), mh = Double(CVPixelBufferGetHeight(map))
        let values = withHalfFloatMap(map) { value -> [Double] in
            var out: [Double] = []
            for y in stride(from: Int(a.y * mh), through: Int(b.y * mh), by: 1) {
                for x in stride(from: Int(a.x * mw), through: Int(b.x * mw), by: 1) { out.append(value(x, y)) }
            }
            return out
        } ?? []
        guard !values.isEmpty else { return nil }
        return fit.metres(values.sorted()[values.count / 2])
    }
}

/// The camera test: back camera + LiDAR + vehicle model, live. Foreground only: iOS stops the camera in the background.
@Observable final class CameraRadar {
    private(set) var tracks: [VehicleTrack] = []
    private(set) var problem: String?
    private(set) var running = false
    private(set) var fps = 0
    private(set) var detectMs = 0.0
    private(set) var depth = "–"
    private(set) var camera = ""
    private(set) var depthModel = "–"
    private(set) var road = "–"
    /// Which vision model finds the vehicles.
    var detector = CameraDetector.yolo26Large {
        didSet {
            guard let worker else { return }
            let d = detector
            queue.async { worker.use(d) }
        }
    }
    /// How distance is worked out (all are recorded; this one is shown and used). Depth Anything only runs in its mode.
    var method = DistanceMethod.calculation {
        didSet {
            guard let worker else { return }
            let m = method
            queue.async { worker.method = m }
        }
    }
    private(set) var recording = false
    private(set) var recorded: Double?       // seconds into the current recording
    private(set) var recordedFiles: [URL] = []  // the last finished recording
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "camera")
    @ObservationIgnored private var worker: CameraWorker?
    @ObservationIgnored private var synchronizer: AVCaptureDataOutputSynchronizer?
    @ObservationIgnored private var framesThisSecond = 0
    @ObservationIgnored private var secondStart = Date.now

    func start() async {
        guard !running else { return }
        if worker == nil { guard await configure() else { return } }
        let session = session
        queue.async { session.startRunning() }
        running = true
    }

    func stop() {
        if recording { stopRecording() }
        let session = session
        queue.async { session.stopRunning() }
        running = false
        tracks = []
    }

    func startRecording() {
        guard let worker, running else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let folder = URL.documentsDirectory.appending(path: "Camera recordings/\(stamp.string(from: .now))")
        queue.async { worker.startRecording(folder) }
        recording = true
        recordedFiles = []
    }

    func stopRecording() {
        guard let worker else { return }
        recording = false
        recorded = nil
        let done: @Sendable ([URL]) -> Void = { [weak self] files in
            guard let self else { return }
            Task { @MainActor in self.recordedFiles = files }
        }
        queue.async { worker.stopRecording(done) }
    }

    /// The tester's note at this moment of the recording ("vehicle passed now", "missed", "false warning").
    func mark(_ note: String) {
        guard let worker else { return }
        queue.async { worker.mark(note) }
    }

    private func configure() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            problem = "Camera access denied: Settings › Sound Radar › Camera"
            return false
        }
        let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
        guard let device = lidar ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            problem = "No back camera on this device"
            return false
        }
        let depthModel = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc").flatMap { try? MLModel(contentsOf: $0) }
        let worker = CameraWorker(depthModel: depthModel)
        if !worker.use(detector) { problem = "The \(detector.rawValue) model is missing from the app" }
        worker.method = method

        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false  // leave the radar's microphone alone
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            problem = "The camera couldn't be opened"
            return false
        }
        session.addInput(input)
        // Largest format up to 1920 wide that runs at 30 fps and, with LiDAR, also delivers depth.
        let format = device.formats.filter { f in
            f.formatDescription.dimensions.width <= 1920 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
                && (lidar == nil || !f.supportedDepthDataFormats.isEmpty)
        }.max { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width }
        let depthFormat = format?.supportedDepthDataFormats.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        } ?? format?.supportedDepthDataFormats.first
        if (try? device.lockForConfiguration()) != nil {
            if let format { device.activeFormat = format }
            if lidar != nil, let depthFormat { device.activeDepthDataFormat = depthFormat }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }
        worker.videoOutput.alwaysDiscardsLateVideoFrames = true
        worker.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.addOutput(worker.videoOutput)
        let withDepth = lidar != nil && depthFormat != nil && session.canAddOutput(worker.depthOutput)
        if withDepth {
            worker.depthOutput.isFilteringEnabled = true  // fills small holes in the depth map
            worker.depthOutput.alwaysDiscardsLateDepthData = true
            session.addOutput(worker.depthOutput)
        }
        session.commitConfiguration()

        // Focal length from the lens's field of view until LiDAR calibration data says better.
        let dims = device.activeFormat.formatDescription.dimensions
        let fx = 0.5 / tan(Double(device.activeFormat.videoFieldOfView) * .pi / 360)
        worker.camera = CameraIntrinsics(fx: fx, fy: fx * Double(dims.width) / Double(dims.height))
        worker.onFrame = { [weak self] frame in
            guard let self else { return }
            Task { @MainActor in self.show(frame) }
        }
        if withDepth {
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [worker.videoOutput, worker.depthOutput])
            sync.setDelegate(worker, queue: queue)
            synchronizer = sync
        } else {
            worker.videoOutput.setSampleBufferDelegate(worker, queue: queue)
        }
        camera = "\(withDepth ? "LiDAR depth camera" : "Wide camera, no LiDAR") · \(dims.width)×\(dims.height)"
        self.worker = worker
        return true
    }

    private func show(_ frame: CameraFrame) {
        tracks = frame.tracks.filter(\.confirmed)  // one-off boxes aren't shown (they're in the recording, greyed)
        detectMs = frame.detectMs
        depthModel = frame.depthModel
        road = frame.road
        if recording { recorded = frame.recorded }
        depth = frame.depth
        framesThisSecond += 1
        if Date.now.timeIntervalSince(secondStart) >= 1 {
            fps = framesThisSecond
            framesThisSecond = 0
            secondStart = .now
        }
    }
}

// MARK: - Screen

/// "Car #3 · 12 m · reaches you in 1.8 s"
private func trackLine(_ t: VehicleTrack) -> String {
    var parts = ["\(pretty(t.label)) #\(t.id)"]
    if let d = t.distance { parts.append(String(format: "%.1f m (%@)", d, t.distanceFrom)) }
    parts.append(t.timeToReach.map { String(format: "reaches you in %.1f s", $0) } ?? "not coming closer")
    return parts.joined(separator: " · ")
}

private func metres(_ m: Double?) -> String { m.map { String(format: "%.1f m", $0) } ?? "–" }

private func sideText(_ lateral: Double?) -> String {
    guard let l = lateral else { return "–" }
    return abs(l) < 0.3 ? "on your path" : String(format: "%.1f m to your %@", abs(l), l > 0 ? "left" : "right")
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let boxes = CALayer()

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        preview.session = session
        preview.videoGravity = .resizeAspect
        layer.addSublayer(boxes)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { nil }

    func show(_ tracks: [VehicleTrack]) {
        if let c = preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }  // upright
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boxes.frame = bounds
        boxes.sublayers = nil
        for t in tracks {
            let r = preview.layerRectConverted(fromMetadataOutputRect: t.rect)
            let color = (t.warn ? UIColor.systemRed : .systemYellow).cgColor
            let box = CAShapeLayer()
            box.path = UIBezierPath(roundedRect: r, cornerRadius: 4).cgPath
            box.strokeColor = color
            box.fillColor = UIColor.clear.cgColor
            box.lineWidth = t.warn ? 4 : 2
            boxes.addSublayer(box)
            let text = CATextLayer()
            text.string = "\(pretty(t.label)) " + (t.distance.map { String(format: "%.0f m", $0) } ?? "")
                + (t.timeToReach.map { String(format: " · %.1f s", $0) } ?? "")
            text.fontSize = 13
            text.foregroundColor = UIColor.black.cgColor
            text.backgroundColor = color
            text.contentsScale = traitCollection.displayScale
            text.frame = CGRect(x: r.minX, y: max(r.minY - 18, 0), width: 170, height: 18)
            boxes.addSublayer(text)
        }
        CATransaction.commit()
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let tracks: [VehicleTrack]
    func makeUIView(context: Context) -> CameraPreviewView { CameraPreviewView(session: session) }
    func updateUIView(_ view: CameraPreviewView, context: Context) { view.show(tracks) }
}

struct CameraView: View {
    let radar: SoundRadar
    @State private var camera = CameraRadar()
    @State private var lastBuzz = Date.distantPast

    private var warning: VehicleTrack? { camera.tracks.filter(\.warn).min { ($0.timeToReach ?? 99) < ($1.timeToReach ?? 99) } }

    var body: some View {
        List {
            Section {
                CameraPreview(session: camera.session, tracks: camera.tracks)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Hold or strap the phone upright with the back camera facing behind you. Yellow = vehicle, red = warning.")
            }
            if let p = camera.problem {
                Section { Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if let w = warning {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("⚠️ \(pretty(w.label)) behind you").font(.title2.bold()).foregroundStyle(.red)
                        Text("Reaches you in \(String(format: "%.1f", w.timeToReach ?? 0)) s · \(sideText(w.lateral))").font(.title3)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { camera.recording }, set: { $0 ? camera.startRecording() : camera.stopRecording() })) {
                    if camera.recording {
                        Label("Recording · \(Int(camera.recorded ?? 0)) s", systemImage: "record.circle.fill").foregroundStyle(.red)
                    } else {
                        Label("Record session", systemImage: "record.circle")
                    }
                }
                .disabled(!camera.running)
                if camera.recording {
                    HStack {
                        ForEach([("Vehicle passed now", "car.side"), ("Missed one", "eye.slash"), ("False warning", "xmark.octagon")], id: \.0) { note, icon in
                            Button { camera.mark(note) } label: {
                                Label(note, systemImage: icon).font(.caption).frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else if !camera.recordedFiles.isEmpty {
                    ShareLink(items: camera.recordedFiles) {
                        Label("Share last recording (video + tracks.csv + events.txt)", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Saves the video with the boxes and numbers drawn in (≈ 60 MB per minute), tracks.csv (every vehicle in every frame: each distance method's number, reaches-you-in, speed, side, warning, timed to the video) and events.txt with your marks. Tap a mark the moment it happens; it's saved at that video time. Also in Files › On My iPhone › SpatialAudioDetect › Camera recordings.")
            }
            Section("Vehicles (\(camera.tracks.count))") {
                if camera.tracks.isEmpty {
                    Text(camera.running ? "None in view" : camera.problem == nil ? "Starting…" : "Camera not running").foregroundStyle(.secondary)
                }
                ForEach(camera.tracks) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trackLine(t)).font(.subheadline.bold()).foregroundStyle(t.warn ? .red : .primary)
                        Text("Closing \(t.closingSpeed.map { String(format: "%.1f m/s (%.0f km/h)", $0, $0 * 3.6) } ?? "–") · \(sideText(t.lateral)) · \(Int(t.confidence * 100))% sure")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Each way: LiDAR \(metres(t.lidarDistance)) · size \(metres(t.sizeDistance))\(t.learnedHeight.map { String(format: " (its height %.2f m)", $0) } ?? "") · road \(metres(t.groundDistance)) · Depth Anything \(metres(t.modelDistance)) · width \(metres(t.widthDistance))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Picker("Detector", selection: $camera.detector) {
                    ForEach(CameraDetector.allCases, id: \.self) { Text($0.rawValue) }
                }
                Picker("Distance", selection: $camera.method) {
                    ForEach(DistanceMethod.allCases, id: \.self) { Text($0.rawValue) }
                }
            } header: {
                Text("Compare")
            } footer: {
                Text("""
                    Detector: YOLO26s at 960×736 sees farther vehicles; at 640 it's faster; YOLOv3 is the old model, for comparison. \
                    Distance — Calculation: LiDAR within 5 m; beyond, the vehicle's height in the picture (its real height learned by \
                    LiDAR if it came within 5 m, else typical: car 1.5 m, motorbike with rider 1.45 m) combined with where its wheels \
                    meet the road (road fitted from LiDAR, used up to 15 m), smoothed over time. + Depth Anything: also the AI depth \
                    model, calibrated by LiDAR each frame (costs frame rate). OpenCV method: the paper's formula, real width × focal \
                    length ÷ width in pixels (car 1.8 m, motorbike 0.8 m). Every method's number is recorded each frame either way.
                    """)
            }
            Section {
                LabeledContent("Camera", value: camera.camera.isEmpty ? "–" : camera.camera)
                LabeledContent("Depth", value: camera.depth)
                LabeledContent("Road", value: camera.road)
                LabeledContent("Depth Anything", value: camera.depthModel)
                LabeledContent("Frames", value: "\(camera.fps)/s · model \(Int(camera.detectMs.rounded())) ms")
                LabeledContent("Microphone (radar)", value: radar.micStatus)
            } header: {
                Text("Status")
            } footer: {
                Text("""
                    Fewer false alarms: a vehicle must be found with ≥ \(Int(VehicleTracker.startConfidence * 100))% confidence to start \
                    being followed and seen \(VehicleTracker.confirmHits) times before it shows or warns; weaker boxes only keep it followed. \
                    People never raise a vehicle warning, a motorbike's rider merges into the motorbike, and anything LiDAR sees closer than \
                    \(Int(VehicleTracker.lensBlocked * 100)) cm (a hand or strap on the lens) is ignored. \
                    "Reaches you in": how fast its picture grows, which needs no distance at all. Side: where it is in the picture × \
                    distance. Warning (red + vibration): reaches you within \(Int(VehicleTracker.warnSeconds)) s and passes within \
                    \(Int(VehicleTracker.warnSide)) m of your path, or LiDAR sees it within 3 m and closing. Road: the ground behind you as \
                    LiDAR sees it, which gives the camera's real height and tilt every frame. "Microphone": whether the sound radar keeps \
                    listening while the camera runs. To judge distances, park a car or bike at measured distances (5, 10, 20, 30 m) and \
                    compare the methods in tracks.csv.
                    """)
            }
        }
        .navigationTitle("Camera test")
        .navigationBarTitleDisplayMode(.inline)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: warning?.id) {
            guard warning != nil, Date.now.timeIntervalSince(lastBuzz) > 2 else { return }
            lastBuzz = .now
            let s = HapticSettings.load()
            Task { _ = await radar.haptics.play(s.critical, title: "Watch out", body: "Vehicle behind you", via: s.method) }
        }
    }
}
