@preconcurrency import AVFoundation
import CoreML
import CoreMotion
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
    var road: String        // "1.1 m below the camera, looking 8° down (534 LiDAR pts)", "no road in LiDAR range"
    var rotation: PictureRotation
}

extension PictureRotation {
    /// How Vision is told to turn the camera image upright.
    nonisolated var vision: CGImagePropertyOrientation {
        [.landscapeTopLeft: .up, .portrait: .right, .landscapeTopRight: .down, .upsideDown: .left][self]!
    }
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
    var lens = CameraIntrinsics()     // in the sensor's own image; from the lens until LiDAR calibration data arrives
    var method = DistanceMethod.calculation  // camera queue, like everything below
    var settings = CameraSettings()          // camera queue: which objects to detect, warn on, and thresholds
    private var rotation = PictureRotation.portrait  // how the phone is held, from gravity
    private let motion = CMMotionManager()
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
        super.init()
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates()  // read each frame; gravity says portrait or landscape, even with rotation lock on
    }

    deinit { motion.stopDeviceMotionUpdates() }

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
            lens = CameraIntrinsics(fx: Double(m.columns.0.x) / Double(ref.width), fy: Double(m.columns.1.y) / Double(ref.height),
                                    cx: Double(m.columns.2.x) / Double(ref.width), cy: Double(m.columns.2.y) / Double(ref.height))
        }
        // Everything below works in the upright picture, portrait or landscape.
        if let g = motion.deviceMotion?.gravity {
            let r = PictureRotation.from(gravityX: g.x, y: g.y, current: rotation)
            if r != rotation { (rotation, road) = (r, nil); tracker = VehicleTracker() }  // old boxes and road don't line up any more
        }
        let camera = rotation.upright(lens)
        // The road from LiDAR, every other frame; kept half a second if it can't be seen for a moment.
        if frameCount % 2 == 0, let map = depth?.depthDataMap, let plane = fitGroundPlane(roadPoints(map, camera: camera)) { road = (plane, t) }
        if let r = road, t - r.at > 0.5 { road = nil }
        // Depth Anything V2 on every 3rd frame (~10 per second), calibrated against this frame's LiDAR.
        let pw = Double(CVPixelBufferGetWidth(pixels)), ph = Double(CVPixelBufferGetHeight(pixels))
        let crop = DepthCrop(uprightAspect: rotation.rawValue % 180 == 0 ? pw / ph : ph / pw, modelAspect: 518.0 / 392)
        frameCount += 1
        let useDepthModel = method.usesDepthModel
        if useDepthModel, let depthRequest, frameCount % 3 == 0 {
            let started = CACurrentMediaTime()
            depthRequest.regionOfInterest = crop.region
            try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: rotation.vision).perform([depthRequest])
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
            // The model sees the picture the right way up, however the phone is held.
            try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: rotation.vision).perform([request])
            for o in (request.results as? [VNRecognizedObjectObservation]) ?? [] {
                // The box's own score: the label's confidence is only "which class", ~1.0 for every box.
                guard let top = o.labels.first, Double(o.confidence) >= VehicleTracker.keepConfidence else { continue }
                let rect = uprightRect(fromVision: o.boundingBox)
                found.append(VehicleDetection(label: top.identifier, confidence: Double(o.confidence), rect: rect,
                                              lidar: depth.flatMap { medianDepth(in: rotation.sensor(rect), of: $0.depthDataMap) },
                                              modelDepth: modelDistance(of: rect, crop: crop)))
            }
        }
        let ms = (CACurrentMediaTime() - start) * 1000
        let tracks = tracker.update(found, at: t, camera: camera, road: road?.plane, method: method, settings: settings)
        if let folder = recordTo, recorder == nil {
            recorder = try? CameraRecorder(folder: folder, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                                           rotation: rotation)
            if recorder == nil { recordTo = nil }
        }
        if let recorder {
            drawOverlay(tracks, on: pixels, rotation: rotation)  // after the model has seen the frame
            recorder.add(sample, tracks: tracks, modelMs: ms, depth: depth != nil, fit: depthFit, detector: detector.rawValue,
                         method: method.rawValue, road: road?.plane, phone: rotation.name)
        }
        let map = depth?.depthDataMap
        onFrame?(CameraFrame(tracks: tracks, detectMs: ms,
                             depth: map.map { "LiDAR \(CVPixelBufferGetWidth($0))×\(CVPixelBufferGetHeight($0))" } ?? "no depth this frame",
                             recorded: recorder?.seconds, depthModel: depthStatus,
                             road: road.map { String(format: "%@ below the camera, looking %.0f° down (%d LiDAR pts)", distanceText($0.plane.height), $0.plane.tilt, $0.plane.points) }
                                 ?? "no road in LiDAR range (needs ground 0.5–5 m behind you)",
                             rotation: rotation))
    }

    /// LiDAR points (upright camera axes: x right, y down, z out of the lens; m) in the lower part of the upright
    /// picture, where the road behind you is.
    private func roadPoints(_ map: CVPixelBuffer, camera: CameraIntrinsics) -> [SIMD3<Double>] {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return [] }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
        var out: [SIMD3<Double>] = []
        for py in stride(from: 0, to: h, by: 4) {
            let line = (base + py * row).assumingMemoryBound(to: Float32.self)
            for px in stride(from: 0, to: w, by: 4) {
                let p = rotation.upright(x: (Double(px) + 0.5) / Double(w), y: (Double(py) + 0.5) / Double(h)), z = Double(line[px])
                guard p.y >= 0.55, z.isFinite, z >= 0.5, z <= 5 else { continue }  // the lower 45% of the picture
                out.append(SIMD3((p.x - camera.cx) / camera.fx * z, (p.y - camera.cy) / camera.fy * z, z))
            }
        }
        return out
    }

    private var depthStatus: String {
        guard depthRequest != nil else { return "model missing from the app" }
        guard method.usesDepthModel else { return "off (pick a Depth Anything distance method)" }
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
                    let u = rotation.upright(x: (Double(x) + 0.5) / Double(lw), y: (Double(y) + 0.5) / Double(lh))
                    guard z.isFinite, z >= 0.4, z <= 5, let p = crop.modelPoint(x: u.x, y: u.y) else { continue }
                    out.append((value(Int(p.x * Double(mw)), Int(p.y * Double(mh))), z))
                }
            }
            return out
        } ?? []
        return fitDepth(pairs)
    }

    /// The model's distance for a vehicle (upright rect): median value in the middle of its box, converted with this frame's fit.
    private func modelDistance(of rect: CGRect, crop: DepthCrop) -> Double? {
        guard let map = depthMap, let fit = depthFit,
              let a = crop.modelPoint(x: rect.midX - rect.width * 0.2, y: rect.midY - rect.height * 0.2),
              let b = crop.modelPoint(x: rect.midX + rect.width * 0.2, y: rect.midY + rect.height * 0.2) else { return nil }
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
    private(set) var rotation = PictureRotation.portrait
    /// Which vision model finds the vehicles.
    var detector: CameraDetector = {
        if let raw = UserDefaults.standard.string(forKey: "cameraDetector"),
           let d = CameraDetector(rawValue: raw) { return d }
        return .yolo26Large
    }() {
        didSet {
            UserDefaults.standard.set(detector.rawValue, forKey: "cameraDetector")
            guard let worker else { return }
            let d = detector
            queue.async { worker.use(d) }
        }
    }
    /// How distance is worked out (all are recorded; this one is shown and used). Depth Anything only runs in its mode.
    var method: DistanceMethod = {
        if let raw = UserDefaults.standard.string(forKey: "cameraDistanceMethod"),
           let m = DistanceMethod(rawValue: raw) { return m }
        return .calculation
    }() {
        didSet {
            UserDefaults.standard.set(method.rawValue, forKey: "cameraDistanceMethod")
            guard let worker else { return }
            let m = method
            queue.async { worker.method = m }
        }
    }
    /// Configurable object selection, warning objects, and warning thresholds.
    var settings = CameraSettings.load() {
        didSet {
            settings.save()
            let s = settings
            tracks.removeAll { !s.enabledObjects.contains($0.label) }
            guard let worker else { return }
            queue.async { worker.settings = s }
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
        worker.settings = settings

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
        worker.lens = CameraIntrinsics(fx: fx, fy: fx * Double(dims.width) / Double(dims.height))
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
        rotation = frame.rotation
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
    if let d = t.distance { parts.append("\(distanceText(d)) (\(t.distanceFrom))") }
    parts.append(t.timeToReach.map { String(format: "reaches you in %.1f s", $0) } ?? "not coming closer")
    return parts.joined(separator: " · ")
}

private func metres(_ m: Double?) -> String { m.map(distanceText) ?? "–" }

private func sideText(_ lateral: Double?) -> String {
    guard let l = lateral else { return "–" }
    return abs(l) < 0.3 ? "on your path" : "\(distanceText(abs(l))) to your \(l > 0 ? "left" : "right")"
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

    func show(_ tracks: [VehicleTrack], rotation: PictureRotation) {
        if let c = preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }  // matches the portrait screen
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boxes.frame = bounds
        boxes.sublayers = nil
        for t in tracks {
            let r = preview.layerRectConverted(fromMetadataOutputRect: rotation.sensor(t.rect))
            let color = (t.warn ? UIColor.systemRed : .systemYellow).cgColor
            let box = CAShapeLayer()
            box.path = UIBezierPath(roundedRect: r, cornerRadius: 4).cgPath
            box.strokeColor = color
            box.fillColor = UIColor.clear.cgColor
            box.lineWidth = t.warn ? 4 : 2
            boxes.addSublayer(box)
            let text = CATextLayer()
            text.string = "\(pretty(t.label)) " + (t.distance.map(distanceText) ?? "")
                + (t.timeToReach.map { String(format: " · %.1f s", $0) } ?? "")
            text.fontSize = 13
            text.alignmentMode = .center
            text.foregroundColor = UIColor.black.cgColor
            text.backgroundColor = color
            text.contentsScale = traitCollection.displayScale
            // Readable the way the phone is held, just above the vehicle: held sideways, "up" is a side of the screen.
            let angle = CGFloat(90 - rotation.rawValue) * .pi / 180, up = CGPoint(x: sin(angle), y: -cos(angle))
            let reach = abs(up.x) * r.width / 2 + abs(up.y) * r.height / 2 + 9
            text.bounds = CGRect(x: 0, y: 0, width: 170, height: 18)
            text.position = CGPoint(x: r.midX + up.x * reach, y: r.midY + up.y * reach)
            text.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            boxes.addSublayer(text)
        }
        CATransaction.commit()
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let tracks: [VehicleTrack]
    let rotation: PictureRotation
    func makeUIView(context: Context) -> CameraPreviewView { CameraPreviewView(session: session) }
    func updateUIView(_ view: CameraPreviewView, context: Context) { view.show(tracks, rotation: rotation) }
}

enum CameraSubTab: String, CaseIterable, Identifiable {
    case live = "Live"
    case detections = "Detections"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .live: "camera.viewfinder"
        case .detections: "list.bullet.rectangle"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct CameraView: View {
    let radar: SoundRadar
    @State private var camera = CameraRadar()
    @State private var subTab: CameraSubTab = .live
    @State private var lastBuzz = Date.distantPast

    private var warning: VehicleTrack? { camera.tracks.filter(\.warn).min { ($0.timeToReach ?? 99) < ($1.timeToReach ?? 99) } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Camera View", selection: $subTab) {
                ForEach(CameraSubTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))

            switch subTab {
            case .live:
                liveTab
            case .detections:
                detectionsTab
            case .settings:
                settingsTab
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Camera Radar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if camera.running {
                        Button {
                            camera.recording ? camera.stopRecording() : camera.startRecording()
                        } label: {
                            Image(systemName: camera.recording ? "record.circle.fill" : "record.circle")
                                .foregroundStyle(camera.recording ? Color.red : Color.primary)
                        }
                        .accessibilityLabel(camera.recording ? "Stop recording" : "Record session")
                    }
                    Button {
                        if camera.running {
                            camera.stop()
                        } else {
                            Task { await camera.start() }
                        }
                    } label: {
                        Image(systemName: camera.running ? "pause.circle.fill" : "play.circle.fill")
                            .foregroundStyle(camera.running ? Color.secondary : Color.green)
                    }
                    .accessibilityLabel(camera.running ? "Pause camera" : "Start camera")
                }
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: warning?.id) {
            guard warning != nil, Date.now.timeIntervalSince(lastBuzz) > 2 else { return }
            lastBuzz = .now
            let s = HapticSettings.load()
            Task { _ = await radar.haptics.play(s.critical, title: "Watch out", body: "Vehicle behind you", via: s.method) }
        }
    }

    // MARK: - Sub-Tab 1: Live Camera View

    private var liveTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let p = camera.problem {
                    Label(p, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                }

                if let w = warning {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pretty(w.label)) approaching!")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                            Text("Reaches you in \(String(format: "%.1f", w.timeToReach ?? 0)) s · \(sideText(w.lateral))")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        Spacer()
                        if let d = w.distance {
                            Text(distanceText(d))
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(14)
                    .background(Color.red, in: .rect(cornerRadius: 18))
                }

                ZStack(alignment: .topLeading) {
                    CameraPreview(session: camera.session, tracks: camera.tracks, rotation: camera.rotation)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(warning != nil ? Color.red : Color.clear, lineWidth: 4)
                        )

                    // HUD Badges over camera preview
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(camera.running ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(camera.running ? "\(camera.fps) fps · \(Int(camera.detectMs.rounded())) ms" : "Paused")
                            Text("·")
                            Text(camera.depth)
                        }
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: .capsule)

                        if camera.recording {
                            HStack(spacing: 6) {
                                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                                Text("REC \(Int(camera.recorded ?? 0))s")
                            }
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: .capsule)
                        }
                    }
                    .padding(12)
                }

                // Quick filter chips for active objects
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DetectableObject.allCases) { obj in
                            let isOn = camera.settings.enabledObjects.contains(obj.rawValue)
                            Button {
                                toggleObject(obj.rawValue)
                            } label: {
                                Label(obj.title, systemImage: obj.icon)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isOn ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: .capsule)
                                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Live summary of tracked objects & distances
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Detected Objects (\(camera.tracks.count))")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(camera.method.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if camera.tracks.isEmpty {
                        Text(camera.running ? "No enabled objects in view" : camera.problem == nil ? "Camera paused" : "Camera unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(camera.tracks) { t in
                            HStack(spacing: 12) {
                                Image(systemName: DetectableObject(rawValue: t.label)?.icon ?? "car.fill")
                                    .font(.title3)
                                    .foregroundStyle(t.warn ? Color.red : Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(pretty(t.label)) #\(t.id)")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(t.warn ? Color.red : Color.primary)
                                    Text("\(sideText(t.lateral)) · \(t.timeToReach.map { String(format: "reaches in %.1f s", $0) } ?? "steady/away")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(metres(t.distance))
                                        .font(.title3.bold().monospacedDigit())
                                        .foregroundStyle(t.warn ? Color.red : Color.primary)
                                    Text(t.distanceFrom)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                        }
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))

                if camera.recording {
                    HStack(spacing: 8) {
                        ForEach([("Vehicle passed", "car.side"), ("Missed one", "eye.slash"), ("False alarm", "xmark.octagon")], id: \.0) { note, icon in
                            Button { camera.mark(note) } label: {
                                Label(note, systemImage: icon)
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Sub-Tab 2: Detections, Recording & Diagnostics

    private var detectionsTab: some View {
        List {
            Section("Tracked Objects (\(camera.tracks.count))") {
                if camera.tracks.isEmpty {
                    Text(camera.running ? "None in view" : camera.problem == nil ? "Starting…" : "Camera not running")
                        .foregroundStyle(.secondary)
                }
                ForEach(camera.tracks) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trackLine(t)).font(.subheadline.bold()).foregroundStyle(t.warn ? .red : .primary)
                        Text("Closing \(t.closingSpeed.map { String(format: "%.1f m/s (%.0f km/h)", $0, $0 * 3.6) } ?? "–") · \(sideText(t.lateral)) · \(Int(t.confidence * 100))% sure")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Each way: LiDAR \(metres(t.lidarDistance)) · size \(metres(t.sizeDistance))\(t.learnedHeight.map { " (its height \(distanceText($0)))" } ?? "") · road \(metres(t.groundDistance)) · Depth Anything \(metres(t.modelDistance)) · width \(metres(t.widthDistance))")
                            .font(.caption).foregroundStyle(.secondary)
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
            } header: {
                Text("Session Recording")
            } footer: {
                Text("Saves the video with the boxes and numbers drawn in (≈ 60 MB per minute), tracks.csv (every vehicle in every frame: each distance method's number, reaches-you-in, speed, side, warning, timed to the video) and events.txt with your marks. Also in Files › On My iPhone › SpatialAudioDetect › Camera recordings.")
            }

            Section("System & Sensor Status") {
                LabeledContent("Camera", value: camera.camera.isEmpty ? "–" : camera.camera)
                LabeledContent("Phone held", value: camera.rotation.name)
                LabeledContent("Depth", value: camera.depth)
                LabeledContent("Road", value: camera.road)
                LabeledContent("Depth Anything", value: camera.depthModel)
                LabeledContent("Frames", value: "\(camera.fps)/s · model \(Int(camera.detectMs.rounded())) ms")
                LabeledContent("Microphone (radar)", value: radar.micStatus)
            }
        }
    }

    // MARK: - Sub-Tab 3: Camera Settings

    private var settingsTab: some View {
        Form {
            Section {
                ForEach(DetectableObject.allCases) { obj in
                    let isEnabled = camera.settings.enabledObjects.contains(obj.rawValue)
                    Toggle(isOn: Binding(
                        get: { isEnabled },
                        set: { _ in toggleObject(obj.rawValue) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(obj.title)
                                Text("Ref size: \(String(format: "%.2f", obj.typicalHeight)) m tall × \(String(format: "%.2f", obj.typicalWidth)) m wide")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: obj.icon)
                        }
                    }
                }
                HStack {
                    Button("Select All") {
                        camera.settings.enabledObjects = Set(DetectableObject.allCases.map(\.rawValue))
                    }
                    Spacer()
                    Button("Vehicles Only") {
                        camera.settings.enabledObjects = ["car", "motorcycle", "bicycle", "bus", "truck"]
                    }
                }
                .font(.subheadline)
            } header: {
                Text("Objects to Detect & Measure Distance")
            } footer: {
                Text("Choose which road objects the camera tracks and measures distance for. Unchecked objects are ignored on screen and in distance calculations.")
            }

            Section {
                Picker("Distance Method", selection: $camera.method) {
                    ForEach(DistanceMethod.allCases, id: \.self) { Text($0.rawValue) }
                }
                Picker("Vision Detector", selection: $camera.detector) {
                    ForEach(CameraDetector.allCases, id: \.self) { Text($0.rawValue) }
                }
                Toggle("Merge rider into motorcycle / bicycle", isOn: $camera.settings.mergeRiderWithVehicle)
            } header: {
                Text("Distance Measurement & Model")
            } footer: {
                Text("""
                    Detector: YOLO26s at 960×736 sees farther objects; at 640 it runs faster; YOLOv3 is the legacy model.
                    Distance — Calculation: uses direct LiDAR depth within 5 m; beyond 5 m, combines the object's apparent height (calibrated by LiDAR when close, or reference height) with the LiDAR-fitted road plane up to 15 m, smoothed with a Kalman filter.
                    + Depth Anything: adds the neural depth map calibrated against LiDAR each frame.
                    Depth Anything only: just the neural depth map's number, even within 5 m. This model only knows nearer/farther, so LiDAR readings 0.4–5 m away still set its scale each frame; far away that's an extrapolation.
                    OpenCV method: triangle similarity using reference object width.
                    """)
            }

            Section {
                ForEach(DetectableObject.allCases) { obj in
                    let isEnabled = camera.settings.enabledObjects.contains(obj.rawValue)
                    Toggle(isOn: Binding(
                        get: { camera.settings.warnObjects.contains(obj.rawValue) },
                        set: { on in
                            if on {
                                camera.settings.warnObjects.insert(obj.rawValue)
                            } else {
                                camera.settings.warnObjects.remove(obj.rawValue)
                            }
                        }
                    )) {
                        Label(obj.title, systemImage: obj.icon)
                    }
                    .disabled(!isEnabled)
                }
            } header: {
                Text("Trigger Danger Warnings For")
            } footer: {
                Text("Objects enabled here will highlight in red and trigger haptic warnings when they approach on your path. By default, people do not trigger vehicle warnings unless enabled here.")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Warn when reaching within", value: String(format: "%.1f s", camera.settings.warnSeconds))
                    Slider(value: $camera.settings.warnSeconds, in: 1.0...6.0, step: 0.5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Path clearance (side distance)", value: String(format: "%.1f m", camera.settings.warnSide))
                    Slider(value: $camera.settings.warnSide, in: 0.5...4.0, step: 0.5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Minimum detection confidence", value: "\(Int((camera.settings.startConfidence * 100).rounded()))%")
                    Slider(value: $camera.settings.startConfidence, in: 0.25...0.85, step: 0.05)
                }
                Button("Reset Camera Settings to Defaults", role: .destructive) {
                    camera.settings = CameraSettings()
                    camera.detector = .yolo26Large
                    camera.method = .calculation
                }
            } header: {
                Text("Warning & Tracking Thresholds")
            } footer: {
                Text("Warnings fire when an enabled object is confirmed across \(VehicleTracker.confirmHits) frames and will reach you within the time threshold while passing within the side clearance, or when LiDAR sees it within 3 m closing at > 1 m/s.")
            }
        }
    }

    private func toggleObject(_ raw: String) {
        if camera.settings.enabledObjects.contains(raw) {
            camera.settings.enabledObjects.remove(raw)
        } else {
            camera.settings.enabledObjects.insert(raw)
        }
    }
}
