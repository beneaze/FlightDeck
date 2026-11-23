import Foundation
import simd

/// Plane-mode sensor fusion: attitude, track and altitude for a passenger's
/// phone in an airliner cabin.
///
/// What a passenger's phone can and cannot sense:
///
/// - The accelerometer measures specific force. In coordinated flight that
///   stays along the cabin floor normal — through turns included — so the
///   phone's tilt against "gravity" says nothing about bank. It does say how
///   the phone sits in the cabin (the mount), and that never changes while
///   the phone rests on the tray table, wedged or mounted.
/// - The gyroscope sees the aircraft's rotation directly, cleanly and fast,
///   as long as the phone is fixed relative to the cabin.
/// - GPS gives ground track, ground speed and altitude about once a second,
///   without drift but with noise and some latency.
/// - The barometer reads cabin pressure and the magnetometer sits among metal
///   and wiring: neither is used here.
///
/// So the estimator integrates the gyro (mapped into aircraft axes through the
/// mount) for every fast change, and corrects its slow drift toward
/// physically derived references:
///
/// - Roll toward the coordinated-turn bank `atan(V·ψ̇/g)`.
/// - Pitch toward the flight-path angle plus a typical angle of attack.
/// - Track toward the GPS course, with the gyro's earth-vertical yaw rate
///   carrying it between fixes and its bias learnt from GPS.
///
/// The corrections are lag-matched (the estimate is passed through the same
/// low-pass as the reference before the two are compared), so the reference
/// filtering that rejects turbulence does not drag a roll-in back.
///
/// Pure Swift on simd, no Core Motion or Core Location types, so the offline
/// harness in `Tools/PlaneModeHarness` compiles this very file.
struct PlaneModeEstimator {

    /// One Core Motion sample, in the device frame.
    struct Motion {
        /// Bias-corrected gyro rates, rad/s.
        var rotationRate: simd_double3
        /// Unit vector toward the earth (Core Motion's gravity).
        var gravity: simd_double3
        /// The accelerometer's reaction reading less gravity, in g.
        var userAcceleration: simd_double3
    }

    /// Every constant, with the physics behind it.
    enum Tuning {
        // Ground / air dynamics, by ground speed with hysteresis.
        static let airAboveKts = 60.0
        static let groundBelowKts = 40.0
        /// Below this an aircraft cannot turn: heading holds.
        static let stoppedBelowKts = 3.0

        // Airliner envelope.
        static let maxBankDeg = 35.0
        static let maxRollRateDegPerSec = 8.0      // normal ops ≲ 5–7 °/s
        static let maxPitchRateDegPerSec = 4.0     // rotation ≈ 3 °/s
        static let minAirTurnRateDegPerSec = 3.0   // rate one
        static let maxAirTurnRateDegPerSec = 6.0   // 35° bank at approach speed
        static let maxGroundTurnRateDegPerSec = 25.0   // taxi turns 10–20 °/s

        // Phone handling: rotation no airliner makes.
        static let handlingRateAirDegPerSec = 15.0
        static let handlingRateGroundDegPerSec = 35.0
        static let handlingTiltDeg = 30.0
        static let handlingLateralDeg = 12.0
        static let settleRateDegPerSec = 5.0
        static let settleTime = 1.5

        /// Gyro trust falls from 1 to 0 as the short-term scatter of the
        /// rotation rate grows from 3 to 8 °/s (handheld phone, tray wobble).
        static let trustFullBelowDegPerSec = 3.0
        static let trustZeroAboveDegPerSec = 8.0

        // Lag-matched complementary filters. Roll: the reference passes two
        // first-order stages of τ each (turbulent yaw rate at 0.5 Hz is cut
        // to ~1/50), the estimate the same two before they are compared;
        // loop s(1+τs)² + K is well damped. Pitch: one stage,
        // ζ = 1/(2√(K·τ)) ≈ 0.6.
        static let rollReferenceLag = 1.2          // τ per stage, s
        static let rollGain = 0.35                 // K, 1/s
        static let pitchReferenceLag = 2.5
        static let pitchGain = 0.3
        static let rateFilterTime = 0.08           // gyro pre-filter, s
        static let rollDisplayTime = 0.15
        static let pitchDisplayTime = 0.25

