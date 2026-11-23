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
///   as long as the phone is fixed relative to the cabin. Turbulence is real
///   aircraft motion and the gyro sees it as such.
/// - GPS gives ground track, ground speed and altitude about once a second,
///   without drift but with noise and some latency.
/// - The barometer reads cabin pressure and the magnetometer sits among metal
///   and wiring: neither is used here.
///
/// So the gyro, mapped into aircraft axes through the mount, *is* the
/// attitude: it is integrated at full weight, without rate limits, and the
/// display shows it after 0.05 s of smoothing. Only its slow drift is
/// corrected, over tens of seconds, toward physically derived references:
///
/// - Roll toward the coordinated-turn bank `atan(V·ψ̇/g)`.
/// - Pitch toward the flight-path angle plus a typical angle of attack.
/// - Track toward the GPS course, with the gyro's earth-vertical yaw rate
///   carrying it between fixes and its bias learnt from GPS.
///
/// The corrections are lag-matched (the estimate is passed through the same
/// low-pass as the reference before the two are compared), so a correct
/// reference never pulls on a correct estimate however fast it moves.
///
/// The mount is the plumb line (which way is down for the phone) *and* the
/// phone's yaw on the tray: which horizontal direction of the phone points at
/// the nose. A phone lying 30° askew turns 50 % of every roll into pitch if
/// that yaw is wrong, so it is learnt, from the take-off roll and braking
/// (the specific force along GPS acceleration) and in flight (roll activity
/// far exceeds pitch activity, and a roll to the right is followed by a right
/// turn). Until then the screen's up as the passenger reads it (lying flat —
/// the top edge in portrait) or the phone's back (standing) is taken to point
/// at the nose. A phone that is picked up and set down again keeps its yaw:
/// the gyro follows it in the hand.
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

    /// Where the phone's yaw on the tray currently comes from.
    enum YawSource: String {
        /// Screen up (flat) or back (upright) toward the nose.
        case assumed
        /// Carried across a pick-up by integrating the phone's own rotation.
        case carried
        /// The dominant roll axis in flight.
        case flight
        /// Specific force along the GPS acceleration on the ground.
        case ground
    }

    /// Every constant, with the physics behind it.
    enum Tuning {
        // Ground / air dynamics, by ground speed with hysteresis.
        static let airAboveKts = 60.0
        static let groundBelowKts = 40.0
        /// Below this an aircraft cannot turn: heading holds.
        static let stoppedBelowKts = 3.0

        // Airliner envelope (track limits and sanity clamps only — the gyro
        // attitude itself is never rate limited).
        static let maxBankDeg = 35.0
        static let minAirTurnRateDegPerSec = 3.0   // rate one
        static let maxAirTurnRateDegPerSec = 6.0   // 35° bank at approach speed
        static let maxGroundTurnRateDegPerSec = 25.0   // taxi turns 10–20 °/s

        // Phone handling: rotation no airliner makes. Moderate turbulence
        // peaks around 10–15 °/s for a fraction of a second; a hand picking
        // up a phone turns it at 50–200 °/s. Turbulence must never count.
        static let handlingRateAirDegPerSec = 25.0
        static let handlingRateGroundDegPerSec = 40.0
        /// The rate must stay above the limit this long.
        static let handlingSustainTime = 0.2
        /// Rotation far beyond anything an airliner does counts at once.
        static let handlingFastRateAirDegPerSec = 60.0
        static let handlingFastRateGroundDegPerSec = 90.0
        static let handlingFastSustainTime = 0.05
        /// …measured on the rate magnitude low-passed this much.
        static let handlingRateFilterTime = 0.1
        /// The plumb line leaving the mount by this much (slow pick-ups).
        static let handlingTiltDeg = 30.0
        /// Sideways, once the yaw is known (coordinated flight has none).
        static let handlingLateralDeg = 12.0
        /// On detection, attitude goes back to before the pick-up — to where
        /// the rotation rose above handlingStartRate, at least
        /// handlingRewindTime and at most handlingRewindMax ago — and the
        /// phone's rotation since then is replayed for the carried yaw.
        static let handlingRewindTime = 0.3
        static let handlingRewindMax = 1.0
        static let handlingStartRateDegPerSec = 10.0
        /// At rest again: slow rotation and a steady plumb line for this long.
        static let settleRateDegPerSec = 10.0
        static let settleTiltDeg = 3.0
        static let settleTime = 1.5
        /// After a handling episode the attitude is whatever the references
        /// coasted to; the coasting gains fade out over this long.
        static let recoveryTime = 15.0

        // Lag-matched complementary filters. Roll: the reference passes two
        // first-order stages of τ each (turbulent yaw rate at 0.5 Hz is cut
        // to ~1/50), the estimate the same two before they are compared.
        // Gains are small — they only remove gyro drift (a residual bias of
        // 0.05 °/s leaves bias/K ≈ 0.5° in roll) — and smaller still in turns,
        // where the coordinated-turn bank is off by the wind (it uses ground
        // speed for airspeed).
        static let rollReferenceLag = 1.2          // τ per stage, s
        static let rollGainStraight = 0.1          // K, 1/s
        static let rollGainTurning = 0.03
        /// Turn rate at which the roll gain is halfway down, deg/s.
        static let rollGainTurnRate = 0.5
        static let groundRollGain = 0.1
        /// Pitch: the flight path lags the pitch attitude by seconds (aircraft
        /// dynamics plus the GPS climb-rate filter), so a light touch.
        static let pitchReferenceLag = 2.5
        static let pitchGain = 0.03
        static let groundPitchGain = 0.1
        /// Without the gyro (handled, or no motion stream) the attitude coasts
        /// on the references alone, faster.
        static let coastRollGain = 0.35
        static let coastPitchGain = 0.3
        /// Display smoothing, s: the gyro attitude shows within a frame or two.
        static let displayTime = 0.05
        /// A changed yaw re-projects the attitude; the difference fades from
        /// the display over this long instead of jumping.
        static let reprojectionDisplayTime = 1.0

        // Yaw learning, (a) ground: during the take-off roll and braking the
        // phone feels the acceleration along the nose.
        static let groundYawMinSpeedKts = 4.0      // no pushback
        static let groundYawMinAccelKtsPerSec = 0.8
        static let groundYawMaxTurnDegPerSec = 3.0
        /// Speed change that must have been seen, kt.
        static let groundYawEvidenceKts = 12.0
        /// Coherence |Σ f·a| / Σ |f|·|a| needed.
        static let groundYawCoherence = 0.9

        // (b) flight: principal axis of the horizontal rotation rates.
        static let flightYawWindow = 300.0         // s, exponential forgetting
        static let flightYawHighPass = 5.0         // s, drops the q = ψ̇·sinφ of turns
        static let flightYawMinTime = 20.0         // s of data at least
        /// λ₁, deg²/s: one 25° roll-in at 5°/s gives ~80 after the
        /// high-pass, a minute of light turbulence a few hundred.
        static let flightYawMinEnergy = 50.0
        static let flightYawMaxAnisotropy = 0.4    // λ₂/λ₁
        /// Nose vs tail: Σ bank·ψ̇ along the axis, deg²/s. A 25° turn at
        /// 450 kt gives ~900, turbulence noise ~20.
        static let flightYawBankLeak = 60.0        // s
        static let flightYawSignEvidence = 100.0
        /// A flight estimate overrides a ground one only when this far off
        /// and clearly anisotropic (the phone slid without being noticed).
        static let flightOverridesGroundDeg = 20.0
        static let flightOverrideAnisotropy = 0.15
        /// Hysteresis: a new yaw is applied only when it differs by more —
        /// by less when it comes from a better source than the current one.
        static let yawApplyDeg = 2.0
        static let yawUpgradeDeg = 0.5
        /// Samples reach the yaw learners this late, so the first moments of
        /// a pick-up (before it is detected) are dropped, never learnt.
        static let yawLearningDelay = 0.5
        /// Rotation this fast is never learnt from, handling or not.
        static let yawLearningMaxRateDegPerSec = 20.0

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
    /// 1 while the gyro drives the attitude, 0 while the phone is handled or
    /// no motion stream arrives.
    private(set) var gyroTrust = 1.0
    private(set) var yawBiasDegPerSec = 0.0
    /// Device → cabin rotation: cabin right is (1, 0, 0), down (0, -1, 0),
    /// the nose (0, 0, -1). Includes the learnt yaw.
    private(set) var mount: simd_double3x3?
    private(set) var yawSource = YawSource.assumed
    /// How far the assumed direction (screen up flat, back upright) points
    /// right of the learnt nose, deg — the phone's yaw on the tray.
    private(set) var phoneYawDeg = 0.0

    // MARK: State

    // Mount.
    private var mountDown: simd_double3?
    private var fastDown: simd_double3?
    private var slowDown: simd_double3?
    /// Device → level-mount rotation (down aligned, yaw not applied).
    private var level = matrix_identity_double3x3
    /// The nose in device coordinates (only its horizontal part counts).
    private var noseDevice: simd_double3?
    /// The top-edge / back assumption in device coordinates.
    private var defaultNoseDevice = simd_double3(0, 0, -1)
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
    private var bodyRates = simd_double3(repeating: 0)     // p, q, r — rad/s

    // Handling.
    private var rateLevel = 0.0                            // |ω| low-passed, deg/s
    private var overRateTime = 0.0
    private var fastRateTime = 0.0
    /// The direction the interface shows as up, device coordinates.
    private var screenUpDevice: simd_double3?
    private var settleTimer = 0.0
    /// Current device → device-at-pick-up rotation, integrated from the gyro.
    private var handlingRotation = matrix_identity_double3x3
    private var handlingStartTrack = 0.0
    private var handlingStartDown = simd_double3(0, -1, 0)
    private var recoveryTimer = 0.0
    /// Recent rotation rates (device, rad/s) and attitude, for the rewind.
    private var recent: [Recent] = []
    private struct Recent {
        var time: Double, rate: simd_double3, dt: Double
        var roll: Double, pitch: Double, turnRateStage: Double, turnRateReference: Double, track: Double
    }

    /// Motion samples waiting for the yaw learners.
    private var yawQueue: [YawSample] = []
    private struct YawSample {
        var time: Double, dt: Double
        var rate: simd_double3                             // device, rad/s
        var force: simd_double3                            // device, g (gravity + user)
        var groundSpeedKts: Double, groundAcceleration: Double
        var pitch: Double, isAirborne: Bool
    }

    // Yaw learning.
    private var forceBias = simd_double2(0, 0)            // g, level mount (x, z)
    private var forceFiltered = simd_double2(0, 0)
    private var groundSum = simd_double2(0, 0)
    private var groundEvidence = 0.0
    private var groundSpeedChange = 0.0
    private var rateSlow = simd_double2(0, 0)             // deg/s, level mount (x, z)
    private var covXX = 0.0, covXZ = 0.0, covZZ = 0.0
    private var bankVector = simd_double2(0, 0)           // deg
    private var signVector = simd_double2(0, 0)           // deg²/s
    private var flightLearnTime = 0.0

    // Attitude.
    private var roll = 0.0, pitch = 0.0                    // estimates, deg
    private var rollOffset = 0.0, pitchOffset = 0.0        // re-projection, fading
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

    /// The direction, in device coordinates, that the interface currently
    /// shows as up: (0, 1, 0) in portrait, (±1, 0, 0) in landscape. A
    /// passenger reading a phone that lies flat has it toward the nose, so
    /// until a yaw is learnt it is the better guess than the top edge. Nil
    /// when unknown.
    mutating func screenUp(_ up: simd_double3?) {
        guard up != screenUpDevice else { return }
        screenUpDevice = up
        guard mountDown != nil, !isHandling else { return }
        defaultNoseDevice = assumedNose()
        if yawSource == .assumed {
            let n = level * defaultNoseDevice
            if horizontalLength(n) > 0.3 { adoptNose(simd_normalize(simd_double2(n.x, n.z)), source: .assumed) }
        } else {
            updateMount()
        }
    }

    /// Forget the mount: the next motion sample sets it afresh — for when
    /// the crew captures a new attitude zero. A learnt yaw survives if the
    /// phone still lies roughly the same way.
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
            processMotion(motion, dt: dt, groundSpeedKts: gs)
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

    /// The phone's compass heading. Used only until the first GPS course:
    /// standing at the gate or taxiing slowly there is no track, and a
    /// compass reading (off by the cabin's metal and by how the phone lies,
    /// but roughly right with the top edge toward the nose) beats a heading
    /// stuck at 0. Once a course arrives, GPS and the gyro take over for good.
    mutating func compassHeading(_ heading: Double, dt: Double) {
        guard !hasCourse, heading.isFinite, dt > 0 else { return }
        // Follow with a 1 s time constant so the needle doesn't jitter.
        track += wrap180(heading - track) * min(1, dt / 1.0)
        displayTrack = track
        displayOffset = 0
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

    // MARK: - Mount and handling

    private mutating func processMotion(_ m: Motion, dt: Double, groundSpeedKts gs: Double) {
        let apparent = m.gravity + m.userAcceleration
        // In the air the plumb line (apparent gravity) is the cabin's own
        // down, turns included. On the ground taxi accelerations swing it,
        // and the aircraft sits level, so true gravity is the better mount.
        let observed = !isGroundDynamics && simd_length(apparent) > 0.3
            ? simd_normalize(apparent) : simd_normalize(m.gravity)

        guard let currentDown = mountDown, mount != nil else {
            anchorMount(down: observed)
            return
        }
        fastDown = simd_normalize(lowPass(fastDown ?? observed, observed, dt: dt, time: 0.3))
        slowDown = simd_normalize(lowPass(slowDown ?? observed, fastDown ?? observed, dt: dt, time: 1.0))

        let speed = simd_length(m.rotationRate) * 180 / .pi
        rateLevel = lowPass(rateLevel, speed, dt: dt, time: Tuning.handlingRateFilterTime)
        recent.append(Recent(time: clock, rate: m.rotationRate, dt: dt, roll: roll, pitch: pitch,
                             turnRateStage: turnRateStage, turnRateReference: turnRateReference,
                             track: track))
        while let first = recent.first, clock - first.time > Tuning.handlingRewindMax + 0.1 {
            recent.removeFirst()
        }

        // Detect the phone being picked up, turned or set down elsewhere.
        if !isHandling, let mount, let fastDown {
            let limit = isGroundDynamics ? Tuning.handlingRateGroundDegPerSec
                                         : Tuning.handlingRateAirDegPerSec
            overRateTime = rateLevel > limit ? overRateTime + dt : 0
            let fastLimit = isGroundDynamics ? Tuning.handlingFastRateGroundDegPerSec
                                             : Tuning.handlingFastRateAirDegPerSec
            fastRateTime = speed > fastLimit ? fastRateTime + dt : 0
            let down = mount * fastDown
            let tilt = acos(min(1, max(-1, -down.y))) * 180 / .pi
            let lateral = asin(min(1, max(-1, down.x))) * 180 / .pi
            if overRateTime >= Tuning.handlingSustainTime || fastRateTime >= Tuning.handlingFastSustainTime
                || tilt > Tuning.handlingTiltDeg
                || (!isGroundDynamics && yawSource != .assumed
                    && abs(lateral) > Tuning.handlingLateralDeg) {
                beginHandling()
            }
        }
        if isHandling {
            // Follow the phone's own rotation, so its yaw on the tray can be
            // carried over to wherever it is set down.
            handlingRotation = handlingRotation * Self.rotation(m.rotationRate * dt)
            let steady = angle(fastDown ?? observed, slowDown ?? observed) < Tuning.settleTiltDeg
            settleTimer = rateLevel < Tuning.settleRateDegPerSec && steady ? settleTimer + dt : 0
            if settleTimer >= Tuning.settleTime, let fastDown {
                endHandling(down: fastDown)
            } else {
                gyroTrust = 0
                bodyRates = .zero
                return
            }
        } else if abs(groundAcceleration) < 1 {
            // Learn only while the speed is steady: a takeoff roll's 0.25 g
            // tilts the plumb line 14° aft.
            mountAge += dt
            let learning = min(60, max(1, mountAge))
            mountDown = simd_normalize(lowPass(currentDown, observed, dt: dt, time: learning))
            mountPitchDeg = lowPass(mountPitchDeg, pitch, dt: dt, time: learning)
        }
        updateMount()
        gyroTrust = 1

        // Body rates: mount frame x right, y up, z aft, with the body pitched
        // up by mountPitchDeg in it; p about the nose (right wing down +),
        // q about the right wing (nose up +), r about the body's down axis
        // (nose right +). No pre-filter: the integration is the filter.
        let w = (mount ?? matrix_identity_double3x3) * m.rotationRate
        let o = mountPitchDeg * .pi / 180
        let nose = simd_double3(0, sin(o), -cos(o))
        let up = simd_double3(0, cos(o), sin(o))
        bodyRates = simd_double3(simd_dot(w, nose), w.x, -simd_dot(w, up))

        yawQueue.append(YawSample(time: clock, dt: dt, rate: m.rotationRate,
                                  force: m.gravity + m.userAcceleration, groundSpeedKts: gs,
                                  groundAcceleration: groundAcceleration, pitch: pitch,
                                  isAirborne: isAirborne))
        while let first = yawQueue.first, clock - first.time >= Tuning.yawLearningDelay {
            yawQueue.removeFirst()
            learnYaw(first)
        }
    }

    /// A fresh mount on `down`. A yaw learnt before is kept if the phone
    /// still lies roughly the same way, else the top edge / back is assumed.
    private mutating func anchorMount(down: simd_double3) {
        mountDown = down
        fastDown = down
        slowDown = down
        level = Self.minimalRotation(from: down, to: simd_double3(0, -1, 0))
        defaultNoseDevice = assumedNose()
        if let kept = noseDevice, horizontalLength(level * kept) > 0.7 {
            yawSource = yawSource == .assumed ? .assumed : .carried
        } else {
            noseDevice = defaultNoseDevice
            yawSource = .assumed
        }
        mountPitchDeg = pitch
        mountAge = 0
        bodyRates = .zero
        gyroTrust = 0
        resetYawLearning()
        updateMount()
    }

    private mutating func updateMount() {
        guard let mountDown else { return }
        level = Self.minimalRotation(from: mountDown, to: simd_double3(0, -1, 0))
        let n = horizontalNose()
        mount = Self.yawRotation(nose: n) * level
        let reference = level * defaultNoseDevice
        let r = simd_double2(reference.x, reference.z)
        phoneYawDeg = horizontalLength(level * defaultNoseDevice) > 0.3
            ? atan2(r.x * n.y - r.y * n.x, r.x * n.x + r.y * n.y) * -180 / .pi : 0
    }

    /// The nose as assumed before anything is learnt: lying flat, the
    /// screen's up as the passenger reads it (the top edge in portrait);
    /// standing, the phone's back.
    private func assumedNose() -> simd_double3 {
        let back = level.transpose * simd_double3(0, 0, -1)
        let screenNormal = level * simd_double3(0, 0, 1)
        if let up = screenUpDevice, abs(screenNormal.y) > 0.7, horizontalLength(level * up) > 0.5 {
            return up
        }
        return back
    }

    /// The applied nose in the level mount frame as (x, z), unit length.
    private func horizontalNose() -> simd_double2 {
        let n = level * (noseDevice ?? defaultNoseDevice)
        let h = simd_double2(n.x, n.z)
        return simd_length(h) > 1e-6 ? simd_normalize(h) : simd_double2(0, -1)
    }

    private mutating func beginHandling() {
        isHandling = true
        settleTimer = 0
        overRateTime = 0
        fastRateTime = 0
        handlingStartDown = mountDown ?? simd_double3(0, -1, 0)
        // The detection came late: go back to the attitude from before the
        // pick-up and replay the phone's rotation since then.
        handlingRotation = matrix_identity_double3x3
        yawQueue.removeAll()
        var start = recent.count - 1
        while start > 0 {
            let earlier = recent[start - 1]
            let age = clock - earlier.time
            if age > Tuning.handlingRewindMax { break }
            if age > Tuning.handlingRewindTime,
               simd_length(earlier.rate) * 180 / .pi < Tuning.handlingStartRateDegPerSec { break }
            start -= 1
        }
        if start >= 0, start < recent.count {
            let first = recent[start]
            roll = first.roll
            pitch = first.pitch
            // The phone's own rotation went into the turn rate as well.
            turnRateStage = first.turnRateStage
            turnRateReference = first.turnRateReference
            let delta = first.track - track
            track += delta
            for i in history.indices where history[i].time > first.time { history[i].track += delta }
            // The current sample follows in processMotion.
            for s in recent where s.time >= first.time && s.time < clock {
                handlingRotation = handlingRotation * Self.rotation(s.rate * s.dt)
            }
        }
        handlingStartTrack = track
    }

    private mutating func endHandling(down: simd_double3) {
        isHandling = false
        let previousNose = noseDevice ?? defaultNoseDevice
        // The aircraft turned meanwhile (the gyro saw that too): turn the old
        // nose with it, about the old down, then into the phone's new frame.
        let turned = Self.rotation(simd_normalize(handlingStartDown)
                                   * ((track - handlingStartTrack) * .pi / 180)) * previousNose
        let carried = handlingRotation.transpose * turned
        mountDown = down
        fastDown = down
        slowDown = down
        level = Self.minimalRotation(from: down, to: simd_double3(0, -1, 0))
        defaultNoseDevice = assumedNose()
        if horizontalLength(level * carried) > 0.5 {
            noseDevice = carried
            yawSource = .carried
        } else {
            noseDevice = defaultNoseDevice
            yawSource = .assumed
        }
        mountPitchDeg = pitch
        mountAge = 0
        bodyRates = .zero
        recoveryTimer = Tuning.recoveryTime
        resetYawLearning()
    }

    // MARK: - Yaw learning

    private mutating func resetYawLearning() {
        yawQueue.removeAll()
        forceBias = .zero
        forceFiltered = .zero
        groundSum = .zero
        groundEvidence = 0
        groundSpeedChange = 0
        rateSlow = .zero
        covXX = 0; covXZ = 0; covZZ = 0
        bankVector = .zero
        signVector = .zero
        flightLearnTime = 0
    }

    private mutating func learnYaw(_ sample: YawSample) {
        let dt = sample.dt
        let w = level * sample.rate * 180 / .pi                     // deg/s
        guard simd_length(w) < Tuning.yawLearningMaxRateDegPerSec else { return }
        let verticalRate = -w.y - yawBiasDegPerSec                  // nose right +
        let gs = sample.groundSpeedKts, groundAcceleration = sample.groundAcceleration

        if !sample.isAirborne {
            // (a) Accelerating, the phone feels a force toward the tail (the
            // reaction reading); braking, toward the nose. Weighting the
            // horizontal force by the signed GPS acceleration sums both into
            // the nose direction, and any sideways (turn) force averages out.
            let a = level * sample.force
            let h = simd_double2(a.x, a.z)
            if abs(groundAcceleration) < 0.3, abs(verticalRate) < 2 {
                forceBias = lowPass(forceBias, h, dt: dt, time: 3)   // tray tilt residue
            }
            // Roughly the lag of the GPS acceleration.
            forceFiltered = lowPass(forceFiltered, h - forceBias, dt: dt, time: 2)
            if gs >= Tuning.groundYawMinSpeedKts,
               abs(groundAcceleration) > Tuning.groundYawMinAccelKtsPerSec,
               abs(verticalRate) < Tuning.groundYawMaxTurnDegPerSec, abs(sample.pitch) < 3 {
                groundSum -= forceFiltered * groundAcceleration * dt
                groundEvidence += simd_length(forceFiltered) * abs(groundAcceleration) * dt
                groundSpeedChange += abs(groundAcceleration) * dt
            }
            if groundSpeedChange > Tuning.groundYawEvidenceKts,
               simd_length(groundSum) > Tuning.groundYawCoherence * groundEvidence {
                adoptNose(simd_normalize(groundSum), source: .ground)
            }
            return
        }

        // (b) In flight the aircraft rolls far more than it pitches — in
        // turns and in turbulence alike — so the dominant horizontal rotation
        // axis is the longitudinal one. High-passed, so the steady pitch rate
        // of a turn (q = ψ̇·sinφ) does not count.
        let rate = simd_double2(w.x, w.z)
        rateSlow = lowPass(rateSlow, rate, dt: dt, time: Tuning.flightYawHighPass)
        let hp = rate - rateSlow
        let decay = exp(-dt / Tuning.flightYawWindow)
        covXX = covXX * decay + hp.x * hp.x * dt
        covXZ = covXZ * decay + hp.x * hp.y * dt
        covZZ = covZZ * decay + hp.y * hp.y * dt
        // Nose or tail: about the nose, a roll to the right (bank > 0) is
        // followed by a right turn (ψ̇ > 0). Σ bank·ψ̇ along the axis says
        // which end is which.
        bankVector = bankVector * exp(-dt / Tuning.flightYawBankLeak) + rate * dt
        signVector = signVector * decay + bankVector * verticalRate * dt
        flightLearnTime += dt

        let mean = (covXX + covZZ) / 2
        let spread = (((covXX - covZZ) / 2) * ((covXX - covZZ) / 2) + covXZ * covXZ).squareRoot()
        let major = mean + spread, minor = mean - spread
        guard flightLearnTime >= Tuning.flightYawMinTime, major > Tuning.flightYawMinEnergy,
              minor < Tuning.flightYawMaxAnisotropy * major else { return }
        let beta = 0.5 * atan2(2 * covXZ, covXX - covZZ)
        var axis = simd_double2(cos(beta), sin(beta))
        let evidence = simd_dot(axis, signVector)
        let resolved = abs(evidence) > Tuning.flightYawSignEvidence
        if resolved {
            if evidence < 0 { axis = -axis }
        } else if simd_dot(axis, horizontalNose()) < 0 {
            axis = -axis                     // the end nearer the current guess
        }
        if yawSource == .ground {
            // The take-off estimate is the better one; only a phone that
            // clearly slid on the tray overrides it.
            guard resolved, minor < Tuning.flightOverrideAnisotropy * major,
                  angleDeg(axis, horizontalNose()) > Tuning.flightOverridesGroundDeg else { return }
        }
        adoptNose(axis, source: .flight)
    }

    /// Apply a learnt nose direction (level mount frame, (x, z)). The
    /// attitude is re-projected onto the new axes — what was integrated
    /// through the old ones was the same physical tilt — and the display
    /// glides over the difference.
    private mutating func adoptNose(_ nose: simd_double2, source: YawSource) {
        let old = horizontalNose()
        let upgrade = rank(source) > rank(yawSource)
        guard angleDeg(nose, old) > (upgrade ? Tuning.yawUpgradeDeg : Tuning.yawApplyDeg) else {
            if source == .ground || yawSource != .ground { yawSource = source }
            return
        }
        // Tilt as a horizontal rotation vector: roll about the nose, pitch
        // (relative to the reference) about the right wing. Right = (−z, x)
        // in (x, z) for a nose (x, z): up × aft.
        let rightOld = simd_double2(-old.y, old.x)
        let rightNew = simd_double2(-nose.y, nose.x)
        let pitchBase = pitchReference
        let tilt = roll * old + (pitch - pitchBase) * rightOld
        let newRoll = simd_dot(tilt, nose)
        let newPitch = pitchBase + simd_dot(tilt, rightNew)
        rollOffset += roll - newRoll
        pitchOffset += pitch - newPitch
        rollStage += newRoll - roll
        rollLagged += newRoll - roll
        pitchLagged += newPitch - pitch
        roll = newRoll
        pitch = newPitch

        noseDevice = level.transpose * simd_double3(nose.x, 0, nose.y)
        yawSource = source
        updateMount()
    }

    private func rank(_ source: YawSource) -> Int {
        switch source {
        case .assumed: return 0
        case .carried: return 1
        case .flight: return 2
        case .ground: return 3
        }
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

        let gyro = gyroTrust > 0.5
        let rollGain: Double
        let pitchGain: Double
        if !gyro {
            rollGain = Tuning.coastRollGain
            pitchGain = Tuning.coastPitchGain
        } else if recoveryTimer > 0 {
            // Just set down: the attitude is what the references coasted to.
            let f = recoveryTimer / Tuning.recoveryTime
            rollGain = Tuning.rollGainStraight + (Tuning.coastRollGain - Tuning.rollGainStraight) * f
            pitchGain = Tuning.pitchGain + (Tuning.coastPitchGain - Tuning.pitchGain) * f
            recoveryTimer = max(0, recoveryTimer - dt)
        } else if isAirborne {
            let x = turnRateReference / Tuning.rollGainTurnRate
            rollGain = Tuning.rollGainTurning
                + (Tuning.rollGainStraight - Tuning.rollGainTurning) / (1 + x * x)
            pitchGain = Tuning.pitchGain
        } else {
            rollGain = Tuning.groundRollGain
            // Fast on the runway the aircraft rotates: the gyro alone, and
            // the pitch reference waits where the estimate is, so lift-off
            // starts without a pull.
            pitchGain = isGroundDynamics ? Tuning.groundPitchGain : 0
        }
        if pitchGain == 0 { pitchReference = pitchLagged }

        if gyro {
            roll += phiDot * dt
            pitch += thetaDot * dt
        }
        roll += rollGain * (rollReference - rollLagged) * dt
        pitch += pitchGain * (pitchReference - pitchLagged) * dt
        roll = clamp(roll, 60)
        pitch = min(30, max(-20, pitch))

        let fade = exp(-dt / Tuning.reprojectionDisplayTime)
        rollOffset *= fade
        pitchOffset *= fade
        rollDeg = lowPass(rollDeg, roll + rollOffset, dt: dt, time: Tuning.displayTime)
        pitchDeg = lowPass(pitchDeg, pitch + pitchOffset, dt: dt, time: Tuning.displayTime)
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

    /// The rotation by the rotation vector `v` (axis × angle, rad).
    static func rotation(_ v: simd_double3) -> simd_double3x3 {
        let angle = simd_length(v)
        guard angle > 1e-12 else { return matrix_identity_double3x3 }
        let k = v / angle
        let skew = simd_double3x3(rows: [
            simd_double3(0, -k.z, k.y),
            simd_double3(k.z, 0, -k.x),
            simd_double3(-k.y, k.x, 0),
        ])
        return matrix_identity_double3x3 + sin(angle) * skew + (1 - cos(angle)) * (skew * skew)
    }

    /// Level mount → cabin: the yaw that turns `nose` ((x, z) in the level
    /// mount frame) onto the cabin nose (0, 0, −1).
    static func yawRotation(nose n: simd_double2) -> simd_double3x3 {
        let aft = simd_double3(-n.x, 0, -n.y)
        let up = simd_double3(0, 1, 0)
        let right = simd_cross(up, aft)
        return simd_double3x3(rows: [right, up, aft])
    }
}

/// First-order low-pass step, independent of the step rate.
private func lowPass(_ value: Double, _ target: Double, dt: Double, time: Double) -> Double {
    value + (target - value) * -expm1(-dt / time)
}

private func lowPass(_ value: simd_double3, _ target: simd_double3, dt: Double, time: Double) -> simd_double3 {
    value + (target - value) * -expm1(-dt / time)
}

private func lowPass(_ value: simd_double2, _ target: simd_double2, dt: Double, time: Double) -> simd_double2 {
    value + (target - value) * -expm1(-dt / time)
}

private func slew(_ target: Double, from value: Double, rate: Double, dt: Double) -> Double {
    value + clamp(target - value, rate * dt)
}

private func clamp(_ x: Double, _ limit: Double) -> Double { min(limit, max(-limit, x)) }

/// Angle between two unit vectors, deg.
private func angle(_ a: simd_double3, _ b: simd_double3) -> Double {
    acos(min(1, max(-1, simd_dot(a, b)))) * 180 / .pi
}

private func angleDeg(_ a: simd_double2, _ b: simd_double2) -> Double {
    acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
}

private func horizontalLength(_ v: simd_double3) -> Double { simd_double2(v.x, v.z).length }

private extension simd_double2 {
    var length: Double { simd_length(self) }
}

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
