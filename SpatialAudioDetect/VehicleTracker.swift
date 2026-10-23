import CoreGraphics
import Foundation
import simd

// Camera test: vehicles found by the vision model, followed frame to frame, and what that says about each one —
// distance, seconds until it reaches you, closing speed, how far to your side it will pass. Pure, so the Mac can check it.
//
// Geometry assumes the phone is upright (portrait) with its back camera facing backward, e.g. strapped to your back.
// Rects are normalized in the camera sensor's own landscape image, top-left origin: the same space as the LiDAR depth
// map and AVCaptureVideoPreviewLayer's metadata rects. Upright, the sensor's x runs down the picture and its y from
// right to left.

/// One object the model found in one frame. `confidence`: the box's own score (Vision's observation confidence, not the
/// label's, which is ~1.0 for every box). `lidar`: LiDAR distance inside its box (m).
nonisolated struct VehicleDetection: Sendable {
    var label: String
    var confidence: Double
    var rect: CGRect
    var lidar: Double?
    var modelDepth: Double? = nil  // Depth Anything V2's distance (m), when it ran this frame
}

/// The camera's focal lengths and centre, as fractions of the sensor image's width (x) and height (y).
nonisolated struct CameraIntrinsics: Sendable {
    var fx = 0.71, fy = 0.95, cx = 0.5, cy = 0.5
}

/// How a vehicle's distance is worked out; all are computed and recorded every frame, this one is shown and used.
nonisolated enum DistanceMethod: String, CaseIterable, Sendable {
    case calculation = "Calculation"                      // LiDAR ≤ 5 m; beyond: its height in the picture, fused with where it meets the road
    case calculationDepth = "Calculation + Depth Anything"  // the same, plus the AI depth model
    case widthFormula = "OpenCV method (known width)"     // the paper's triangle similarity: real width × focal ÷ width in pixels
}

/// Typical real size (m) per label: height for distance from size, width for the OpenCV method. Two-wheelers include the rider.
nonisolated let vehicleHeights: [String: Double] = ["car": 1.5, "motorcycle": 1.45, "bicycle": 1.7, "bus": 3.1, "truck": 3.0, "person": 1.7]
nonisolated let vehicleWidths: [String: Double] = ["car": 1.8, "motorcycle": 0.8, "bicycle": 0.6, "bus": 2.55, "truck": 2.5, "person": 0.5]

/// The same thing under the label each model uses (Apple's YOLOv3 says "motorbike", YOLO26 "motorcycle").
nonisolated func normalizedLabel(_ label: String) -> String { label == "motorbike" ? "motorcycle" : label }

/// Vision's box for an upright (`.right`) back-camera frame (normalized, bottom-left origin) in sensor coordinates.
nonisolated func sensorRect(fromVision r: CGRect) -> CGRect {
    CGRect(x: 1 - r.maxY, y: 1 - r.maxX, width: r.height, height: r.width)
}

/// Least-squares slope of y over x; nil without spread.
nonisolated func slope(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count >= 2 else { return nil }
    let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
    let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
    guard sxx > 1e-9 else { return nil }
    return zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
}

/// Distance and its rate, smoothed: a constant-velocity Kalman filter, one per vehicle.
nonisolated struct DistanceFilter: Sendable {
    var d = 0.0, v = 0.0                      // m, m/s (− = coming closer)
    var p00 = 0.0, p01 = 0.0, p11 = 25.0      // uncertainty
    var updates = 0
    static let accel = 3.0                    // m/s² it may change speed by between frames

    mutating func update(_ z: Double, sigma: Double, dt: Double) {
        let r = sigma * sigma
        if updates == 0 {
            (d, v, p00, p01, p11) = (z, 0, r, 0, 25)
        } else {
            d += v * dt
            let q = Self.accel * Self.accel
            p00 += dt * (2 * p01 + dt * p11) + q * pow(dt, 4) / 4
            p01 += dt * p11 + q * pow(dt, 3) / 2
            p11 += q * dt * dt
            let s = p00 + r, k0 = p00 / s, k1 = p01 / s, e = z - d
            d += k0 * e
            v += k1 * e
            (p00, p01, p11) = ((1 - k0) * p00, (1 - k0) * p01, p11 - k1 * p01)
        }
        updates += 1
    }
}