        /// Typical body angle of attack: ~6° at approach and climb-out
        /// speeds, ~2.5° in cruise.
        static func angleOfAttackDeg(groundSpeedKts v: Double) -> Double {
            let t = min(1, max(0, (v - 150) / 150))
            return 6 - 3.5 * t
        }

        // Track.
        static let airCourseTime = 5.0             // convergence to GPS, s
        static let groundCourseTime = 2.5
        static let airCourseSigmaDeg = 3.0         // full weight at or below
        static let groundCourseSigmaDeg = 5.0
        static let airMaxCourseSigmaDeg = 10.0
        static let groundMaxCourseSigmaDeg = 20.0
        static let minCourseSpeedKts = 8.0
        static let airOutlierDeg = 25.0
        static let groundOutlierDeg = 60.0
        static let biasGain = 0.01                 // 1/s², bias integrator
        static let maxBiasDegPerSec = 0.3
        /// GPS corrections reach the display through an offset that decays
        /// with this time constant; gyro-carried motion shows without lag.
        static let trackCorrectionDisplayTime = 0.5

        // Altitude: a second-order (alpha-beta) observer on GPS altitude,
        // s² + k1·s + k2 with ωn = 0.2 rad/s, ζ ≈ 0.9.
        static let altitudeK1 = 0.5
        static let altitudeK2 = 0.08
        /// Each fix's innovation enters the anchor over this time constant,
        /// so even the climb rate the display moves at has no kinks.
        static let altitudeInnovationTime = 0.6
        static let goodVerticalAccuracyFt = 40.0
        static let maxVerticalSpeedFps = 8_000.0 / 60
    }

    // MARK: Outputs

    private(set) var rollDeg = 0.0
    private(set) var pitchDeg = 0.0
    /// Ground track, 0..<360 — also the heading in plane mode.
    var trackDeg: Double { wrap360(displayTrack) }
    private(set) var altitudeFt = 0.0
    var verticalSpeedFpm: Double { verticalSpeedFps * 60 }
    private(set) var hasAltitude = false
    private(set) var isHandling = false
    private(set) var isAirborne = false
    private(set) var isGroundDynamics = true
    private(set) var gyroTrust = 1.0
    private(set) var yawBiasDegPerSec = 0.0
    /// Device → cabin rotation: cabin down is (0, -1, 0), the nose (0, 0, -1).
    private(set) var mount: simd_double3x3?

    // MARK: State

    // Mount.
    private var mountDown: simd_double3?
    private var fastDown: simd_double3?
    /// The aircraft's pitch inside the mount frame. The mount is learnt from
    /// the plumb line, which in steady flight hangs along the earth vertical,
    /// so the mount frame is level at whatever pitch the aircraft flew
    /// while it was learnt — the body sits pitched up by that much. Without
    /// this a roll rate would leak into the yaw rate as −p·sinθ, which the
    /// V/g of the bank reference turns into degrees of false bank.
    private var mountPitchDeg = 0.0
    /// Seconds since the mount was (re)anchored: learning averages over
    /// this long (a running mean) up to a minute, then forgets slowly.
    private var mountAge = 0.0
    private var isAttitudeSeeded = false
    private var settleTimer = 0.0
    private var rateMean = simd_double3(repeating: 0)
    private var rateMeanSquare = 0.0
    private var bodyRates = simd_double3(repeating: 0)     // p, q, r — rad/s

    // Attitude.
    private var roll = 0.0, pitch = 0.0                    // estimates, deg
    private var turnRateStage = 0.0, turnRateReference = 0.0   // deg/s, low-passed twice
    private var rollReference = 0.0
    private var rollStage = 0.0, rollLagged = 0.0
    private var pitchReference = 0.0, pitchLagged = 0.0

    // Phase.
    private var lastGroundSpeedKts: Double?
    private var groundAcceleration = 0.0                   // kt/s, smoothed
    private var groundAltitudeFt: Double?

