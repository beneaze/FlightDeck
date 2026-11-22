#!/usr/bin/env python3
"""Build the app's bundled airport and airline tables.

    python3 Tools/BuildAirports/build_airports.py [airports.csv]

airports.json  - large and medium airports with an ICAO or IATA code, from
                 OurAirports (public domain): https://ourairports.com/data/
airlines.json  - IATA -> ICAO airline designators of airlines still in
                 business, from Wikidata (CC0): https://www.wikidata.org/

Both are written to FlightDeck/Resources/. Only the standard library is used.
"""
import csv
import io
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "FlightDeck" / "Resources"
AIRPORTS_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
WIKIDATA_SPARQL = "https://query.wikidata.org/sparql"
USER_AGENT = "airport-data-build-script/1.0"


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def build_airports(csv_text: str) -> list:
    rows = []
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
    rows.sort(key=lambda r: r["i"])
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
    if len(sys.argv) > 1:
        csv_text = Path(sys.argv[1]).read_text(encoding="utf-8")
    else:
        csv_text = fetch(AIRPORTS_URL).decode("utf-8")
    airports = build_airports(csv_text)
    (OUT / "airports.json").write_text(json.dumps(airports, ensure_ascii=False, separators=(",", ":")),
                                       encoding="utf-8")
    print(f"airports.json: {len(airports)} airports")

    airlines = build_airlines()
    (OUT / "airlines.json").write_text(json.dumps(airlines, separators=(",", ":")), encoding="utf-8")
    print(f"airlines.json: {len(airlines)} airlines")


if __name__ == "__main__":
    main()
