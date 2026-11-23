# FlightDeck

An iOS app that turns your iPhone/iPad into an airliner glass cockpit — an
Airbus A320 flight deck or a Boeing 737 one, your choice in the MCDU:

- **PFD (Primary Flight Display)** — attitude indicator (pitch/roll from the
  motion sensors), speed tape, altitude tape, vertical speed and heading tape,
  driven by CoreMotion + GPS.
- **ND (Navigation Display)** — track-up moving map with a flight-plan style
  route (car or bicycle) to a searched destination, ground speed /
  distance-to-go / ETE readouts, range control, and an "open in Google Maps"
  hand-off.
- **Speed limit as VMAX** — the posted limit of the road being driven, from
  OpenStreetMap, drawn as the red barber pole on the speed tape.
- **Vertical Display** — the planned route's height profile ahead of the
  aircraft, from a digital elevation model.

Portrait: PFD above ND. Landscape: side by side. The layout follows the
aspect ratio of the window, so it also behaves on iPad / Split View.

## Two flight decks

The same data drives two complete sets of displays; **FLIGHT DECK** in the
MCDU's settings page switches between them and the choice is remembered.

| | A320 | B737 |
|---|---|---|
| Reference | our own parametric drawing of the A320 PFD / ND and A380 VD, laid out to match the real displays' look | our own parametric drawing of the 737NG PFD, ND and VSD, laid out to match the real displays' look |
| Drawn in | a 100-unit PFD canvas and a 1000-unit ND canvas | a 100 × 102-unit PFD canvas, a 1000-unit ND canvas and a 1000 × 210 VSD strip |
| Attitude | stadium-shaped window, yellow aircraft reference, green FD bars | rounded frame with the bank scale on a fixed sky band, white bracket wings, magenta FD bars |
| Tapes | grey tapes, yellow speed pointer, altitude readout box on the tape | grey tapes with odometer readout boxes pointing onto the scales, thousand-foot bars on the altitude tape |
| Targets | cyan FCU values | magenta MCP values and bugs |
| Heading | heading tape under the attitude | compass arc at the foot of the display, MAG annunciation |
| FMA | five Airbus columns (THR CLB, ALT CRZ, NAV …) | three Boeing boxes (N1, LNAV / HDG SEL, ALT HOLD / LVL CHG) |
| ND | ARC mode, heading up, green track line and flight plan | expanded MAP mode, track up, white track line with range ticks, magenta flight plan, four-point waypoint stars |
| VD | A380 vertical display: altitude tape left, range labels above, dashed quarter-range grid, yellow aircraft, green path | 737 VSD: altitude axis left and range axis along the bottom of a plain plot, side-view airplane with its flight path vector, terrain in green with the path along its top in magenta, MCP altitude as a magenta line |

Each display is drawn in one fixed coordinate system and scaled once, so
every element keeps its place relative to the others. All displays are
parametric: a few design values (horizon centre, attitude window or frame,
tape band, scale factors) in `PFDGeometry.swift`, `NDGeometry.swift`,
`Boeing.swift` (`B737PFD`), `BoeingNDView.swift` (`B737ND`) and
`VerticalDisplayView.swift` (`VD`, `B737VSD`), with everything else placed
from them. The Boeing palette (sky `#338cda`, ground `#714d27`, tape grey
`#3b3a3e`, green `#00ff3d`, magenta `#f560f7`) is chosen to read as the 737's;
the display face uses the system font in its condensed width with fixed-width
figures, set at its on-screen size, the nearest match to the 737's narrow
display type.

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
| Pitch | `CMDeviceMotion.gravity` (0° when the phone is vertical) |
| Roll | **LATERAL G** (default): the bank an aircraft would need for the measured lateral acceleration (`atan(a_lat / g)`, plus any real tilt) — a car corners flat, so gravity alone would always read 0°. **TILT**: the phone's physical bank from gravity. Switch on the MCDU's settings page. |
| Heading / track | GPS course when moving (> 3 kt), carried between fixes by the gyro yaw rate; magnetic heading (rotation matrix) when stationary |
| Position | GPS fixes, dead-reckoned along the track at ground speed between them |
| Ground speed | `CLLocation.speed`, smoothed with a 0.8 s time constant |
| Altitude | GPS altitude, carried between fixes by the vertical speed |
| Vertical speed | Barometer (`CMAltimeter`) where available, else GPS altitude differences |
| Speed limit | OpenStreetMap `maxspeed` tags via the Overpass API (see below) |

