import Foundation
import CoreMotion
import CoreLocation
import Combine
import simd

/// Unit used by every speed readout. Values are computed in knots internally;
/// conversion happens at the display edge.
enum SpeedUnit: String, CaseIterable {
    case kmh, mph, knots

    /// Display units per knot.
    var perKnot: Double {
        switch self {
        case .kmh: return 1.852
        case .mph: return 1.150779
        case .knots: return 1
        }
    }

    var label: String {
        switch self {
        case .kmh: return "KM/H"
        case .mph: return "MPH"
        case .knots: return "KT"
        }
    }
}

/// Unit for the vertical speed scale. In m/s the scale keeps the reference
/// display's geometry but spans ±6 m/s — car-sized — instead of ±6000 ft/min.
enum VerticalSpeedUnit: String, CaseIterable {
    case ms, fpm

    var label: String {
        switch self {
        case .ms: return "M/S"
        case .fpm: return "FT/MIN"
        }
    }
}

/// Publishes live flight data derived from the phone's sensors.
///
/// Conventions (all angles in degrees):
/// - The phone is assumed to be mounted like an instrument panel: roughly
///   vertical, screen facing the pilot, top edge up. A mount at any other
///   angle can be captured as the zero reference with ``calibrate()``.
/// - `pitchDeg` positive = nose up (top of phone tilts toward the pilot).
/// - `rollDeg`  positive = right bank.
/// - `headingDeg` = magnetic heading while (nearly) stationary, GPS track
///   while moving — GPS track is far more reliable in a moving vehicle.
@MainActor
final class FlightDataModel: NSObject, ObservableObject {

    // MARK: Published flight data
    @Published private(set) var pitchDeg: Double = 0
    @Published private(set) var rollDeg: Double = 0
    @Published private(set) var headingDeg: Double = 0
    @Published private(set) var trackDeg: Double = 0          // GPS ground track
    @Published private(set) var groundSpeedKts: Double = 0
    /// Speed change projected 10 s ahead — the yellow trend arrow on the tape.
    /// Rate-limited to ±12 kt/s, as the reference display draws it.
    @Published private(set) var speedTrendKts: Double = 0
    /// Trend-arrow visibility, with the reference display's hysteresis:
    /// shown above 2 kt of trend, hidden again only below 1 kt.
    @Published private(set) var isSpeedTrendShown = false
    @Published private(set) var altitudeFt: Double = 0
    @Published private(set) var verticalSpeedFpm: Double = 0
    @Published private(set) var location: CLLocation?
    @Published private(set) var isDemoMode = false

    /// Wind is only known when something can solve the wind triangle for us.
    /// A phone has no air-data source, so outside demo mode this stays nil and
    /// the ND shows the Airbus amber dashes instead of inventing a number.
    @Published private(set) var windDirDeg: Double?
    @Published private(set) var windSpeedKts: Double?

    /// FCU selected altitude — the cyan bug on the altitude tape.
    @Published var selectedAltitudeFt: Double = 3_000
    /// True while the baro reference is STD (above transition altitude).
    @Published var isStandardBaro: Bool = true

    /// True while a calibration pose is active — pitch and roll are then
    /// measured relative to it rather than to a vertical phone.
    @Published private(set) var isCalibrated = false

    /// How the displays print speeds. A car flies in km/h.
    @Published var speedUnit: SpeedUnit = .kmh {
        didSet { UserDefaults.standard.set(speedUnit.rawValue, forKey: Self.speedUnitKey) }
    }
    private static let speedUnitKey = "speedDisplayUnit"

    /// Vertical speed scale unit — m/s by default; a car never sees
    /// 1000 ft/min.
    @Published var verticalSpeedUnit: VerticalSpeedUnit = .ms {
        didSet { UserDefaults.standard.set(verticalSpeedUnit.rawValue, forKey: Self.vsUnitKey) }
    }
    private static let vsUnitKey = "verticalSpeedDisplayUnit"

