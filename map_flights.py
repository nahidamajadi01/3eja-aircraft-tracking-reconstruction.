import csv
import html
import webbrowser
from collections import defaultdict
from pathlib import Path

import folium

project_folder = Path(__file__).resolve().parent
csv_path = project_folder / "flight_points.csv"

flights = defaultdict(list)

with csv_path.open(newline="") as file:
    for row in csv.DictReader(file):
        if not row["latitude"] or not row["longitude"]:
            continue

        key = (row["hex_code"], row["flight_number"])
        flights[key].append(row)

flight_map = folium.Map(tiles="OpenStreetMap")
colors = ["blue", "orange", "purple"]
all_locations = []

for index, ((hex_code, flight_number), rows) in enumerate(flights.items()):
    color = colors[index % len(colors)]
    layer = folium.FeatureGroup(
        name=f"{hex_code} — flight {flight_number}"
    )
    segment = []
    observed_locations = []

    for row in rows:
        location = [float(row["latitude"]), float(row["longitude"])]
        gap = float(row["gap_seconds"]) if row["gap_seconds"] else None
        stale = row["is_stale"].lower() in ("true", "t", "1")

        if gap is None or gap > 120 or stale:
            if len(segment) > 1:
                folium.PolyLine(segment, color=color).add_to(layer)
            segment = []

        if stale:
            continue

        segment.append(location)
        observed_locations.append(location)
        all_locations.append(location)

        popup = html.escape(
            f"{row['recorded_at_utc']} UTC | "
            f"Altitude: {row['altitude_raw']}"
        )
        folium.CircleMarker(
            location,
            radius=2,
            color=color,
            fill=True,
            popup=popup,
        ).add_to(layer)

    if len(segment) > 1:
        folium.PolyLine(segment, color=color).add_to(layer)

    if observed_locations:
        folium.Marker(
            observed_locations[0],
            tooltip=f"{hex_code}: first fresh recorded position",
        ).add_to(layer)
        folium.Marker(
            observed_locations[-1],
            tooltip=f"{hex_code}: last fresh recorded position",
        ).add_to(layer)

    layer.add_to(flight_map)

if not all_locations:
    raise ValueError("No usable positions found in flight_points.csv.")

flight_map.fit_bounds(all_locations)
folium.LayerControl(collapsed=False).add_to(flight_map)

map_path = project_folder / "flight_map.html"
flight_map.save(str(map_path))
print(f"Map saved: {map_path}")
webbrowser.open(map_path.as_uri())