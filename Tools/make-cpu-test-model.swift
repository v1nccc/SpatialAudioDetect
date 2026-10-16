import AVFoundation
import CreateML

// Builds SpatialAudioDetect/SoundRadarCPUTest.mlmodel: a throwaway model (siren / car_horn / background) trained on
// synthetic sounds, only to test whether a CPU-only model keeps running in the background. From the project folder:
//
//   swiftc -O Tools/make-cpu-test-model.swift -o /tmp/make-model && /tmp/make-model /tmp/cpu-model
//   cp /tmp/cpu-model/SoundRadarCPUTest.mlmodel SpatialAudioDetect/
//
// ponytail: synthetic data only; a real model needs recorded sirens, horns and street audio in the same folders.
let fs = 16000.0, clip = 2.0, n = Int(fs * clip), perClass = 120
let root = URL(fileURLWithPath: CommandLine.arguments[1])
struct Rng { var s: UInt64; mutating func u() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
             mutating func r(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() } }
var rng = Rng(s: 42)

func background() -> [Double] {
    var out = [Double](repeating: 0, count: n), a = 0.0, b = 0.0, brown = 0.0
    let kind = Int(rng.u() * 8), hum = rng.r(30, 90), blip = rng.r(300, 2500)
    var pink = [Double](repeating: 0, count: 3)
    for i in 0..<n {
        let t = Double(i) / fs, w = rng.u() * 2 - 1
        a += 0.3 * (w - a); b += 0.03 * (w - b); brown = 0.995 * brown + 0.05 * w
        switch kind {
        case 0: out[i] = a - b                                                        // street-ish band noise
        case 1: out[i] = brown * 3                                                    // rumble / wind
        case 2: out[i] = (a - b) * (0.3 + 0.7 * abs(sin(t * .pi * rng.r(2.5, 4.5))))  // chatter rhythm
        case 3: out[i] = (1...6).map { sin(2 * .pi * hum * Double($0) * t) / Double($0) }.reduce(0, +) * 0.3 + 0.3 * (a - b)  // engine
        case 4: out[i] = 0.4 * (a - b) + (Int(t * 3) % 3 == 0 ? 0.3 * sin(2 * .pi * blip * t) : 0)  // beeps, birds, phones
        case 5: out[i] = w                                                            // hiss (mic noise, wind on the mic)
        case 6:                                                                       // pink-ish noise (rain, crowd)
            pink[0] = 0.99 * pink[0] + 0.1 * w; pink[1] = 0.9 * pink[1] + 0.3 * w; pink[2] = 0.5 * pink[2] + 0.5 * w
            out[i] = pink[0] + pink[1] + pink[2]
        default: out[i] = 0.02 * w + 0.5 * brown                                      // quiet street
        }
    }
    return out
}
func tone(_ f: (Double) -> Double, duration: ClosedRange<Double>? = nil) -> [Double] {
    var phase = 0.0, out = [Double](repeating: 0, count: n)
    let bright = rng.r(0.3, 1)
    for i in 0..<n {
        let t = Double(i) / fs
        phase += f(t) / fs
        if let d = duration, !d.contains(t) { continue }
        let saw = 2 * (phase - (phase + 0.5).rounded(.down)), sine = sin(2 * .pi * phase)
        out[i] = bright * saw + (1 - bright) * sine
    }
    return out
}
func siren() -> [Double] {
    switch Int(rng.u() * 3) {
    case 0:  // hi-lo
        let f1 = rng.r(550, 800), f2 = f1 * rng.r(1.25, 1.45), half = rng.r(0.35, 0.7), off = rng.r(0, 1)
        return tone { Int(($0 + off) / half) % 2 == 0 ? f1 : f2 }
    case 1:  // wail
        let fc = rng.r(700, 1100), a = rng.r(200, 450), p = rng.r(2, 5), ph = rng.r(0, 6.28)
        return tone { fc + a * sin(2 * .pi * $0 / p + ph) }
    default: // yelp
        let fc = rng.r(800, 1200), a = rng.r(250, 450), p = rng.r(0.15, 0.35)
        return tone { fc + a * sin(2 * .pi * $0 / p) }
    }
}
func horn() -> [Double] {
    let f1 = rng.r(330, 470), f2 = f1 * rng.r(1.18, 1.3), start = rng.r(0, 0.6), len = rng.r(0.3, 1.3)
    let a = tone({ _ in f1 }, duration: start...(start + len)), b = tone({ _ in f2 }, duration: start...(start + len))
    return zip(a, b).map { $0 + $1 }
}
func mix(_ s: [Double], _ bg: [Double]) -> [Double] {
    let rms = { (x: [Double]) in (x.map { $0 * $0 }.reduce(0, +) / Double(x.count)).squareRoot() + 1e-9 }
    let snr = rng.r(-3, 15), g = rms(s) / rms(bg) / pow(10, snr / 20)
    return zip(s, bg).map { $0 + g * $1 }
}
func write(_ x: [Double], _ url: URL) throws {
    let peak = max(x.map(abs).max() ?? 1, 1e-9), gain = rng.r(0.2, 0.9) / peak
    let f = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { buf.floatChannelData![0][i] = Float(x[i] * gain) }
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fs, AVNumberOfChannelsKey: 1,
                                                          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
    try file.write(from: buf)
}
let data = root.appending(path: "data")
try? FileManager.default.removeItem(at: data)  // fresh set each run
for (label, make) in [("siren", { mix(siren(), background()) }), ("car_horn", { mix(horn(), background()) }), ("background", { background() })] {
    let dir = data.appending(path: label)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for k in 0..<perClass { try write(make(), dir.appending(path: "\(label)-\(k).wav")) }
}
print("wrote \(3 * perClass) clips; training…")
let model = try MLSoundClassifier(trainingData: .labeledDirectories(at: data))
print(String(format: "training accuracy %.1f%%, validation accuracy %.1f%%",
             (1 - model.trainingMetrics.classificationError) * 100, (1 - model.validationMetrics.classificationError) * 100))
try model.write(to: root.appending(path: "SoundRadarCPUTest.mlmodel"),
                metadata: MLModelMetadata(author: "Sound Radar", shortDescription: "Throwaway test: can a CPU-only sound model run in the background? Trained on synthetic sirens, horns and street noise.", version: "0.1"))
print("model written")