    // MARK: Derived air data

    /// True airspeed.
    ///
    /// With no pitot-static input the best we can do is ground speed corrected
    /// for whatever wind we know about. Good enough to drive the Mach readout;
    /// not good enough to fly on.
    var tasKts: Double {
        guard let dir = windDirDeg, let speed = windSpeedKts else { return groundSpeedKts }
        // Head/tail component of the wind along the current track.
        let delta = (dir - trackDeg) * .pi / 180
        return groundSpeedKts + speed * cos(delta)
    }

    /// Mach number from TAS against the ISA speed of sound at this altitude.
    var machNumber: Double {
        let isaTempK = max(216.65, 288.15 - 0.0019812 * altitudeFt)   // ISA lapse, capped at the tropopause
        let speedOfSoundKts = 661.4788 * (isaTempK / 288.15).squareRoot()
        return tasKts / speedOfSoundKts
    }

    /// Flight path angle — the vertical angle the aircraft is actually moving
    /// along, which is what the FPV "bird" is parked on.
    var flightPathAngleDeg: Double {
        let horizontalFps = groundSpeedKts * 1.68781
        guard horizontalFps > 10 else { return 0 }
        return atan2(verticalSpeedFpm / 60, horizontalFps) * 180 / .pi
    }

    /// Drift — track minus heading, positive to the right.
    var driftAngleDeg: Double { angularDifference(trackDeg, headingDeg) }

    // MARK: Internals
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let locationManager = CLLocationManager()
    /// Maps the gravity vector captured by ``calibrate()`` onto a vertical
    /// phone's, so that pose reads as 0° pitch and 0° roll.
    private var calibrationRotation: simd_double3x3?
    private var lastGravity: simd_double3?
    private static let calibrationKey = "attitudeCalibrationZeroGravity"
    private var magneticHeadingDeg: Double = 0
    private var lastAltitudeSample: (date: Date, feet: Double)?
    private var lastSpeedSample: (date: Date, kts: Double)?

    // Speed display dynamics (see stepSpeedDynamics).
    private var gpsSpeedKts = 0.0
    private var speedTrendTargetKts = 0.0
    private var speedLagFilter = LagFilter(cornerFrequency: 1.2)
    private var trendRateLimiter = RateLimiter(risingRate: 12, fallingRate: -12)
    private var lastMotionTimestamp: TimeInterval?

    // Vertical speed: barometric when the phone has a pressure sensor,
    // GPS-derived otherwise.
    private var hasBarometer = false
    private var lastBaroSample: (time: TimeInterval, meters: Double)?
    private var verticalSpeedTargetFpm = 0.0
    private var verticalSpeedLagFilter = LagFilter(cornerFrequency: 1.2)
    private var demoTimer: Timer?
    private var hasInitialisedSelectedAltitude = false

