# Flight track archive

A daily job that turns [adsb.lol](https://adsb.lol)'s open ADS-B archive into a
static lookup: for each airline callsign, the most recent track that flight
actually flew, with its departure and arrival airport. FlightDeck downloads
the file for your flight before departure and shows that path on the ND in
plane mode. No server, no API key and no cost: it runs on GitHub Actions and
is served by GitHub Pages.

## What it produces

```
https://<user>.github.io/<repo>/v1/meta.json
https://<user>.github.io/<repo>/v1/DLH/DLH400.json
```

```json
{"callsign":"DLH400","flownOn":"2026-11-21","origin":"EDDF","destination":"KJFK",
 "icao24":"3c6444","source":"adsb.lol (ODbL 1.0)",
 "track":[[50.0379,8.5622,1500],[50.1102,8.4021,6200], …]}
```

- `callsign`: the ICAO callsign as transmitted, upper case, no spaces or
  padding. It is also the file name; the folder is its first three characters.
- `flownOn`: the UTC day the track was recorded.
- `origin` / `destination`: ICAO codes of the airports within 6 NM of the first
  and last airborne point, provided the aircraft was below about 6000 ft there.
- `track`: `[lat, lon, altitudeFt]`, simplified to at most about 300 points.
  A point is kept if dropping it would move the path more than 0.3 NM
  sideways or 1000 ft vertically. Altitude is barometric, rounded to 100 ft
  and never below 0. Where there was no receiver
  coverage (oceans, remote areas) the track jumps straight across the gap.
- If a callsign flew several legs that day, the longest is kept.
- Each run keeps yesterday's files for callsigns that didn't fly today, up to
  14 days old.

A missing file (HTTP 404) means the callsign wasn't seen recently. The app then
falls back to a great circle between the airports the passenger picks.

## How it works

1. `workflow/build.yml` runs daily at 06:15 UTC (and on demand). It finds the
   newest `*-planes-readsb-prod-0` release in `adsblol/globe_history_<year>`.
2. It streams the release parts (`.tar.aa`, `.tar.ab`, about 3.5 GB a day)
   straight from GitHub into `build_archive.py`, so the tar is never written to
   disk.
3. The script reads each aircraft's `traces/**/trace_full_<hex>.json`. It
   splits the day into legs using readsb's new-leg flag, long silences and
   callsign changes, then keeps legs that start and end at an airport.
4. It merges in the previous run's output (restored from the Actions cache)
   and publishes `out/` to GitHub Pages.

## Set up (once)

1. Create a new **public** GitHub repository named `flightdeck-flight-archive`
   (the app looks for `https://<user>.github.io/flightdeck-flight-archive/v1/`;
   with another name or account, change `FlightArchiveProvider.publishedBaseURL`
   in `FlightDeck/Model/FlightLookup.swift`).
2. Copy `build_archive.py` to the repository root and `workflow/build.yml` to
   `.github/workflows/build.yml`.
3. In the repository settings, go to **Pages → Build and deployment →
   Source** and choose **GitHub Actions**.
4. Under **Actions**, run *Build flight archive* once by hand
   (*Run workflow*). Later runs happen daily.
5. Set the app's archive base URL to `https://<user>.github.io/<repo>/v1/`.

Public repositories get GitHub Actions minutes and Pages hosting for free. A
run takes roughly 30–60 minutes, most of it downloading the release.

## Licence obligations (ODbL 1.0)

adsb.lol publishes its archive under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/):
"use it freely, just keep it open". For this archive and the app that means:

- **Attribution**: show "Contains data from adsb.lol, ODbL 1.0" wherever the
  tracks are used (the app's menu and about text), and keep `meta.json`'s
  attribution.
- **Share-alike**: this derived database must stay available under the ODbL.
  Publishing it openly on GitHub Pages from a public repository does that.
  Don't move it behind a login or a paywall.
- Airport positions come from [OurAirports](https://ourairports.com/data/),
  which is public domain.

## Test locally

Streaming a whole day needs a fast connection. For a quick check, run it on a
local part of a release:

```
python3 build_archive.py --input part.tar --out /tmp/archive \
    --release v2026.11.21-planes-readsb-prod-0 --max-members 5000
```

A truncated tar is fine. Whatever was read before the end is written out.
