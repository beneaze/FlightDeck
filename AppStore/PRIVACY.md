# FlightDeck Privacy Policy

_Last updated: 22 November 2026_

FlightDeck has no accounts, no analytics, no advertising and no tracking. The
developer does not run any server and receives no data from the app.

## What the app uses on your device

- **Location**: speed, track, altitude and your position on the navigation
  display. Used only while the app is open.
- **Motion and barometer**: pitch, roll, heading and vertical speed.
- **Settings** (units, display style, calibration) stay on your device.

## What leaves your device, and where it goes

To provide some features, the app sends requests directly from your device
to these services. The requests carry no name, account or device identifier.

| Feature | Sent to | What is sent |
|---|---|---|
| Speed limit (can be switched off in the menu) | OpenStreetMap Overpass API (`overpass-api.de`) | Your current position, about once every 350 m |
| Route height profile (car and bike) | Amazon Web Services, Open Data terrain tiles (`s3.amazonaws.com`) | Requests for the map tiles that cover the planned route |
| Flight lookup (plane mode) | The FlightDeck flight-track archive (static files on GitHub Pages) | The flight's callsign, e.g. `DLH400` |
| Offline flight download (plane mode) | Amazon Web Services, Open Data terrain tiles | Requests for the map tiles along the flight's route |
| Destination search and routing | Apple Maps | Your search text, position and destination |
| "Open in Google Maps" (only when you tap it) | Google Maps | Your position and destination |

Downloaded flights are stored only on your device and are deleted a week
after the flight's date.

Each service handles these requests under its own privacy policy:
[OpenStreetMap Foundation](https://osmfoundation.org/wiki/Privacy_Policy),
[Amazon Web Services](https://aws.amazon.com/privacy/),
[GitHub](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement),
[Apple](https://www.apple.com/legal/privacy/),
[Google](https://policies.google.com/privacy).

## Children

The app does not knowingly collect data from anyone, including children.

## Contact

Questions about this policy: <CONTACT EMAIL OR URL>