    // Track — unwrapped degrees.
    private var track = 0.0
    private var displayTrack = 0.0
    private var displayOffset = 0.0
    private var fastSlew = false
    private var hasCourse = false
    private var history: [(time: Double, track: Double)] = []
    private var lastCourse: (time: Double, course: Double)?
    private var lastAcceptedCourseTime: Double?
    private var gpsTurnRate = 0.0                          // deg/s
    private var gyroTurnRate = 0.0                         // deg/s, bias-corrected
    private var courseOutliers = 0
    private var clock = 0.0

    // Altitude.
    private var altitudeState = 0.0
    private var verticalSpeedFps = 0.0
    private var altitudeAnchor = 0.0
    private var altitudeInnovation = 0.0                   // not yet in the anchor
    private var lastGPSAltitude: Double?

    init(trackDeg: Double = 0) {
        track = trackDeg
        displayTrack = trackDeg
    }

    // MARK: - Inputs

    /// A starting point for altitude and vertical speed, so entering plane
    /// mode does not restart them from zero.
    mutating func seedAltitude(feet: Double, verticalSpeedFpm: Double) {
        altitudeState = feet
        altitudeAnchor = feet
        altitudeInnovation = 0
        altitudeFt = feet
        verticalSpeedFps = verticalSpeedFpm / 60
        hasAltitude = true
    }

    /// Forget the mount: the next motion sample sets it afresh — for when
    /// the crew captures a new attitude zero.
    mutating func reanchorMount() {
        mountDown = nil
        mount = nil
    }

    /// One display frame. `motion` is nil when no motion sample is available;
    /// everything then runs on the references alone.
    mutating func step(dt: Double, time: Double, motion: Motion?, groundSpeedKts gs: Double) {
        guard dt > 0, dt < 2 else { return }
        clock = time
        updatePhase(dt: dt, groundSpeedKts: gs)
        stepAltitude(dt: dt)

        if let motion {
            processMotion(motion, dt: dt)
        } else {
            gyroTrust = 0
            bodyRates = .zero
        }
        stepAttitude(dt: dt, groundSpeedKts: gs)
        stepTrack(dt: dt, time: time, groundSpeedKts: gs)
    }

    /// A GPS course. `accuracyDeg` is Core Location's courseAccuracy (nil or
    /// negative when unknown); `time` the fix's own timestamp, on the same
    /// clock as ``step(dt:time:motion:groundSpeedKts:)``.
    mutating func gpsCourse(_ course: Double, accuracyDeg: Double?, speedKts: Double, time: Double) {
        guard course >= 0, speedKts >= Tuning.minCourseSpeedKts else { return }
        // Without a reported accuracy, assume ±0.5 m/s of velocity noise.
        let sigma = accuracyDeg.flatMap { $0 > 0 ? $0 : nil }
            ?? max(1, atan(0.5 / (speedKts * 0.514444)) * 180 / .pi)
        let air = !isGroundDynamics
        guard sigma <= (air ? Tuning.airMaxCourseSigmaDeg : Tuning.groundMaxCourseSigmaDeg) else { return }

        // The track's own turn rate, the fallback when the gyro is not
        // trusted.
        if let last = lastCourse, time - last.time > 0.3, time - last.time < 3 {
            let interval = time - last.time
            let limit = air ? Tuning.maxAirTurnRateDegPerSec : Tuning.maxGroundTurnRateDegPerSec
            let raw = clamp(wrap180(course - last.course) / interval, limit)
            gpsTurnRate += (raw - gpsTurnRate) * 0.4
        }
        lastCourse = (time, course)

        guard hasCourse else {
            hasCourse = true
            reseedTrack(course)
            lastAcceptedCourseTime = time
            return
        }

        // Compare with what the track was when the fix was taken, not now:
        // the fix arrives late, and in a turn that lag would read as error.
        let error = wrap180(course - track(at: time))
        if abs(error) > (air ? Tuning.airOutlierDeg : Tuning.groundOutlierDeg) {
            courseOutliers += 1
            // One wild course is ignored; a run of them is the truth.
            if !air || courseOutliers >= 3 {
                courseOutliers = 0
                reseedTrack(course)
                lastAcceptedCourseTime = time
            }
            return
        }
        courseOutliers = 0

        let sigma0 = air ? Tuning.airCourseSigmaDeg : Tuning.groundCourseSigmaDeg
        let weight = min(1, (sigma0 / sigma) * (sigma0 / sigma))
        let interval = min(2, max(0.2, lastAcceptedCourseTime.map { time - $0 } ?? 1))
        lastAcceptedCourseTime = time
        let gain = min(1, interval / (air ? Tuning.airCourseTime : Tuning.groundCourseTime)) * weight
        let correction = gain * error
        track += correction
        displayOffset -= correction
        for i in history.indices where history[i].time > time { history[i].track += correction }

        // Learn the gyro's residual yaw bias in straight flight only, so a
        // scale error during a turn is not taken for bias.
        if air, !isHandling, gyroTrust > 0.8, abs(turnRateReference) < 0.5 {
            yawBiasDegPerSec = clamp(yawBiasDegPerSec - Tuning.biasGain * error * interval * weight,
                                     Tuning.maxBiasDegPerSec)
        }
    }

