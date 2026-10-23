import CoreGraphics
import Foundation

// Trial: distance from Depth Anything V2 (Apple's Core ML version, Apache-2.0). The model only gives *relative* depth,
// as inverse depth up to an unknown scale and offset: value = a · (1 / metres) + b, different for every frame. LiDAR's
// exact readings (0.4–5 m) give a and b for each frame; then any pixel's value becomes metres = a / (value − b), also
// far beyond LiDAR's range. How well that holds at 20–40 m is what this trial measures.

/// The part of the upright camera picture the depth model sees: the full width and the middle band at the model's
/// landscape shape (518×392), so nothing is stretched. Upright, the sensor's x runs down the picture and its y from
/// right to left (as in VehicleTracker).
nonisolated struct DepthCrop: Sendable {
    let band: Double     // fraction of the picture's height inside the crop
    let top: Double      // where it starts, from the top

    /// `uprightAspect`: the upright picture's width ÷ height (0.75 for 1440×1920). `modelAspect`: 518 ÷ 392.
    init(uprightAspect: Double, modelAspect: Double) {
        band = min(uprightAspect / modelAspect, 1)
        top = (1 - band) / 2
    }

    /// Vision's region of interest for this crop (normalized, bottom-left origin; symmetric, so the same either way).
    var region: CGRect { CGRect(x: 0, y: top, width: 1, height: band) }

    /// A sensor-normalized point (top-left origin) in the depth map (0…1 across, 0…1 down), nil outside the crop.
    func modelPoint(sensorX: Double, sensorY: Double) -> (x: Double, y: Double)? {
        let across = 1 - sensorY, down = (sensorX - top) / band
        return down >= 0 && down <= 1 ? (across, down) : nil
    }
}

/// This frame's conversion from the model's relative value to metres.
nonisolated struct DepthFit: Sendable {
    var a: Double, b: Double
    var points: Int      // LiDAR pixels it was fitted on
    var r2: Double       // 1 = the model and LiDAR agree perfectly up close

    /// Metres for a model value; nil when it reads as farther than 150 m (or behind the camera).
    func metres(_ value: Double) -> Double? {
        let inverse = (value - b) / a
        return inverse >= 1 / 150 ? 1 / inverse : nil
    }
}

/// Least-squares fit of model value = a · (1/z) + b on (value, LiDAR metres) pairs, refitted without the worst outliers
/// (edges, reflections). Nil with too few points, no spread, or the model getting it backwards (a ≤ 0).
nonisolated func fitDepth(_ pairs: [(value: Double, metres: Double)]) -> DepthFit? {
    func fit(_ p: [(value: Double, metres: Double)]) -> DepthFit? {
        guard p.count >= 30 else { return nil }
        let x = p.map { 1 / $0.metres }, y = p.map(\.value)
        guard let a = slope(x, y), a > 0 else { return nil }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count), b = my - a * mx
        let total = y.reduce(0) { $0 + ($1 - my) * ($1 - my) }, residual = zip(x, y).reduce(0) { $0 + pow($1.1 - (a * $1.0 + b), 2) }
        return DepthFit(a: a, b: b, points: p.count, r2: total > 0 ? 1 - residual / total : 0)
    }
    guard let first = fit(pairs) else { return nil }
    let sigma = (pairs.reduce(0) { $0 + pow($1.value - (first.a / $1.metres + first.b), 2) } / Double(pairs.count)).squareRoot()
    return fit(pairs.filter { abs($0.value - (first.a / $0.metres + first.b)) <= 2 * sigma + 1e-9 }) ?? first
}

nonisolated func depthModelSelfCheck() {
    // Upright 1440×1920 picture into a 518×392 model: the middle 57% of the height.
    let crop = DepthCrop(uprightAspect: 1440.0 / 1920, modelAspect: 518.0 / 392)
    precondition(abs(crop.band - 0.5676) < 0.001 && abs(crop.top - 0.2162) < 0.001, "crop -> \(crop)")
    let centre = crop.modelPoint(sensorX: 0.5, sensorY: 0.5)!
    precondition(abs(centre.x - 0.5) < 1e-9 && abs(centre.y - 0.5) < 1e-9, "picture centre = model centre")
    let right = crop.modelPoint(sensorX: 0.5, sensorY: 0.1)!  // sensor y near 0 = the upright picture's right edge
    precondition(right.x > 0.85, "sensor y ≈ 0 is the right of the picture -> \(right)")
    precondition(crop.modelPoint(sensorX: 0.05, sensorY: 0.5) == nil, "the top of the picture is outside the band")

    // A model whose values are 3/z + 0.2 (plus a few bad reflections): recovered from LiDAR at 0.5–5 m, then 30 m read back.
    var pairs = stride(from: 0.5, through: 5.0, by: 0.05).map { (value: 3 / $0 + 0.2, metres: $0) }
    pairs += [(value: 9, metres: 4.5), (value: 0.1, metres: 0.6)]
    let f = fitDepth(pairs)!
    precondition(abs(f.a - 3) < 0.05 && abs(f.b - 0.2) < 0.02 && f.r2 > 0.99, "fit -> \(f)")
    precondition(abs(f.metres(3.0 / 30 + 0.2)! - 30) < 1.5, "30 m read back -> \(f.metres(3.0 / 30 + 0.2)!)")
    precondition(f.metres(0.19) == nil, "beyond the far end: no distance")
    precondition(fitDepth(Array(pairs.prefix(10))) == nil, "too few LiDAR points: no fit")
}
