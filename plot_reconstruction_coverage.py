
import csv
from collections import Counter
from pathlib import Path

import matplotlib.pyplot as plt

project_folder = Path(__file__).resolve().parent
csv_files = list(
    project_folder.glob("mart_3eja_reconstruction*.csv")
)

if len(csv_files) != 1:
    raise FileNotFoundError(
        f"Expected one reconstruction CSV, found {len(csv_files)}"
    )

with csv_files[0].open(newline="", encoding="utf-8-sig") as file:
    rows = list(csv.DictReader(file))

counts = Counter(row["reconstruction_status"] for row in rows)

labels = [
    "Both airports matched",
    "Departure only",
    "Arrival only",
    "Neither airport",
]

values = [
    counts["both_airports_matched"],
    counts["departure_only"],
    counts["arrival_only"],
    counts["neither_airport"],
]

fig, ax = plt.subplots(figsize=(10, 5))

bars = ax.barh(labels, values)
ax.invert_yaxis()

for bar, value in zip(bars, values):
    ax.text(
        value + 1,
        bar.get_y() + bar.get_height() / 2,
        str(value),
        va="center",
    )

ax.set_xlim(0, max(values) * 1.2)
ax.set_xlabel("Number of provisional airborne segments")
ax.set_title("3EJA — Airport Reconstruction Coverage")
ax.spines["top"].set_visible(False)
ax.spines["right"].set_visible(False)

plt.tight_layout()

output_path = project_folder / "reconstruction_coverage.png"
plt.savefig(output_path, dpi=200)
plt.show()

print(f"Chart saved: {output_path}")