    /// A GPS altitude. `time` is the fix's timestamp, `now` the current time
    /// on the same clock — the difference is the delivery latency.
    mutating func gpsAltitude(feet: Double, accuracyFt: Double, time: Double, now: Double) {
        guard accuracyFt > 0, feet.isFinite else { return }
        // An altitude repeated to the last bit is a stale vertical solution,
        // not a level-off: skip it rather than flatten the climb.
        if let last = lastGPSAltitude, last == feet { return }
        lastGPSAltitude = feet
        guard hasAltitude else {
            seedAltitude(feet: feet, verticalSpeedFpm: 0)
            return
        }
        let latency = min(2, max(0, now - time))
        let measured = feet + verticalSpeedFps * latency
        if abs(measured - altitudeAnchor - altitudeInnovation) > 1_500 {
            seedAltitude(feet: measured, verticalSpeedFpm: verticalSpeedFpm)
            return
        }
        let weight = min(1, pow(Tuning.goodVerticalAccuracyFt / accuracyFt, 2))
        altitudeInnovation = (measured - altitudeAnchor) * weight
    }

    // MARK: - Phase

    private mutating func updatePhase(dt: Double, groundSpeedKts gs: Double) {
        if isGroundDynamics, gs > Tuning.airAboveKts { isGroundDynamics = false }
        if !isGroundDynamics, gs < Tuning.groundBelowKts { isGroundDynamics = true }

        if let last = lastGroundSpeedKts {
            groundAcceleration += ((gs - last) / dt - groundAcceleration) * -expm1(-dt / 2)
        }
        lastGroundSpeedKts = gs

        // Airborne: off the ground by height or climb, or simply too fast to
        // be rolling. Landed: slow, or braking hard while level.
        if gs < Tuning.groundBelowKts {
            isAirborne = false
            if hasAltitude { groundAltitudeFt = altitudeFt }
        } else if !isAirborne {
            if let ground = groundAltitudeFt {
                isAirborne = gs > 200 || (gs > Tuning.airAboveKts
                    && (altitudeFt - ground > 150 || verticalSpeedFpm > 600))
            } else {
                isAirborne = gs > 100       // started in flight
            }
        } else if groundAcceleration < -2.5, abs(verticalSpeedFpm) < 300, gs < 170 {
            isAirborne = false
            groundAltitudeFt = altitudeFt
        }
    }

    // MARK: - Mount, handling, gyro trust

