#!/usr/bin/env python3
"""Build the bundled US terminal procedures from the FAA's CIFP.

    python3 Tools/BuildProcedures/build_procedures.py path/to/FAACIFP18

The FAA publishes its Coded Instrument Flight Procedures (CIFP) every 28
days in ARINC 424 format, in the public domain:
https://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/cifp/

This keeps the SIDs, STARs and approaches of the airports in the app's
airport table (FlightDeck/Resources/airports.json), resolves every fix to a
position, and writes FlightDeck/Resources/procedures-us.json:

    { "KSFO": { "SID": { "CIITY3": { "RW10L": [leg, ...], ... } },
                "STAR": { ... },
                "APP":  { "I28R": { "": [final legs], "ARCHI": [transition legs] } } } }

A leg is [fix ident, lat, lon, path terminator, altitude description,
altitude 1, altitude 2, magnetic course, distance, flags], with lat/lon null
for legs that end at no fix (heading or course to an altitude, vectors).
Flags: "M" marks the missed approach point, after which an approach's legs
are left out. Route types, transitions and field positions follow ARINC 424
as the X-Plane CIFP specification describes it, so the app's importer for
X-Plane CIFP files reads the same fields.

Only the standard library is used.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "FlightDeck" / "Resources"


def col(line: str, start: int, end: int) -> str:
    """ARINC 424 columns are 1-based and inclusive."""
    return line[start - 1:end]


def coordinate(lat: str, lon: str):
    """N37461570 / W121423091 → degrees (DDMMSS.ss)."""
    lat, lon = lat.strip(), lon.strip()
    if len(lat) != 9 or len(lon) != 10:
        return None
    try:
        la = int(lat[1:3]) + int(lat[3:5]) / 60 + int(lat[5:9]) / 100 / 3600
        lo = int(lon[1:4]) + int(lon[4:6]) / 60 + int(lon[6:10]) / 100 / 3600
    except ValueError:
        return None
    if lat[0] == "S":
        la = -la
    if lon[0] == "W":
        lo = -lo
    return round(la, 5), round(lo, 5)


def altitude(text: str):
    text = text.strip()
    if not text:
        return None
    if text.startswith("FL"):
        try:
            return int(text[2:]) * 100
        except ValueError:
            return None
    try:
        return int(text)
    except ValueError:
        return None


def number(text: str, scale: float):
    text = text.strip()
    if not text or not text.lstrip("-").isdigit():
        return None
    return int(text) / scale


def main() -> None:
    source = Path(sys.argv[1])
    airports = {a["i"] for a in json.loads((RESOURCES / "airports.json").read_text(encoding="utf-8"))
                if a.get("k") in ("US", "PR", "VI", "GU", "AS", "MP")}

    # Pass 1: positions of everything a procedure can name.
    terminal = {}     # (airport, ident) -> pos   terminal waypoints, terminal NDBs, runways
    enroute = {}      # (ident, region) -> pos     enroute waypoints
    navaids = {}      # (ident, region) -> pos     VHF navaids and NDBs
    lines = source.read_text(encoding="latin-1").splitlines()
    for line in lines:
        if len(line) < 51 or line[0] != "S":
            continue
        section = line[4]
        if section == "P" and line[12] in "CGN":
            airport = col(line, 7, 10).strip()
            ident = col(line, 14, 18).strip()
            pos = coordinate(col(line, 33, 41), col(line, 42, 51))
            if pos:
                terminal[(airport, ident)] = pos
        elif section == "E" and line[5] == "A":
            pos = coordinate(col(line, 33, 41), col(line, 42, 51))
            if pos:
                enroute[(col(line, 14, 18).strip(), col(line, 20, 21))] = pos
        elif section == "D":
            ident = col(line, 14, 17).strip()
            region = col(line, 20, 21)
            pos = coordinate(col(line, 33, 41), col(line, 42, 51))
            if not pos and len(line) >= 74:   # DME only: its own position
                pos = coordinate(col(line, 56, 64), col(line, 65, 74))
            if pos:
                navaids[(ident, region)] = pos

    def resolve(airport, ident, region, sec, sub):
        if not ident:
            return None
        if sec == "P":
            return terminal.get((airport, ident))
        if sec == "E":
            return enroute.get((ident, region))
        if sec == "D":
            return navaids.get((ident, region))
        return terminal.get((airport, ident)) or enroute.get((ident, region)) or navaids.get((ident, region))

    # Pass 2: procedure legs.
    kinds = {"D": "SID", "E": "STAR", "F": "APP"}
    out = {}
    unresolved = 0
    for line in lines:
        if len(line) < 94 or line[0] != "S" or line[4] != "P" or line[12] not in kinds:
            continue
        airport = col(line, 7, 10).strip()
        if airport not in airports:
            continue
        if col(line, 39, 39) not in ("0", "1", " "):   # continuation records
            continue
        kind = kinds[line[12]]
        ident = col(line, 14, 19).strip()
        route_type = col(line, 20, 20)
        transition = col(line, 21, 25).strip()
        fix = col(line, 30, 34).strip()
        pos = resolve(airport, fix, col(line, 35, 36), col(line, 37, 37), col(line, 38, 38))
        if fix and not pos:
            unresolved += 1
        description = col(line, 40, 43)
        leg = [
            fix,
            pos[0] if pos else None,
            pos[1] if pos else None,
            col(line, 48, 49).strip(),
            col(line, 83, 83).strip(),
            altitude(col(line, 85, 89)),
            altitude(col(line, 90, 94)),
            number(col(line, 71, 74), 10),
            number(col(line, 75, 78), 10),
            "M" if description[3:4] == "M" else "",
        ]
        # An approach's final segment has a route type other than "A"
        # (transition) and no transition name; keep it under "".
        if kind == "APP" and route_type != "A":
            transition = ""
        procedures = out.setdefault(airport, {}).setdefault(kind, {}).setdefault(ident, {})
        procedures.setdefault(transition, []).append(leg)

    # Approaches end at the missed approach point.
    for procs in out.values():
        for ident, transitions in procs.get("APP", {}).items():
            final = transitions.get("")
            if final:
                for i, leg in enumerate(final):
                    if leg[9] == "M":
                        transitions[""] = final[: i + 1]
                        break

    target = RESOURCES / "procedures-us.json"
    target.write_text(json.dumps(out, separators=(",", ":")), encoding="utf-8")
    count = sum(len(p) for a in out.values() for p in a.values())
    print(f"procedures-us.json: {count} procedures at {len(out)} airports, "
          f"{target.stat().st_size // 1024} KB, {unresolved} fixes unresolved")


if __name__ == "__main__":
    main()
