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

/// Unit for the vertical speed scale. In m/s the scale keeps the same
/// graduations but spans ±6 m/s — car-sized — instead of ±6000 ft/min.
enum VerticalSpeedUnit: String, CaseIterable {
    case ms, fpm

    var label: String {
        switch self {
        case .ms: return "M/S"
        case .fpm: return "FT/MIN"
        }
    }
}

/// Where the roll indication comes from.
enum RollSource: String, CaseIterable {
    /// The phone's physical bank, read off the gravity vector — an aircraft's
    /// roll. A car corners flat, so on the road this sits at zero.
    case tilt
    /// The bank an aircraft would need to fly the same turn: the angle a plumb
    /// line swings out to under the vehicle's lateral acceleration, so a
    /// 0.3 g corner reads as a 17° bank. Tilt is still added in, so a banked
    /// road reads the same as a flat one taken at the same cornering force.
    case lateralAcceleration

    var label: String {
        switch self {
        case .tilt: return "TILT"
        case .lateralAcceleration: return "LATERAL G"
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
///   In plane mode it is always the track, from ``PlaneModeEstimator``.
///
/// GPS reports about once a second; the motion sensors sixty times a second.
/// Everything the displays draw is stepped at the motion rate — the speed
/// tape and V/S needle through first-order smoothing, track,
/// position and altitude by dead reckoning between fixes — so the picture
/// moves continuously rather than once a second.
@MainActor
final class FlightDataModel: NSObject, ObservableObject {

    // MARK: Published flight data
    @Published private(set) var pitchDeg: Double = 0
    @Published private(set) var rollDeg: Double = 0
    @Published private(set) var headingDeg: Double = 0
    @Published private(set) var trackDeg: Double = 0          // GPS ground track
    @Published private(set) var groundSpeedKts: Double = 0
    /// Speed change projected 10 s ahead — the yellow trend arrow on the tape.
    /// Slew-limited, so the arrow grows and shrinks steadily rather than
    /// jumping with each GPS fix.
    @Published private(set) var speedTrendKts: Double = 0
    /// Trend-arrow visibility, with hysteresis so it does not flicker:
    /// shown above 2 kt of trend, hidden again only below 1 kt.
    @Published private(set) var isSpeedTrendShown = false
    @Published private(set) var altitudeFt: Double = 0
    @Published private(set) var verticalSpeedFpm: Double = 0
    /// Present position, dead-reckoned at the motion rate between GPS fixes.
    /// This is what the displays draw from.
    @Published private(set) var location: CLLocation?
    /// The raw GPS fixes, about once a second, for consumers that want
    /// measurements rather than a smooth picture — the speed-limit lookup.
    @Published private(set) var gpsFix: CLLocation?
    /// Lateral acceleration in the vehicle frame, in g, positive to the right.
    @Published private(set) var lateralG: Double = 0
    @Published private(set) var isDemoMode = false
    /// Whether the user has let the app use location. Without it there is
    /// no speed, track, altitude or position, and the displays say so.
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined

    var isLocationDenied: Bool {
        !isDemoMode && (locationAuthorization == .denied || locationAuthorization == .restricted)
    }

    /// Wind is only known when something can solve the wind triangle for us.
    /// A phone has no air-data source, so outside demo mode this stays nil and
    /// the ND shows the Airbus amber dashes instead of inventing a number.
    @Published private(set) var windDirDeg: Double?
    @Published private(set) var windSpeedKts: Double?

    /// FCU selected altitude — the cyan bug on the altitude tape.
    @Published var selectedAltitudeFt: Double = 3_000
    /// The rest of the FCU / MCP: speed, heading, V/S, FD, AP, approach.
    @Published var autoFlight = AutoFlight()
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

    /// What the roll indication measures — see ``RollSource``. Lateral G by
    /// default: this is an instrument for the road.
    @Published var rollSource: RollSource = .lateralAcceleration {
        didSet { UserDefaults.standard.set(rollSource.rawValue, forKey: Self.rollSourceKey) }
    }
    private static let rollSourceKey = "rollSource"

    /// Riding in an airliner rather than driving: set from the PLANE
    /// transport mode. In the cabin the barometer reads cabin pressure, the
    /// compass sits among metal and wiring, and a coordinated turn leaves no
    /// lateral force to sense. ``PlaneModeEstimator`` then supplies
    /// attitude, track and altitude: the gyro for every fast change,
    /// corrected toward the coordinated-turn bank, the flight path and the
    /// GPS course and altitude.
    @Published var isFlightMode = false {
        didSet {
            guard isFlightMode != oldValue else { return }
            verticalSpeedTargetFpm = 0
            lastBaroSample = nil
            lastAltitudeSample = nil
            planeEstimator = PlaneModeEstimator(trackDeg: trackDeg)
            if isFlightMode {
                if altitudeAnchorFt != nil {
                    planeEstimator.seedAltitude(feet: altitudeFt, verticalSpeedFpm: 0)
                }
            } else {
                // Back on the road: restart the track from the next fix and
                // carry on from the altitude plane mode left on display.
                trackAnchorDeg = nil
                if altitudeAnchorFt != nil { altitudeAnchorFt = altitudeFt }
            }
        }
    }
    /// Plane-mode sensor fusion; idle outside plane mode.
    private var planeEstimator = PlaneModeEstimator()

    /// In the Simulator, a flight plan for the demo to fly — climb, cruise
    /// and descent along its path — instead of the circuit over Boston.
    var demoFlightPlan: FlightPlan? {
        didSet {
            guard isDemoMode, demoFlightPlan?.id != oldValue?.id else { return }
            demoTimer?.invalidate()
            demoTimer = nil
            startDemoMode()
        }
    }

    /// Whose flight deck the displays imitate — see ``DisplayStyle``.
    @Published var displayStyle: DisplayStyle = .airbus {
        didSet { UserDefaults.standard.set(displayStyle.rawValue, forKey: Self.displayStyleKey) }
    }
    private static let displayStyleKey = "displayStyle"

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

    /// The motion sensors run at this rate, and so does everything derived
    /// from them — it is the displays' frame clock.
    private static let motionRateHz = 60.0

    // Speed display dynamics (see stepSpeedDynamics).
    private var gpsSpeedKts = 0.0
    private var speedTrendTargetKts = 0.0
    private var speedSmoother = Smoother(timeConstant: 0.8)
    private var trendSlew = SlewLimiter(maxRate: 10)
    private var lastMotionTimestamp: TimeInterval?
    /// The interval of the latest motion step, for filters run alongside it.
    private var lastMotionStepInterval: Double?
    private var lastMotionDate: Date?

    // Vehicle acceleration, low-passed to strip road vibration (see
    // updateAttitude).
    private var accelerationFilter = VectorSmoother(timeConstant: 1.4)
    /// Rate of turn about the vertical, °/s, smoothed — the flight-mode bank.
    private var turnRateSmoother = Smoother(timeConstant: 1.5)
    private var filteredAcceleration = simd_double3(repeating: 0)

    // Dead reckoning between GPS fixes (see stepDeadReckoning). Each anchor is
    // the last fix, carried forward the same way the display value is, so the
    // difference between them is the error left to close.
    private var displayCoordinate: CLLocationCoordinate2D?
    private var fixAnchor: CLLocationCoordinate2D?
    private var trackAnchorDeg: Double?
    private var altitudeAnchorFt: Double?
    private var lastFixAccuracy: (horizontal: Double, vertical: Double) = (0, 0)
    /// Fraction of the remaining anchor error closed per second.
    private static let anchorPullRate = 2.0
    /// GPS altitude is the noisiest of the three; the barometer-driven climb
    /// carries most of the weight and the fix pulls only gently.
    private static let altitudeAnchorPullRate = 0.4

    // Vertical speed: barometric when the phone has a pressure sensor,
    // GPS-derived otherwise.
    private var hasBarometer = false
    private var lastBaroSample: (time: TimeInterval, meters: Double)?
    private var verticalSpeedTargetFpm = 0.0
    private var verticalSpeedSmoother = Smoother(timeConstant: 0.8)
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
        if let raw = UserDefaults.standard.string(forKey: Self.rollSourceKey),
           let source = RollSource(rawValue: raw) {
            rollSource = source
        }
        if let raw = UserDefaults.standard.string(forKey: Self.displayStyleKey),
           let style = DisplayStyle(rawValue: raw) {
            displayStyle = style
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
            guard let self, let data, !self.isDemoMode, !self.isFlightMode else { return }
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
        // In plane mode attitude is physical, not relative to a captured
        // pose: attitude zero only tells the estimator where the phone now
        // sits, and leaves the car's mounting calibration as it was.
        if isFlightMode {
            planeEstimator.reanchorMount()
            return
        }
        guard let gravity = lastGravity else { return }
        setCalibration(zeroGravity: gravity)
        UserDefaults.standard.set([gravity.x, gravity.y, gravity.z],
                                  forKey: Self.calibrationKey)
    }

    /// Return to the built-in reference: a vertical, panel-mounted phone.
    func clearCalibration() {
        if isFlightMode {
            planeEstimator.reanchorMount()
            return
        }
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
        motion.deviceMotionUpdateInterval = 1.0 / Self.motionRateHz
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
        lastMotionDate = Date()

        // Unit vector toward the ground, the accelerometer's reaction to the
        // vehicle's own acceleration (both in g) and the turn rates, all in
        // device coordinates.
        let rawGravity = simd_double3(dm.gravity.x, dm.gravity.y, dm.gravity.z)
        let g = simd_length(rawGravity) > 0.5 ? simd_normalize(rawGravity) : simd_double3(0, -1, 0)
        lastGravity = g
        let acceleration = simd_double3(dm.userAcceleration.x, dm.userAcceleration.y,
                                        dm.userAcceleration.z)
        let rotationRate = simd_double3(dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z)

        // The motion callback is the display's frame clock: step every
        // dynamic here so the picture glides at the motion rate between 1 Hz
        // GPS fixes.
        lastMotionStepInterval = nil
        if let last = lastMotionTimestamp, dm.timestamp - last > 0, dm.timestamp - last < 2 {
            let dt = dm.timestamp - last
            lastMotionStepInterval = dt
            filteredAcceleration = accelerationFilter.step(toward: acceleration, deltaTime: dt)
            stepSpeedDynamics(deltaTime: dt)
            // Rate of turn about the vertical, clockwise from above positive:
            // the rotation-rate component along gravity.
            let turnRate = simd_dot(rotationRate, g) * 180 / .pi
            _ = turnRateSmoother.step(toward: turnRate, deltaTime: dt)
            if isFlightMode {
                planeEstimator.step(
                    dt: dt, time: Date().timeIntervalSinceReferenceDate,
                    motion: .init(rotationRate: rotationRate, gravity: g, userAcceleration: acceleration),
                    groundSpeedKts: groundSpeedKts)
                applyPlaneEstimate()
            }
            stepDeadReckoning(deltaTime: dt, headingRateDegPerSec: turnRate)
        } else {
            filteredAcceleration = acceleration
        }
        lastMotionTimestamp = dm.timestamp

        updateAttitude(gravity: g)

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
            // Plane mode: the compass seeds the heading until GPS gives a
            // course (at the gate, slow taxi); the estimator ignores it after.
            if isFlightMode, let dt = lastMotionStepInterval {
                planeEstimator.compassHeading(magneticHeadingDeg, dt: dt)
                applyPlaneEstimate()
            }
        }
        updateHeading()
    }

    /// Pitch and roll from the gravity vector — 0° when the phone is exactly
    /// vertical, or, once calibrated, in whatever pose the crew captured as
    /// zero.
    private func updateAttitude(gravity g: simd_double3) {
        let rotate = calibrationRotation ?? matrix_identity_double3x3
        let gv = rotate * g
        pitchDeg = atan2(gv.z, -gv.y) * 180 / .pi
        let tiltRoll = atan2(gv.x, -gv.y) * 180 / .pi

        // Apparent gravity: where a plumb line hangs once the vehicle's own
        // acceleration is added to gravity. In an aircraft it stays down the
        // body axis through a coordinated turn; in a car it swings outward
        // through the corner while the body stays level.
        //
        // Core Motion's userAcceleration is the accelerometer's reaction
        // reading, not the vehicle's acceleration: it points the way the
        // plumb line swings (a right turn reads negative x — the same
        // convention that has gravity read -1 along the down axis). So
        // apparent gravity is gravity *plus* userAcceleration, i.e. the raw
        // accelerometer vector, and the vehicle's own lateral acceleration,
        // positive to the right, is its negative.
        let apparent = rotate * (g + filteredAcceleration)
        lateralG = -(rotate * filteredAcceleration).x

        if isFlightMode {
            // Attitude comes from the plane-mode estimator (applyPlaneEstimate);
            // the slip ball reads lateral acceleration in its cabin frame.
            pitchDeg = planeEstimator.pitchDeg
            if let mount = planeEstimator.mount { lateralG = -(mount * filteredAcceleration).x }
            return
        }

        switch rollSource {
        case .tilt:
            rollDeg = tiltRoll
        case .lateralAcceleration:
            // The bank that would put apparent gravity down the body axis:
            // the body's tilt from true gravity, less its tilt from apparent
            // gravity. For an aircraft in a coordinated turn the second term
            // is zero and this is plain roll; for a car cornering flat the
            // first is zero and this is the turn's equivalent bank.
            let apparentRoll = atan2(apparent.x, -apparent.y) * 180 / .pi
            rollDeg = angularDifference(tiltRoll, apparentRoll)
        }
    }

    /// The flight-mode attitude for the demo flight, which has no motion
    /// stream: bank from its rate of turn, pitch from its flight path.
    fileprivate func updateAttitudeForDemoFlight() {
        let speedMps = groundSpeedKts * 0.514444
        let omega = turnRateSmoother.value * .pi / 180
        rollDeg = atan(speedMps * omega / 9.80665) * 180 / .pi
        pitchDeg = flightPathAngleDeg
    }

    /// Prefer GPS track when moving; magnetic heading only when slow/stationary.
    /// In plane mode the estimator decides: the compass only until the first
    /// GPS course, since in the cabin it reads the airframe's metal and
    /// points along the phone rather than the nose.
    private func updateHeading() {
        if isFlightMode {
            headingDeg = trackDeg
            return
        }
        if groundSpeedKts > 3 {
            headingDeg = trackDeg
        } else {
            headingDeg = magneticHeadingDeg
            // Stationary, there is no meaningful track: park it on the heading
            // so the ND track line stays on the lubber line instead of
            // swinging to wherever a stale GPS course points. The next course
            // fix, once rolling, starts the track afresh.
            trackDeg = headingDeg
            trackAnchorDeg = nil
        }
    }

    /// Publish the plane-mode estimator's outputs.
    private func applyPlaneEstimate() {
        rollDeg = planeEstimator.rollDeg
        pitchDeg = planeEstimator.pitchDeg
        trackDeg = planeEstimator.trackDeg
        headingDeg = trackDeg
        if planeEstimator.hasAltitude {
            altitudeFt = planeEstimator.altitudeFt
            verticalSpeedFpm = planeEstimator.verticalSpeedFpm
        }
    }

    // MARK: - Speed display dynamics

    /// Display dynamics: the tape value and the V/S needle glide toward the
    /// sensor values with a time constant just under a second, and the trend
    /// arrow slews at no more than 10 kt/s toward its target, appearing above
    /// 2 kt of trend and disappearing only below 1 kt. Stepped at the motion rate (or the demo
    /// timer), so everything animates smoothly even though the sensors only
    /// report about once a second.
    private func stepSpeedDynamics(deltaTime: Double) {
        guard deltaTime > 0, deltaTime < 2 else { return }
        groundSpeedKts = speedSmoother.step(toward: gpsSpeedKts, deltaTime: deltaTime)
        speedTrendKts = trendSlew.step(toward: speedTrendTargetKts, deltaTime: deltaTime)
        verticalSpeedFpm = verticalSpeedSmoother.step(toward: verticalSpeedTargetFpm,
                                                      deltaTime: deltaTime)

        if abs(speedTrendTargetKts) < 1 {
            isSpeedTrendShown = false
        } else if abs(speedTrendTargetKts) > 2 {
            isSpeedTrendShown = true
        }
    }

    // MARK: - Dead reckoning

    /// Between GPS fixes the track, position and altitude are dead-reckoned at
    /// the motion rate: track carried by the gyro's yaw rate, position by
    /// ground speed along the track, altitude by the vertical speed. A fix is
    /// never applied as a jump. It becomes an anchor that is carried forward
    /// the same way, and the display closes onto it over the next second — so
    /// the ND, the heading tape and the guidance move continuously, and a
    /// turn shows on the displays as it happens rather than a second later.
    private func stepDeadReckoning(deltaTime dt: Double, headingRateDegPerSec: Double) {
        guard dt > 0, dt < 2 else { return }
        let pull = min(1, dt * Self.anchorPullRate)
        let moving = groundSpeedKts > 3

        // In plane mode the estimator carries track and altitude.
        if !isFlightMode, moving, let anchor = trackAnchorDeg {
            let yaw = headingRateDegPerSec * dt
            trackDeg = normalizedHeading(trackDeg + yaw)
            let carried = normalizedHeading(anchor + yaw)
            trackAnchorDeg = carried
            let error = angularDifference(carried, trackDeg)
            // A gross disagreement — the magnetic heading was wrong when we
            // started rolling — is snapped rather than eased.
            trackDeg = normalizedHeading(trackDeg + (abs(error) > 45 ? error : error * pull))
        }

        if var position = displayCoordinate, var anchor = fixAnchor {
            if moving {
                let meters = groundSpeedKts / Self.mpsToKts * dt
                let t = trackDeg * .pi / 180
                position = Self.offset(position, northMeters: meters * cos(t), eastMeters: meters * sin(t))
                anchor = Self.offset(anchor, northMeters: meters * cos(t), eastMeters: meters * sin(t))
            }
            position = CLLocationCoordinate2D(
                latitude: position.latitude + (anchor.latitude - position.latitude) * pull,
                longitude: position.longitude + (anchor.longitude - position.longitude) * pull)
            displayCoordinate = position
            fixAnchor = anchor
        }

        if !isFlightMode, let anchor = altitudeAnchorFt {
            let climb = verticalSpeedFpm / 60 * dt
            altitudeFt += climb
            let carried = anchor + climb
            altitudeAnchorFt = carried
            altitudeFt += (carried - altitudeFt) * min(1, dt * Self.altitudeAnchorPullRate)
        }

        publishLocation()
    }

    private func publishLocation() {
        guard let coordinate = displayCoordinate else { return }
        location = CLLocation(coordinate: coordinate,
                              altitude: altitudeFt / Self.metersToFt,
                              horizontalAccuracy: lastFixAccuracy.horizontal,
                              verticalAccuracy: lastFixAccuracy.vertical,
                              course: trackDeg,
                              speed: groundSpeedKts / Self.mpsToKts,
                              timestamp: Date())
    }

    private static func offset(_ c: CLLocationCoordinate2D,
                               northMeters: Double, eastMeters: Double) -> CLLocationCoordinate2D {
        let metersPerDegree = 111_320.0
        return CLLocationCoordinate2D(
            latitude: c.latitude + northMeters / metersPerDegree,
            longitude: c.longitude + eastMeters / (metersPerDegree * cos(c.latitude * .pi / 180)))
    }

    private static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // MARK: - Location processing

    /// Each fix retargets the display dynamics and re-anchors the dead
    /// reckoning; the displays themselves glide toward the new values in the
    /// motion callback.
    private func processLocation(_ loc: CLLocation) {
        guard !isDemoMode else { return }
        gpsFix = loc
        lastFixAccuracy = (loc.horizontalAccuracy, loc.verticalAccuracy)

        if loc.speed >= 0 {
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

        let now = Date().timeIntervalSinceReferenceDate
        let fixTime = loc.timestamp.timeIntervalSinceReferenceDate
        if isFlightMode {
            if loc.course >= 0, loc.speed >= 0 {
                planeEstimator.gpsCourse(loc.course, accuracyDeg: loc.courseAccuracy,
                                         speedKts: loc.speed * Self.mpsToKts, time: fixTime)
            }
        } else if loc.course >= 0, loc.speed * Self.mpsToKts > 3 {
            // The first course after standing still starts the track outright;
            // after that the gyro carries it and each fix only anchors it.
            if trackAnchorDeg == nil { trackDeg = loc.course }
            trackAnchorDeg = loc.course
        }

        // The first fix — or a jump too big to glide across, such as leaving
        // a tunnel — is the display position outright.
        if let current = displayCoordinate, Self.distanceMeters(current, loc.coordinate) < 150 {
            fixAnchor = loc.coordinate
        } else {
            displayCoordinate = loc.coordinate
            fixAnchor = loc.coordinate
        }

        if loc.verticalAccuracy > 0 {
            let feet = loc.altitude * Self.metersToFt
            if altitudeAnchorFt == nil { altitudeFt = feet }
            altitudeAnchorFt = feet

            // Park the FCU bug a round 1000 ft above the first fix so the
            // altitude tape has a sensible target until the crew moves it.
            if !hasInitialisedSelectedAltitude {
                hasInitialisedSelectedAltitude = true
                selectedAltitudeFt = ((feet / 1_000).rounded(.down) + 1) * 1_000
            }

            // Plane mode: altitude and climb rate from the estimator's
            // alpha-beta filter on GPS altitude — never the barometer,
            // which reads cabin pressure.
            if isFlightMode {
                planeEstimator.gpsAltitude(feet: feet, accuracyFt: loc.verticalAccuracy * Self.metersToFt,
                                           time: fixTime, now: now)
            }

            // GPS-derived climb rate, for devices without a barometer only.
            // Differenced from the raw fixes — differencing the smoothed
            // altitude would stack a second lag on top.
            if isFlightMode {
                lastAltitudeSample = nil
            } else if let last = lastAltitudeSample {
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

        // With no motion stream to carry the dead reckoning, the fix is the
        // display, stepped once per fix.
        if lastMotionDate.map({ Date().timeIntervalSince($0) > 1 }) ?? true {
            stepSpeedDynamics(deltaTime: 1)
            if isFlightMode {
                planeEstimator.step(dt: 1, time: now, motion: nil, groundSpeedKts: groundSpeedKts)
                applyPlaneEstimate()
            } else {
                if let anchor = trackAnchorDeg { trackDeg = anchor }
                if let anchor = altitudeAnchorFt { altitudeFt = anchor }
            }
            displayCoordinate = fixAnchor
            publishLocation()
        }
        updateHeading()
    }

    // MARK: - Demo mode (Simulator / devices without motion sensors)

    /// Flies a gentle climbing right turn from a seed position so all
    /// displays are alive without real sensors.
    private func startDemoMode() {
        guard demoTimer == nil else { return }
        isDemoMode = true
        if let plan = demoFlightPlan {
            startDemoFlight(plan)
            return
        }
        var demoHeading = 80.0
        var demoAltFt = 9_800.0
        var demoLat = 42.363, demoLon = -71.006     // over Boston Logan
        var t = 0.0
        var lastFixTime = -1.0

        // A steady climb at a jet speed so the Mach readout and the tape
        // annotations all sit somewhere meaningful.
        windDirDeg = 270
        windSpeedKts = 46
        selectedAltitudeFt = 12_000

        let interval = 1.0 / Self.motionRateHz
        demoTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                t += interval
                let bank = 12 + 8 * sin(t / 6)
                let speed = 280.0
                demoHeading = (demoHeading + bank * 0.09 * interval).truncatingRemainder(dividingBy: 360)
                demoAltFt += 900.0 / 60 * interval

                // Dead-reckon the position (1 kt ≈ 1/60 deg lat per hour).
                let distDeg = speed / 3600.0 / 60.0 * interval
                demoLat += distDeg * cos(demoHeading * .pi / 180)
                demoLon += distDeg * sin(demoHeading * .pi / 180) / cos(demoLat * .pi / 180)

                self.pitchDeg = 7 + 2 * sin(t / 4)
                self.rollDeg = bank
                self.lateralG = tan(bank * .pi / 180)
                // Crabbing into the demo wind, so track and heading differ and
                // the drift-driven symbology (FPV, track line) is visible.
                self.trackDeg = demoHeading
                self.headingDeg = normalizedHeading(demoHeading - 6)
                self.gpsSpeedKts = speed + 5 * sin(t / 9)
                self.speedTrendTargetKts = 5.0 / 9 * cos(t / 9) * 10    // d(GS)/dt over 10 s
                self.stepSpeedDynamics(deltaTime: interval)
                self.altitudeFt = demoAltFt
                self.verticalSpeedTargetFpm = 900 + 100 * sin(t / 4)
                let fix = CLLocation(
                    coordinate: .init(latitude: demoLat, longitude: demoLon),
                    altitude: demoAltFt / Self.metersToFt,
                    horizontalAccuracy: 5, verticalAccuracy: 5,
                    course: demoHeading, speed: speed / Self.mpsToKts,
                    timestamp: Date()
                )
                self.location = fix
                // A once-a-second "GPS fix", as the real receiver would give.
                if t - lastFixTime >= 1 {
                    lastFixTime = t
                    self.gpsFix = fix
                }
            }
        }
    }
}

// MARK: - Demo flight

extension FlightDataModel {
    /// Flies the plan in the Simulator: along its path at airliner speeds,
    /// climbing and descending on its vertical profile, starting
    /// `demoStartNm` along it (a launch argument; 30 NM by default) and with
    /// the clock running at `demoTimeScale` times real time (default 1).
    fileprivate func startDemoFlight(_ plan: FlightPlan) {
        let defaults = UserDefaults.standard
        var along = defaults.object(forKey: "demoStartNm") != nil ? defaults.double(forKey: "demoStartNm") : 30
        let timeScale = max(1, defaults.double(forKey: "demoTimeScale"))
        let total = plan.totalDistanceNm
        var lastFixTime = -1.0
        var t = 0.0
        windDirDeg = nil
        windSpeedKts = nil
        selectedAltitudeFt = plan.reachableCruiseFt

        let interval = 1.0 / 60
        demoTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                t += interval
                let dt = interval * timeScale
                // Speed schedule: 250 kt low down, cruise at altitude, slowing
                // through the descent.
                let altitude = plan.plannedAltitudeFt(atNm: along)
                let speed = 250 + min(1, max(0, (altitude - 10_000) / 20_000)) * 200
                let previousAlt = altitude
                along = min(total, along + speed * dt / 3600)
                let newAlt = plan.plannedAltitudeFt(atNm: along)
                let here = plan.coordinate(atNm: along)
                let course = plan.course(atNm: along)

                self.verticalSpeedTargetFpm = dt > 0 ? (newAlt - previousAlt) / dt * 60 : 0
                self.gpsSpeedKts = along < total ? speed : 0
                self.stepSpeedDynamics(deltaTime: dt)
                let turn = angularDifference(course, self.trackDeg) / max(dt, 1e-3)
                _ = self.turnRateSmoother.step(toward: max(-3, min(3, turn)), deltaTime: dt)
                self.trackDeg = course
                self.headingDeg = course
                self.altitudeFt = newAlt
                self.updateAttitudeForDemoFlight()
                let fix = CLLocation(coordinate: here, altitude: newAlt / 3.28084,
                                     horizontalAccuracy: 5, verticalAccuracy: 5,
                                     course: course, speed: speed / 1.943844, timestamp: Date())
                self.location = fix
                if t - lastFixTime >= 1 {
                    lastFixTime = t
                    self.gpsFix = fix
                }
            }
        }
    }
}

// MARK: - Display dynamics

/// Exponential smoothing: each step closes the gap to the input by the share
/// a first-order system with time constant `timeConstant` would close in
/// `deltaTime`, so the result does not depend on the step rate.
struct Smoother {
    let timeConstant: TimeInterval
    private(set) var value = 0.0

