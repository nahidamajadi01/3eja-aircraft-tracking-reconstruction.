from pathlib import Path
import csv
import urllib.request
import urllib.error
import gzip
import json

project_folder = Path(__file__).resolve().parent
lookup_path = project_folder / "aircraft_lookup.csv"
output_folder = project_folder / "tracking"
report_path = project_folder / "download_report.csv"

analysis_date = "2026-10-02"
date_path = analysis_date.replace("-", "/")

output_folder.mkdir(exist_ok=True)

with lookup_path.open(encoding="utf-8-sig", newline="") as file:
    aircraft_rows = list(csv.DictReader(file))

aircraft_by_hex = {}

for row in aircraft_rows:
    if row["lookup_status"] == "Ready":
        hex_code = row["hex_codes"].strip().lower()
        aircraft_by_hex.setdefault(hex_code, []).append(
            row["registration_key"]
        )


def check_tracking(data, expected_hex):
    if not isinstance(data, dict):
        raise ValueError("JSON is not an object")

    if str(data.get("icao", "")).lower() != expected_hex:
        raise ValueError("Aircraft hex does not match requested aircraft")

    if not isinstance(data.get("trace"), list):
        raise ValueError("Missing or invalid trace array")

    if not isinstance(data.get("timestamp"), (int, float)):
        raise ValueError("Missing or invalid reference timestamp")

    return len(data["trace"])


report_columns = [
    "registration_key",
    "hex_code",
    "analysis_date",
    "status",
    "http_status",
    "tracking_points",
    "source_filename",
    "error",
]

with report_path.open("w", encoding="utf-8", newline="") as report_file:
    writer = csv.DictWriter(report_file, fieldnames=report_columns)
    writer.writeheader()

    for hex_code, registrations in sorted(aircraft_by_hex.items()):
        file_path = output_folder / f"{analysis_date}_{hex_code}.json"

        result = {
            "registration_key": "; ".join(registrations),
            "hex_code": hex_code,
            "analysis_date": analysis_date,
            "status": "",
            "http_status": "",
            "tracking_points": "",
            "source_filename": "",
            "error": "",
        }

        # Reuse existing files only after checking their contents.
        if file_path.exists():
            try:
                tracking_data = json.loads(
                    file_path.read_text(encoding="utf-8")
                )
                point_count = check_tracking(tracking_data, hex_code)

                result["status"] = (
                    "reused" if point_count else "reused_empty_trace"
                )
                result["tracking_points"] = point_count
                result["source_filename"] = file_path.name

            except (OSError, ValueError) as error:
                print(f"{hex_code}: existing file invalid; requesting again")

        if not result["status"]:
            url = (
                f"https://globe.adsb.lol/globe_history/{date_path}/"
                f"traces/{hex_code[-2:]}/trace_full_{hex_code}.json"
            )

            try:
                with urllib.request.urlopen(url, timeout=30) as response:
                    result["http_status"] = response.status
                    contents = response.read()

                if contents.startswith(b"\x1f\x8b"):
                    contents = gzip.decompress(contents)

                tracking_data = json.loads(contents)
                point_count = check_tracking(tracking_data, hex_code)

                file_path.write_text(
                    json.dumps(tracking_data),
                    encoding="utf-8",
                )

                result["status"] = (
                    "downloaded" if point_count else "empty_trace"
                )
                result["tracking_points"] = point_count
                result["source_filename"] = file_path.name

            except urllib.error.HTTPError as error:
                result["http_status"] = error.code
                result["status"] = (
                    "not_found_404" if error.code == 404 else "http_error"
                )
                result["error"] = str(error)

            except urllib.error.URLError as error:
                result["status"] = "network_error"
                result["error"] = str(error.reason)

            except (OSError, ValueError, EOFError) as error:
                result["status"] = "file_or_data_error"
                result["error"] = str(error)

        writer.writerow(result)
        report_file.flush()

        print(f"{hex_code}: {result['status']}")

print(f"\nAircraft hex codes processed: {len(aircraft_by_hex)}")
print(f"Tracking folder: {output_folder}")
print(f"Download report: {report_path}")



