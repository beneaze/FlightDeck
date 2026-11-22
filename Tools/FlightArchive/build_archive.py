#!/usr/bin/env python3
"""Turn one day of adsb.lol's open ADS-B archive into a per-callsign lookup of
the most recently flown track.

    cat v2026.11.21-planes-readsb-prod-0.tar.a? | \\
        python3 build_archive.py --out out --previous previous --release v2026.11.21-planes-readsb-prod-0

Input: a readsb "globe_history" daily release (tar, possibly split into
.tar.aa/.tar.ab parts that are simply concatenated), streamed on stdin or read
from --input. Only traces/**/trace_full_*.json members are used; each holds
one aircraft's day.

Output (static files, published as is):
    out/v1/<first 3 chars>/<CALLSIGN>.json
        {"callsign": "DLH400", "flownOn": "2026-11-21", "origin": "EDDF",
         "destination": "KJFK", "icao24": "3c6444",
         "source": "adsb.lol (ODbL 1.0)", "track": [[lat, lon, altFt], ...]}
    out/v1/meta.json

Data: adsb.lol (https://adsb.lol), ODbL 1.0. Airports: OurAirports (public
domain). The derived database is ODbL as well and must stay openly published.
Only the Python standard library is used.
"""
import argparse
import csv
import gzip
import io
import json
import math
import os
import shutil
import sys
import tarfile
import time
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

AIRPORTS_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
USER_AGENT = "archive-build-script/1.0"
SOURCE = "adsb.lol (ODbL 1.0)"
ATTRIBUTION = "Contains data from adsb.lol (https://adsb.lol), ODbL 1.0. Airports: OurAirports (public domain)."

EARTH_NM = 3440.065
AIRPORT_RADIUS_NM = 6.0          # first/last airborne point must be this close to an airport…
AIRPORT_MAX_ALT_FT = 6000.0      # …and this low
MIN_FLIGHT_NM = 30.0             # shorter hops (pattern work, helicopters) are skipped
GAP_SECONDS = 30 * 60            # a silence this long without the new-leg flag still splits…
GAP_GROUND_SECONDS = 10 * 60     # …or this long if the aircraft was last seen low
LOW_ALT_FT = 3000.0
SIMPLIFY_NM = 0.3
SIMPLIFY_FT = 1000.0
MAX_POINTS = 300
KEEP_DAYS = 14

# readsb trace flags (README-json.md): 1 = stale position, 2 = start of a new
# leg, 4 = vertical rate geometric, 8 = altitude geometric.
FLAG_STALE = 1
FLAG_NEW_LEG = 2


# MARK: - Geometry

def distance_nm(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_NM * math.asin(min(1.0, math.sqrt(h)))


def _to_xyz(lat, lon):
    la, lo = math.radians(lat), math.radians(lon)
    return (math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo), math.sin(la))


def cross_track_nm(p, a, b):
    """Distance of p from the great circle through a and b (nm); falls back to
    the distance to a when a and b coincide."""
    ax, ay, az = _to_xyz(*a)
    bx, by, bz = _to_xyz(*b)
    nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
    norm = math.sqrt(nx * nx + ny * ny + nz * nz)
    if norm < 1e-12:
        return distance_nm(p[0], p[1], a[0], a[1])
    px, py, pz = _to_xyz(*p)
    return abs(math.asin(max(-1.0, min(1.0, (nx * px + ny * py + nz * pz) / norm)))) * EARTH_NM


def douglas_peucker(points, tolerance_nm, tolerance_ft):
    """Iterative Douglas–Peucker on [lat, lon, altFt] points. A point is kept
    when it lies more than `tolerance_nm` off the great circle between the
    kept neighbours, or more than `tolerance_ft` off the straight climb or
    descent between them, so both the lateral path and the vertical profile
    keep their shape."""
    if len(points) < 3:
        return list(points)
    along = [0.0]
    for a, b in zip(points, points[1:]):
        along.append(along[-1] + distance_nm(a[0], a[1], b[0], b[1]))
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        if last - first < 2:
            continue
        a, b = points[first], points[last]
        span = max(along[last] - along[first], 1e-9)
        worst, index = -1.0, -1
        for i in range(first + 1, last):
            lateral = cross_track_nm(points[i][:2], a[:2], b[:2]) / tolerance_nm
            expected = a[2] + (b[2] - a[2]) * (along[i] - along[first]) / span
            vertical = abs(points[i][2] - expected) / tolerance_ft
            score = max(lateral, vertical)
            if score > worst:
                worst, index = score, i
        if worst > 1.0:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def simplify(points):
    tolerance_nm, tolerance_ft = SIMPLIFY_NM, SIMPLIFY_FT
    result = douglas_peucker(points, tolerance_nm, tolerance_ft)
    while len(result) > MAX_POINTS:
        tolerance_nm *= 1.6
        tolerance_ft *= 1.6
        result = douglas_peucker(points, tolerance_nm, tolerance_ft)
    return result