    private static let mpsToKts = 1.943844
    private static let metersToFt = 3.28084

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .otherNavigation
        loadCalibration()
        if let raw = UserDefaults.standard.string(forKey: Self.speedUnitKey),
           let unit = SpeedUnit(rawValue: raw) {
            speedUnit = unit
        }
        if let raw = UserDefaults.standard.string(forKey: Self.vsUnitKey),
           let unit = VerticalSpeedUnit(rawValue: raw) {
            verticalSpeedUnit = unit
        }
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        startMotionUpdates()
        startAltimeterUpdates()
        #if targetEnvironment(simulator)
        startDemoMode()
        #else
        if !motion.isDeviceMotionAvailable { startDemoMode() }
        #endif
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        locationManager.stopUpdatingLocation()
        demoTimer?.invalidate()
        demoTimer = nil
    }

    // MARK: - Barometric vertical speed

    /// The pressure sensor resolves centimetres of height change at about
    /// 1 Hz — a far faster and cleaner climb rate than differentiating GPS
    /// altitude, which is what the V/S needle had to make do with before.
    private func startAltimeterUpdates() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        hasBarometer = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data, !self.isDemoMode else { return }
            let meters = data.relativeAltitude.doubleValue
            if let last = self.lastBaroSample {
                let dt = data.timestamp - last.time
                if dt > 0.1 {
                    self.verticalSpeedTargetFpm =
                        (meters - last.meters) * Self.metersToFt / dt * 60
                }
            }
            self.lastBaroSample = (data.timestamp, meters)
        }
    }

    // MARK: - Calibration

    /// Capture the phone's current pose as the zero reference, so pitch and
    /// roll read relative to however it happens to be mounted. Persists
    /// across launches; no-op until the first motion sample arrives.
    func calibrate() {
        guard let gravity = lastGravity else { return }
        setCalibration(zeroGravity: gravity)
        UserDefaults.standard.set([gravity.x, gravity.y, gravity.z],
                                  forKey: Self.calibrationKey)
    }

    /// Return to the built-in reference: a vertical, panel-mounted phone.
    func clearCalibration() {
        calibrationRotation = nil
        isCalibrated = false
        UserDefaults.standard.removeObject(forKey: Self.calibrationKey)
    }

    private func setCalibration(zeroGravity gravity: simd_double3) {
        calibrationRotation = Self.rotation(from: simd_normalize(gravity),
                                            to: simd_double3(0, -1, 0))
        isCalibrated = true
    }

    private func loadCalibration() {
        guard let stored = UserDefaults.standard.array(forKey: Self.calibrationKey) as? [Double],
              stored.count == 3 else { return }
        setCalibration(zeroGravity: simd_double3(stored[0], stored[1], stored[2]))
    }

    /// The smallest rotation carrying unit vector `a` onto unit vector `b`
    /// (Rodrigues' formula). Rotating only the gravity vector — rather than
    /// subtracting angle offsets — keeps pitch and roll orthogonal at steep
    /// mounting angles, and leaves rotation about gravity (heading) alone.
    private static func rotation(from a: simd_double3, to b: simd_double3) -> simd_double3x3 {
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

    // MARK: - Motion (pitch / roll / magnetic heading)

    private func startMotionUpdates() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
            ? .xMagneticNorthZVertical : .xArbitraryZVertical
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.processDeviceMotion(dm, magneticFrame: frame == .xMagneticNorthZVertical)
        }
    }

    private func processDeviceMotion(_ dm: CMDeviceMotion, magneticFrame: Bool) {
        guard !isDemoMode else { return }

        // The motion callback is the display's frame clock: step the speed
        // dynamics here so the tape glides at 30 Hz between 1 Hz GPS fixes.
        if let last = lastMotionTimestamp {
            stepSpeedDynamics(deltaTime: dm.timestamp - last)
        }
        lastMotionTimestamp = dm.timestamp

        let g = dm.gravity   // unit vector toward the ground, in device coordinates
        lastGravity = simd_double3(g.x, g.y, g.z)

        // 0° pitch/roll when the phone is exactly vertical — or, once
        // calibrated, in whatever pose the crew captured as zero.
        let gv = calibrationRotation.map { $0 * lastGravity! } ?? lastGravity!
        pitchDeg = atan2(gv.z, -gv.y) * 180 / .pi
        rollDeg  = atan2(gv.x, -gv.y) * 180 / .pi

        if magneticFrame {
            // Reference frame: x = magnetic north, z = up, y = west.
            // Heading of whichever device axis currently points "forward":
            // the back of the phone (-z) when panel-mounted / near vertical,
            // the top of the phone (+y) when the phone is held flat.
            let m = dm.attitude.rotationMatrix
            let raw: Double
            if abs(g.z) < abs(g.y) {
                raw = atan2(m.m23, -m.m13)          // back-of-device projection
            } else {
                raw = atan2(-m.m22, m.m12)          // top-of-device projection
            }
            magneticHeadingDeg = (raw * 180 / .pi + 360)
                .truncatingRemainder(dividingBy: 360)
        }
        updateHeading()
    }

    /// Prefer GPS track when moving; magnetic heading only when slow/stationary.
    private func updateHeading() {
        if groundSpeedKts > 3 {
            headingDeg = trackDeg
        } else {
            headingDeg = magneticHeadingDeg
            // Stationary, there is no meaningful track: park it on the heading
            // so the ND track line stays on the lubber line instead of
            // swinging to wherever a stale GPS course points.
            trackDeg = headingDeg
        }
    }

    // MARK: - Speed display dynamics

    /// Display dynamics from the A32NX PFD: the tape value and the V/S needle
    /// glide through first-order lags, and the trend arrow slews at no more
    /// than ±12 kt/s toward its target, appearing above 2 kt of trend and
    /// disappearing only below 1 kt. Stepped at the motion rate (or the demo
    /// timer), so everything animates smoothly even though the sensors only
    /// report about once a second.
    private func stepSpeedDynamics(deltaTime: Double) {
        guard deltaTime > 0, deltaTime < 2 else { return }
        groundSpeedKts = speedLagFilter.step(gpsSpeedKts, deltaTime: deltaTime)
        speedTrendKts = trendRateLimiter.step(speedTrendTargetKts, deltaTime: deltaTime)
        verticalSpeedFpm = verticalSpeedLagFilter.step(verticalSpeedTargetFpm,
                                                       deltaTime: deltaTime)

        if abs(speedTrendTargetKts) < 1 {
            isSpeedTrendShown = false
        } else if abs(speedTrendTargetKts) > 2 {
            isSpeedTrendShown = true
        }
    }

    // MARK: - Location processing

    private func processLocation(_ loc: CLLocation) {
        guard !isDemoMode else { return }
        location = loc

        if loc.speed >= 0 {
            // Each fix only retargets the display dynamics — the tape itself
            // glides toward the new value in stepSpeedDynamics.
            gpsSpeedKts = loc.speed * Self.mpsToKts

            if let last = lastSpeedSample {
                let dt = loc.timestamp.timeIntervalSince(last.date)
                if dt > 0.5 {
                    let trend = (gpsSpeedKts - last.kts) / dt * 10   // 10 s projection
                    speedTrendTargetKts += (trend - speedTrendTargetKts) * 0.2
                    lastSpeedSample = (loc.timestamp, gpsSpeedKts)
                }
            } else {
                lastSpeedSample = (loc.timestamp, gpsSpeedKts)
            }
        }
        if loc.course >= 0, loc.speed * Self.mpsToKts > 3 {
            trackDeg = loc.course
        }
        if loc.verticalAccuracy > 0 {
            let feet = loc.altitude * Self.metersToFt
            altitudeFt += (feet - altitudeFt) * 0.3

            // Park the FCU bug a round 1000 ft above the first fix so the
            // altitude tape has a sensible target until the crew moves it.
            if !hasInitialisedSelectedAltitude {
                hasInitialisedSelectedAltitude = true
                selectedAltitudeFt = ((altitudeFt / 1_000).rounded(.down) + 1) * 1_000
            }

            // GPS-derived climb rate, for devices without a barometer only.
            // Differenced from the raw fixes — differencing the smoothed
            // altitude would stack a second lag on top.
            if let last = lastAltitudeSample {
                let dt = loc.timestamp.timeIntervalSince(last.date)
                if dt > 0.5 {
                    if !hasBarometer {
                        let fpm = (feet - last.feet) / dt * 60
                        verticalSpeedTargetFpm += (fpm - verticalSpeedTargetFpm) * 0.4
                    }
                    lastAltitudeSample = (loc.timestamp, feet)
                }
            } else {
                lastAltitudeSample = (loc.timestamp, feet)
            }
        }
        updateHeading()
    }

    // MARK: - Demo mode (Simulator / devices without motion sensors)

    /// Flies a gentle climbing right turn from a seed position so all
    /// displays are alive without real sensors.
    private func startDemoMode() {
        guard demoTimer == nil else { return }
        isDemoMode = true
        var demoHeading = 80.0
        var demoAltFt = 9_800.0
        var demoLat = 42.363, demoLon = -71.006     // over Boston Logan
        var t = 0.0

        // A steady climb at a jet speed so the Mach, VLS and VMAX annotations
        // on the tapes all sit somewhere meaningful.
        windDirDeg = 270
        windSpeedKts = 46
        selectedAltitudeFt = 12_000

        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                t += 1.0 / 30.0
                let bank = 12 + 8 * sin(t / 6)
                let speed = 280.0
                demoHeading = (demoHeading + bank * 0.09 / 30).truncatingRemainder(dividingBy: 360)
                demoAltFt += 900.0 / 60 / 30

                // Dead-reckon the position (1 kt ≈ 1/60 deg lat per hour).
                let distDeg = speed / 3600.0 / 60.0 / 30.0
                demoLat += distDeg * cos(demoHeading * .pi / 180)
                demoLon += distDeg * sin(demoHeading * .pi / 180) / cos(demoLat * .pi / 180)

                self.pitchDeg = 7 + 2 * sin(t / 4)
                self.rollDeg = bank
                // Crabbing into the demo wind, so track and heading differ and
                // the drift-driven symbology (FPV, track line) is visible.
                self.trackDeg = demoHeading
                self.headingDeg = normalizedHeading(demoHeading - 6)
                self.gpsSpeedKts = speed + 5 * sin(t / 9)
                self.speedTrendTargetKts = 5.0 / 9 * cos(t / 9) * 10    // d(GS)/dt over 10 s
                self.stepSpeedDynamics(deltaTime: 1.0 / 30.0)
                self.altitudeFt = demoAltFt
                self.verticalSpeedTargetFpm = 900 + 100 * sin(t / 4)
                self.location = CLLocation(
                    coordinate: .init(latitude: demoLat, longitude: demoLon),
                    altitude: demoAltFt / Self.metersToFt,
                    horizontalAccuracy: 5, verticalAccuracy: 5,
                    course: demoHeading, speed: speed / Self.mpsToKts,
                    timestamp: Date()
                )
            }
        }
    }
}