    private mutating func processMotion(_ m: Motion, dt: Double) {
        let apparent = m.gravity + m.userAcceleration
        // In the air the plumb line (apparent gravity) is the cabin's own
        // down, turns included. On the ground taxi accelerations swing it,
        // and the aircraft sits level, so true gravity is the better mount.
        let observed = !isGroundDynamics && simd_length(apparent) > 0.3
            ? simd_normalize(apparent) : simd_normalize(m.gravity)

        guard mountDown != nil, mount != nil else {
            mountDown = observed
            fastDown = observed
            mount = Self.minimalRotation(from: observed, to: simd_double3(0, -1, 0))
            mountPitchDeg = pitch
            mountAge = 0
            bodyRates = .zero
            gyroTrust = 0
            return
        }
        fastDown = simd_normalize(lowPass(fastDown ?? observed, observed, dt: dt, time: 0.3))

        let rateDeg = m.rotationRate * 180 / .pi
        let speed = simd_length(rateDeg)
        rateMean = lowPass(rateMean, rateDeg, dt: dt, time: 1.5)
        rateMeanSquare = lowPass(rateMeanSquare, simd_length_squared(rateDeg), dt: dt, time: 1.5)
        let scatter = max(0, rateMeanSquare - simd_length_squared(rateMean)).squareRoot()

        // Detect the phone being picked up, turned or set down elsewhere.
        if !isHandling, let mount, let fastDown {
            let down = mount * fastDown
            let tilt = acos(min(1, max(-1, -down.y))) * 180 / .pi
            let lateral = asin(min(1, max(-1, down.x))) * 180 / .pi
            let limit = isGroundDynamics ? Tuning.handlingRateGroundDegPerSec
                                         : Tuning.handlingRateAirDegPerSec
            if speed > limit || tilt > Tuning.handlingTiltDeg
                || (!isGroundDynamics && abs(lateral) > Tuning.handlingLateralDeg) {
                isHandling = true
                settleTimer = 0
            }
        }
        if isHandling {
            settleTimer = speed < Tuning.settleRateDegPerSec ? settleTimer + dt : 0
            if settleTimer >= Tuning.settleTime, let fastDown {
                // At rest again: wherever it now sits is the new mount.
                isHandling = false
                mountDown = fastDown
                mountPitchDeg = pitch
                mountAge = 0
                bodyRates = .zero
            }
        } else if let current = mountDown, abs(groundAcceleration) < 1 {
            // Learn only while the speed is steady: a takeoff roll's 0.25 g
            // tilts the plumb line 14° aft.
            mountAge += dt
            let learning = min(60, max(1, mountAge))
            mountDown = simd_normalize(lowPass(current, observed, dt: dt, time: learning))
            mountPitchDeg = lowPass(mountPitchDeg, pitch, dt: dt, time: learning)
        }
        if let mountDown { mount = Self.minimalRotation(from: mountDown, to: simd_double3(0, -1, 0)) }

        if isHandling {
            gyroTrust = 0
            bodyRates = .zero
            return
        }
        gyroTrust = isGroundDynamics ? 1 : min(1, max(0,
            1 - (scatter - Tuning.trustFullBelowDegPerSec)
                / (Tuning.trustZeroAboveDegPerSec - Tuning.trustFullBelowDegPerSec)))

        // Body rates: mount frame x right, y up, z aft, with the body pitched
        // up by mountPitchDeg in it; p about the nose (right wing down +),
        // q about the right wing (nose up +), r about the body's down axis
        // (nose right +).
        let w = (mount ?? matrix_identity_double3x3) * m.rotationRate
        let o = mountPitchDeg * .pi / 180
        let nose = simd_double3(0, sin(o), -cos(o))
        let up = simd_double3(0, cos(o), sin(o))
        let body = simd_double3(simd_dot(w, nose), w.x, -simd_dot(w, up))
        bodyRates = lowPass(bodyRates, body, dt: dt, time: Tuning.rateFilterTime)
    }

    // MARK: - Attitude