# MARK: - Airports

class Airports:
    """Large and medium airports in 1° buckets for nearest-airport lookups."""

    def __init__(self, csv_text):
        self.buckets = {}
        for row in csv.DictReader(io.StringIO(csv_text)):
            if row["type"] not in ("large_airport", "medium_airport"):
                continue
            code = (row.get("icao_code") or row.get("gps_code") or "").strip().upper()
            if len(code) != 4 or not code.isalnum():
                continue
            try:
                lat, lon = float(row["latitude_deg"]), float(row["longitude_deg"])
            except ValueError:
                continue
            self.buckets.setdefault((math.floor(lat), math.floor(lon)), []).append((code, lat, lon))

    def nearest(self, lat, lon, radius_nm):
        best, best_d = None, radius_nm
        la, lo = math.floor(lat), math.floor(lon)
        for dla in (-1, 0, 1):
            for dlo in (-1, 0, 1):
                key = (la + dla, (lo + dlo + 180) % 360 - 180)
                for code, alat, alon in self.buckets.get(key, ()):
                    d = distance_nm(lat, lon, alat, alon)
                    if d <= best_d:
                        best, best_d = code, d
        return best


def load_airports(cache_path):
    cache = Path(cache_path)
    if not cache.exists() or time.time() - cache.stat().st_mtime > 30 * 86400:
        request = urllib.request.Request(AIRPORTS_URL, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=300) as response:
            data = response.read()
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(data)
    return Airports(cache.read_text(encoding="utf-8"))


# MARK: - Traces

def normalize_callsign(raw):
    """Upper case, no padding or spaces; only plausible ICAO callsigns."""
    if not isinstance(raw, str):
        return None
    callsign = "".join(raw.split()).upper()
    if not (3 <= len(callsign) <= 8) or not callsign.isalnum():
        return None
    # Airline flights: three-letter operator + flight number. Registrations
    # (D-AIXX shows as DAIXX) and military callsigns are skipped.
    if not (callsign[:3].isalpha() and callsign[3:4].isdigit()):
        return None
    return callsign


def altitude_ft(value):
    if value == "ground":
        return 0.0, True
    if isinstance(value, (int, float)):
        return float(value), False
    return None, False


def split_legs(trace):
    """Yield (callsign, points) per leg; points are (t, lat, lon, alt_ft, on_ground)."""
    callsign = None
    leg = []
    leg_callsign = None
    last_t = None
    last_alt = None

    def flush():
        if leg and leg_callsign:
            yield leg_callsign, list(leg)

    for entry in trace:
        if not isinstance(entry, list) or len(entry) < 7:
            continue
        t, lat, lon = entry[0], entry[1], entry[2]
        if lat is None or lon is None:
            continue
        flags = entry[6] if isinstance(entry[6], int) else 0
        details = entry[8] if len(entry) > 8 and isinstance(entry[8], dict) else None
        if details is not None and "flight" in details:
            new = normalize_callsign(details.get("flight"))
            if new != callsign:
                callsign = new
        alt, on_ground = altitude_ft(entry[3])
        gap = last_t is not None and (
            t - last_t > GAP_SECONDS
            or (t - last_t > GAP_GROUND_SECONDS and last_alt is not None and last_alt < LOW_ALT_FT)
        )
        # The callsign usually arrives a few fixes after a leg starts (it is
        # broadcast less often than the position). Those first fixes — the
        # takeoff — belong to the callsign once it shows up, so only a change
        # between two known callsigns splits a leg.
        if leg and leg_callsign is None and callsign is not None:
            leg_callsign = callsign
        changed = leg and callsign is not None and leg_callsign is not None and callsign != leg_callsign
        if (flags & FLAG_NEW_LEG) or gap or changed:
            yield from flush()
            leg = []
        if not leg:
            leg_callsign = callsign
        leg.append((t, float(lat), float(lon), alt, on_ground))
        last_t = t
        if alt is not None:
            last_alt = alt
    yield from flush()


def airborne_ends(points):
    airborne = [p for p in points if not p[4] and p[3] is not None]
    if len(airborne) < 2:
        return None
    return airborne[0], airborne[-1], airborne