nonisolated struct VehicleTrack: Sendable, Identifiable {
    struct Sample: Sendable { var t: Double, size: Double }
    var id: Int
    var label: String
    var confidence: Double
    var rect: CGRect
    var lastSeen: Double
    var hits = 0                      // frames it was seen in
    var confirmed = false             // seen 3 times: shown and allowed to warn
    var samples: [Sample] = []        // the last second
    var distance: Double?             // m, smoothed, by the chosen method
    var distanceFrom = ""             // "LiDAR", "size", "size + road", "size + road + Depth Anything", "width"
    var fromLidar = false             // within LiDAR range this frame
    var timeToReach: Double?          // s until it reaches you, from how fast its picture grows; nil = not coming closer
    var closingSpeed: Double?         // m/s, + = coming closer
    var lateral: Double?              // m to your left (+) or right (−) of your path
    var warn = false
    // This frame's raw estimates, all recorded for comparison
    var lidarDistance: Double?
    var sizeDistance: Double?
    var groundDistance: Double?       // where it meets the road, with the LiDAR-fitted road plane
    var widthDistance: Double?        // the OpenCV / paper method
    var modelDistance: Double?        // Depth Anything V2
    var learnedHeight: Double?        // its real height, measured by LiDAR when it was within 5 m
    var heights: [Double] = []
    var filter = DistanceFilter()
}

