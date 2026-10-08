# 1. Import the tools
from pathlib import Path
import duckdb

# 2. Locate and open our existing database
project_folder = Path(__file__).resolve().parent
database_path = project_folder / "aviation.duckdb"

connection = duckdb.connect(str(database_path), read_only=True)

# 3. Count distinct aircraft under each certificate
operator_counts = connection.execute("""
    SELECT
        "DSGN",
        COUNT(DISTINCT "Registration No.") AS aircraft_count
    FROM raw_faa_fleet
    GROUP BY "DSGN"
    ORDER BY aircraft_count DESC
    LIMIT 20
""").fetchdf()

# 4. Display the results and close the connection
print(operator_counts.to_string(index=False))
connection.close()