"""Run pure Swift Cloudflare model fixtures, without credentials or the app.

    python3 Tests/traffic-analytics.py
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/ControlCenter/CloudflareStore.swift").read_text()
models = source.split("/// Website traffic from Cloudflare", 1)[0]
fixtures = r'''
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func group(_ date: String, _ requests: Int, _ visitors: Int, _ countries: [[String: Any]]) -> [String: Any] {
    ["dimensions": ["date": date], "uniq": ["uniques": visitors],
     "sum": ["requests": requests, "pageViews": requests / 2, "bytes": requests * 100,
             "cachedRequests": requests / 2, "countryMap": countries,
             "responseStatusMap": [["edgeResponseStatus": 200, "requests": requests]]]]
}
let base = CFZone(id: "zone", name: "example.test")
let zone = base.withDailyGroups([
    group("2026-10-14", 90, 12, [["clientCountryName": " id ", "requests": 20],
                               ["clientCountryName": "US", "requests": 30],
                               ["clientCountryName": "", "requests": 4]]),
    group("2026-10-13", 10, 8, [["clientCountryName": "ID", "requests": 5],
                              ["clientCountryName": "US", "requests": 2]])
])
require(zone.days.map(\.date) == ["2026-10-13", "2026-10-14"], "Daily buckets must be chronologically sorted")
require(zone.latestDay?.date == "2026-10-14" && zone.latestDay?.visitors == 12, "Latest unique-IP metric must use the latest date, not sum")
require(zone.visitors == 20 && zone.requests == 100 && zone.pageViews == 50, "Totals must preserve the supplied daily counts")
require(zone.countries.first?.0 == "US" && zone.countries.first?.1 == 32, "Country requests must sum across days and rank descending")
require(zone.countries.first { $0.0 == "ID" }?.1 == 25, "Country codes must normalize case and whitespace")
require(zone.countries.first { $0.0 == "XX" }?.1 == 4, "Unknown origins must remain represented")
require(zone.countryRequests == 61 && zone.requests - zone.countryRequests == 39, "Unattributed requests must remain distinguishable")
require(zone.statuses.first?.0 == 200 && zone.statuses.first?.1 == 100, "Status counts must retain all days")
let manyCountries = ["US", "ID", "SG", "AU", "DE", "FR", "JP", "BR", "CA"].enumerated().map {
    ["clientCountryName": $0.element, "requests": $0.offset + 1] as [String: Any]
}
let longTail = base.withDailyGroups([group("2026-10-14", 45, 9, manyCountries)])
require(longTail.countries.count == 9 && longTail.countryRequests == 45, "Map must retain countries beyond the previous six-country limit")
let empty = zone.withDailyGroups([])
require(empty.days.isEmpty && empty.countries.isEmpty && empty.latestDay == nil, "Refresh with no records must clear stale data")
print("Cloudflare analytics fixtures passed (daily uniques, full countries, normalization, unknown origins, totals, empty refresh).")
'''
result = subprocess.run(["swift", "-"], input=models + fixtures, text=True, capture_output=True)
print(result.stdout, end="")
if result.returncode:
    print(result.stderr, end="")
raise SystemExit(result.returncode)
