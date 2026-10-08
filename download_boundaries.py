from pathlib import Path
from datetime import date
import csv
import gzip
import json
import urllib.request
import urllib.error

project_folder = Path(__file__).resolve().parent
request_file = project_folder / "boundary_requests.csv"
tracking_folder = project_folder / "tracking"
report_file = project_folder / "boundary_download_report.csv"

tracking_folder.mkdir(exist_ok=True)


def validate_tracking(data, hex_code):
    if not isinstance(data, dict):
        raise ValueError("JSON must contain an object")

    if str(data.get("icao", "")).lower() != hex_code:
        raise ValueError("Aircraft code does not match the request")

    timestamp = data.get("timestamp")
    if isinstance(timestamp, bool) or not isinstance(timestamp, (int, float)):
        raise ValueError("Missing or invalid reference timestamp")

    if not isinstance(data.get("trace"), list):
        raise ValueError("Missing or invalid trace array")

    return len(data["trace"])


with request_file.open(encoding="utf-8-sig", newline="") as file:
    requests = sorted({
        (
            row["hex_code"].strip().lower(),
            row["adjacent_date"].strip()
        )
        for row in csv.DictReader(file)
    })

# Check the request list before downloading.
for hex_code, requested_date in requests:
    if len(hex_code) != 6 or any(
        character not in "0123456789abcdef"
        for character in hex_code
    ):
        raise ValueError(f"Invalid aircraft code: {hex_code}")

    date.fromisoformat(requested_date)

    if requested_date not in {"2026-10-01", "2026-10-03"}:
        raise ValueError(f"Unexpected adjacent date: {requested_date}")

report_columns = [
    "hex_code",
    "requested_date",
    "status",
    "position_count",
    "source_filename",
    "error"
]

with report_file.open("w", encoding="utf-8", newline="") as file:
    writer = csv.DictWriter(file, fieldnames=report_columns)
    writer.writeheader()

    for hex_code, requested_date in requests:
        filename = f"{requested_date}_{hex_code}.json"
        output_file = tracking_folder / filename

        result = {
            "hex_code": hex_code,
            "requested_date": requested_date,
            "status": "",
            "position_count": "",
            "source_filename": filename,
            "error": ""
        }

        try:
            reused = False

            if output_file.exists():
                try:
                    data = json.loads(
                        output_file.read_text(encoding="utf-8")
                    )
                    position_count = validate_tracking(data, hex_code)
                    reused = True
                except (ValueError, OSError):
                    print(f"{filename}: invalid cached file; requesting again")

            if not reused:
                date_path = requested_date.replace("-", "/")
                url = (
                    f"https://globe.adsb.lol/globe_history/{date_path}/"
                    f"traces/{hex_code[-2:]}/trace_full_{hex_code}.json"
                )

                with urllib.request.urlopen(url, timeout=30) as response:
                    contents = response.read()

                if contents.startswith(b"\x1f\x8b"):
                    contents = gzip.decompress(contents)

                data = json.loads(contents)
                position_count = validate_tracking(data, hex_code)

                temporary_file = output_file.with_suffix(".json.tmp")
                temporary_file.write_text(
                    json.dumps(data),
                    encoding="utf-8"
                )
                temporary_file.replace(output_file)

            result["position_count"] = position_count

            if position_count == 0:
                result["status"] = "empty_trace"
            else:
                result["status"] = "reused" if reused else "downloaded"

        except urllib.error.HTTPError as error:
            result["status"] = (
                "not_found_404" if error.code == 404 else "http_error"
            )
            result["error"] = str(error)

        except Exception as error:
            result["status"] = "other_error"
            result["error"] = str(error)

        writer.writerow(result)
        file.flush()

        print(f"{requested_date} {hex_code}: {result['status']}")

print(f"\nAircraft/date requests processed: {len(requests)}")
print(f"Tracking folder: {tracking_folder}")
print(f"Download report: {report_file}")