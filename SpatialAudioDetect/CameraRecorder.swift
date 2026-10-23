@preconcurrency import AVFoundation
import CoreText
import Foundation

// Camera test recordings, in Documents/Camera recordings/<date time>/ (also in the Files app):
//   video.mov    what the camera saw, boxes and numbers drawn in, upright
//   tracks.csv   one row per vehicle per frame (a row with empty vehicle columns when none), timed to the video;
//                boxes normalized in the upright picture (top-left origin), however the phone was held
//   events.txt   the tester's marks ("vehicle passed now", "missed", "false warning") at video time

/// Draws each vehicle's box and a label ("Motorbike 12.3 m · 1.8 s") onto a BGRA frame in the camera sensor's own
/// (landscape) orientation, upright and above the box once the video is turned as `rotation` says.
nonisolated func drawOverlay(_ tracks: [VehicleTrack], on pixels: CVPixelBuffer, rotation: PictureRotation) {
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pixels) else { return }
    let w = CGFloat(CVPixelBufferGetWidth(pixels)), h = CGFloat(CVPixelBufferGetHeight(pixels))
    guard let ctx = CGContext(data: base, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, min(w, h) / 40, nil)
    // Draw in the upright picture (CG: y up), turned back onto the sensor's pixels.
    let sideways = rotation.rawValue % 180 != 0, uw = sideways ? h : w, uh = sideways ? w : h
    ctx.translateBy(x: rotation == .portrait || rotation == .landscapeTopRight ? w : 0,
                    y: rotation == .landscapeTopRight || rotation == .upsideDown ? h : 0)
    ctx.rotate(by: CGFloat(rotation.rawValue) * .pi / 180)
    for t in tracks {
        let color = t.warn ? CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1) : CGColor(red: 1, green: 0.84, blue: 0, alpha: 1)
        let box = CGRect(x: t.rect.minX * uw, y: (1 - t.rect.maxY) * uh, width: t.rect.width * uw, height: t.rect.height * uh)
        guard t.confirmed else {  // not yet confirmed (maybe a false detection): thin grey, no label
            ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 0.8))
            ctx.setLineWidth(2)
            ctx.stroke(box)
            continue
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(t.warn ? 8 : 4)
        ctx.stroke(box)
        var text = pretty(t.label)
        if let d = t.distance { text += " \(distanceText(d))\(t.fromLidar ? " LiDAR" : "")" }
        if let m = t.modelDistance { text += " (DA \(distanceText(m)))" }
        if let s = t.timeToReach { text += String(format: " · %.1f s", s) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let base = min(box.maxY + descent + 2, uh - ascent - 2)  // just above the box, or inside it at the top edge
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: box.minX, y: base - descent - 2, width: width + 8, height: ascent + descent + 4))
        ctx.textPosition = CGPoint(x: box.minX + 4, y: base)
        CTLineDraw(line, ctx)
    }
}

// ponytail: uses AVAssetWriter's classic append API, deprecated (still working) in iOS 27 in favour of input receivers
// with CMReadySampleBuffer; move over once that can be tested on a device.
nonisolated final class CameraRecorder {
    let folder: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let csv: FileHandle
    private let events: FileHandle
    private var start: CMTime?
    private var frame = 0
    private(set) var seconds = 0.0
    private(set) var dropped = 0

    static let columns = ["video_time_s", "frame", "model_ms", "lidar_depth", "vehicle_id", "label", "confidence", "box_x", "box_y",
                          "box_w", "box_h", "distance_m", "distance_from", "lidar_m", "size_estimate_m", "reaches_you_s",
                          "closing_mps", "side_m_left_plus", "warning", "depth_model_m", "depth_fit_points", "depth_fit_r2",
                          "detector", "distance_method", "confirmed", "distance_by", "road_m", "width_m", "learned_height_m",
                          "road_height_m", "road_tilt_deg", "phone"]

    init(folder: URL, width: Int, height: Int, rotation: PictureRotation) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: folder.appending(path: "video.mov"), fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        input.transform = CGAffineTransform(rotationAngle: CGFloat(rotation.rawValue) * .pi / 180)  // play upright, as held at the start
        writer.add(input)
        func open(_ name: String, _ header: String) throws -> FileHandle {
            let url = folder.appending(path: name)
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data(header.utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        }
        csv = try open("tracks.csv", Self.columns.joined(separator: ",") + "\n")
        events = try open("events.txt", "")
        self.folder = folder
    }

    var files: [URL] { ["video.mov", "tracks.csv", "events.txt"].map { folder.appending(path: $0) } }

    /// The frame (already drawn on) and what was found in it. Camera queue.
    func add(_ sample: CMSampleBuffer, tracks: [VehicleTrack], modelMs: Double, depth: Bool, fit: DepthFit?, detector: String,
             method: String, road: GroundPlane?, phone: String) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if start == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            start = pts
        }
        if input.isReadyForMoreMediaData { input.append(sample) } else { dropped += 1 }
        seconds = (pts - start!).seconds
        frame += 1
        func f(_ x: Double?, _ digits: Int = 2) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "" }
        let head = [f(seconds, 3), "\(frame)", f(modelMs, 1), depth ? "yes" : "no"]
        let frameTail = [fit.map { "\($0.points)" } ?? "", f(fit?.r2, 3), "\"\(detector)\"", "\"\(method)\""]
        let roadTail = [f(road?.height), f(road?.tilt, 1), "\"\(phone)\""]
        let empty = Array(repeating: "", count: 14)  // the vehicle columns before depth_model_m
        let rows = tracks.isEmpty ? [head + empty + [""] + frameTail + ["", "", "", "", ""] + roadTail] : tracks.map { t in
            head + ["\(t.id)", t.label, f(t.confidence), f(Double(t.rect.minX), 4), f(Double(t.rect.minY), 4), f(Double(t.rect.width), 4),
                    f(Double(t.rect.height), 4), f(t.distance), t.fromLidar ? "lidar" : "estimate", f(t.lidarDistance), f(t.sizeDistance),
                    f(t.timeToReach), f(t.closingSpeed), f(t.lateral), t.warn ? "yes" : "no", f(t.modelDistance)] + frameTail
                + [t.confirmed ? "yes" : "no", "\"\(t.distanceFrom)\"", f(t.groundDistance), f(t.widthDistance), f(t.learnedHeight)] + roadTail
        }
        assert(rows.allSatisfy { $0.count == Self.columns.count }, "tracks.csv row doesn't match its header")
        try? csv.write(contentsOf: Data(rows.map { $0.joined(separator: ",") + "\n" }.joined().utf8))
    }

    func mark(_ note: String) {
        try? events.write(contentsOf: Data(String(format: "%.2f s  %@\n", seconds, note).utf8))
    }

    func finish(_ done: @escaping @Sendable () -> Void) {
        try? csv.close()
        try? events.close()
        guard start != nil else { writer.cancelWriting(); done(); return }
        input.markAsFinished()
        writer.finishWriting(completionHandler: done)
    }
}
