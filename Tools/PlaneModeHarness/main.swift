// Offline check of the plane-mode estimator against synthetic flights.
//
//   swiftc -O FlightDeck/Model/PlaneModeEstimator.swift \
//       Tools/PlaneModeHarness/main.swift -o /tmp/planemode && /tmp/planemode [csvDir]
//
// Simulates the true aircraft (Euler angles, coordinated turns), turns it into
// what a phone resting on a tray table would measure (gyro with turbulence,
// noise and bias; gravity; user acceleration; 1 Hz GPS with noise and
// latency), and runs both the new estimator and a replica of the previous
// plane-mode math over the same data.

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

// MARK: - Truth and sensors

struct Truth {
    var phi = 0.0, theta = 0.0, psi = 0.0        // deg
    var gsKts = 0.0
    var altFt = 0.0
    var vsFpm = 0.0
}

struct SensorModel {
    var turbulence = false
    var gyroBias = simd_double3(0.03, -0.02, 0.05)      // deg/s, cabin axes p q r
    var gyroNoise = 0.2                                 // deg/s σ
    var courseSigma = 0.3
    var reportedCourseAccuracy = 1.0
    var altitudeNoiseFt = 15.0                          // uniform ±
    var latency = 0.6
    var staleAltitudes = false
}

/// The previous plane-mode math (FlightDataModel before this change),
/// replicated for comparison.
struct OldModel {
    var turnRateSmoothed = 0.0
    var track = 0.0, trackAnchor: Double? = nil
    var vsTarget = 0.0, vs = 0.0
    var alt = 0.0, altAnchor: Double? = nil
    var lastAlt: (t: Double, ft: Double)? = nil
    var roll = 0.0, pitch = 0.0

    mutating func step(dt: Double, yawRateDeg: Double, gsKts: Double) {
        turnRateSmoothed += (yawRateDeg - turnRateSmoothed) * -expm1(-dt / 1.5)
        vs += (vsTarget - vs) * -expm1(-dt / 0.8)
        if gsKts > 3, let anchor = trackAnchor {
            let yaw = yawRateDeg * dt
            track += yaw
            let carried = anchor + yaw
            trackAnchor = carried
            let e = angleWrap(carried - track)
            track += abs(e) > 45 ? e : e * min(1, dt * 2)
        }
        if let anchor = altAnchor {
            let climb = vs / 60 * dt
            alt += climb
            altAnchor = anchor + climb
            alt += (anchor + climb - alt) * min(1, dt * 0.4)
        }
        let v = gsKts * 0.514444
        roll = v > 25 ? deg(atan(v * rad(turnRateSmoothed) / 9.80665)) : 0
        pitch = gsKts * 1.68781 > 10 ? deg(atan2(vs / 60, gsKts * 1.68781)) : 0
    }
    mutating func fix(course: Double?, gsKts: Double, altFt: Double, t: Double) {
        if let c = course, gsKts > 3 {
            if trackAnchor == nil { track = c }
            trackAnchor = c
        }
        if altAnchor == nil { alt = altFt }
        altAnchor = altFt
        if let last = lastAlt {
            let dt = t - last.t
            if dt > 0.5 {
                vsTarget += ((altFt - last.ft) / dt * 60 - vsTarget) * 0.4
                lastAlt = (t, altFt)
            }
        } else { lastAlt = (t, altFt) }
    }
}

struct Sample {
    var t: Double
    var truth: Truth
    var new: (roll: Double, pitch: Double, track: Double, alt: Double, vs: Double, handling: Bool, trust: Double)
    var old: (roll: Double, pitch: Double, track: Double, alt: Double, vs: Double)
}

/// Phone pose disturbances: extra rotation of the phone relative to the
/// cabin, as a function of time (rotation matrix device-from-nominal, plus
/// its angular rate in the cabin frame, deg/s).
typealias PhonePose = (Double) -> (extra: simd_double3x3, rate: simd_double3)