    private mutating func stepAttitude(dt: Double, groundSpeedKts gs: Double) {
        let phi = roll * .pi / 180, theta = pitch * .pi / 180
        let p = bodyRates.x, q = bodyRates.y, r = bodyRates.z
        // Euler kinematics: in a steady turn the gyro sees a pitch-axis rate
        // q = ψ̇·sinφ that is not a pitch change — this is where it cancels.
        let phiDot = (p + tan(theta) * (q * sin(phi) + r * cos(phi))) * 180 / .pi
        let thetaDot = (q * cos(phi) - r * sin(phi)) * 180 / .pi
        let psiDot = (q * sin(phi) + r * cos(phi)) / cos(theta) * 180 / .pi
        gyroTurnRate = psiDot - yawBiasDegPerSec

        // References.
        let speedMps = gs * 0.514444
        let turnRate = gyroTrust * gyroTurnRate + (1 - gyroTrust) * gpsTurnRate
        // Filter the turn rate itself, then convert: atan is concave and
        // clamped, so converting a turbulent rate first would bias the bank
        // low.
        turnRateStage = lowPass(turnRateStage, isAirborne ? turnRate : 0,
                                dt: dt, time: Tuning.rollReferenceLag)
        turnRateReference = lowPass(turnRateReference, turnRateStage, dt: dt, time: Tuning.rollReferenceLag)
        let bankReference = isAirborne && speedMps > 30
            ? clamp(atan(speedMps * turnRateReference * .pi / 180 / 9.80665) * 180 / .pi, Tuning.maxBankDeg)
            : 0
        let pathAngle = speedMps > 10
            ? atan2(verticalSpeedFps * 0.3048, speedMps) * 180 / .pi : 0
        let pitchTarget = isAirborne
            ? min(20, max(-10, pathAngle + Tuning.angleOfAttackDeg(groundSpeedKts: gs))) : 0

        // Out of the air the reference is wings level, filtered alike.
        rollReference = isAirborne && speedMps > 30
            ? bankReference
            : lowPass(rollReference, 0, dt: dt, time: 2 * Tuning.rollReferenceLag)
        rollStage = lowPass(rollStage, roll, dt: dt, time: Tuning.rollReferenceLag)
        rollLagged = lowPass(rollLagged, rollStage, dt: dt, time: Tuning.rollReferenceLag)
        pitchReference = lowPass(pitchReference, pitchTarget, dt: dt, time: Tuning.pitchReferenceLag)
        pitchLagged = lowPass(pitchLagged, pitch, dt: dt, time: Tuning.pitchReferenceLag)

        if !isAttitudeSeeded {
            // First frame: start on the references rather than at zero.
            isAttitudeSeeded = true
            pitch = pitchTarget
            pitchReference = pitchTarget
            pitchLagged = pitchTarget
            pitchDeg = pitchTarget
            mountPitchDeg = pitchTarget
        }
        let gyroRoll = clamp(phiDot * gyroTrust, Tuning.maxRollRateDegPerSec)
        let gyroPitch = clamp(thetaDot * gyroTrust, Tuning.maxPitchRateDegPerSec)
        roll += (gyroRoll + Tuning.rollGain * (rollReference - rollLagged)) * dt
        pitch += (gyroPitch + Tuning.pitchGain * (pitchReference - pitchLagged)) * dt
        roll = clamp(roll, 45)
        pitch = min(25, max(-15, pitch))

        rollDeg = slew(lowPass(rollDeg, roll, dt: dt, time: Tuning.rollDisplayTime),
                       from: rollDeg, rate: 10, dt: dt)
        pitchDeg = slew(lowPass(pitchDeg, pitch, dt: dt, time: Tuning.pitchDisplayTime),
                        from: pitchDeg, rate: 5, dt: dt)
    }

    // MARK: - Track

    private mutating func stepTrack(dt: Double, time: Double, groundSpeedKts gs: Double) {
        if let last = lastCourse, time - last.time > 2 {
            gpsTurnRate *= exp(-dt / 5)        // no fresh courses: stop turning
        }
        let limit: Double
        if isGroundDynamics {
            limit = Tuning.maxGroundTurnRateDegPerSec
        } else {
            let physical = 9.80665 * tan(Tuning.maxBankDeg * .pi / 180) / max(1, gs * 0.514444) * 180 / .pi
            limit = min(Tuning.maxAirTurnRateDegPerSec, max(Tuning.minAirTurnRateDegPerSec, physical))
        }
        var rate = gyroTrust * gyroTurnRate + (1 - gyroTrust) * gpsTurnRate
        if isGroundDynamics, gs < Tuning.stoppedBelowKts { rate = 0 }   // parked: hold
        track += clamp(rate, limit) * dt

        history.append((time, track))
        if let first = history.first, time - first.time > 4 { history.removeFirst() }

        displayOffset *= exp(-dt / Tuning.trackCorrectionDisplayTime)
        if fastSlew, abs(track - displayTrack) < 1 { fastSlew = false }
        let displayRate = fastSlew || isGroundDynamics ? 30 : limit + 1
        displayTrack = slew(track + displayOffset, from: displayTrack, rate: displayRate, dt: dt)
    }

