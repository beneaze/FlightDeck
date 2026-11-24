# App Store Connect metadata (draft)

Paste these into App Store Connect. Character limits are in brackets.

## Name [30]
CockpitView: In Flight PFD

The App Store name is "CockpitView: In Flight PFD"; the home screen shows "CockpitView". "FlightDeck", "CockpitView" and "JumpSeat" alone were taken. The Xcode project and target keep the FlightDeck name. Bundle ID `com.flightdeck.efis`, SKU `flightdeck-efis`.

## Subtitle [30]
Jump Seat for Passengers

## Category
Primary: Travel. Secondary: Entertainment.

## Promotional text [170]
Follow your flight from your seat on airliner cockpit displays: flight plan, moving map, terrain and altitude. Works offline, in airplane mode.

## Description [4000]
CockpitView gives you the pilots' view from your seat in the cabin. Your iPhone or iPad becomes the glass cockpit of an airliner and follows your flight on cockpit-style displays, in airplane mode and without Wi-Fi.

BEFORE YOU BOARD
• Enter your flight number, or pick the departure and arrival airports
• Download the flight: route, airports and terrain are stored on your device for use without internet
• Set it up like the crew does: choose the departure runway and the approach on the flight plan page, or add waypoints

IN FLIGHT
• Switch on airplane mode, keep GPS on, and the displays follow your aircraft from takeoff to landing
• Primary flight display: attitude indicator, speed and altitude tapes, vertical speed and heading
• Navigation display: moving map with your flight plan and waypoints, terrain coloured by height, distance and time to destination
• Vertical display: the ground below and ahead of you, and the climb and descent of your flight

TWO FLIGHT DECKS
Choose between two classic airliner cockpits. Everything is set up on a working flight computer (MCDU / CDU): type into the scratchpad and press the line-select keys, just like in the cockpit. Set speed, heading and altitude on the autopilot panel. Speed in km/h, mph or knots; vertical speed in m/s or ft/min.

Works in portrait and landscape, on iPhone and iPad, including Split View.

GOOD TO KNOW
• GPS is required: iPhone, or iPad with cellular. A window seat gives the best reception.
• The flight path is the planned route (from SimBrief, the flight number's airports, or waypoints you enter), so the route actually flown can differ.

CockpitView is for entertainment. It is not a navigation aid or a certified instrument, and not for flying an aircraft. Follow the crew's instructions on using devices on board.

Flight routes: adsbdb.com (Virtual Radar Server standing data, CC0) and hexdb.io. Flight tracks contain data from adsb.lol (ODbL 1.0). US procedures: FAA CIFP. Terrain: AWS Open Data Terrain Tiles. Airports: OurAirports. Map data © OpenStreetMap contributors (ODbL).

## Keywords [100]
flight tracker,airplane mode,offline,inflight,aviation,avgeek,pfd,flight map,airliner,window seat

## Support URL
<required: a web page or GitHub repo page with a contact option>

## Privacy Policy URL
<required: host AppStore/PRIVACY.md, e.g. on GitHub Pages>

## Copyright
2026 <your name>

## Age rating
All answers "None" → 4+.

## App Privacy ("nutrition label")
- Data collected: **Yes**
- Location → Precise Location (speed-limit lookup)
- Location → Coarse Location (terrain tiles for the planned route or flight)
- Search History (flight numbers looked up at adsbdb.com and hexdb.io)
- For each: used for App Functionality, **not** linked to the user, **not** used for tracking.
- Everything else: not collected.

(Requests to Apple Maps are covered by Apple and need not be declared. The
Overpass lookup sends the position, terrain tile requests reveal the route's
area, and flight lookups send the callsign, which is why these are declared.)

## Export compliance
Answered in the build: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only).

## App Review notes
CockpitView shows a passenger's flight on airliner-style cockpit displays. It is meant to be used on board, in airplane mode with GPS on.

To try it at a desk: grant location and motion access. Swipe right from anywhere to open the MCDU (the cockpit's flight computer keypad). On the MENU page choose PLANE, then INIT. Type a flight number (e.g. LH400) with the keypad and press the key beside FLT NBR, or type two airport codes like LSZH/LPPT and press the key beside FROM/TO, then press DOWNLOAD*. On F-PLN, the key beside the first line opens the departure runways and the key beside DEST the approaches; typing a navaid such as KRK and pressing a line key inserts a waypoint. The displays then show that flight; on the ground in Cupertino the aircraft symbol simply sits at your position. Tilt the device to move the attitude indicator.

PERF opens the settings, where FLIGHT DECK switches between the two display styles. ◂ DISPLAYS returns to the instruments. A left swipe on the instruments opens the autopilot panel (FCU / MCP): drag a knob up or down to set speed, heading, altitude or vertical speed, and press LOC, APPR or FD to see the instruments follow.

The MENU page also still offers CAR and BIKE: these show a road route to a searched destination (INIT, type a place, press the key beside DEST, pick a result, FLY*) with the road's speed limit from OpenStreetMap.

On first launch the app shows a one-time notice. No account or login is needed.
