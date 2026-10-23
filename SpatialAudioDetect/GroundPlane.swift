import Foundation
import simd

// The road under you, from LiDAR, so a vehicle's distance can be read from where its wheels touch it. The plane gives
// the camera's real height and tilt every frame, so the runner's bounce is measured instead of guessed (a 1° tilt error
// alone would turn 20 m into 15–29 m). Camera axes of the upright picture: X right, Y down, Z straight out of the lens;
// all metres.

nonisolated struct GroundPlane: Sendable {
    var normal: SIMD3<Double>  // unit, pointing up (away from the road, toward the camera)
    var height: Double         // camera height above the road, m: normal · p + height = 0 on the road
    var points: Int            // LiDAR points that agreed

    /// Tilt of the camera's view toward the road, degrees (0 = looking level, + = looking down).
    var tilt: Double { asin(max(-1, min(1, -normal.z))) * 180 / .pi }

    /// Range to where the ray through a point of the upright picture meets the road; nil if it never does or is beyond 25 m.
    func distance(x: Double, y: Double, camera: CameraIntrinsics) -> Double? {
        let ray = SIMD3((x - camera.cx) / camera.fx, (y - camera.cy) / camera.fy, 1)
        let along = simd_dot(normal, ray)
        guard along < -1e-6 else { return nil }  // pointing at or above the horizon
        let range = height / -along * simd_length(ray)
        return range <= 25 ? range : nil
    }
}

/// Least-squares plane Y = a·X + b·Z + c through points (the road is roughly "constant Y": below the camera).
nonisolated func planeThrough(_ points: [SIMD3<Double>]) -> GroundPlane? {
    guard points.count >= 3 else { return nil }
    // Normal equations for [a, b, c] · [X, Z, 1] = Y
    var m = simd_double3x3(0), v = SIMD3<Double>(0, 0, 0)
    for p in points {
        let row = SIMD3(p.x, p.z, 1)
        m += simd_double3x3(columns: (row * row.x, row * row.y, row * row.z))
        v += row * p.y
    }
    guard abs(m.determinant) > 1e-12 else { return nil }
    let s = m.inverse * v
    // Y − aX − bZ − c = 0  →  up = −(−a, 1, −b)/|…| (up is −Y), height = c/|…|
    let length = simd_length(SIMD3(-s.x, 1, -s.y))
    return GroundPlane(normal: SIMD3(s.x, -1, s.y) / length, height: s.z / length, points: points.count)
}

/// The road among LiDAR points from the lower part of the picture: RANSAC (random 3-point planes, keep the one most
/// points agree with within 5 cm), refitted on those points. Nil unless it looks like a floor the camera is above:
/// 0.3–2.5 m below, facing up within 45°, and ≥ 40 points and ≥ 30% of them agreeing.
nonisolated func fitGroundPlane(_ points: [SIMD3<Double>]) -> GroundPlane? {
    guard points.count >= 40 else { return nil }
    var seed: UInt64 = 0x9E3779B97F4A7C15, best: [SIMD3<Double>] = []
    func pick() -> SIMD3<Double> {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return points[Int(seed >> 33) % points.count]
    }
    func plausible(_ g: GroundPlane) -> Bool { (0.3...2.5).contains(g.height) && -g.normal.y >= 0.7 }
    for _ in 0..<80 {
        guard let g = planeThrough([pick(), pick(), pick()]), plausible(g) else { continue }
        let inliers = points.filter { abs(simd_dot(g.normal, $0) + g.height) <= 0.05 }
        if inliers.count > best.count { best = inliers }
    }
    guard best.count >= 40, Double(best.count) >= 0.3 * Double(points.count), let g = planeThrough(best), plausible(g) else { return nil }
    return g
}

nonisolated func groundPlaneSelfCheck() {
    // Camera 1.1 m up, looking 10° down, LiDAR seeing the road 0.5–5 m away (1 cm noise) plus a wall 2 m to one side.
    let camera = CameraIntrinsics(fx: 0.95, fy: 0.71), h = 1.1, tilt = 10 * Double.pi / 180  // portrait 1× camera
    let up = SIMD3(0, -cos(tilt), -sin(tilt))
    var points: [SIMD3<Double>] = [], seed: UInt64 = 7
    func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 0.02 }
    for y in stride(from: 0.55, through: 1.0, by: 0.02) {
        for x in stride(from: 0.0, through: 1.0, by: 0.04) {
            let ray = SIMD3((x - camera.cx) / camera.fx, (y - camera.cy) / camera.fy, 1), along = simd_dot(up, ray)
            guard along < 0 else { continue }
            let p = ray * (h / -along)
            if p.z <= 5 { points.append(p + SIMD3(noise(), noise(), noise())) }
        }
    }
    let road = points.count
    for k in 0..<Int(Double(road) * 0.3) { points.append(SIMD3(2, -0.5 + Double(k % 20) * 0.08, 1 + Double(k / 20) * 0.2)) }  // the wall
    let g = fitGroundPlane(points)!
    precondition(abs(g.height - h) < 0.03 && abs(g.tilt - 10) < 1, "road: \(g.height) m below, \(g.tilt)° -> \(g)")

    // A car whose wheels touch the road 12 m away, straight behind you: find that point in the picture, read it back.
    // Looking 10° down, the picture centre meets the road 6.3 m away; 12 m is above the centre, below the horizon.
    var lo = 0.0, hi = camera.cy
    func range(_ y: Double) -> Double {
        let ray = SIMD3(0, (y - camera.cy) / camera.fy, 1), along = simd_dot(up, ray)
        return along < 0 ? h / -along * simd_length(ray) : .infinity
    }
    for _ in 0..<60 { let mid = (lo + hi) / 2; if range(mid) > 12 { lo = mid } else { hi = mid } }
    let read = g.distance(x: camera.cx, y: hi, camera: camera)!
    precondition(abs(read - 12) < 0.6, "12 m read back -> \(read)")
    precondition(g.distance(x: 0.5, y: 0.2, camera: camera) == nil, "above the horizon: never meets the road")
    precondition(fitGroundPlane(Array(points.prefix(20))) == nil, "too few points: no road")
}