func runScenario(name: String, duration: Double, seed: UInt64, sensors: SensorModel,
                 truthAt: (Double) -> Truth, phone: PhonePose? = nil,
                 gpsOutage: ClosedRange<Double>? = nil, courseOutliers: Set<Int> = [],
                 csvDir: String?) -> [Sample] {
    var rng = RNG(state: seed)
    let dt = 1.0 / 60
    // Phone flat on the tray table, top edge toward the nose, tray tilted
    // 4° toward the passenger and 2° to the side.
    let mountNominal = rotY(rad(2)) * rotX(rad(-90 + 4))          // device → cabin
    var est = PlaneModeEstimator(trackDeg: truthAt(0).psi)
    var old = OldModel()
    old.track = truthAt(0).psi
    var gsSmoothed = truthAt(0).gsKts
    var gpsSpeed = truthAt(0).gsKts
    est.seedAltitude(feet: truthAt(0).altFt, verticalSpeedFpm: truthAt(0).vsFpm)
    old.alt = truthAt(0).altFt; old.vs = truthAt(0).vsFpm; old.vsTarget = old.vs
    var pending: [(deliver: Double, t: Double, course: Double, gs: Double, alt: Double)] = []
    var lastFix = -1.0
    var fixIndex = 0
    var staleAlt = truthAt(0).altFt
    var samples: [Sample] = []
    var prevTruth = truthAt(-dt)
    var prevVel: simd_double3?
    var csv = "t,true_roll,new_roll,old_roll,true_pitch,new_pitch,old_pitch,true_track,new_track,old_track,true_alt,new_alt,old_alt,true_vs,new_vs,old_vs,handling,trust\n"

    var t = 0.0
    while t <= duration {
        let tr = truthAt(t)
        // Euler rates → body rates.
        let phiDot = rad(tr.phi - prevTruth.phi) / dt
        let thetaDot = rad(tr.theta - prevTruth.theta) / dt
        let psiDot = rad(angleWrap(tr.psi - prevTruth.psi)) / dt
        let (phi, theta, psi) = (rad(tr.phi), rad(tr.theta), rad(tr.psi))
        var p = phiDot - psiDot * sin(theta)
        var q = thetaDot * cos(phi) + psiDot * sin(phi) * cos(theta)
        var r = -thetaDot * sin(phi) + psiDot * cos(phi) * cos(theta)
        if sensors.turbulence {
            // 0.5 Hz turbulence / tray wobble on the gyro: ±2 °/s roll and
            // yaw, ±1 °/s pitch.
            p += rad(2 * sin(2 * .pi * 0.5 * t))
            q += rad(1 * sin(2 * .pi * 0.5 * t + 1.1))
            r += rad(2 * sin(2 * .pi * 0.5 * t + 2.3))
        }
        p += rad(sensors.gyroBias.x + sensors.gyroNoise * rng.gauss())
        q += rad(sensors.gyroBias.y + sensors.gyroNoise * rng.gauss())
        r += rad(sensors.gyroBias.z + sensors.gyroNoise * rng.gauss())
        var cabinRate = bodyToCabin(simd_double3(p, q, r))

        // Kinematic acceleration from the velocity vector.
        let v = tr.gsKts * 0.514444
        let vel = simd_double3(v * cos(psi), v * sin(psi), -tr.vsFpm * 0.00508)
        let accel = prevVel.map { (vel - $0) / dt } ?? .zero
        prevVel = vel
        let C = dcm(phi, theta, psi)
        var userAccelBody = C * (-accel / 9.80665)
        if sensors.turbulence {
            userAccelBody += simd_double3(0, 0.03 * sin(2 * .pi * 0.9 * t), 0.15 * sin(2 * .pi * 0.7 * t))
        }
        let gravityBody = C * simd_double3(0, 0, 1)

        var mountTrue = mountNominal
        if let phone {
            let pose = phone(t)
            mountTrue = pose.extra * mountNominal
            cabinRate += pose.rate * .pi / 180
        }
        // Device = mountᵀ · cabin.
        let toDevice = mountTrue.transpose
        let motion = PlaneModeEstimator.Motion(
            rotationRate: toDevice * cabinRate,
            gravity: toDevice * bodyToCabin(gravityBody),
            userAcceleration: toDevice * bodyToCabin(userAccelBody))

        // GPS: sample once a second, deliver after the latency.
        if t - lastFix >= 1 - 1e-9 {
            lastFix = t
            fixIndex += 1
            let inOutage = gpsOutage.map { $0.contains(t) } ?? false
            if !inOutage {
                var course = tr.psi + sensors.courseSigma * rng.gauss()
                if courseOutliers.contains(fixIndex) { course += 30 }
                var alt = tr.altFt + rng.uniform(sensors.altitudeNoiseFt)
                if sensors.staleAltitudes {
                    if fixIndex % 3 == 0 { staleAlt = alt } else { alt = staleAlt }
                }
                pending.append((t + sensors.latency, t, course, tr.gsKts + 0.3 * rng.gauss(), alt))
            }
        }
        while let fix = pending.first, fix.deliver <= t {
            pending.removeFirst()
            gpsSpeed = fix.gs
            let course = (fix.course.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            est.gpsCourse(course, accuracyDeg: sensors.reportedCourseAccuracy, speedKts: fix.gs, time: fix.t)
            est.gpsAltitude(feet: fix.alt, accuracyFt: 30, time: fix.t, now: t)
            old.fix(course: course, gsKts: fix.gs, altFt: fix.alt, t: fix.t)
        }
        gsSmoothed += (gpsSpeed - gsSmoothed) * -expm1(-dt / 0.8)

        est.step(dt: dt, time: t, motion: motion, groundSpeedKts: gsSmoothed)
        // Old yaw rate: rotation rate along Core Motion's gravity.
        let oldYaw = deg(simd_dot(motion.rotationRate, motion.gravity))
        old.step(dt: dt, yawRateDeg: oldYaw, gsKts: gsSmoothed)

        let s = Sample(t: t, truth: tr,
                       new: (est.rollDeg, est.pitchDeg, est.trackDeg, est.altitudeFt, est.verticalSpeedFpm,
                             est.isHandling, est.gyroTrust),
                       old: (old.roll, old.pitch, old.track, old.alt, old.vs))
        samples.append(s)
        csv += [t, tr.phi, s.new.roll, s.old.roll, tr.theta, s.new.pitch, s.old.pitch,
                tr.psi, s.new.track, s.old.track, tr.altFt, s.new.alt, s.old.alt,
                tr.vsFpm, s.new.vs, s.old.vs, s.new.handling ? 1 : 0, s.new.trust]
            .map { String(format: "%.3f", $0) }.joined(separator: ",") + "\n"
        prevTruth = tr
        t += dt
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

let csvDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

// MARK: - A: 25° bank turn in turbulence at cruise

do {
    print("=== A: cruise 450 kt, roll-in to 25° at 3°/s, 60 s turn, roll-out; turbulence 0.5 Hz ±2°/s gyro, ±0.15 g")
    func bank(_ t: Double) -> Double {
        if t < 30 { return 0 }
        if t < 90 { return 25 * smoothstep((t - 30) / (25.0 / 3 + 1)) }
        return 25 * (1 - smoothstep((t - 90) / (25.0 / 3 + 1)))
    }
    var psi = 90.0
    var lastT = 0.0
    let truth: (Double) -> Truth = { t in
        // Integrate the coordinated turn rate (called with increasing t).
        if t > lastT {
            psi += deg(9.80665 * tan(rad(bank(t))) / (450 * 0.514444)) * (t - lastT)
            lastT = t
        }
        return Truth(phi: bank(t), theta: 2.5, psi: psi, gsKts: 450, altFt: 35_000, vsFpm: 0)
    }
    var sensors = SensorModel()
    sensors.turbulence = ProcessInfo.processInfo.environment["CALM"] == nil
    if ProcessInfo.processInfo.environment["PERFECT"] != nil { sensors.gyroBias = .zero; sensors.gyroNoise = 0 }
    let s = runScenario(name: "A_turn_turbulence", duration: 130, seed: 1, sensors: sensors, truthAt: truth, csvDir: csvDir)

    var straightNew = Stats(), straightOld = Stats(), turnNew = Stats(), turnOld = Stats()
    var pitchNew = Stats(), pitchOld = Stats(), trackNew = Stats(), trackOld = Stats()
    for x in window(s, 10...29) { straightNew.add(x.new.roll); straightOld.add(x.old.roll) }
    for x in window(s, 50...89) { turnNew.add(x.new.roll); turnOld.add(x.old.roll) }
    for x in window(s, 10...130) {
        pitchNew.add(x.new.pitch); pitchOld.add(x.old.pitch)
        trackNew.add(angleWrap(x.new.track - x.truth.psi)); trackOld.add(angleWrap(x.old.track - x.truth.psi))
    }
    print("                       new: mean   p-p   std  |  old: mean   p-p   std")
    print("roll, straight (0°)    ", f1(straightNew.mean), f1(straightNew.peakToPeak), f2(straightNew.std),
          " | ", f1(straightOld.mean), f1(straightOld.peakToPeak), f2(straightOld.std))
    print("roll, in turn (25°)    ", f1(turnNew.mean), f1(turnNew.peakToPeak), f2(turnNew.std),
          " | ", f1(turnOld.mean), f1(turnOld.peakToPeak), f2(turnOld.std))
    print("pitch (2.5°)           ", f1(pitchNew.mean), f1(pitchNew.peakToPeak), f2(pitchNew.std),
          " | ", f1(pitchOld.mean), f1(pitchOld.peakToPeak), f2(pitchOld.std))
    print("track error            ", f2(trackNew.mean), f2(trackNew.maxAbs), "max | ", f2(trackOld.mean), f2(trackOld.maxAbs), "max")
    for level in [12.5, 22.5] {
        let tTrue = firstTime(s, after: 30) { $0.truth.phi >= level }!
        let tNew = firstTime(s, after: 30) { $0.new.roll >= level }
        let tOld = firstTime(s, after: 30) { $0.old.roll >= level }
        print(String(format: "roll-in reaches %4.1f°: truth %.2f s, new %+.2f s, old %@", level, tTrue - 30,
                     (tNew ?? .nan) - tTrue, tOld.map { String(format: "%+.2f s", $0 - tTrue) } ?? "never"))
    }
    let outTrue = firstTime(s, after: 90) { $0.truth.phi <= 2.5 }!
    let outNew = firstTime(s, after: 90) { $0.new.roll <= 2.5 }!
    print(String(format: "roll-out reaches 2.5°: new %+.2f s after truth", outNew - outTrue))
    print("time    true  new   old   (roll, every 4 s)")
    for x in s where x.t.truncatingRemainder(dividingBy: 4) < 1.0 / 60 && x.t > 20 && x.t < 112 {
        print(String(format: "%5.0f  %5.1f %5.1f %5.1f", x.t, x.truth.phi, x.new.roll, x.old.roll))
    }
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
        let ry = simd_double3x3(rows: [simd_double3(cos(rad(yaw)), 0, sin(rad(yaw))),
                                       simd_double3(0, 1, 0),
                                       simd_double3(-sin(rad(yaw)), 0, cos(rad(yaw)))])
        extra = ry
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
        var n = Stats(), o = Stats(), rn = Stats(), ro = Stats()
        for x in window(s, r) {
            n.add(angleWrap(x.new.track - 270)); o.add(angleWrap(x.old.track - 270))
            rn.add(x.new.roll); ro.add(x.old.roll)
        }
        print(label, "track err new rms", f2(n.rms), "max", f2(n.maxAbs), "| old rms", f2(o.rms), "max", f2(o.maxAbs),
              "|| roll new max", f1(rn.maxAbs), "old max", f1(ro.maxAbs))
    }
    report("  steady 30–199 s       ", 30...199)
    report("  GPS outage 200–260 s  ", 200...260)
    report("  after outage 261–399 s", 261...399)
    report("  phone turned 400–449 s", 400...449)
    report("  handled 450–470 s     ", 450...470)
    report("  after 470–600 s       ", 470...600)
    let handlingTime = window(s, 0...600).filter { $0.new.handling }.count
    print(String(format: "  handling detected for %.1f s in total", Double(handlingTime) / 60))
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
        let ry = simd_double3x3(rows: [simd_double3(cos(rad(yaw)), 0, sin(rad(yaw))), simd_double3(0, 1, 0),
                                       simd_double3(-sin(rad(yaw)), 0, cos(rad(yaw)))])
        return (ry, simd_double3(0, rate, 0))
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
    print("  time  true   new   old")
    for x in s where x.t.truncatingRemainder(dividingBy: 1) < 1.0 / 60 && x.t >= 9 && x.t <= 20 {
        print(String(format: "  %4.0f %6.1f %6.1f %6.1f", x.t, x.truth.psi, x.new.track, x.old.track))
    }
    let parkedNew = window(s, 32...60).map { angleWrap($0.new.track - 100) }
    print(String(format: "  parked 32–60 s, phone turned 45° at 40 s: new heading moved %.2f° (old code: the",
                 (parkedNew.max() ?? 0) - (parkedNew.min() ?? 0)))
    print("  magnetometer of the phone — it follows the phone round by the full 45°)")
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
        var an = Stats(), ao = Stats(), vn = Stats(), vo = Stats(), rateNew = Stats(), rateOld = Stats()
        let w = window(s, r)
        for (a, b) in zip(w, w.dropFirst()) {
            an.add(b.new.alt - b.truth.altFt); ao.add(b.old.alt - b.truth.altFt)
            vn.add(b.new.vs - b.truth.vsFpm); vo.add(b.old.vs - b.truth.vsFpm)
            // Rate the display actually moves at, frame to frame (fpm).
            rateNew.add((b.new.alt - a.new.alt) * 60 * 60 - b.truth.vsFpm)
            rateOld.add((b.old.alt - a.old.alt) * 60 * 60 - b.truth.vsFpm)
        }
        print("  \(label): alt err new rms", f1(an.rms), "max", f1(an.maxAbs), "ft | old rms", f1(ao.rms), "max", f1(ao.maxAbs))
        print("        V/S err new rms", f1(vn.rms), "max", f1(vn.maxAbs), "fpm | old rms", f1(vo.rms), "max", f1(vo.maxAbs))
        print("        display climb-rate scatter (frame to frame) new std", f1(rateNew.std), "max", f1(rateNew.maxAbs),
              "fpm | old std", f1(rateOld.std), "max", f1(rateOld.maxAbs))
    }
    let onset = firstTime(s, after: 30) { $0.new.vs >= 2250 }!
    let onsetOld = firstTime(s, after: 30) { $0.old.vs >= 2250 }
    print(String(format: "  V/S reaches 90%% of 2500 fpm %.1f s after the climb starts (old %@)", onset - 30,
                 onsetOld.map { String(format: "%.1f s", $0 - 30) } ?? "never"))
}
climbScenario(stale: false)
climbScenario(stale: true)
