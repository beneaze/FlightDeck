// Offline check of the plane-mode estimator against synthetic flights.
//
//   swiftc -O FlightDeck/Model/PlaneModeEstimator.swift Tools/PlaneModeHarness/*.swift \
//       -o /tmp/planemode && /tmp/planemode [csvDir]
//
// Simulates the true aircraft (Euler angles, coordinated turns, turbulence as
// real aircraft motion), turns it into what a phone lying or standing on the
// tray table would measure (gyro with noise and bias; gravity; user
// acceleration; 1 Hz GPS with noise and latency), and runs the current
// estimator ("new") and the Build 8 one flown on the first real flight
// ("old", PlaneModeEstimatorV1.swift) over the same data.

import Foundation
import simd

// MARK: - Helpers

struct RNG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double {
        let u = max(1e-12, next()), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
    mutating func uniform(_ a: Double) -> Double { (next() * 2 - 1) * a }
}

func angleWrap(_ d: Double) -> Double {
    var d = d.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
func rad(_ d: Double) -> Double { d * .pi / 180 }
func deg(_ r: Double) -> Double { r * 180 / .pi }
func smoothstep(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
func ramp(_ x: Double) -> Double { min(1, max(0, x)) }

/// Body-from-NED direction cosine matrix (rows), standard aerospace order.
func dcm(_ phi: Double, _ theta: Double, _ psi: Double) -> simd_double3x3 {
    let (sf, cf, st, ct, sp, cp) = (sin(phi), cos(phi), sin(theta), cos(theta), sin(psi), cos(psi))
    return simd_double3x3(rows: [
        simd_double3(ct * cp, ct * sp, -st),
        simd_double3(sf * st * cp - cf * sp, sf * st * sp + cf * cp, sf * ct),
        simd_double3(cf * st * cp + sf * sp, cf * st * sp - sf * cp, cf * ct),
    ])
}
/// Body (x nose, y right, z down) to the cabin frame (x right, y up, z aft).
func bodyToCabin(_ v: simd_double3) -> simd_double3 { simd_double3(v.y, -v.z, -v.x) }

func rotX(_ a: Double) -> simd_double3x3 {
    simd_double3x3(rows: [simd_double3(1, 0, 0), simd_double3(0, cos(a), -sin(a)), simd_double3(0, sin(a), cos(a))])
}
func rotY(_ a: Double) -> simd_double3x3 {
    simd_double3x3(rows: [simd_double3(cos(a), 0, sin(a)), simd_double3(0, 1, 0), simd_double3(-sin(a), 0, cos(a))])
}
func rotZ(_ a: Double) -> simd_double3x3 {
    simd_double3x3(rows: [simd_double3(cos(a), -sin(a), 0), simd_double3(sin(a), cos(a), 0), simd_double3(0, 0, 1)])
}

struct Stats {
    var values: [Double] = []
    mutating func add(_ v: Double) { values.append(v) }
    var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    var rms: Double { values.isEmpty ? 0 : (values.map { $0 * $0 }.reduce(0, +) / Double(values.count)).squareRoot() }
    var maxAbs: Double { values.map(abs).max() ?? 0 }
    var peakToPeak: Double { (values.max() ?? 0) - (values.min() ?? 0) }
    var std: Double { let m = mean; return values.isEmpty ? 0 : (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(values.count)).squareRoot() }
}

func f1(_ x: Double) -> String { String(format: "%6.1f", x) }
func f2(_ x: Double) -> String { String(format: "%6.2f", x) }

// MARK: - Phone placements (device → cabin; cabin x right, y up, z aft)

/// Flat on the tray, top edge toward the nose, tray tilted 4° toward the
/// passenger and 2° to the side.
let flatBase = rotZ(rad(2)) * rotX(rad(-90 + 4))
/// `screenUp`: what the app's interface orientation says is up on the screen
/// (device coordinates) — the passenger reads the phone from behind it.
let portraitUp = simd_double3(0, 1, 0)
let placements: [(name: String, mount: simd_double3x3, screenUp: simd_double3?)] = [
    ("flat, aligned", flatBase, portraitUp),
    ("flat, 30° askew", rotY(rad(30)) * flatBase, portraitUp),
    ("flat, landscape", rotY(rad(-90)) * flatBase, simd_double3(-1, 0, 0)),
    ("flat, landscape, no hint", rotY(rad(-90)) * flatBase, nil),
    ("upright, facing pax", rotY(rad(15)) * rotX(rad(15)), portraitUp),   // leaning back 15°, 15° askew
]

// MARK: - Truth and sensors

struct Truth {
    var phi = 0.0, theta = 0.0, psi = 0.0        // deg
    var gsKts = 0.0
    var altFt = 0.0
    var vsFpm = 0.0
    /// Extra specific force from gusts, body axes, g (not in the kinematics).
    var gust = simd_double3(0, 0, 0)
    /// Direction of flight when it differs from the heading (sideslip).
    var track: Double? = nil
}

struct SensorModel {
    var gyroBias = simd_double3(0.03, -0.02, 0.05)      // deg/s, cabin axes p q r
    var gyroNoise = 0.2                                 // deg/s σ
    var courseSigma = 0.3
    var reportedCourseAccuracy = 1.0
    var altitudeNoiseFt = 15.0                          // uniform ±
    var latency = 0.6
    var staleAltitudes = false
}

struct Output {
    var roll = 0.0, pitch = 0.0, track = 0.0, alt = 0.0, vs = 0.0
    var handling = false
    var yawErr = 0.0
}

struct Sample {
    var t: Double
    var truth: Truth
    var new: Output
    var old: Output
}

/// Phone pose disturbances: extra rotation of the phone relative to the
/// cabin, as a function of time (rotation matrix applied after the nominal
/// mount, plus its angular rate in the cabin frame, deg/s).
typealias PhonePose = (Double) -> (extra: simd_double3x3, rate: simd_double3)

/// Signed error of an estimated mount's nose against the true one, about the
/// cabin's down axis, deg.
func yawError(_ est: simd_double3x3?, _ truth: simd_double3x3) -> Double {
    guard let est else { return .nan }
    let down = truth.transpose * simd_double3(0, -1, 0)
    func horizontal(_ v: simd_double3) -> simd_double3 { simd_normalize(v - simd_dot(v, down) * down) }
    let a = horizontal(truth.transpose * simd_double3(0, 0, -1))
    let b = horizontal(est.transpose * simd_double3(0, 0, -1))
    return deg(atan2(simd_dot(simd_cross(a, b), down), simd_dot(a, b)))
}

func runScenario(name: String, duration: Double, seed: UInt64, sensors: SensorModel,
                 mount mountNominal: simd_double3x3 = flatBase, screenUp: simd_double3? = portraitUp,
                 truthAt: (Double) -> Truth, phone: PhonePose? = nil,
                 gpsOutage: ClosedRange<Double>? = nil, courseOutliers: Set<Int> = [],
                 csvDir: String?) -> [Sample] {
    var rng = RNG(state: seed)
    let dt = 1.0 / 60
    let steps = Int(duration / dt) + 1
    let truths = (0..<steps).map { truthAt(Double($0) * dt) }
    var est = PlaneModeEstimator(trackDeg: truths[0].psi)
    var old = PlaneModeEstimatorV1(trackDeg: truths[0].psi)
    var gsSmoothed = truths[0].gsKts
    var gpsSpeed = truths[0].gsKts
    if truths[0].gsKts > 100 {
        // Started in flight: the app seeds altitude from its last value.
        est.seedAltitude(feet: truths[0].altFt, verticalSpeedFpm: truths[0].vsFpm)
        old.seedAltitude(feet: truths[0].altFt, verticalSpeedFpm: truths[0].vsFpm)
    }
    var pending: [(deliver: Double, t: Double, course: Double, gs: Double, alt: Double)] = []
    var lastFix = -1.0
    var fixIndex = 0
    var staleAlt = truths[0].altFt
    var samples: [Sample] = []
    samples.reserveCapacity(steps)
    var prevTruth = truths[0]
    var prevVel: simd_double3?
    var csv = "t,true_roll,new_roll,old_roll,true_pitch,new_pitch,old_pitch,true_track,new_track,old_track,true_alt,new_alt,old_alt,true_vs,new_vs,old_vs,new_handling,new_yaw_err\n"

    for i in 0..<steps {
        let t = Double(i) * dt
        let tr = truths[i]
        // Euler rates → body rates.
        let phiDot = rad(tr.phi - prevTruth.phi) / dt
        let thetaDot = rad(tr.theta - prevTruth.theta) / dt
        let psiDot = rad(angleWrap(tr.psi - prevTruth.psi)) / dt
        let (phi, theta, psi) = (rad(tr.phi), rad(tr.theta), rad(tr.psi))
        var p = phiDot - psiDot * sin(theta)
        var q = thetaDot * cos(phi) + psiDot * sin(phi) * cos(theta)
        var r = -thetaDot * sin(phi) + psiDot * cos(phi) * cos(theta)
        p += rad(sensors.gyroBias.x + sensors.gyroNoise * rng.gauss())
        q += rad(sensors.gyroBias.y + sensors.gyroNoise * rng.gauss())
        r += rad(sensors.gyroBias.z + sensors.gyroNoise * rng.gauss())
        var cabinRate = bodyToCabin(simd_double3(p, q, r))

        // Kinematic acceleration from the velocity vector.
        let v = tr.gsKts * 0.514444
        let chi = rad(tr.track ?? tr.psi)
        let vel = simd_double3(v * cos(chi), v * sin(chi), -tr.vsFpm * 0.00508)
        let accel = prevVel.map { (vel - $0) / dt } ?? .zero
        prevVel = vel
        let C = dcm(phi, theta, psi)
        // The reaction reading: minus the acceleration, minus gust forces.
        let userAccelBody = C * (-accel / 9.80665) - tr.gust
        let gravityBody = C * simd_double3(0, 0, 1)

        var mountTrue = mountNominal
        if let phone {
            let pose = phone(t)
            mountTrue = pose.extra * mountNominal
            cabinRate += pose.rate * .pi / 180
        }
        // Device = mountᵀ · cabin.
        let toDevice = mountTrue.transpose
        let rotation = toDevice * cabinRate
        let gravity = toDevice * bodyToCabin(gravityBody)
        let user = toDevice * bodyToCabin(userAccelBody)

        // GPS: sample once a second, deliver after the latency.
        if t - lastFix >= 1 - 1e-9 {
            lastFix = t
            fixIndex += 1
            let inOutage = gpsOutage.map { $0.contains(t) } ?? false
            if !inOutage {
                var course = (tr.track ?? tr.psi) + sensors.courseSigma * rng.gauss()
                if courseOutliers.contains(fixIndex) { course += 30 }
                var alt = tr.altFt + rng.uniform(sensors.altitudeNoiseFt)
                if sensors.staleAltitudes {
                    if fixIndex % 3 == 0 { staleAlt = alt } else { alt = staleAlt }
                }
                pending.append((t + sensors.latency, t, course, max(0, tr.gsKts + 0.3 * rng.gauss()), alt))
            }
        }
        while let fix = pending.first, fix.deliver <= t {
            pending.removeFirst()
            gpsSpeed = fix.gs
            let course = (fix.course.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            est.gpsCourse(course, accuracyDeg: sensors.reportedCourseAccuracy, speedKts: fix.gs, time: fix.t)
            est.gpsAltitude(feet: fix.alt, accuracyFt: 30, time: fix.t, now: t)
            old.gpsCourse(course, accuracyDeg: sensors.reportedCourseAccuracy, speedKts: fix.gs, time: fix.t)
            old.gpsAltitude(feet: fix.alt, accuracyFt: 30, time: fix.t, now: t)
        }
        gsSmoothed += (gpsSpeed - gsSmoothed) * -expm1(-dt / 0.8)

        est.screenUp(screenUp)
        est.step(dt: dt, time: t, motion: .init(rotationRate: rotation, gravity: gravity, userAcceleration: user),
                 groundSpeedKts: gsSmoothed)
        old.step(dt: dt, time: t, motion: .init(rotationRate: rotation, gravity: gravity, userAcceleration: user),
                 groundSpeedKts: gsSmoothed)

        let s = Sample(t: t, truth: tr,
                       new: Output(roll: est.rollDeg, pitch: est.pitchDeg, track: est.trackDeg, alt: est.altitudeFt,
                                   vs: est.verticalSpeedFpm, handling: est.isHandling,
                                   yawErr: yawError(est.mount, mountTrue)),
                       old: Output(roll: old.rollDeg, pitch: old.pitchDeg, track: old.trackDeg, alt: old.altitudeFt,
                                   vs: old.verticalSpeedFpm, handling: old.isHandling,
                                   yawErr: yawError(old.mount, mountTrue)))
        samples.append(s)
        if csvDir != nil {
            csv += [t, tr.phi, s.new.roll, s.old.roll, tr.theta, s.new.pitch, s.old.pitch,
                    tr.psi, s.new.track, s.old.track, tr.altFt, s.new.alt, s.old.alt,
                    tr.vsFpm, s.new.vs, s.old.vs, s.new.handling ? 1 : 0, s.new.yawErr]
                .map { String(format: "%.3f", $0) }.joined(separator: ",") + "\n"
        }
        prevTruth = tr
    }
    if let csvDir {
        try? csv.write(toFile: "\(csvDir)/\(name).csv", atomically: true, encoding: .utf8)
    }
    return samples
}

func window(_ s: [Sample], _ range: ClosedRange<Double>) -> [Sample] { s.filter { range.contains($0.t) } }

func firstTime(_ s: [Sample], after t0: Double, where cond: (Sample) -> Bool) -> Double? {
    s.first { $0.t >= t0 && cond($0) }?.t
}

/// The earliest time after which `cond` holds for the rest of the run.
func settledTime(_ s: [Sample], after t0: Double, where cond: (Sample) -> Bool) -> Double? {
    var result: Double?
    for x in s where x.t >= t0 {
        if cond(x) { if result == nil { result = x.t } } else { result = nil }
    }
    return result
}

/// Delay (s) of `y` behind `x` that maximises their cross-correlation, and
/// the correlation coefficient there.
func lag(_ x: [Double], _ y: [Double], dt: Double, maxLag: Double = 6) -> (delay: Double, corr: Double) {
    let n = min(x.count, y.count)
    let mx = x.prefix(n).reduce(0, +) / Double(n), my = y.prefix(n).reduce(0, +) / Double(n)
    let xc = x.prefix(n).map { $0 - mx }, yc = y.prefix(n).map { $0 - my }
    let kMax = Int(maxLag / dt), kMin = -Int(1 / dt)
    var best = (k: 0, c: -Double.infinity)
    for k in kMin...kMax {
        var c = 0.0, sx = 0.0, sy = 0.0
        for i in max(0, -k)..<min(n, n - k) {
            c += xc[i] * yc[i + k]; sx += xc[i] * xc[i]; sy += yc[i + k] * yc[i + k]
        }
        let r = c / max(1e-12, (sx * sy).squareRoot())
        if r > best.c { best = (k, r) }
    }
    return (Double(best.k) * dt, best.c)
}

/// First-order high-pass, τ seconds.
func highPass(_ v: [Double], dt: Double, time: Double) -> [Double] {
    var slow = v.first ?? 0
    return v.map { x in slow += (x - slow) * -expm1(-dt / time); return x - slow }
}

let csvDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let dt = 1.0 / 60

// MARK: - Turbulence as real aircraft motion

/// Sum of sines, amplitudes ∝ 1/f (rates roughly equal per component),
/// scaled so the amplitudes add up to `peak`.
struct Series {
    var parts: [(f: Double, a: Double, phase: Double)]
    init(peak: Double, freqs: [Double], rng: inout RNG) {
        let norm = freqs.map { 1 / $0 }.reduce(0, +)
        parts = freqs.map { ($0, peak / ($0 * norm), rng.next() * 2 * .pi) }
    }
    func callAsFunction(_ t: Double) -> Double { parts.reduce(0) { $0 + $1.a * sin(2 * .pi * $1.f * t + $1.phase) } }
}

struct Turbulence {
    var name: String
    var roll, pitch, yaw, vertical, lateral: Series
    init(name: String, rollPeak: Double, pitchPeak: Double, gustG: Double, seed: UInt64) {
        self.name = name
        var rng = RNG(state: seed)
        roll = Series(peak: rollPeak, freqs: [0.3, 0.55, 1.0, 1.9], rng: &rng)
        pitch = Series(peak: pitchPeak, freqs: [0.35, 0.7, 1.3, 2.0], rng: &rng)
        yaw = Series(peak: rollPeak * 0.15, freqs: [0.25, 0.6, 1.1], rng: &rng)     // deg/s of yaw rate
        vertical = Series(peak: gustG, freqs: [0.5, 0.9, 1.6], rng: &rng)
        lateral = Series(peak: gustG * 0.25, freqs: [0.4, 0.8, 1.5], rng: &rng)
    }
}

let turbulenceLevels: [Turbulence?] = [
    nil,
    Turbulence(name: "light", rollPeak: 2, pitchPeak: 1, gustG: 0.08, seed: 11),
    Turbulence(name: "moderate", rollPeak: 5, pitchPeak: 2, gustG: 0.2, seed: 12),
]

// MARK: - Manoeuvre block (times relative to its start)
//
//   0–20 straight · 20–25 roll right to 25° at 5°/s · hold · 55–60 roll out
//   · 90–92.5 pitch +5° at 2°/s · hold · 112.5–115 back · 130–135 roll left
//   to 25° · hold · 165–170 roll out · straight to 190.

let blockLength = 190.0
func blockBank(_ τ: Double) -> Double {
    25 * (ramp((τ - 20) / 5) - ramp((τ - 55) / 5)) - 25 * (ramp((τ - 130) / 5) - ramp((τ - 165) / 5))
}
func blockPitch(_ τ: Double) -> Double { 5 * (ramp((τ - 90) / 2.5) - ramp((τ - 112.5) / 2.5)) }
let rollWindows: [ClosedRange<Double>] = [20...28, 55...63, 130...138, 165...173]

/// The estimator's own angle-of-attack model, less 0.3° — so the pitch
/// reference is slightly wrong, as it will be in reality.
func trueAoA(_ v: Double) -> Double { 6 - 3.5 * min(1, max(0, (v - 150) / 150)) - 0.3 }

enum Profile { case takeoff, cruise }

/// A stateful truth generator (must be called with increasing t).
func flight(_ profile: Profile, turbulence: Turbulence?) -> (truth: (Double) -> Truth, blockStart: Double, duration: Double) {
    let blockStart = profile == .takeoff ? 160.0 : 240.0
    var psi = 75.0, sideslip = 0.0, alt = profile == .takeoff ? 1_200.0 : 35_000.0, gamma = 0.0, lastT = 0.0
    let truth: (Double) -> Truth = { t in
        let gs: Double, thetaBase: Double, airborne: Bool
        switch profile {
        case .takeoff:
            gs = t < 15 ? 0 : t < 50 ? (t - 15) * 150 / 35 : t < 130 ? 150 + (t - 50) * 100 / 80 : 250
            thetaBase = t < 50 ? 0 : t < 55 ? 12 * (t - 50) / 5 : t < 130 ? 12 : t < 138 ? 12 - (t - 130) : 4
            airborne = t > 52
        case .cruise:
            gs = 450; thetaBase = trueAoA(450); airborne = true
        }
        let τ = t - blockStart
        let turbScale = profile == .takeoff ? ramp((t - 60) / 10) : 1
        var phi = blockBank(τ), theta = thetaBase + blockPitch(τ)
        var yawTurb = 0.0
        var gust = simd_double3(0, 0, 0)
        if let turbulence, airborne {
            phi += turbScale * turbulence.roll(t)
            theta += turbScale * turbulence.pitch(t)
            yawTurb = turbScale * turbulence.yaw(t)
            gust = turbScale * simd_double3(0, turbulence.lateral(t), turbulence.vertical(t))
        }
        let step = max(0, t - lastT)
        lastT = max(lastT, t)
        let v = max(1, gs * 0.514444)
        if airborne {
            // The flight path follows pitch less AoA with 2 s lag; the track
            // follows bank (coordinated); turbulent yaw swings the nose about
            // it (sideslip, weathercocked back within seconds).
            gamma += (theta - trueAoA(gs) - gamma) * -expm1(-step / 2)
            psi += deg(9.80665 * tan(rad(phi)) / v) * step
            sideslip += (yawTurb - sideslip / 3) * step
        }
        let vs = airborne ? v * sin(rad(gamma)) / 0.00508 : 0
        alt += vs / 60 * step
        return Truth(phi: phi, theta: theta, psi: psi + sideslip, gsKts: gs, altFt: alt, vsFpm: vs,
                     gust: gust, track: psi)
    }
    return (truth, blockStart, blockStart + blockLength)
}

// MARK: - Metrics

struct BlockMetrics {
    var rollLag = 0.0, rollTurbLag = 0.0, rollTurbCorr = 0.0
    var pitchLag = 0.0, pitchTurbLag = 0.0, pitchTurbCorr = 0.0
    var coupling = 0.0          // max pitch-error change during the pure rolls
    var bankErrRight = 0.0, bankErrLeft = 0.0
    var rollRmsStraight = 0.0, pitchRms = 0.0
    var rollMax = 0.0, pitchMax = 0.0
}

func metrics(_ s: [Sample], blockStart b: Double, new: Bool) -> BlockMetrics {
    func out(_ x: Sample) -> Output { new ? x.new : x.old }
    var m = BlockMetrics()
    let block = window(s, b...(b + blockLength))
    let tr = block.map { $0.truth.phi }, er = block.map { out($0).roll }
    m.rollLag = lag(tr, er, dt: dt).delay
    let rt = lag(highPass(tr, dt: dt, time: 1), highPass(er, dt: dt, time: 1), dt: dt)
    (m.rollTurbLag, m.rollTurbCorr) = (rt.delay, rt.corr)
    let pw = window(s, (b + 80)...(b + 125))
    m.pitchLag = lag(pw.map { $0.truth.theta }, pw.map { out($0).pitch }, dt: dt).delay
    let tp = block.map { $0.truth.theta }, ep = block.map { out($0).pitch }
    let pt = lag(highPass(tp, dt: dt, time: 1), highPass(ep, dt: dt, time: 1), dt: dt)
    (m.pitchTurbLag, m.pitchTurbCorr) = (pt.delay, pt.corr)
    for w in rollWindows {
        let ws = window(s, (b + w.lowerBound)...(b + w.upperBound))
        guard let first = ws.first else { continue }
        let e0 = out(first).pitch - first.truth.theta
        for x in ws { m.coupling = max(m.coupling, abs(out(x).pitch - x.truth.theta - e0)) }
    }
    var right = Stats(), left = Stats(), straight = Stats(), pitch = Stats(), rollAll = Stats()
    for x in window(s, (b + 35)...(b + 55)) { right.add(out(x).roll - x.truth.phi) }
    for x in window(s, (b + 145)...(b + 165)) { left.add(out(x).roll - x.truth.phi) }
    for x in window(s, b...(b + 20)) + window(s, (b + 65)...(b + 90)) + window(s, (b + 175)...(b + 190)) {
        straight.add(out(x).roll - x.truth.phi)
    }
    for x in block { pitch.add(out(x).pitch - x.truth.theta); rollAll.add(out(x).roll - x.truth.phi) }
    m.bankErrRight = right.mean; m.bankErrLeft = left.mean
    m.rollRmsStraight = straight.rms; m.pitchRms = pitch.rms
    m.rollMax = rollAll.maxAbs; m.pitchMax = pitch.maxAbs
    return m
}

func printMetricsHeader() {
    print("  est  yaw-learn  yawErr | lag roll/turb(corr)  lag pitch/turb(corr) | r→p coupl | bank err R/L | roll rms str | pitch rms | max roll/pitch err | handl")
}

func printMetrics(_ label: String, _ m: BlockMetrics, learn: String, yawErr: Double, handling: Double) {
    print(String(format: "  %@  %9@  %6.1f | %5.2f / %5.2f (%.2f)   %5.2f / %5.2f (%.2f)  | %8.2f° | %5.1f / %5.1f | %10.2f° | %8.2f° | %7.1f / %5.1f | %4.1fs",
                 label, learn, yawErr, m.rollLag, m.rollTurbLag, m.rollTurbCorr, m.pitchLag, m.pitchTurbLag,
                 m.pitchTurbCorr, m.coupling, m.bankErrRight, m.bankErrLeft, m.rollRmsStraight, m.pitchRms,
                 m.rollMax, m.pitchMax, handling))
}

// MARK: - 1–4: phone placements × turbulence × take-off / cruise start

print("=== Attitude: 5 phone placements × calm / light / moderate turbulence (real aircraft motion)")
print("    take-off: 15 s parked, take-off roll 0→150 kt in 35 s, rotation 12° at 2.4°/s, climb, level off at 138 s,")
print("              manoeuvre block from 160 s at 250 kt. cruise: 450 kt, phone placed at 0 s, block from 240 s.")
print("    block: 25° roll right at 5°/s, hold 30 s, out; +5° pitch at 2°/s, hold 20 s, back; 25° roll left, hold, out.")
print("    lag: cross-correlation delay (s), manoeuvre signal / 1 s high-passed (turbulence) signal (correlation).")
print("    r→p coupl: largest change of the pitch error during the four roll-ins/-outs. yaw-learn: time from the")
print("    start of the take-off roll (take-off) or from placement (cruise) until the yaw stays within 5°.")
var summary: [(String, BlockMetrics, BlockMetrics, String, Double)] = []
for profile in [Profile.takeoff, .cruise] {
    for placement in placements {
        for turbulence in turbulenceLevels {
            let f = flight(profile, turbulence: turbulence)
            let name = "\(profile)_\(placement.name)_\(turbulence?.name ?? "calm")"
            let s = runScenario(name: name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ",", with: ""),
                                duration: f.duration, seed: 7, sensors: SensorModel(), mount: placement.mount,
                                screenUp: placement.screenUp,
                                truthAt: f.truth, csvDir: csvDir)
            let origin = profile == .takeoff ? 15.0 : 0.0
            let learnT = settledTime(s, after: 0) { abs($0.new.yawErr) < 5 }
            let learn = learnT.map { String(format: "%6.1f s", max(0, $0 - origin)) } ?? "    never"
            let finalNew = abs(s.last!.new.yawErr), finalOld = abs(s.last!.old.yawErr)
            let hNew = Double(s.filter { $0.new.handling }.count) * dt
            let hOld = Double(s.filter { $0.old.handling }.count) * dt
            let mNew = metrics(s, blockStart: f.blockStart, new: true)
            let mOld = metrics(s, blockStart: f.blockStart, new: false)
            print("\n-- \(profile), \(placement.name), \(turbulence?.name ?? "calm")")
            printMetricsHeader()
            printMetrics("new", mNew, learn: learn, yawErr: finalNew, handling: hNew)
            printMetrics("old", mOld, learn: "        -", yawErr: finalOld, handling: hOld)
            summary.append(("\(profile), \(placement.name), \(turbulence?.name ?? "calm")", mNew, mOld, learn, finalNew))
        }
    }
}

// MARK: - 5: handled in flight

do {
    print("\n=== Handled: cruise 450 kt, light turbulence, phone flat 30° askew; block at 40 s; picked up at 250 s,")
    print("    waved ±20° for 8 s, set down turned another 40° on the tray (258–260 s) while the aircraft rolls")
    print("    into a 15° left bank at 3°/s (252 s), holds it to 290 s; second block from 320 s")
    let turbulence = turbulenceLevels[1]!
    var rng = RNG(state: 5)
    let roll = Series(peak: 2, freqs: [0.3, 0.55, 1.0, 1.9], rng: &rng)
    let pitchT = Series(peak: 1, freqs: [0.35, 0.7, 1.3, 2.0], rng: &rng)
    _ = turbulence
    var psi = 75.0, lastT = 0.0, gamma = 0.0, alt = 35_000.0
    func bank(_ t: Double) -> Double {
        blockBank(t - 40) + blockBank(t - 320) - 15 * (ramp((t - 252) / 5) - ramp((t - 290) / 5))
    }
    let truth: (Double) -> Truth = { t in
        let phi = bank(t) + roll(t)
        let theta = trueAoA(450) + blockPitch(t - 40) + blockPitch(t - 320) + pitchT(t)
        let step = max(0, t - lastT)
        psi += deg(9.80665 * tan(rad(phi)) / (450 * 0.514444)) * step
        gamma += (theta - trueAoA(450) - gamma) * -expm1(-step / 2)
        let vs = 450 * 0.514444 * sin(rad(gamma)) / 0.00508
        alt += vs / 60 * step
        lastT = max(lastT, t)
        return Truth(phi: phi, theta: theta, psi: psi, gsKts: 450, altFt: alt, vsFpm: vs)
    }
    let phone: PhonePose = { t in
        guard t > 250 else { return (matrix_identity_double3x3, .zero) }
        let wobble = t < 258 ? 20 * sin(2 * .pi * 0.7 * (t - 250)) : 0
        let wobbleRate = t < 258 ? 20 * 2 * .pi * 0.7 * cos(2 * .pi * 0.7 * (t - 250)) : 0
        let yaw = 40 * smoothstep((t - 258) / 2)
        let x = (t - 258) / 2
        let yawRate = (t > 258 && t < 260) ? 40 * 6 * x * (1 - x) / 2 : 0
        let extra = rotY(rad(yaw)) * rotX(rad(wobble))
        let rate = simd_double3(0, yawRate, 0) + rotY(rad(yaw)) * simd_double3(wobbleRate, 0, 0)
        return (extra, rate)
    }
    let s = runScenario(name: "E_handled", duration: 510, seed: 9, sensors: SensorModel(),
                        mount: placements[1].mount, screenUp: portraitUp, truthAt: truth, phone: phone, csvDir: csvDir)
    var rn = Stats(), ro = Stats(), pn = Stats(), po = Stats()
    for x in window(s, 250...265) {
        rn.add(x.new.roll - x.truth.phi); ro.add(x.old.roll - x.truth.phi)
        pn.add(x.new.pitch - x.truth.theta); po.add(x.old.pitch - x.truth.theta)
    }
    let detect = firstTime(s, after: 250) { $0.new.handling }
    let settle = firstTime(s, after: 258) { !$0.new.handling }
    print(String(format: "  handling detected %.2f s after the pick-up; at rest again (mount re-learnt) at %.1f s",
                 (detect ?? .nan) - 250, settle ?? .nan))
    print(String(format: "  250–265 s attitude error: new roll max %.1f° rms %.1f°, pitch max %.1f° | old roll max %.1f°, pitch max %.1f°",
                 rn.maxAbs, rn.rms, pn.maxAbs, ro.maxAbs, po.maxAbs))
    if let settle, let after = s.first(where: { $0.t >= settle + 0.1 }) {
        print(String(format: "  yaw error right after setting down: new %.1f° (carried through the handling) | old %.1f°",
                     after.new.yawErr, after.old.yawErr))
    }
    let relearn = settledTime(s, after: 258) { abs($0.new.yawErr) < 5 }
    print(String(format: "  yaw within 5° for good from %.1f s; false handling outside 250–262 s: new %.1f s, old %.1f s",
                 relearn ?? .nan,
                 Double(s.filter { $0.new.handling && !(250...262).contains($0.t) }.count) * dt,
                 Double(s.filter { $0.old.handling && !(250...262).contains($0.t) }.count) * dt))
    print("  second block (after the re-placement):")
    printMetricsHeader()
    printMetrics("new", metrics(s, blockStart: 320, new: true), learn: "        -", yawErr: abs(s.last!.new.yawErr),
                 handling: Double(s.filter { $0.new.handling }.count) * dt)
    printMetrics("old", metrics(s, blockStart: 320, new: false), learn: "        -", yawErr: abs(s.last!.old.yawErr),
                 handling: Double(s.filter { $0.old.handling }.count) * dt)
}

// MARK: - B: long straight flight — course noise, bias, outage, phone moved

do {
    print("\n=== B: 10 min straight at 450 kt, GPS course σ 0.5° (+3 wild fixes 30° off),")
    print("        gyro yaw bias 0.1°/s, GPS outage 200–260 s, phone turned 60° on the tray at 400 s,")
    print("        picked up and handled 450–460 s, set down tilted")
    var sensors = SensorModel()
    sensors.gyroBias = simd_double3(0.05, -0.05, 0.1)
    sensors.courseSigma = 0.5
    sensors.reportedCourseAccuracy = 2
    let truth: (Double) -> Truth = { _ in Truth(phi: 0, theta: 2.5, psi: 270, gsKts: 450, altFt: 37_000, vsFpm: 0) }
    let phone: PhonePose = { t in
        var extra = matrix_identity_double3x3
        var rate = simd_double3.zero
        // Turned 60° about the floor normal (cabin y), 400–402 s.
        let yaw = 60 * smoothstep((t - 400) / 2)
        let yawRate = (t > 400 && t < 402) ? 60 * 6 * ((t - 400) / 2) * (1 - (t - 400) / 2) / 2 : 0
        extra = rotY(rad(yaw))
        rate.y += yawRate
        // Handheld 450–460 s: wobbling ±20° at 0.7 Hz about the cabin x axis,
        // then set down 8° steeper.
        if t > 450 {
            let wobble = t < 460 ? 20 * sin(2 * .pi * 0.7 * (t - 450)) : 0
            let tilt = 8 * smoothstep((t - 458) / 2)
            let a = rad(wobble + tilt)
            extra = rotX(a) * extra
            rate.x += t < 460 ? 20 * 2 * .pi * 0.7 * cos(2 * .pi * 0.7 * (t - 450)) : 0
            rate.x += (t > 458 && t < 460) ? 8 * 6 * ((t - 458) / 2) * (1 - (t - 458) / 2) / 2 : 0
        }
        return (extra, rate)
    }
    let s = runScenario(name: "B_straight_drift", duration: 600, seed: 2, sensors: sensors, truthAt: truth,
                        phone: phone, gpsOutage: 200...260, courseOutliers: [100, 150, 330], csvDir: csvDir)
    func report(_ label: String, _ r: ClosedRange<Double>) {
        var n = Stats(), o = Stats(), rn = Stats(), ro = Stats(), yn = Stats(), yo = Stats()
        for x in window(s, r) {
            n.add(angleWrap(x.new.track - 270)); o.add(angleWrap(x.old.track - 270))
            rn.add(x.new.roll); ro.add(x.old.roll)
            yn.add(x.new.yawErr); yo.add(x.old.yawErr)
        }
        print(label, "track err new rms", f2(n.rms), "max", f2(n.maxAbs), "| old rms", f2(o.rms), "max", f2(o.maxAbs),
              "|| roll new max", f1(rn.maxAbs), "old max", f1(ro.maxAbs), "|| yaw err new max", f1(yn.maxAbs), "old", f1(yo.maxAbs))
    }
    report("  steady 30–199 s       ", 30...199)
    report("  GPS outage 200–260 s  ", 200...260)
    report("  after outage 261–399 s", 261...399)
    report("  phone turned 403–449 s", 403...449)
    report("  handled 450–470 s     ", 450...470)
    report("  after 470–600 s       ", 470...600)
    let handlingNew = Double(window(s, 0...600).filter { $0.new.handling }.count) * dt
    let handlingOld = Double(window(s, 0...600).filter { $0.old.handling }.count) * dt
    print(String(format: "  handling detected for %.1f s in total (old %.1f s)", handlingNew, handlingOld))
}

// MARK: - C: taxi turn 90° in 6 s, then stop; phone moved at the gate

do {
    print("\n=== C: taxi 15 kt, 90° right turn in 6 s, stop, phone turned 45° while parked")
    var sensors = SensorModel()
    sensors.courseSigma = 2.2
    sensors.reportedCourseAccuracy = 3
    sensors.altitudeNoiseFt = 15
    func heading(_ t: Double) -> Double { 10 + 90 * smoothstep((t - 10) / 6) }
    func speed(_ t: Double) -> Double { t < 26 ? 15 : max(0, 15 * (1 - (t - 26) / 5)) }
    let truth: (Double) -> Truth = { t in Truth(phi: 0, theta: 0, psi: heading(t), gsKts: speed(t), altFt: 20, vsFpm: 0) }
    let phone: PhonePose = { t in
        let yaw = 45 * smoothstep((t - 40) / 1.5)
        let rate = (t > 40 && t < 41.5) ? 45 * 6 * ((t - 40) / 1.5) * (1 - (t - 40) / 1.5) / 1.5 : 0
        return (rotY(rad(yaw)), simd_double3(0, rate, 0))
    }
    let s = runScenario(name: "C_taxi", duration: 60, seed: 3, sensors: sensors, truthAt: truth, phone: phone, csvDir: csvDir)
    var turnNew = Stats(), turnOld = Stats()
    for x in window(s, 10...20) {
        turnNew.add(angleWrap(x.new.track - x.truth.psi)); turnOld.add(angleWrap(x.old.track - x.truth.psi))
    }
    print("  error during the turn: new max", f2(turnNew.maxAbs), "rms", f2(turnNew.rms),
          "| old max", f2(turnOld.maxAbs), "rms", f2(turnOld.rms))
    let settle = firstTime(s, after: 16) { abs(angleWrap($0.new.track - 100)) < 2 }!
    print(String(format: "  new within 2° of 100° at %.2f s after the turn ends", settle - 16))
    let parkedNew = window(s, 32...60).map { angleWrap($0.new.track - 100) }
    let parkedOld = window(s, 32...60).map { angleWrap($0.old.track - 100) }
    print(String(format: "  parked 32–60 s, phone turned 45° at 40 s: heading moved new %.2f°, old %.2f°",
                 (parkedNew.max() ?? 0) - (parkedNew.min() ?? 0), (parkedOld.max() ?? 0) - (parkedOld.min() ?? 0)))
    print(String(format: "  yaw error at 60 s: new %.1f°, old %.1f° (learnt from the braking at 26–31 s, carried through the turn)",
                 s.last!.new.yawErr, s.last!.old.yawErr))
}

// MARK: - D: climb at 2500 fpm

func climbScenario(stale: Bool) {
    print(stale ? "\n=== D2: same climb, GPS repeating the last altitude on 2 fixes out of 3"
                : "\n=== D: level 5000 ft, climb 2500 fpm (onset 3 s), level off at ~10000 ft; GPS ±15 ft, 1 Hz, 0.6 s latency")
    var sensors = SensorModel()
    sensors.staleAltitudes = stale
    func vs(_ t: Double) -> Double {
        if t < 30 { return 0 }
        if t < 150 { return 2500 * smoothstep((t - 30) / 3) }
        return 2500 * (1 - smoothstep((t - 150) / 5))
    }
    var alt = 5_000.0, lastT = 0.0
    let truth: (Double) -> Truth = { t in
        if t > lastT { alt += vs(t) / 60 * (t - lastT); lastT = t }
        return Truth(phi: 0, theta: 4, psi: 45, gsKts: 250, altFt: alt, vsFpm: vs(t))
    }
    let s = runScenario(name: stale ? "D2_climb_stale" : "D_climb", duration: 210, seed: 4,
                        sensors: sensors, truthAt: truth, csvDir: csvDir)
    for (label, r) in [("climb 45–148 s", 45.0...148.0), ("level 175–210 s", 175.0...210.0)] {
        var an = Stats(), ao = Stats(), vn = Stats(), vo = Stats()
        for b in window(s, r) {
            an.add(b.new.alt - b.truth.altFt); ao.add(b.old.alt - b.truth.altFt)
            vn.add(b.new.vs - b.truth.vsFpm); vo.add(b.old.vs - b.truth.vsFpm)
        }
        print("  \(label): alt err new rms", f1(an.rms), "max", f1(an.maxAbs), "ft | old rms", f1(ao.rms), "max", f1(ao.maxAbs))
        print("        V/S err new rms", f1(vn.rms), "max", f1(vn.maxAbs), "fpm | old rms", f1(vo.rms), "max", f1(vo.maxAbs))
    }
}
climbScenario(stale: false)
climbScenario(stale: true)

// MARK: - Summary

print("\n=== Summary (new vs old): roll lag s, turbulence corr, roll→pitch coupling °, max roll / pitch error °")
for (label, n, o, learn, yaw) in summary {
    print(String(format: "  %-44@ lag %4.2f|%4.2f  corr %4.2f|%4.2f  coupl %5.2f|%5.2f  max %4.1f/%4.1f | %4.1f/%4.1f  yaw %@ (%.1f°)",
                 label, n.rollLag, o.rollLag, n.rollTurbCorr, o.rollTurbCorr, n.coupling, o.coupling,
                 n.rollMax, n.pitchMax, o.rollMax, o.pitchMax, learn, yaw))
}
