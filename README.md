# FlightDeck

An iOS app that turns your iPhone/iPad into an A320-style glass cockpit:

- **PFD (Primary Flight Display)** — attitude indicator (pitch/roll from the
  motion sensors), speed tape, altitude tape, vertical speed and heading tape,
  driven by CoreMotion + GPS.
- **ND (Navigation Display)** — track-up moving map with a flight-plan style
  route to a searched destination, ground speed / distance-to-go / ETE
  readouts, range control, and an "open in Google Maps" hand-off.

Portrait: PFD above ND. Landscape: side by side. The layout follows the
aspect ratio of the window, so it also behaves on iPad / Split View.

## Requirements

- Xcode 16 or newer (install from the Mac App Store, then run
  `sudo xcode-select -s /Applications/Xcode.app`)
- iOS 17.0+ deployment target
- A real device for live sensor data — the Simulator has no motion sensors,
  so the app automatically runs a **demo flight** (climbing right turn over
  Boston) there. Demo mode is indicated by an orange `DEMO` tag on the PFD.

## Getting started

1. Open `FlightDeck.xcodeproj` in Xcode.
2. Select the FlightDeck target → *Signing & Capabilities* → choose your
   personal team (bundle id is `com.benny.FlightDeck`, change as you like).
3. Run on your iPhone. Grant location + motion permission when asked.

Mount the phone upright like an instrument panel (screen facing you):
pitch/roll are referenced to that orientation.

## How the data is derived

| Value | Source |
|---|---|
| Pitch / roll | `CMDeviceMotion.gravity` (0° when the phone is vertical) |
| Heading | GPS track when moving (> 3 kt), magnetic heading (rotation matrix) when stationary |
| Ground speed | `CLLocation.speed` |
| Altitude | GPS altitude (smoothed) |
| Vertical speed | Derived from altitude changes |

Note: the magnetic-heading projection has not been verified on hardware yet —
if the stationary heading reads mirrored on a real device, flip the signs in
`FlightDataModel.processDeviceMotion`. In motion, GPS track takes over and is
always correct.

## Route planning

Search uses `MKLocalSearch` and routing `MKDirections` (Apple Maps — no API
key needed). The map button opens the identical route in Google Maps via
universal URL. If you later want routes computed *by* Google, add a provider
that calls the Google Directions API inside `RoutePlanner` (it's isolated
there on purpose).

## Extending to other aircraft

All display styling and tape geometry live in `AircraftProfile`
(`Model/AircraftProfile.swift`). Add e.g. `AircraftProfile.b737` and pass it
into `PFDView`/`NDView` to reskin the displays; a runtime aircraft picker can
be added in `ContentView`.

## Project layout

```
FlightDeck/
├── FlightDeckApp.swift          App entry, injects the models
├── ContentView.swift            Adaptive PFD/ND layout
├── Model/
│   ├── FlightDataModel.swift    CoreMotion + CoreLocation fusion, demo mode
│   ├── RoutePlanner.swift       Search, routing, Google Maps hand-off
│   └── AircraftProfile.swift    Per-aircraft styling (A320 for now)
├── PFD/
│   ├── PFDView.swift            PFD composition
│   ├── AttitudeIndicatorView.swift
│   └── TapeViews.swift          Speed / altitude / heading tapes
└── ND/
    └── NDView.swift             Moving map + route + controls
```