    init(timeConstant: TimeInterval) {
        self.timeConstant = timeConstant
    }

    mutating func step(toward target: Double, deltaTime: TimeInterval) -> Double {
        guard target.isFinite, deltaTime > 0 else { return value }
        value += (target - value) * -expm1(-deltaTime / timeConstant)
        return value
    }
}

/// ``Smoother`` applied to each axis of a vector.
struct VectorSmoother {
    private var axes: [Smoother]

    init(timeConstant: TimeInterval) {
        axes = Array(repeating: Smoother(timeConstant: timeConstant), count: 3)
    }

    mutating func step(toward target: simd_double3, deltaTime: TimeInterval) -> simd_double3 {
        simd_double3((0..<3).map { axes[$0].step(toward: target[$0], deltaTime: deltaTime) })
    }
}

/// Follows its target, but never faster than `maxRate` units per second in
/// either direction.
struct SlewLimiter {
    let maxRate: Double
    private(set) var value = 0.0

    init(maxRate: Double) {
        self.maxRate = maxRate
    }

    mutating func step(toward target: Double, deltaTime: TimeInterval) -> Double {
        guard target.isFinite, deltaTime > 0 else { return value }
        let limit = maxRate * deltaTime
        value += min(max(target - value, -limit), limit)
        return value
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.locationAuthorization = status }
    }
}