/// Follows vehicles across frames and keeps each one's numbers current.
nonisolated struct VehicleTracker {
    // ponytail: set on synthetic approaches and the research report; tune on real passes with the Camera test screen
    static let warnSeconds = 3.0       // warn when it reaches you within this…
    static let warnSide = 2.0          // …passing within this many metres of your path
    static let lidarRange = 5.0        // the iPhone's LiDAR measures up to ~5 m
    static let startConfidence = 0.5   // a box this sure may start a new track (weaker ones only keep tracks going)
    static let keepConfidence = 0.15   // the model is asked for boxes down to this
    static let confirmHits = 3         // seen this many times before it's shown or can warn
    static let lensBlocked = 0.3       // LiDAR closer than this: a hand or strap over the lens, not a vehicle
    private(set) var tracks: [VehicleTrack] = []
    private var nextID = 1

    /// One frame's detections at stream time `t`.
    mutating func update(_ raw: [VehicleDetection], at t: Double, camera: CameraIntrinsics, road: GroundPlane? = nil,
                         method: DistanceMethod = .calculation) -> [VehicleTrack] {
        var detections = raw.map { d -> VehicleDetection in
            var d = d
            d.label = normalizedLabel(d.label)
            return d
        }.filter { vehicleHeights[$0.label] != nil && $0.confidence >= Self.keepConfidence && ($0.lidar ?? 1) >= Self.lensBlocked }
        // A motorbike or bicycle rider is also found as a person: keep just the vehicle.
        let rides = detections.filter { $0.label == "motorcycle" || $0.label == "bicycle" }.map(\.rect)
        detections.removeAll { d in
            d.label == "person" && rides.contains { r in
                let inter = r.intersection(d.rect)
                return !inter.isNull && inter.width * inter.height >= 0.5 * d.rect.width * d.rect.height
            }
        }
        // Greedy by overlap: each track takes the detection that overlaps it most (labels may flicker car ↔ truck).
        for i in tracks.indices {
            func iou(_ d: VehicleDetection) -> Double {
                let a = tracks[i].rect, b = d.rect, inter = a.intersection(b)
                guard !inter.isNull else { return 0 }
                let x = inter.width * inter.height
                return Double(x / (a.width * a.height + b.width * b.height - x))
            }
            guard let j = detections.indices.max(by: { iou(detections[$0]) < iou(detections[$1]) }), iou(detections[j]) >= 0.25 else { continue }
            add(detections.remove(at: j), to: i, at: t, camera: camera, road: road, method: method)
        }
        for d in detections where d.confidence >= Self.startConfidence {
            tracks.append(VehicleTrack(id: nextID, label: d.label, confidence: d.confidence, rect: d.rect, lastSeen: t))
            nextID += 1
            add(d, to: tracks.count - 1, at: t, camera: camera, road: road, method: method)
        }
        tracks.removeAll { t - $0.lastSeen > 1 }
        return tracks
    }

    private mutating func add(_ d: VehicleDetection, to i: Int, at t: Double, camera: CameraIntrinsics, road: GroundPlane?,
                              method: DistanceMethod) {
        var k = tracks[i]
        let dt = k.hits == 0 ? 0 : t - k.lastSeen
        if d.confidence >= k.confidence - 0.1 { k.label = d.label }
        k.confidence = d.confidence
        k.rect = d.rect
        k.lastSeen = t
        k.hits += 1
        k.confirmed = k.confirmed || k.hits >= Self.confirmHits

        // Upright, its height in the picture is the sensor rect's width, its width the rect's height, and its
        // left–right position the rect's y; the road contact point is the box's bottom = the rect's maxX.
        let size = Double(d.rect.width)
        let lidar = d.lidar.flatMap { $0 <= Self.lidarRange ? $0 : nil }
        if let lidar {  // learn this vehicle's real height while LiDAR can measure it
            let h = lidar * size / camera.fx
            if (0.5...4.5).contains(h) { k.heights = Array((k.heights + [h]).suffix(15)) }
        }
        k.learnedHeight = k.heights.count >= 3 ? k.heights.sorted()[k.heights.count / 2] : nil
        k.lidarDistance = d.lidar
        k.modelDistance = d.modelDepth
        k.sizeDistance = camera.fx * (k.learnedHeight ?? vehicleHeights[k.label]!) / max(size, 1e-4)
        k.widthDistance = camera.fy * vehicleWidths[k.label]! / max(Double(d.rect.height), 1e-4)
        k.groundDistance = road?.distance(sensorX: Double(d.rect.maxX), sensorY: Double(d.rect.midY), camera: camera)
        k.fromLidar = lidar != nil

        // This frame's measurement by the chosen method, with how uncertain it is (as a fraction of the distance).
        // ponytail: error sizes from the research report (height prior ±12%, LiDAR-learned height ±5%, road plane ±4% + 0.6%/m,
        // Depth Anything ±5% + 1%/m, known width ±30%); replace with errors measured in tracks.csv
        func fused(_ parts: [(z: Double, rel: Double)]) -> (z: Double, sigma: Double) {
            let w = parts.map { 1 / pow($0.rel * $0.z, 2) }, total = w.reduce(0, +)
            return (zip(parts, w).reduce(0) { $0 + $1.0.z * $1.1 } / total, (1 / total).squareRoot())
        }
        var parts: [(z: Double, rel: Double)] = [(k.sizeDistance!, k.learnedHeight == nil ? 0.12 : 0.05)]
        var from = "size"
        if let g = k.groundDistance, g <= 15 { parts.append((g, 0.04 + 0.006 * g)); from += " + road" }
        if method == .calculationDepth, let m = k.modelDistance { parts.append((m, 0.05 + 0.01 * m)); from += " + Depth Anything" }
        let measured: (z: Double, sigma: Double)
        switch method {
        case .widthFormula:
            measured = (k.widthDistance!, 0.3 * k.widthDistance!)
            from = "width"
        case _ where lidar != nil:
            measured = (lidar!, 0.05)
            from = "LiDAR"
        default:
            measured = fused(parts)
        }
        k.filter.update(measured.z, sigma: measured.sigma, dt: dt)
        k.distance = max(k.filter.d, 0.3)
        k.distanceFrom = from
        k.closingSpeed = k.filter.updates >= 5 ? -k.filter.v : nil
        // Looking backward, the camera's right is your left.
        k.lateral = (camera.cy - Double(d.rect.midY)) / camera.fy * k.distance!

        // Picture size ∝ 1 / distance, so d(ln size)/dt = closing speed ÷ distance = 1 / seconds until it reaches you.
        k.samples.append(.init(t: t, size: size))
        k.samples.removeAll { t - $0.t > 1 }
        let window = k.samples.filter { t - $0.t <= 0.6 }
        let growth = window.count >= 5 ? slope(window.map(\.t), window.map { log($0.size) }) : nil
        // The fit describes the middle of the window, ~0.3 s ago: take that time off. Further than 10 s away = not coming
        // closer (box jitter alone reads as ~30 s; nothing that far off needs a warning).
        let lag = t - window.map(\.t).reduce(0, +) / Double(max(window.count, 1))
        k.timeToReach = growth.flatMap { $0 > 1 / 10 ? max(1 / $0 - lag, 0) : nil }
        let closingNear = k.fromLidar && k.distance! <= 3 && (k.closingSpeed ?? 0) > 1
        k.warn = k.confirmed && k.label != "person"
            && (((k.timeToReach ?? .infinity) <= Self.warnSeconds && abs(k.lateral ?? 0) <= Self.warnSide) || closingNear)
        tracks[i] = k
    }
}

