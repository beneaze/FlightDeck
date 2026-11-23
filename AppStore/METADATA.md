# App Store Connect metadata (draft)

Paste these into App Store Connect. Character limits are in brackets.

## Name [30]
Glassdeck

The App Store record is "Glassdeck" ("FlightDeck" was taken). Bundle ID `com.flightdeck.efis`, SKU `flightdeck-efis`. The home-screen name stays FlightDeck.

## Subtitle [30]
Airliner displays for the road

## Category
Primary: Navigation. Secondary: Entertainment.

## Promotional text [170]
Turn your iPhone or iPad into an airliner glass cockpit for your car or bike: attitude, speed and altitude tapes, a moving map and your route's height profile.

## Description [4000]
FlightDeck turns your iPhone or iPad into the glass cockpit of an airliner, for the road.

PRIMARY FLIGHT DISPLAY
• Attitude indicator driven by the motion sensors, with a lateral-G mode that banks the horizon through corners the way an aircraft would
• Speed tape with the road's posted speed limit drawn as the red overspeed barber pole
• Altitude tape and vertical speed from GPS and the barometer
• Heading and flight director that follow your planned route

NAVIGATION DISPLAY
• Track-up moving map with your route drawn as a flight plan
• Ground speed, distance to go and time to destination
• Plan routes for car or bicycle; hand the route off to Google Maps in one tap

VERTICAL DISPLAY
• The height profile of the road ahead, from a digital elevation model

PLANE MODE FOR PASSENGERS
• Enter your flight number, or pick the airports, before you board
• Download the flight: route, airports and terrain for use without internet
• In flight (airplane mode, GPS on), follow your progress on the map, with terrain coloured by height, the ground below on the vertical display, and distance and time to go
• Flight paths come from the track the flight flew on an earlier day; GPS required (iPhone, or iPad with cellular)

TWO FLIGHT DECKS
Choose between two classic airliner display styles. Everything is set up on a working MCDU / CDU: type into the scratchpad, press the line-select keys, just like in the cockpit. Speed in km/h, mph or knots; vertical speed in m/s or ft/min.

Works in portrait and landscape, on iPhone and iPad, including Split View.

FlightDeck is for entertainment. It is not a navigation aid or a certified instrument. Set it up before you drive, keep your eyes on the road and follow posted signs and traffic laws.

Speed limits © OpenStreetMap contributors (ODbL). Flight tracks contain data from adsb.lol (ODbL). Terrain: AWS Open Data Terrain Tiles. Airports: OurAirports.

## Keywords [100]
cockpit,pfd,efis,glass cockpit,pilot,aviation,dashboard,speedometer,hud,altimeter,attitude,gps,car

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
- Search History (flight numbers looked up in the flight archive)
- For each: used for App Functionality, **not** linked to the user, **not** used for tracking.
- Everything else: not collected.

(Requests to Apple Maps are covered by Apple and need not be declared. The
Overpass lookup sends the position, terrain tile requests reveal the route's
area, and flight lookups send the callsign, which is why these are declared.)

## Export compliance
Answered in the build: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only).

## App Review notes
FlightDeck shows the device's own motion in airliner-style displays and is meant to be mounted in a car or on a bike.

To try it at a desk: grant location and motion access, then tilt the device to move the attitude indicator, and turn it to change heading. Speed and the moving map need real movement. Swipe right from anywhere to open the MCDU (the cockpit's flight computer keypad). On the MENU page pick CAR; on the INIT page type a place into the scratchpad (bottom line) with the keypad and press the key beside DEST, pick a result and press FLY* to see a route on the navigation display. PERF opens the settings, where FLIGHT DECK switches between the two display styles. ◂ DISPLAYS returns to the instruments.

Plane mode: on the MCDU MENU page choose PLANE, then INIT. Type a flight number (e.g. LH400) and press the key beside FLT NBR, or type two airport codes like LSZH/LPPT and press the key beside FROM/TO, then press DOWNLOAD*. On F-PLN, the key beside the first line opens the departure runways and the key beside DEST the approaches; typing a navaid such as KRK and pressing a line key inserts a waypoint. The displays then show that flight; on the ground in Cupertino the aircraft symbol simply sits at your position.

On first launch the app shows a one-time safety notice. No account or login is needed.