Everything the displays draw is stepped at the 60 Hz motion rate. GPS
reports about once a second; rather than jumping to each fix, the track,
position and altitude are dead-reckoned between fixes and each fix becomes
an anchor the display glides onto over the next second. The ND, the heading
tape and the flight director therefore move continuously.

Note: the magnetic-heading projection has not been verified on hardware yet —
if the stationary heading reads mirrored on a real device, flip the signs in
`FlightDataModel.processDeviceMotion`. In motion, GPS track takes over and is
always correct.

## Route planning

Search uses `MKLocalSearch` and routing `MKDirections` (Apple Maps — no API
key needed), for a **car** or a **bicycle** — pick the mode on the MCDU or
in the destination picker; switching with a destination active replans at
once. The map button opens the identical route in Google Maps via universal
URL, in the same travel mode. If you later want routes computed *by* Google,
add a provider that calls the Google Directions API inside `RoutePlanner`
(it's isolated there on purpose).

The aircraft is projected onto the nearest route leg on every position
update, so distance-to-go, the TO waypoint and the flight director's
look-ahead point all move continuously along the plan.

## MCDU

Every setting, the route and the flight are set up on an MCDU, operated the
way a pilot operates one. Swipe right from anywhere to bring it up; its
**◂ DISPLAYS** key or a left swipe returns to the instruments. Beside the A320
displays it is an Airbus MCDU; beside the 737's, a Boeing CDU, with that
unit's colours, page names and an EXEC key that lights when a downloaded
flight is waiting to be activated.

Type on the keypad into the scratchpad (the bottom line), then press the
line-select key beside a field to enter it, as on the real unit; `CLR` (737:
`DEL`) on an empty scratchpad followed by a line-select key deletes that
entry. Wrong entries answer FORMAT ERROR, NOT IN DATA BASE or ENTRY OUT OF
RANGE in the scratchpad.

| Page | A320 key | 737 key | |
|---|---|---|---|
| Menu | MCDU MENU | MENU | CAR / BIKE / PLANE, prompts to every page |
| Route / flight setup | INIT | RTE | Plane: FLT NBR, FROM/TO, DATE, CRZ FL, DOWNLOAD*, ACTIVATE*. Car/bike: DEST, MAP> |
| Destination search | DIR | FIX | Apple Maps search results; pick one, then FLY* |
| Flight plan | F-PLN | LEGS | Waypoints with distance, planned altitude and ETA |
| Progress | PROG | PROG | GS, altitude, height above ground, distances, ETE/ETA, position |
| Settings | PERF | INIT REF | Units, flight deck, roll source, speed limit, attitude zero |
| Stored flights | DATA | via INIT REF | Downloaded flight packs: activate, resume, delete |

The MCDU is our own drawing, laid out parametrically like the displays.

## Plane mode

For passengers: on the MCDU's MENU page choose **PLANE**, then open the INIT (A320) / RTE (737) page.

1. **Pick the flight.** Type a flight number (`LH400`) into the scratchpad and
   press the line-select key beside FLT NBR. The
   app turns it into the ICAO callsign aircraft transmit (`DLH400`, via a
   bundled IATA→ICAO airline table from Wikidata, CC0) and fetches that
   callsign's most recent flown track from the **free flight-track archive**
   (see below). That gives the departure and arrival airports and the path
   the flight actually took on an earlier day. When no track is found, or
   without internet, choose the two airports from the built-in list
   (OurAirports, public domain, about 3,300 airports): the route is then a
   great circle.
2. **Download for offline.** DOWNLOAD* stores a *flight pack*: the plan and the
   terrain along the route (AWS Open Data terrain tiles, about ±80 NM either
   side, finer around both airports). Packs live in Application Support,
   excluded from backups, and are deleted a week after the flight.
3. **In flight**, in airplane mode with GPS on, nothing needs the network:
   - **ND:** the route from the aircraft to T/C, T/D and the destination,
     airports around, and terrain coloured by height (EGPWS-style near the
     ground, peaks mode at cruise).
   - **VD:** the ground along the current track, with the window always
     spanning from the ground to above the aircraft.
   - **PFD:** a ground band on the altitude tape and the height above the
     ground (HGT).

In the cabin the sensors are used differently:
- Vertical speed comes from GPS altitude, because the barometer reads cabin
  pressure.
- Heading is the GPS track.
- Bank is computed from the rate of turn and the speed (a coordinated turn
  leaves no sideways force to measure).
- Pitch is the flight-path angle.

In the Simulator, the demo flies the active flight plan (launch arguments
`-demoStartNm 150` start further along it, `-demoTimeScale 10` speeds it up,
`-simulateOffline YES` makes every download fail to check offline behaviour).

### The free flight-track archive

No free source publishes filed flight plans in a form a distributed app may
use, so the expected path is the one the flight really flew recently.
`Tools/FlightArchive/` holds a daily GitHub Actions job that reads
[adsb.lol](https://www.adsb.lol)'s open ADS-B history (ODbL 1.0), cuts each
aircraft's day into flights between airports, and publishes one small JSON
file per callsign on GitHub Pages. The app reads
`<base>/v1/<first three letters>/<CALLSIGN>.json`, where `<base>` is
`FlightArchiveProvider.publishedBaseURL`. Set up the archive repository as
described in `Tools/FlightArchive/README.md`. Credit: "Flight tracks contain
data from adsb.lol (ODbL 1.0)"; the derived archive stays public, as the
licence requires.

Any other source of flight paths (for example a paid one with filed routes,
behind a server that keeps its key) can be added as another
`FlightLookupProvider`.

## Vertical display

The strip under the ND is styled after the A350/A380 **Vertical Display**
(in plane mode it shows the terrain along the track instead, see above).
It plots the **height profile of the planned
route**: when a route is adopted, `RoutePlanner` samples it every 50–500 m
along-track and reads the ground elevation from terrain tiles (AWS Open
Data Terrain Tiles, zoom 12, about 30 m), which are downloaded once and
cached, so the profile also works offline afterwards. The strip then shows the
road ahead — from the aircraft out to the selected ND range — as a brown
ground silhouette with the green route profile along its top, the aircraft
at its own altitude on the left, the FCU altitude bracket when in range,
and the destination marker. The vertical scale follows the display's rule
(a 4° slope spans the strip at the selected range) but tightens to fit the
terrain ahead when the ground is flatter than that.

## Speed limit

MapKit has no speed-limit data, so `SpeedLimitProvider` asks the public
OpenStreetMap **Overpass API** (`overpass-api.de`, no key) for every road
with a `maxspeed*` tag within 600 m, caches them, and matches each GPS fix
to the nearest road whose direction agrees with the track. One request is
made per ~350 m of travel. The limit becomes VMAX on the PFD: the red
barber pole starts at
the limit; `maxspeed=none` (autobahn) shows no pole. Roads without a tag
show nothing rather than a guess. The lookup sends your position to a
third-party server and can be switched off on the MCDU's settings page. Road data ©
OpenStreetMap contributors (ODbL).

## App icon

The icon is a miniature of the PFD itself — the FMA row, the stadium-shaped
attitude window, speed, heading and altitude tapes, EFIS colours and stroke
widths straight from `PFDGeometry.swift` / `EFIS.swift` — straight and level,
with an iOS 26 finish (depth shadow, glass sheen, lit rims) on top.
Regenerate it after changing the display:

```
swiftc -O -o /tmp/render-app-icon \
    FlightDeck/PFD/PFDGeometry.swift FlightDeck/Style/EFIS.swift \
    Tools/RenderAppIcon/main.swift
/tmp/render-app-icon        # writes Assets.xcassets/AppIcon.appiconset/AppIcon1024.png
```

## Extending to other aircraft

A flight deck is a `DisplayStyle` case (`Model/DisplayStyle.swift`), an
`AircraftProfile` with its speed envelope and ND ranges
(`Model/AircraftProfile.swift`), a colour/type/geometry file under `Style/`,
and a PFD and ND view drawn in one fixed coordinate system from a
parametric layout spec. `ContentView` picks the views for the selected style; the MCDU's
FLIGHT DECK choice comes from `DisplayStyle`. The route guidance the
flight director and deviation scales use is shared in `Model/Guidance.swift`,
and `VerticalDisplayView` takes a `style` for its colours.

## Project layout

```
FlightDeck/
├── FlightDeckApp.swift          App entry, injects the models
├── ContentView.swift            Adaptive PFD/ND layout
├── Model/
│   ├── FlightDataModel.swift    CoreMotion + CoreLocation fusion, dead reckoning, demo mode
│   ├── RoutePlanner.swift       Routing (car / bicycle), leg projection, Google Maps hand-off
│   ├── SpeedLimitProvider.swift OpenStreetMap speed limits via Overpass
│   ├── RouteElevation.swift     Route height profile from terrain tiles
│   ├── TerrainStore.swift       Terrain tiles on disk: decoding, lookups, downloads
│   ├── FlightPlan.swift         Flight plans, great-circle maths, vertical profile
│   ├── FlightLookup.swift       Flight number → airports and path (archive client)
│   ├── FlightPackStore.swift    Offline flight packs
│   ├── Airports.swift           Bundled airport and airline tables
│   ├── AircraftProfile.swift    Per-aircraft envelope and tape scales (A320, B737)
│   ├── DisplayStyle.swift       Which flight deck the displays imitate
│   └── Guidance.swift           Course and path deviation from the flight plan
├── Menu/
│   ├── MCDU/                    The MCDU: all settings, route and flight setup
│   │   ├── MCDUStyle.swift      Airbus MCDU / Boeing CDU look, keys, screen types
│   │   ├── MCDUController.swift Keys, scratchpad, actions
│   │   ├── MCDUPages.swift      The pages and their line-select keys
│   │   └── MCDUView.swift       The unit on screen
│   ├── DestinationPickerView.swift  Map picker (MCDU MAP> prompt)
│   └── SafetyNoticeView.swift   One-time safety notice
├── PFD/
│   ├── PFDGeometry.swift        A320 PFD layout spec
│   ├── PFDView.swift            A320 PFD composition
│   └── BoeingPFDView.swift      737 PFD composition
├── ND/
│   ├── NDGeometry.swift         A320 ND layout spec + map projection
│   ├── NDView.swift             A320 moving map + route + controls
│   ├── BoeingNDView.swift       737 expanded MAP mode
│   ├── NDTerrainRenderer.swift  Terrain raster for the ND (EGPWS / peaks colours)
│   ├── NDTerrainLayer.swift     Renders it off the main thread, places it on the map
│   └── VerticalDisplayView.swift
└── Style/
    ├── EFIS.swift               Airbus colour code, fonts, canvas helpers
    └── Boeing.swift             Boeing colour code, type, PFD/ND geometry
├── Resources/                   airports.json, airlines.json (built by Tools/BuildAirports)
Tools/
├── RenderAppIcon/main.swift     Renders the app icon from the PFD geometry
├── BuildAirports/               Builds the bundled airport and airline tables
└── FlightArchive/               Daily job that builds the free flight-track archive
```

## Data credits

- Road speed limits © OpenStreetMap contributors (ODbL).
- Flight tracks contain data from adsb.lol (ODbL 1.0).
- Airports: OurAirports (public domain). Airline codes: Wikidata (CC0).
- Terrain: AWS Open Data Terrain Tiles (Mapzen / Tilezen). Sources, as
  required by its attribution notice: ArcticDEM (DigitalGlobe imagery, NSF
  awards 1043681, 1559691, 1542736); Australia © Commonwealth of Australia
  (Geoscience Australia) 2017; Austria © offene Daten Österreichs – DGM
  Österreich; Canada, Open Government Licence – Canada; Europe, Copernicus
  EU-DEM (funded by the European Union); global ETOPO1, U.S. NOAA; Mexico,
  INEGI Continental relief 2016; New Zealand © Crown copyright, Land
  Information New Zealand; Norway © Kartverket; United Kingdom ©
  Environment Agency 2015; United States 3DEP, global GMTED2010 and SRTM
  courtesy of the U.S. Geological Survey.

## App Store

`AppStore/` holds the release material: `SUBMISSION.md` (checklist and open
legal points), `METADATA.md` (store listing, privacy label, review notes) and
`PRIVACY.md` (privacy policy to host). The privacy manifest is
`FlightDeck/PrivacyInfo.xcprivacy`.