def flights_from_trace(doc, airports, day):
    icao24 = str(doc.get("icao", "")).lower()
    for callsign, points in split_legs(doc.get("trace") or []):
        ends = airborne_ends(points)
        if not ends:
            continue
        first, last, airborne = ends
        if first[3] > AIRPORT_MAX_ALT_FT or last[3] > AIRPORT_MAX_ALT_FT:
            continue
        origin = airports.nearest(first[1], first[2], AIRPORT_RADIUS_NM)
        destination = airports.nearest(last[1], last[2], AIRPORT_RADIUS_NM)
        if not origin or not destination or origin == destination:
            continue
        length = sum(distance_nm(a[1], a[2], b[1], b[2]) for a, b in zip(airborne, airborne[1:]))
        if length < MIN_FLIGHT_NM:
            continue
        track = simplify([[p[1], p[2], p[3]] for p in airborne])
        yield {
            "callsign": callsign,
            "flownOn": day,
            "origin": origin,
            "destination": destination,
            "icao24": icao24,
            "source": SOURCE,
            # Barometric altitude: a few hundred feet below zero on the
            # ground at a low airport on a high-pressure day; clamped.
            "track": [[round(p[0], 4), round(p[1], 4), max(0, int(round(p[2] / 100.0) * 100))]
                      for p in track],
            "_length": length,
        }


def read_member(tar, member):
    raw = tar.extractfile(member).read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return json.loads(raw)


def day_of_release(release):
    """'v2026.11.21-planes-readsb-prod-0' -> '2026-11-21'."""
    try:
        return datetime.strptime(release.lstrip("v")[:10], "%Y.%m.%d").date().isoformat()
    except ValueError:
        return date.today().isoformat()


# MARK: - Output

def output_path(root, callsign):
    return Path(root) / "v1" / callsign[:3] / f"{callsign}.json"


def write_json(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, path)


def merge_previous(previous, out, today):
    """Copy the previous day's files that are still fresh and not superseded."""
    prev_root = Path(previous) / "v1"
    if not prev_root.is_dir():
        return 0
    cutoff = (date.fromisoformat(today) - timedelta(days=KEEP_DAYS)).isoformat()
    kept = 0
    for path in prev_root.glob("*/*.json"):
        target = Path(out) / "v1" / path.parent.name / path.name
        if target.exists():
            continue                     # today's flight wins
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if doc.get("flownOn", "") < cutoff:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        kept += 1
    return kept


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", help="release tar (default: stdin)")
    parser.add_argument("--out", required=True, help="output directory (gets v1/…)")
    parser.add_argument("--previous", help="previous output directory to merge")
    parser.add_argument("--release", default="", help="release tag, e.g. v2026.11.21-planes-readsb-prod-0")
    parser.add_argument("--airports-cache", default=".cache/airports.csv")
    parser.add_argument("--max-members", type=int, default=0, help="stop after N trace files (testing)")
    args = parser.parse_args()

    airports = load_airports(args.airports_cache)
    day = day_of_release(args.release)
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    (out / "v1").mkdir(parents=True)

    best = {}                       # callsign -> flight (longest leg of the day)
    members = traces = 0
    truncated = False
    stream = open(args.input, "rb") if args.input else sys.stdin.buffer
    try:
        with tarfile.open(fileobj=stream, mode="r|*") as tar:
            for member in tar:
                if not member.isfile():
                    continue
                name = member.name
                if "/traces/" not in f"/{name}" or "trace_full_" not in name:
                    continue
                members += 1
                try:
                    doc = read_member(tar, member)
                except (OSError, ValueError, EOFError, tarfile.TarError):
                    continue
                traces += 1
                for flight in flights_from_trace(doc, airports, day):
                    current = best.get(flight["callsign"])
                    if current is None or flight["_length"] > current["_length"]:
                        best[flight["callsign"]] = flight
                if args.max_members and members >= args.max_members:
                    break
                if members % 20000 == 0:
                    print(f"… {members} traces, {len(best)} flights", file=sys.stderr)
    except (tarfile.ReadError, EOFError) as error:
        # A truncated stream (test samples, or a failed part) ends the read;
        # everything parsed so far is still written.
        truncated = True
        print(f"stream ended early: {error}", file=sys.stderr)

    for callsign, flight in best.items():
        flight.pop("_length", None)
        write_json(output_path(out, callsign), flight)

    kept = merge_previous(args.previous, out, day) if args.previous else 0
    total = sum(1 for _ in (out / "v1").glob("*/*.json"))
    meta = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "release": args.release,
        "flownOn": day,
        "tracesRead": traces,
        "flightsToday": len(best),
        "flightsCarriedOver": kept,
        "count": total,
        "truncatedInput": truncated,
        "license": "ODbL 1.0",
        "attribution": ATTRIBUTION,
        "format": "v1/<first 3 chars>/<CALLSIGN>.json",
    }
    write_json(out / "v1" / "meta.json", meta)
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