// MARK: - Display dynamics filters
//
// Ported from the FlyByWire A32NX PFD (PFDUtils.tsx), which is the reference
// implementation for how these displays move.

/// First-order lag filter (bilinear discretisation).
struct LagFilter {
    private var previousInput = 0.0
    private var previousOutput = 0.0
    let cornerFrequency: Double

    init(cornerFrequency: Double) {
        self.cornerFrequency = cornerFrequency
    }

    mutating func step(_ input: Double, deltaTime: Double) -> Double {
        let input = input.isNaN ? 0 : input
        let scaled = deltaTime * cornerFrequency
        let sum0 = scaled + 2
        let output = (input + previousInput) * scaled / sum0
            + (2 - scaled) / sum0 * previousOutput
        previousInput = input
        if output.isFinite { previousOutput = output }
        return previousOutput
    }
}

/// Limits how fast the output may chase the input, with separate rising and
/// falling rates (per second).
struct RateLimiter {
    private var previousOutput = 0.0
    let risingRate: Double
    let fallingRate: Double

    init(risingRate: Double, fallingRate: Double) {
        self.risingRate = risingRate
        self.fallingRate = fallingRate
    }

    mutating func step(_ input: Double, deltaTime: Double) -> Double {
        let input = input.isNaN ? 0 : input
        let delta = input - previousOutput
        previousOutput += max(min(risingRate * deltaTime, delta), fallingRate * deltaTime)
        return previousOutput
    }
}

// MARK: - CLLocationManagerDelegate

extension FlightDataModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.processLocation(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Keep last known values; GPS will recover on its own.
    }
}
