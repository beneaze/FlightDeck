#!/usr/bin/env python3
"""Build the app's bundled airport, runway, navaid and airline tables.

    python3 Tools/BuildAirports/build_airports.py [data-directory]

airports.json  - large and medium airports with an ICAO or IATA code, from
                 OurAirports (public domain): https://ourairports.com/data/
runways.json   - the runway ends of those airports (OurAirports): ident,
                 threshold position, elevation, true heading, length
navaids.json   - VORs, NDBs, DMEs and TACANs worldwide (OurAirports), the
                 points a flight plan can be built from
airlines.json  - IATA -> ICAO airline designators of airlines still in
                 business, from Wikidata (CC0): https://www.wikidata.org/

The data directory, when given, holds airports.csv, runways.csv and
navaids.csv already downloaded; otherwise they are fetched.

Both are written to FlightDeck/Resources/. Only the standard library is used.
"""
import csv
import io
import json
import math
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "FlightDeck" / "Resources"
OURAIRPORTS = "https://davidmegginson.github.io/ourairports-data/"
WIKIDATA_SPARQL = "https://query.wikidata.org/sparql"
USER_AGENT = "airport-data-build-script/1.0"


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def build_airports(csv_text: str):
    """The airport rows, and OurAirports ident -> our code for those kept."""
    rows = []
    idents = {}
    for row in csv.DictReader(io.StringIO(csv_text)):
        if row["type"] not in ("large_airport", "medium_airport"):
            continue
        if row.get("scheduled_service") != "yes" and row["type"] != "large_airport":
            continue
        icao = (row.get("icao_code") or row.get("gps_code") or "").strip().upper()
        iata = (row.get("iata_code") or "").strip().upper() or None
        if len(icao) != 4 and not iata:
            continue
        if not icao:
            icao = row["ident"].strip().upper()
        try:
            lat, lon = float(row["latitude_deg"]), float(row["longitude_deg"])
        except ValueError:
            continue
        try:
            elevation = float(row["elevation_ft"])
        except ValueError:
            elevation = 0.0
        entry = {
            "i": icao,
            "n": row["name"].strip(),
            "c": (row.get("municipality") or "").strip(),
            "k": row["iso_country"].strip(),
            "y": round(lat, 4),
            "x": round(lon, 4),
            "e": round(elevation),
            "l": row["type"] == "large_airport",
        }
        if iata:
            entry["a"] = iata
        rows.append(entry)
        idents[row["ident"].strip().upper()] = icao
    rows.sort(key=lambda r: r["i"])
    return rows, idents


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def course(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def build_runways(csv_text: str, idents: dict) -> dict:
    """Runway ends per airport: [ident, lat, lon, elevation ft, true
    heading, length ft, displaced threshold ft]. Ends without a position
    (helipads, unsurveyed strips) and closed runways are left out."""
    table = {}
    for row in csv.DictReader(io.StringIO(csv_text)):
        code = idents.get(row["airport_ident"].strip().upper())
        if not code or row.get("closed") == "1":
            continue
        length = number(row["length_ft"]) or 0
        ends = []
        for this, other in (("le", "he"), ("he", "le")):
            ident = (row[f"{this}_ident"] or "").strip().upper()
            lat, lon = number(row[f"{this}_latitude_deg"]), number(row[f"{this}_longitude_deg"])
            olat, olon = number(row[f"{other}_latitude_deg"]), number(row[f"{other}_longitude_deg"])
            if not ident or ident.startswith("H") or lat is None or lon is None:
                continue
            heading = number(row[f"{this}_heading_degT"])
            if heading is None and olat is not None and olon is not None:
                heading = course(lat, lon, olat, olon)
            if heading is None:
                continue
            elevation = number(row[f"{this}_elevation_ft"])
            ends.append([ident, round(lat, 5), round(lon, 5),
                         round(elevation) if elevation is not None else None,
                         round(heading, 1), round(length),
                         round(number(row[f"{this}_displaced_threshold_ft"]) or 0)])
        if ends:
            table.setdefault(code, []).extend(ends)
    for ends in table.values():
        ends.sort(key=lambda e: e[0])
    return dict(sorted(table.items()))


NAVAID_TYPES = {"VOR": "V", "VOR-DME": "VD", "VORTAC": "VT", "TACAN": "T",
                "NDB": "N", "NDB-DME": "ND", "DME": "D"}


def build_navaids(csv_text: str) -> list:
    """Navaids: [ident, name, type, lat, lon, frequency kHz]."""
    rows = []
    for row in csv.DictReader(io.StringIO(csv_text)):
        kind = NAVAID_TYPES.get(row["type"].strip())
        ident = row["ident"].strip().upper()
        lat, lon = number(row["latitude_deg"]), number(row["longitude_deg"])
        if not kind or not ident or lat is None or lon is None:
            continue
        rows.append([ident, row["name"].strip(), kind, round(lat, 5), round(lon, 5),
                     round(number(row["frequency_khz"]) or 0)])
    rows.sort(key=lambda r: (r[0], r[3]))
    return rows


SPARQL = """
SELECT ?iata ?icao WHERE {
  ?airline wdt:P229 ?iata ; wdt:P230 ?icao .
  FILTER NOT EXISTS { ?airline wdt:P576 ?dissolved }
  FILTER (STRLEN(?iata) = 2 && STRLEN(?icao) = 3)
}
"""


def build_airlines() -> dict:
    url = WIKIDATA_SPARQL + "?" + urllib.parse.urlencode({"query": SPARQL, "format": "json"})
    data = json.loads(fetch(url))
    table = {}
    counts = {}
    for binding in data["results"]["bindings"]:
        iata = binding["iata"]["value"].upper()
        icao = binding["icao"]["value"].upper()
        if not icao.isalpha():
            continue
        counts.setdefault(iata, {}).setdefault(icao, 0)
        counts[iata][icao] += 1
    for iata, options in counts.items():
        # An IATA code reused by several live airlines is ambiguous; keep it
        # only when one ICAO code clearly dominates.
        ranked = sorted(options.items(), key=lambda kv: -kv[1])
        if len(ranked) == 1 or ranked[0][1] > ranked[1][1]:
            table[iata] = ranked[0][0]
    return dict(sorted(table.items()))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    def source(name: str) -> str:
        if len(sys.argv) > 1:
            return (Path(sys.argv[1]) / f"{name}.csv").read_text(encoding="utf-8")
        return fetch(OURAIRPORTS + f"{name}.csv").decode("utf-8")

    def save(name: str, value) -> None:
        (OUT / name).write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")),
                                encoding="utf-8")

    airports, idents = build_airports(source("airports"))
    save("airports.json", airports)
    print(f"airports.json: {len(airports)} airports")

    runways = build_runways(source("runways"), idents)
    save("runways.json", runways)
    print(f"runways.json: {sum(len(e) for e in runways.values())} runway ends at {len(runways)} airports")

    navaids = build_navaids(source("navaids"))
    save("navaids.json", navaids)
    print(f"navaids.json: {len(navaids)} navaids")

    airlines = build_airlines()
    (OUT / "airlines.json").write_text(json.dumps(airlines, separators=(",", ":")), encoding="utf-8")
    print(f"airlines.json: {len(airlines)} airlines")


if __name__ == "__main__":
    main()