    private mutating func reseedTrack(_ course: Double) {
        let new = track + wrap180(course - track)
        let delta = new - track
        track = new
        displayOffset = 0
        for i in history.indices { history[i].track += delta }
        fastSlew = true
    }

    /// The track at an earlier time, from the last four seconds' history.
    private func track(at time: Double) -> Double {
        guard let last = history.last, time < last.time else { return track }
        guard let first = history.first, time > first.time else { return history.first?.track ?? track }
        var i = history.count - 1
        while i > 0, history[i - 1].time > time { i -= 1 }
        let a = history[i - 1], b = history[i]
        let f = (time - a.time) / max(1e-9, b.time - a.time)
        return a.track + (b.track - a.track) * f
    }

    // MARK: - Altitude

    /// The display altitude rides on the estimated climb rate; each fix moves
    /// only an anchor carried the same way, and the gap closes continuously
    /// (k1) while also trimming the climb rate (k2). No fix ever shows as a
    /// step, and a steady climb has no lag.
    private mutating func stepAltitude(dt: Double) {
        guard hasAltitude else { return }
        let entering = altitudeInnovation * -expm1(-dt / Tuning.altitudeInnovationTime)
        altitudeInnovation -= entering
        altitudeAnchor += verticalSpeedFps * dt + entering
        let error = altitudeAnchor - altitudeState
        altitudeState += (verticalSpeedFps + Tuning.altitudeK1 * error) * dt
        verticalSpeedFps = clamp(verticalSpeedFps + Tuning.altitudeK2 * error * dt,
                                 Tuning.maxVerticalSpeedFps)
        altitudeFt = altitudeState
    }
}

// MARK: - Math

extension PlaneModeEstimator {
    /// The smallest rotation carrying unit vector `a` onto unit vector `b`
    /// (Rodrigues' formula).
    static func minimalRotation(from a: simd_double3, to b: simd_double3) -> simd_double3x3 {
        let v = simd_cross(a, b)
        let c = simd_dot(a, b)

        // Antiparallel vectors: 180° about any axis perpendicular to `a`.
        if c < -0.999_999 {
            var axis = simd_cross(a, simd_double3(1, 0, 0))
            if simd_length_squared(axis) < 1e-6 {
                axis = simd_cross(a, simd_double3(0, 0, 1))
            }
            let n = simd_normalize(axis)
            return 2 * simd_double3x3(columns: (n * n.x, n * n.y, n * n.z))
                - matrix_identity_double3x3
        }

        let skew = simd_double3x3(rows: [
            simd_double3(0, -v.z, v.y),
            simd_double3(v.z, 0, -v.x),
            simd_double3(-v.y, v.x, 0),
        ])
        return matrix_identity_double3x3 + skew + (1 / (1 + c)) * (skew * skew)
    }
}

/// First-order low-pass step, independent of the step rate.
private func lowPass(_ value: Double, _ target: Double, dt: Double, time: Double) -> Double {
    value + (target - value) * -expm1(-dt / time)
}

private func lowPass(_ value: simd_double3, _ target: simd_double3, dt: Double, time: Double) -> simd_double3 {
    value + (target - value) * -expm1(-dt / time)
}

private func slew(_ target: Double, from value: Double, rate: Double, dt: Double) -> Double {
    value + clamp(target - value, rate * dt)
}

private func clamp(_ x: Double, _ limit: Double) -> Double { min(limit, max(-limit, x)) }

private func wrap180(_ d: Double) -> Double {
    var d = d.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

private func wrap360(_ d: Double) -> Double {
    let d = d.truncatingRemainder(dividingBy: 360)
    return d < 0 ? d + 360 : d
}