nonisolated func vehicleTrackerSelfCheck() {
    // Vision box (bottom-left origin, upright picture) -> sensor rect.
    let r = sensorRect(fromVision: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    precondition(abs(r.minX - 0.4) < 1e-9 && abs(r.minY - 0.6) < 1e-9 && abs(r.width - 0.4) < 1e-9 && abs(r.height - 0.3) < 1e-9, "rect -> \(r)")

    // A motorbike at 30 km/h coming up behind you, 1 m to your left, seen at 30 fps with ±3% box jitter.
    let camera = CameraIntrinsics(fx: 0.71, fy: 0.95)  // 1× camera: focal ÷ sensor width / height
    var tracker = VehicleTracker(), wobble: UInt64 = 1, warnedAt: Double?
    func jitter() -> Double { wobble = wobble &* 6364136223846793005 &+ 1442695040888963407; return 1 + 0.06 * (Double(wobble >> 11) / Double(1 << 53) - 0.5) }
    func box(distance d: Double, left: Double, height: Double) -> CGRect {
        let size = camera.fx * height / d * jitter(), mid = 0.5 - left / d * camera.fy
        return CGRect(x: 0.5 - size / 2, y: mid - size * 0.3, width: size, height: size * 0.6)
    }
    var atTwo: VehicleTrack?
    for k in 0..<117 {  // 40 m to 7.5 m (3.9 s)
        let t = Double(k) / 30, d = 40 - 8.33 * t
        let found = tracker.update([VehicleDetection(label: "motorbike", confidence: 0.8, rect: box(distance: d, left: 1, height: 1.45))],
                                   at: t, camera: camera)
        if warnedAt == nil, found.first?.warn == true { warnedAt = d / 8.33 }
        if atTwo == nil, d <= 16.7 { atTwo = found.first }
    }
    let bike = atTwo!
    precondition(bike.id == 1 && tracker.tracks.count == 1 && bike.label == "motorcycle", "one bike, one track, one label")
    precondition(abs(bike.timeToReach! - 2) < 0.4, "reaches you in ~2 s -> \(bike.timeToReach!)")
    precondition(abs(bike.distance! - 16.7) < 2.5, "~16.7 m away -> \(bike.distance!)")
    precondition(abs(bike.closingSpeed! - 8.33) < 2, "closing at ~8.3 m/s -> \(bike.closingSpeed!)")
    precondition(abs(bike.lateral! - 1) < 0.3, "1 m to your left -> \(bike.lateral!)")
    precondition(abs((warnedAt ?? 0) - 3) < 0.5, "warned ~3 s before it reaches you -> \(warnedAt.map { "\($0) s" } ?? "never")")

    // A car on the road 4 m to your side: coming closer, but passing clear of you. A parked car: never.
    var road = VehicleTracker(), parked = VehicleTracker(), roadWarned = false, parkedWarned = false
    for k in 0..<120 {
        let t = Double(k) / 30
        if k < 75 {  // 30 m to 5 m
            roadWarned = roadWarned || road.update([VehicleDetection(label: "car", confidence: 0.9, rect: box(distance: 30 - 10 * t, left: -4, height: 1.5))],
                                                   at: t, camera: camera).contains { $0.warn }
        }
        parkedWarned = parkedWarned || parked.update([VehicleDetection(label: "car", confidence: 0.9, rect: box(distance: 8, left: 1, height: 1.5))],
                                                     at: t, camera: camera).contains { $0.warn }
    }
    precondition(!roadWarned && road.tracks.first.map { $0.lateral! < -3 } == true, "passing 4 m to your right: no warning")
    precondition(!parkedWarned && parked.tracks.first?.timeToReach == nil, "parked car: no warning, never 'reaching you'")

    // LiDAR within 5 m is the distance; a label that isn't a road user is ignored.
    var near = VehicleTracker()
    let close = near.update([VehicleDetection(label: "car", confidence: 0.9, rect: box(distance: 4, left: 0, height: 1.5), lidar: 3.2),
                             VehicleDetection(label: "dog", confidence: 0.9, rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))],
                            at: 0, camera: camera)
    precondition(close.count == 1 && close[0].distance == 3.2 && close[0].fromLidar && close[0].distanceFrom == "LiDAR", "LiDAR distance used -> \(close)")

    // False positives: a one-frame ghost never confirms or warns; a weak box can't start a track; a hand on the lens
    // (LiDAR 0.1 m) is dropped; a rider's person box inside the motorbike is dropped; a person never warns.
    var ghosts = VehicleTracker()
    let ghost = ghosts.update([VehicleDetection(label: "car", confidence: 0.95, rect: box(distance: 3, left: 0, height: 1.5))], at: 0, camera: camera)
    precondition(ghost.count == 1 && !ghost[0].confirmed && !ghost[0].warn, "one frame: not confirmed")
    precondition(ghosts.update([], at: 1.2, camera: camera).isEmpty, "gone after a second unseen")
    precondition(ghosts.update([VehicleDetection(label: "car", confidence: 0.3, rect: box(distance: 3, left: 0, height: 1.5))], at: 2, camera: camera).isEmpty,
                 "a 0.3 box can't start a track")
    precondition(ghosts.update([VehicleDetection(label: "car", confidence: 0.9, rect: box(distance: 3, left: 0, height: 1.5), lidar: 0.1)], at: 3, camera: camera).isEmpty,
                 "hand over the lens dropped")
    let bikeBox = box(distance: 6, left: 0, height: 1.45)
    let rider = CGRect(x: bikeBox.minX, y: bikeBox.minY + bikeBox.height * 0.2, width: bikeBox.width * 0.6, height: bikeBox.height * 0.6)
    precondition(ghosts.update([VehicleDetection(label: "motorcycle", confidence: 0.9, rect: bikeBox), VehicleDetection(label: "person", confidence: 0.9, rect: rider)],
                               at: 4, camera: camera).map(\.label) == ["motorcycle"], "rider merged into the motorbike")
    var walker = VehicleTracker(), walkerWarned = false
    for k in 0..<60 {
        let t = Double(k) / 30
        walkerWarned = walkerWarned || walker.update([VehicleDetection(label: "person", confidence: 0.9, rect: box(distance: 8 - 3 * t, left: 0, height: 1.7))],
                                                     at: t, camera: camera).contains { $0.warn }
    }
    precondition(!walkerWarned, "a person walking up to you doesn't raise a vehicle warning")

    // Methods: LiDAR teaches a car's real height (a 1.9 m van), which then fixes the size estimate beyond 5 m;
    // the OpenCV width method reads a correctly sized car right.
    var van = VehicleTracker(), vanAt20: VehicleTrack?
    for k in 0..<240 {
        let t = Double(k) / 30, d = 3 + 2.5 * t  // driving away from 3 m to 23 m
        let rect = CGRect(x: 0.5 - camera.fx * 1.9 / d / 2, y: 0.4, width: camera.fx * 1.9 / d, height: camera.fy * 1.8 / d)
        vanAt20 = van.update([VehicleDetection(label: "car", confidence: 0.9, rect: rect, lidar: d <= 5 ? d : nil)], at: t, camera: camera).first
        if d >= 20 { break }
    }
    precondition(abs(vanAt20!.learnedHeight! - 1.9) < 0.05 && abs(vanAt20!.sizeDistance! - 20) < 1, "learned 1.9 m height -> \(vanAt20!)")
    precondition(abs(vanAt20!.widthDistance! - 20) < 1, "known width: 1.8 m wide car at 20 m -> \(vanAt20!.widthDistance!)")
}
