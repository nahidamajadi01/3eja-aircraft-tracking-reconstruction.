
import csv
import html
import webbrowser
from collections import Counter
from pathlib import Path

import folium

project_folder = Path(__file__).resolve().parent
csv_files = list(project_folder.glob("mart_3eja_reconstruction*.csv"))

if len(csv_files) != 1:
    raise FileNotFoundError(
        f"Expected one reconstruction CSV, found {len(csv_files)}"
    )

csv_path = csv_files[0]
output_path = project_folder / "validated_routes_map.html"

# Airport coordinates for the candidate routes
# Coordinates are approximate airport reference points.
airports = {
    "KAPC": (38.2132, -122.2807),
    "KNUQ": (37.4161, -122.0491),
    "KATW": (44.2581, -88.5191),
    "KFCM": (44.8272, -93.4571),
    "KAUS": (30.1975, -97.6664),
    "KAVL": (35.4362, -82.5418),
    "KGSO": (36.0978, -79.9373),
    "KTEB": (40.8501, -74.0608),
    "KHIO": (45.5404, -122.9498),
    "KIAD": (38.9445, -77.4558),
    "KOPF": (25.9070, -80.2784),
    "KPDK": (33.8756, -84.3020),
    "KSAT": (29.5337, -98.4698),
    "KSNA": (33.6757, -117.8682),
    "KSBA": (34.4262, -119.8404),
    "KLRD": (27.5438, -99.4616),
}

with csv_path.open(newline="", encoding="utf-8-sig") as file:
    rows = list(csv.DictReader(file))

if not rows:
    raise ValueError("The reconstruction CSV is empty.")

status_counts = Counter(
    row["reconstruction_status"] for row in rows
)

candidate_routes = [
    row for row in rows
    if row["reconstruction_status"] == "both_airports_matched"
]

flight_map = folium.Map(
    location=[39.5, -98.35],
    zoom_start=4,
    tiles="OpenStreetMap",
)

route_layer = folium.FeatureGroup(
    name="Candidate airport pairs",
    show=True,
)

all_locations = []
unmapped = []

for row in candidate_routes:
    departure = (row.get("departure_airport") or "").strip()
    arrival = (row.get("arrival_airport") or "").strip()

    if departure not in airports or arrival not in airports:
        unmapped.append(
            (row["hex_code"], departure, arrival)
        )
        continue

    start = airports[departure]
    end = airports[arrival]

    hex_code = row["hex_code"]
    segment = row["segment_number"]

    popup_text = (
        f"Aircraft: {hex_code}<br>"
        f"Segment: {segment}<br>"
        f"Candidate pair: {departure} → {arrival}<br>"
        f"First airborne: {html.escape(row['first_airborne_time'])}<br>"
        f"Last airborne: {html.escape(row['last_airborne_time'])}<br>"
        f"Observed span: {html.escape(row['observed_span_minutes'])} min<br>"
        "Airport pair is provisional; line is not an observed track."
    )

    folium.PolyLine(
        locations=[start, end],
        color="blue",
        weight=2,
        opacity=0.7,
        dash_array="6, 8",
        tooltip=f"{departure} → {arrival}",
        popup=folium.Popup(popup_text, max_width=350),
    ).add_to(route_layer)

    folium.CircleMarker(
        location=start,
        radius=5,
        color="green",
        fill=True,
        fill_opacity=0.9,
        tooltip=f"Departure candidate: {departure}",
    ).add_to(route_layer)

    folium.CircleMarker(
        location=end,
        radius=5,
        color="red",
        fill=True,
        fill_opacity=0.9,
        tooltip=f"Arrival candidate: {arrival}",
    ).add_to(route_layer)

    all_locations.extend([start, end])

route_layer.add_to(flight_map)

if all_locations:
    flight_map.fit_bounds(all_locations)

folium.LayerControl(collapsed=False).add_to(flight_map)

legend = """
<div style="
    position: fixed;
    bottom: 25px;
    left: 25px;
    z-index: 9999;
    background: white;
    padding: 12px;
    border: 1px solid #999;
    border-radius: 6px;
    font-size: 13px;
">
<b>3EJA — Candidate Airport Pairs</b><br>
<span style="color:green;">●</span> Departure candidate<br>
<span style="color:red;">●</span> Arrival candidate<br>
<span style="color:blue;">- - -</span> Straight-line connection<br>
<small>Not a verified flight track</small>
</div>
"""

flight_map.get_root().html.add_child(
    folium.Element(legend)
)

flight_map.save(str(output_path))

print(f"Total provisional segments: {len(rows)}")
print(f"Both airports matched: {len(candidate_routes)}")
print(f"Departure only: {status_counts['departure_only']}")
print(f"Arrival only: {status_counts['arrival_only']}")
print(f"Neither airport: {status_counts['neither_airport']}")
print(f"Candidate pairs not mapped: {len(unmapped)}")

for item in unmapped:
    print("Missing airport coordinates:", item)

print(f"Map saved: {output_path}")
webbrowser.open(output_path.as_uri())
